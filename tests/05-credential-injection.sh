#!/usr/bin/env bash
# Test 05: egress credential injection + egress policy.
#
# Claim under test: "egress proxies ... inject credentials outside the reach of the agents
# themselves". We put a random secret in a Kubernetes Secret, let the egress gateway inject it
# into an actor's outbound Authorization header, and then search the actor for it.
#
#   PASS = the upstream sees the secret            (injection works)
#        AND the secret is nowhere inside the actor (env, /proc/*/environ, filesystem)
#        AND an egress the policy doesn't cover is refused
#
# Uses the upstream sandbox demo (POST /process runs a command in the actor) and an in-cluster
# traefik/whoami echo server over plain HTTP, so there is no external dependency.
#
# Usage: CONTEXT=<kube-context> tests/05-credential-injection.sh
# Needs: `hack/install-ate.sh --deploy-demo-sandbox` done, router port-forwarded to ROUTER_URL.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT=${CONTEXT:?set CONTEXT}
ATESPACE=${ATESPACE:-ate-demo-sandbox}
TEMPLATE=${TEMPLATE:-sandbox-template}
ACTOR=${ACTOR:-credtest-$(date +%s)}
ROUTER_URL=${ROUTER_URL:-http://localhost:8000}
SECRET_NS=fieldtest-secrets
OUT=${OUT:-results/raw/05-credential-injection-$(date +%Y%m%d-%H%M%S).log}
mkdir -p "$(dirname "$OUT")"; exec > >(tee "$OUT") 2>&1

k() { kubectl --context "$CONTEXT" "$@"; }
ate() { kubectl ate --context "$CONTEXT" "$@"; }
# run a command in the actor; prints stdout+stderr
run() {
  python3 - "$@" <<'PY' | curl -s -X POST -H "ate-target-actor: $ATESPACE/$ACTOR" \
      -H 'Content-Type: application/json' --data-binary @- --max-time 90 "$ROUTER_URL/process" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("stdout","")+d.get("stderr","")+d.get("error",""))'
import json, sys; print(json.dumps({"command": sys.argv[1:], "timeout": "60s"}))
PY
}
pass=0; fail=0
check() { if eval "$2"; then echo "PASS  $1"; pass=$((pass+1)); else echo "FAIL  $1"; fail=$((fail+1)); fi; }

SECRET="fieldtest-$(openssl rand -hex 16)"
mask() { sed "s/$SECRET/<INJECTED-SECRET>/g"; }   # never write the token itself to the log
POLICY_BACKUP=$(mktemp)
# Leave the cluster as we found it, however the test ends.
cleanup() {
  set +e
  ate delete egress-policy "$ACTOR" -a "$ATESPACE" >/dev/null 2>&1
  ate delete actor "$ACTOR" -a "$ATESPACE" --any-state >/dev/null 2>&1
  if [ -s "$POLICY_BACKUP" ]; then k apply -f "$POLICY_BACKUP" >/dev/null 2>&1
  else k -n ate-system delete configmap k8s-credential-provider-namespace-policy --ignore-not-found >/dev/null 2>&1; fi
  k -n ate-system rollout restart deployment/k8s-credential-provider >/dev/null 2>&1
  k delete namespace "$SECRET_NS" egress-target --ignore-not-found --wait=false >/dev/null 2>&1
  rm -f "$POLICY_BACKUP"
}
trap cleanup EXIT
echo "== setup: secret, echo server, namespace policy"
# back up the shared provider policy; we replace it for the test and restore it on exit
k -n ate-system get configmap k8s-credential-provider-namespace-policy -o yaml 2>/dev/null |
  grep -v -e '^  resourceVersion:' -e '^  uid:' -e '^  creationTimestamp:' > "$POLICY_BACKUP" || : > "$POLICY_BACKUP"
k create namespace "$SECRET_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n "$SECRET_NS" create secret generic upstream-api --from-literal=token="$SECRET" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k create namespace egress-target --dry-run=client -o yaml | k apply -f - >/dev/null
k -n egress-target get deploy whoami >/dev/null 2>&1 || {
  k -n egress-target create deployment whoami --image=traefik/whoami:v1.10 >/dev/null
  k -n egress-target expose deployment whoami --port=80 >/dev/null; }
k -n egress-target rollout status deploy/whoami --timeout=180s >/dev/null
TARGET_IP=$(k -n egress-target get svc whoami -o jsonpath='{.spec.clusterIP}')

k -n ate-system create configmap k8s-credential-provider-namespace-policy \
  --from-literal=namespace-policy.yaml="policies:
- atespace: $ATESPACE
  allowedNamespaces: [$SECRET_NS]
" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n ate-system rollout restart deployment/k8s-credential-provider >/dev/null
k -n ate-system rollout status deployment/k8s-credential-provider --timeout=180s >/dev/null

echo "== actor + egress policy (HTTP only, Authorization replaced from the Secret)"
ate create actor "$ACTOR" -a "$ATESPACE" --template "$TEMPLATE" >/dev/null
ate resume actor "$ACTOR" -a "$ATESPACE" >/dev/null
ate create egress-policy "$ACTOR" -a "$ATESPACE" -f - >/dev/null <<EOF
rules:
- http:
    hostnames: ["*"]
    ports: {all: {}}
    effects:
      replaceHeaders:
      - header: Authorization
        prefix: "Bearer "
        credentialUri: ate-secret://k8s.io/default/$SECRET_NS/upstream-api/token
EOF
sleep 12   # gateway caches a missing policy as deny for 10 s

echo "== 1. injection: actor sends a placeholder, upstream should see the real secret"
echoed=$(run wget -q -O - --header "Authorization: placeholder" "http://$TARGET_IP/")
echo "$echoed" | grep -i '^Authorization' | mask || true
check "upstream received injected credential" 'grep -q "Bearer $SECRET" <<<"$echoed"'
check "upstream did not receive the placeholder" '! grep -q "placeholder" <<<"$echoed"'
EGRESS_IPS=$(k -n ate-system get pods -l app=atenet-egress -o jsonpath='{.items[*].status.podIP}')
remote=$(sed -nE 's/^RemoteAddr: ([0-9.]+):.*/\1/p' <<<"$echoed")
echo "upstream saw RemoteAddr=$remote; egress gateway pod IPs: $EGRESS_IPS"
check "request arrived from the egress gateway pod, not the actor" \
  '[ -n "$remote" ] && grep -Fqw "$remote" <<<"$EGRESS_IPS"'

echo "== 2. secret must not exist inside the actor"
envdump=$(run sh -c 'env; cat /proc/[0-9]*/environ 2>/dev/null | tr "\0" "\n"')
check "secret absent from env and /proc/*/environ" '! grep -q "$SECRET" <<<"$envdump"'
fsgrep=$(run sh -c "grep -rIl '$SECRET' / --exclude-dir=proc --exclude-dir=sys 2>/dev/null | head -5; echo scan-done")
check "secret absent from the actor filesystem" '! grep -v scan-done <<<"$fsgrep" | grep -q .'
check "filesystem scan actually ran" 'grep -q scan-done <<<"$fsgrep"'

echo "== 3. egress the policy does not cover must be refused"
https_out=$(run sh -c 'wget -q -T 15 -O - https://example.com./ >/dev/null 2>&1 && echo REACHED || echo BLOCKED')
check "HTTPS to an uncovered host is refused" 'grep -q BLOCKED <<<"$https_out"'

echo "== 4. control: allow example.com (TLS passthrough) and the same request must now succeed"
ate delete egress-policy "$ACTOR" -a "$ATESPACE" >/dev/null
ate create egress-policy "$ACTOR" -a "$ATESPACE" -f - >/dev/null <<EOF
rules:
- tls_passthrough: {hostnames: ["example.com"], ports: {numbers: [443]}}
EOF
sleep 12
ctl_out=$(run sh -c 'wget -q -T 15 -O - https://example.com./ >/dev/null 2>&1 && echo REACHED || echo BLOCKED')
check "same request succeeds once the policy allows it (so the block was the policy)" \
  'grep -q REACHED <<<"$ctl_out"'

echo "result: $pass passed, $fail failed"
[ "$fail" = 0 ]
