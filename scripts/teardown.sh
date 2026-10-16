#!/usr/bin/env bash
# Remove everything scripts/setup.sh created, and prove it's gone.
#
#   scripts/teardown.sh                    # substrate + cluster + bucket + IAM (keeps the project)
#   scripts/teardown.sh --delete-project   # ...and delete the project (stops all billing;
#                                          #    recoverable for 30 days)
#   scripts/teardown.sh --verify-only      # just check nothing billable is left
#
# Safety: it only ever acts on $PROJECT_ID from scripts/env.sh, and only if that project
# carries the label setup.sh puts on projects it creates.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/scripts/env.sh"
MODE=${1:-}
case "$MODE" in ""|--delete-project|--verify-only) ;; *) echo "unknown option: $MODE" >&2; exit 2 ;; esac
TARGET="$PROJECT_ID"
LABEL=purpose=substrate-field-test

# count lines of a gcloud listing; fail loudly instead of counting an error as "0 resources"
count() {
  local out; out=$(gcloud "$@" --project "$TARGET" --format="value(name)" 2>&1) || { echo "ERR"; return; }
  [ -z "$out" ] && echo 0 || echo "$out" | wc -l | tr -d ' '
}

verify() {
  local left=0 n
  echo "== verify ($TARGET)"
  for what in "container clusters list" "compute instances list" "compute disks list" \
              "compute addresses list" "storage buckets list" "artifacts repositories list"; do
    # shellcheck disable=SC2086
    n=$(count $what)
    printf '  %-30s %s\n' "$what" "$n"; [ "$n" = 0 ] || left=1
  done
  [ $left = 0 ] && echo "  nothing billable left" || echo "  RESOURCES REMAIN (or a listing failed: ERR)"
  return $left
}

if [ "$MODE" = --verify-only ]; then verify; exit; fi

labels=$(gcloud projects describe "$TARGET" --format="value(labels)" 2>/dev/null) ||
  { echo "project $TARGET not found or not accessible" >&2; exit 1; }
case "$labels" in *"${LABEL%%=*}=${LABEL#*=}"*) ;; *)
  echo "refusing: project $TARGET lacks label $LABEL, so setup.sh did not create it" >&2; exit 1 ;; esac

if [ -f "$SUBSTRATE_DIR/.ate-dev-env.sh" ]; then
  cd "$SUBSTRATE_DIR"; source .ate-dev-env.sh
  if [ "$PROJECT_ID" != "$TARGET" ]; then
    echo "refusing: $SUBSTRATE_DIR/.ate-dev-env.sh targets $PROJECT_ID, env.sh targets $TARGET" >&2; exit 1
  fi
  export KUBECTL_CONTEXT="gke_${TARGET}_${ZONE}_${CLUSTER_NAME}"
  echo "== remove benchmark workloads, demos and ate-system"
  ./benchmarking/workloads/deploy.sh --delete || true
  ./hack/install-ate.sh --delete-all || true
  echo "== remove cloud resources (upstream teardown: dashboards, node pool, cluster, bucket, IAM)"
  ./hack/teardown.sh --all || echo "upstream teardown reported errors; see above"
else
  echo "no $SUBSTRATE_DIR/.ate-dev-env.sh; skipping in-cluster cleanup"
fi

if [ "$MODE" = --delete-project ]; then
  echo "== delete project $TARGET"
  gcloud projects delete "$TARGET" --quiet || { echo "FAILED to delete $TARGET" >&2; exit 1; }
  gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" \
    --format="value(name,displayName)" | awk -v n="$TARGET-budget" '$2==n{print $1}' |
    while read -r b; do gcloud billing budgets delete "$b" --quiet; done
  echo "project deleted; billing has stopped. 'gcloud projects undelete $TARGET' within 30 days."
else
  verify
fi
echo "Local: hack/delete-kind-cluster.sh (if you used kind), and revoke any API key you gave the demos."
