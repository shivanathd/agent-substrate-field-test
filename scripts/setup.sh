#!/usr/bin/env bash
# Stand up everything the field test needs, from nothing, in a throwaway GCP project.
#
#   1. project + billing + budget alert
#   2. substrate checkout pinned to $SUBSTRATE_REF (+ our one-line macOS bash 3.2 fix)
#   3. upstream setup-gcp bootstrap: GKE, snapshot bucket, IAM, dashboards       (~6 min)
#   4. upstream install: ate-system + counter, sandbox demos                     (~16 min first time)
#   5. optional: claude-code-multiplex demo (needs ANTHROPIC_API_KEY)
#   6. benchmark harness: locust image + IAM for its results upload              (~12 min on arm64)
#
# Measured on an arm64 Mac over a home connection: ~45-60 min end to end, most of it image
# builds under amd64 emulation. On an amd64 Linux box expect roughly half.
#
# Usage: cp scripts/env.example.sh scripts/env.sh && $EDITOR scripts/env.sh && scripts/setup.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
source "$HERE/scripts/env.sh"
step() { printf '\n\033[1m== %s  (%s)\033[0m\n' "$*" "$(date +%H:%M:%S)"; }

for c in gcloud kubectl go docker git python3; do command -v $c >/dev/null || { echo "missing: $c"; exit 1; }; done
python3 -c 'import yaml, zstandard' 2>/dev/null || { echo "missing python modules: pip install pyyaml zstandard"; exit 1; }
# Only for microVM runs (hack/install-microvm-deps.sh untars a .tar.zst after a 924 MB download):
command -v zstd >/dev/null || echo "note: no zstd CLI; install it before running hack/install-microvm-deps.sh"
gcloud auth print-access-token >/dev/null 2>&1 || { echo "run: gcloud auth login"; exit 1; }
gcloud auth application-default print-access-token >/dev/null 2>&1 || { echo "run: gcloud auth application-default login"; exit 1; }

step "1. project, billing, budget"
LABEL=purpose=substrate-field-test   # teardown.sh refuses any project without it
if labels=$(gcloud projects describe "$PROJECT_ID" --format="value(labels)" 2>/dev/null); then
  case "$labels" in *"$LABEL"*) echo "reusing $PROJECT_ID (created by this script)" ;; *)
    echo "refusing: project $PROJECT_ID exists and was not created by this script (no $LABEL label)." >&2
    echo "Pick a new PROJECT_ID in scripts/env.sh." >&2; exit 1 ;; esac
else
  gcloud projects create "$PROJECT_ID" ${ORG_ID:+--organization="$ORG_ID"} \
    --name="Substrate field test" --labels="$LABEL"
fi
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" >/dev/null
gcloud services enable billingbudgets.googleapis.com container.googleapis.com compute.googleapis.com --project "$PROJECT_ID"
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT" --format="value(displayName)" | grep -x "$PROJECT_ID-budget" >/dev/null ||
  gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" --display-name="$PROJECT_ID-budget" \
    --budget-amount="${BUDGET_USD}USD" --filter-projects="projects/$PROJECT_ID" \
    --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
    --billing-project="$PROJECT_ID"

step "2. substrate @ $SUBSTRATE_REF"
# The checkout is ours: it is re-pinned, patched and its .ate-dev-env.sh overwritten, so never
# point SUBSTRATE_DIR at a checkout you use for anything else. A marker file guards that.
if [ ! -d "$SUBSTRATE_DIR/.git" ]; then
  git clone https://github.com/agent-substrate/substrate.git "$SUBSTRATE_DIR"
  touch "$SUBSTRATE_DIR/.field-test-owned"
elif [ ! -f "$SUBSTRATE_DIR/.field-test-owned" ]; then
  echo "refusing: $SUBSTRATE_DIR is an existing checkout not created by this script." >&2
  echo "Set SUBSTRATE_DIR in scripts/env.sh to a new path." >&2; exit 1
fi
git -C "$SUBSTRATE_DIR" fetch -q origin "$SUBSTRATE_REF" && git -C "$SUBSTRATE_DIR" checkout -q "$SUBSTRATE_REF"
# Upstream bug on macOS bash 3.2: empty-array expansion under `set -u`. Harmless elsewhere.
P="$HERE/docs/upstream-patch-bash32.diff"
if git -C "$SUBSTRATE_DIR" apply --check "$P" 2>/dev/null; then git -C "$SUBSTRATE_DIR" apply "$P"
elif git -C "$SUBSTRATE_DIR" apply --check --reverse "$P" 2>/dev/null; then :  # already applied
else echo "note: bash 3.2 patch no longer applies at $SUBSTRATE_REF (maybe fixed upstream); continuing"; fi
sed -e "s/^export PROJECT_ID=.*/export PROJECT_ID=$PROJECT_ID/" \
    -e "s/^export GCE_REGION=.*/export GCE_REGION=$REGION/" \
    -e "s/^export CLUSTER_LOCATION=.*/export CLUSTER_LOCATION=$ZONE/" \
    -e "s/^export NODE_MACHINE_TYPE=.*/export NODE_MACHINE_TYPE=$NODE_MACHINE_TYPE/" \
    -e "s/^export CLUSTER_VERSION=.*/export CLUSTER_VERSION=$GKE_VERSION/" \
    -e "s/^export NODE_POOL_VERSION=.*/export NODE_POOL_VERSION=$GKE_VERSION/" \
    "$SUBSTRATE_DIR/hack/ate-dev-env.sh.example" > "$SUBSTRATE_DIR/.ate-dev-env.sh"
printf 'export GOOGLE_CLOUD_QUOTA_PROJECT=%s\nexport CLOUDSDK_CORE_PROJECT=%s\n' "$PROJECT_ID" "$PROJECT_ID" \
  >> "$SUBSTRATE_DIR/.ate-dev-env.sh"

cd "$SUBSTRATE_DIR"; source .ate-dev-env.sh
CTX="gke_${PROJECT_ID}_${ZONE}_${CLUSTER_NAME}"; export KUBECTL_CONTEXT="$CTX"

step "3. GKE + bucket + IAM (upstream setup-gcp bootstrap)"
go run ./tools/setup-gcp bootstrap
gcloud container clusters get-credentials "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT_ID"
gcloud auth configure-docker gcr.io --quiet >/dev/null

# The install builds images on this machine. Don't run two builds at once: on Docker Desktop
# that starved a build's apt-get of network and failed it (see docs/timeline.md).
retry() { for i in 1 2 3; do "$@" && return 0; echo "attempt $i failed; retrying (slow image pulls hit 60 s timeouts)"; sleep 20; done; return 1; }

step "4. ate-system + demos"
retry ./hack/install-ate.sh --deploy-ate-system --credential-provider='{"name":"k8s.io"}' \
  --deploy-demo-counter --deploy-demo-sandbox

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  step "5. claude-code-multiplex demo"
  retry ./hack/install-ate.sh --deploy-demo-claude-code-multiplex
fi

step "6. benchmark harness"
./benchmarking/locust/build_and_push.sh
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" --role=roles/storage.objectAdmin \
  --member="principal://iam.googleapis.com/projects/$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/benchmarking/sa/benchmark-runner" >/dev/null
go install ./cmd/kubectl-ate
command -v kubectl-ate >/dev/null ||
  echo "note: add $(go env GOPATH)/bin to PATH so 'kubectl ate' works for the tests"

cat <<EOF

Ready. Next:
  export CONTEXT=$CTX
  kubectl --context \$CONTEXT -n ate-system port-forward svc/atenet-router 8000:80 &
  tests/01-state-persistence.sh        tests/05-credential-injection.sh
  tests/03-claude-multiplex.sh         (if the Claude demo was installed)
  SUBSTRATE=$SUBSTRATE_DIR CONTEXT=\$CONTEXT BUCKET=$BUCKET_NAME \\
    IMAGE=$KO_DOCKER_REPO/locust-test:latest bench/run-all.sh
  bench/summarize.py
Cost while up: ~\$0.50/h (~\$12/day). Tear down with scripts/teardown.sh.
EOF
