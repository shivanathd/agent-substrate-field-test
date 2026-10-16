#!/usr/bin/env bash
# Run the benchmark suite: upstream catalogue entries, grouped by the workload shape they need
# (worker count, actor memory, sandbox class) so the workloads are redeployed once per group.
#
# Usage:
#   SUBSTRATE=~/src/substrate CONTEXT=<ctx> BUCKET=<bucket> IMAGE=<.../locust-test:latest> \
#     bench/run-all.sh [group ...]
# Groups: base mem1g mem2g w5 w10 microvm microvm2g   (default: the gVisor ones)
# microvm groups need `hack/install-microvm-deps.sh --install` in $SUBSTRATE first.
#
# Needs: substrate's .ate-dev-env.sh in $SUBSTRATE (the workload deploy builds images with ko).
set -uo pipefail

SUBSTRATE=${SUBSTRATE:?}; CONTEXT=${CONTEXT:?}; BUCKET=${BUCKET:?}; IMAGE=${IMAGE:?}
HERE=$(cd "$(dirname "$0")/.." && pwd)
GROUPS_TO_RUN=${*:-base mem1g mem2g w5 w10}
LOG="$HERE/results/raw/bench-run-all-$(date +%Y%m%d-%H%M%S).log"

# group -> "workerCount actorMemory sandboxClass | catalogue entries"
group_def() {
  case $1 in
    base)    echo "1 - gvisor | glutton_baseline_1_user glutton_baseline_1_user_pause durdir_data_baseline durdir_implicit_resume durdir_full_baseline" ;;
    mem1g)   echo "1 1536Mi gvisor | glutton_mem_1gi_gvisor glutton_mem_1gi_gvisor_pause" ;;
    mem2g)   echo "1 2560Mi gvisor | glutton_mem_2gi_gvisor" ;;
    w5)      echo "5 - gvisor | glutton_baseline_5_users" ;;
    w10)     echo "10 - gvisor | glutton_baseline_10_users glutton_oversubscribe_15_users" ;;
    durdir)  echo "1 - gvisor | durdir_data_baseline durdir_implicit_resume durdir_full_baseline" ;;
    microvm) echo "1 1536Mi microvm | glutton_mem_1gi_microvm" ;;
    microvm2g) echo "1 2560Mi microvm | glutton_mem_2gi_microvm" ;;
    # Same catalogue entries run for $LONG (default 5m): 1 min fits only 1-7 cycles at 1-2 GiB.
    long-g1)  echo "1 1536Mi gvisor | glutton_mem_1gi_gvisor" ;;
    long-g2)  echo "1 2560Mi gvisor | glutton_mem_2gi_gvisor" ;;
    long-m1)  echo "1 1536Mi microvm | glutton_mem_1gi_microvm" ;;
    long-m2)  echo "1 2560Mi microvm | glutton_mem_2gi_microvm" ;;
  esac
}

redeploy() {  # workers memory class
  local args=(--worker-count "$1" --sandbox-class "$3"); [ "$2" != - ] && args+=(--actor-memory "$2")
  ( cd "$SUBSTRATE" && source .ate-dev-env.sh && export KUBECTL_CONTEXT="$CONTEXT" &&
    ./benchmarking/workloads/deploy.sh --delete --sandbox-class "$3" >/dev/null 2>&1;
    ./benchmarking/workloads/deploy.sh --deploy "${args[@]}" )
}

{
for g in $GROUPS_TO_RUN; do
  def=$(group_def "$g"); [ -n "$def" ] || { echo "unknown group: $g (skipped; nothing deleted)"; continue; }
  shape=${def%%|*}; tests=${def#*|}
  read -r w m c <<<"$shape"
  echo "=== group $g: workers=$w actorMemory=$m class=$c  $(date +%H:%M:%S)"
  t0=$(date +%s)
  redeploy "$w" "$m" "$c" > "$HERE/results/raw/deploy-$g.log" 2>&1 || { echo "deploy failed for $g (see deploy-$g.log)"; continue; }
  echo "    workloads ready in $(( $(date +%s) - t0 ))s"
  extra=(); case $g in long-*) extra=(--duration-override "${LONG:-5m}" --timeout-min 40) ;; esac
  for t in $tests; do
    python3 "$HERE/bench/run-locust.py" --substrate "$SUBSTRATE" --context "$CONTEXT" \
      --bucket "$BUCKET" --image "$IMAGE" --catalog "$t" --out "$HERE/results/raw/bench" \
      ${extra[@]+"${extra[@]}"} 2>&1 | tail -1
  done
done
} 2>&1 | tee "$LOG"
