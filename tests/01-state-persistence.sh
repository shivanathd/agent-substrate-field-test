#!/usr/bin/env bash
# Test 01: does an actor's state survive repeated suspend/resume cycles?
#
# Uses the upstream counter demo. Each cycle:
#   1. POST to the actor through the router (wakes it if suspended) -> time it
#   2. POST again while warm                                         -> time it
#   3. suspend it, poll until SUSPENDED                              -> time it
# and checks the memory, file and rootfs counters all equal the expected count.
#
# Request times are measured from wherever this runs. Through `kubectl port-forward` from far
# away they include WAN + tunnel time, so read resume overhead as first_req_s - warm_req_s.
# The suspend time includes CLI polling (0.2 s granularity) and the API round trip.
#
# Usage: CONTEXT=<kube-context> CYCLES=20 tests/01-state-persistence.sh
# Needs: kubectl-ate on PATH, router port-forwarded to ROUTER_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT=${CONTEXT:?set CONTEXT to the kube context}
ATESPACE=${ATESPACE:-ate-demo-counter}
TEMPLATE=${TEMPLATE:-counter}
ACTOR=${ACTOR:-persist-$(date +%s)}
CYCLES=${CYCLES:-20}
ROUTER_URL=${ROUTER_URL:-http://localhost:8000/}
OUT=${OUT:-results/raw/01-state-persistence-$(date +%Y%m%d-%H%M%S).csv}

ate() { kubectl ate --context "$CONTEXT" "$@"; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
state() { ate get actor "$ACTOR" -a "$ATESPACE" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])'; }
worker() { ate get actor "$ACTOR" -a "$ATESPACE" -o json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["status"].get("workerAssignment",{}).get("workerPod",""))'; }

# POST once; prints "<http_code> <seconds> <body>"
hit() {
  curl -s -X POST -H "ate-target-actor: $ATESPACE/$ACTOR" \
    -w ' %{http_code} %{time_total}' --max-time 60 "$ROUTER_URL" | tr -d '\n'
}
# body -> "mem file rootfs"
counters() { sed -E 's/.*memory count: ([0-9]+).*file counter: ([0-9]+).*rootfs counter: ([0-9]+).*/\1 \2 \3/'; }

mkdir -p "$(dirname "$OUT")"
echo "cycle,first_req_s,first_http,warm_req_s,suspend_operator_s,mem,file,rootfs,expected,ok,worker" > "$OUT"

# wait until the actor reaches $1, at most $2 seconds (default 120); fail instead of hanging
wait_state() {
  local deadline=$(( $(date +%s) + ${2:-120} ))
  until [ "$(state)" = "$1" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "timeout waiting for $ACTOR to reach $1" >&2; return 1; }
    sleep 0.2
  done
}
cleanup() { ate delete actor "$ACTOR" -a "$ATESPACE" --any-state >/dev/null 2>&1 || true; }
trap cleanup EXIT

ate create actor "$ACTOR" -a "$ATESPACE" --template "$TEMPLATE" >/dev/null
echo "actor $ATESPACE/$ACTOR created; running $CYCLES cycles -> $OUT"

expected=0; fails=0
for c in $(seq 1 "$CYCLES"); do
  r1=$(hit); expected=$((expected+1))
  first_s=$(awk '{print $NF}' <<<"$r1"); first_code=$(awk '{print $(NF-1)}' <<<"$r1")
  r2=$(hit); expected=$((expected+1))
  warm_s=$(awk '{print $NF}' <<<"$r2")
  read -r mem file rootfs <<<"$(counters <<<"$r2")"
  w=$(worker)

  t0=$(now_ms); ate suspend actor "$ACTOR" -a "$ATESPACE" >/dev/null
  wait_state ACTOR_STATE_SUSPENDED
  susp_s=$(python3 -c "print(($(now_ms)-$t0)/1000)")

  ok=1; for v in "$mem" "$file" "$rootfs"; do [ "$v" = "$expected" ] || ok=0; done
  [ $ok = 1 ] || fails=$((fails+1))
  echo "$c,$first_s,$first_code,$warm_s,$susp_s,$mem,$file,$rootfs,$expected,$ok,$w" | tee -a "$OUT"
done

echo "done: $CYCLES cycles, $fails state mismatches"
[ "$fails" = 0 ]
