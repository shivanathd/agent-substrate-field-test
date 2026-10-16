#!/usr/bin/env bash
# Test 03: real Claude Code agents survive suspend/resume and migration.
#
# Upstream demo (demos/claude-code-multiplex): each agent is a shell loop that runs
# `claude --print "$TASK"` every 45 s and keeps a TICK counter in shell memory. Only process
# memory carries TICK, so if an agent comes back from a suspend and its next tick is N+1 (not 1),
# the live process tree (bash + node + Claude Code) was restored from the memory snapshot.
#
# Two things the upstream demo does not do, which this test adds:
#   - an egress policy per agent. Substrate denies all egress (DNS included) to an actor with no
#     policy, so without this every `claude` call fails with EAI_AGAIN. We allow exactly
#     api.anthropic.com:443 (TLS passthrough) and nothing else.
#   - checking that Claude actually answered, rather than that the loop ticked.
#
# Usage: CONTEXT=<kube-context> tests/03-claude-multiplex.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT=${CONTEXT:?set CONTEXT}
NS=claude-multiplex-demo
TICK_WAIT=${TICK_WAIT:-100}   # two 45 s ticks plus a Claude call
OUT=${OUT:-results/raw/03-claude-multiplex-$(date +%Y%m%d-%H%M%S).log}
mkdir -p "$(dirname "$OUT")"; exec > >(tee "$OUT") 2>&1

ate() { kubectl ate --context "$CONTEXT" "$@"; }
k() { kubectl --context "$CONTEXT" "$@"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }
st() { ate get actor "$1" -a "$NS" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])'; }
pod() { ate get actor "$1" -a "$NS" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"].get("workerAssignment",{}).get("workerPod",""))'; }
# wait until agent $1 reaches state $2 (max 180 s); prints seconds taken, fails instead of hanging
wait_state() {
  local t0 deadline; t0=$(now); deadline=$(( $(date +%s) + 180 ))
  until [ "$(st "$1")" = "$2" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "timeout: $1 never reached $2" >&2; return 1; }
    sleep 0.5
  done
  python3 -c "print(f'{$(now)-$t0:.1f}')"
}
# Whatever happens, stop the agents: a running agent calls the Anthropic API every 45 s.
cleanup() { for a in luna mars orion; do ate suspend actor "$a" -a "$NS" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

# Agent messages since a unix time, one per line, from every worker pod's structured log.
msgs() {  # $1 agent  $2 since-epoch
  for p in $(k -n "$NS" get pods -o name); do k -n "$NS" logs "$p" 2>/dev/null; done | python3 -c '
import json, sys, datetime
agent, since = sys.argv[1], float(sys.argv[2])
rows = []
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("logging.googleapis.com/labels", {}).get("ate.actor.name") != agent: continue
    # Go writes 1-9 fractional digits; Python < 3.11 fromisoformat needs exactly 0, 3 or 6
    base, _, frac = d["time"].rstrip("Z").partition(".")
    t = datetime.datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp() + float("0." + (frac or "0"))
    if t >= since: rows.append((t, d.get("message", "")))
for _, m in sorted(rows): print(m)' "$1" "$2"
}
last_tick() { msgs "$1" 0 | sed -nE "s/^\[demo-actor:$1\] === tick ([0-9]+) .*/\1/p" | tail -1; }
# Claude replies: every agent line that is not a loop marker, a substrate lifecycle line, an
# error, gVisor boot output, or blank.
answers() {
  msgs "$1" "$2" | grep -v -e '^\[demo-actor' -e '^---$' -e '^Actor ' -e 'API Error' \
    -e '^[IWE][0-9]\{4\} ' -e '^$' || true
}
errors() { msgs "$1" "$2" | grep -c -e 'API Error' -e 'claude exited non-zero' || true; }

pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }

echo "== workers"; ate get workers -n "$NS"
for a in luna mars orion; do
  ate get actor "$a" -a "$NS" >/dev/null 2>&1 || ate create actor "$a" -a "$NS" --template "agent-$a" >/dev/null
  ate delete egress-policy "$a" -a "$NS" >/dev/null 2>&1 || true
  ate create egress-policy "$a" -a "$NS" -f - >/dev/null <<'EOF'
rules:
- tls_passthrough: {hostnames: ["api.anthropic.com"], ports: {numbers: [443]}}
EOF
done
sleep 12   # gateway caches a missing policy as deny for 10 s
T0=$(now)

echo "== phase 1: all three agents running"
for a in luna mars orion; do
  [ "$(st $a)" = ACTOR_STATE_RUNNING ] || ate resume actor "$a" -a "$NS" >/dev/null
  echo "$a RUNNING after $(wait_state $a ACTOR_STATE_RUNNING)s on $(pod $a)"
done
sleep "$TICK_WAIT"
for a in luna mars orion; do echo "--- $a"; answers $a "$T0" | head -3; done
check "all three agents got a real Claude answer" \
  '[ -n "$(answers luna $T0)" ] && [ -n "$(answers mars $T0)" ] && [ -n "$(answers orion $T0)" ]'
check "no API errors while running" '[ "$(errors luna $T0)$(errors mars $T0)$(errors orion $T0)" = 000 ]'

echo "== phase 2: suspend all, resume each (likely onto a different worker)"
for a in luna mars orion; do
  printf -v "bt_$a" %s "$(last_tick $a)"; printf -v "bp_$a" %s "$(pod $a)"; btv="bt_$a"; bpv="bp_$a"
  ate suspend actor "$a" -a "$NS" >/dev/null; echo "$a SUSPENDED after $(wait_state $a ACTOR_STATE_SUSPENDED)s at tick ${!btv}"
done
T1=$(now)
for a in orion mars luna; do   # reverse order nudges placement onto the other worker
  bpv="bp_$a"; ate resume actor "$a" -a "$NS" >/dev/null
  echo "$a RUNNING after $(wait_state $a ACTOR_STATE_RUNNING)s on $(pod $a) (was ${!bpv})"
done
sleep "$TICK_WAIT"

moved=0
for a in luna mars orion; do
  btv="bt_$a"; bpv="bp_$a"; b=${!btv}; after=$(last_tick $a); echo "$a tick $b -> $after"
  check "$a tick counter continued (process memory restored)" "[ ${after:-0} -gt ${b:-0} ] && [ ${b:-0} -ge 1 ]"
  check "$a got a real Claude answer after resume" '[ -n "$(answers '"$a"' $T1)" ]'
  [ "$(pod $a)" != "${!bpv}" ] && moved=$((moved+1))
done
# Placement is the scheduler's choice, so migration is observed, not asserted. (Run 1 of this
# test saw 2/3 agents move with ticks intact; test 01 forces it across many cycles.)
echo "INFO  agents that resumed on a different worker pod: $moved/3"

echo "== park everything"
for a in luna mars orion; do ate suspend actor "$a" -a "$NS" >/dev/null 2>&1 || true; done
echo "result: $pass passed, $fail failed"
[ "$fail" = 0 ]
