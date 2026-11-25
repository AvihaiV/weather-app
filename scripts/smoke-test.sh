#!/usr/bin/env bash
# Post-deploy checks: the app works AND the security controls hold. Used by CI, the demo, and locally.
# Usage: scripts/smoke-test.sh   (expects the kind cluster from infra/local)
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kind-weather}"
URL="${URL:-http://127.0.0.1:8088}"
NS=weather
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; exit 1; }

echo "== Functional"
job="weather-collector-manual-$(date +%s)"
kubectl -n "$NS" create job --from=cronjob/weather-collector "$job" >/dev/null
kubectl -n "$NS" wait "job/$job" --for=condition=complete --timeout=180s >/dev/null && pass "collector job completed"
n=$(curl -sf "$URL/api/weather/current" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[ "$n" -ge 6 ] && pass "API returns $n cities" || fail "API returned $n cities"
curl -sf -o /dev/null "$URL/" && pass "UI responds"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/weather/history?location=Nowhere")
[ "$code" = 404 ] && pass "unknown city rejected (allow-list)" || fail "unknown city -> $code"

echo "== Edge security (nginx)"
curl -sI "$URL/" | grep -qi '^content-security-policy:' && pass "CSP header present" || fail "CSP header missing"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/api/weather/current")
[ "$code" = 403 ] && pass "non-GET blocked ($code)" || fail "POST returned $code"
if curl -s "$URL/metrics" | grep -q http_requests_total; then fail "/metrics is public"; else pass "/metrics not exposed"; fi

echo "== Pod Security Admission"
if kubectl -n "$NS" run psa-test --image=busybox:1.37 --restart=Never --dry-run=server \
     --overrides='{"spec":{"containers":[{"name":"t","image":"busybox:1.37","securityContext":{"privileged":true}}]}}' >/dev/null 2>&1; then
  fail "privileged pod was admitted"
else pass "privileged pod rejected"; fi

echo "== NetworkPolicy"
for p in rogue:none fe:frontend; do
  name="np-${p%%:*}"; label="${p#*:}"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $name, namespace: $NS, labels: { app.kubernetes.io/component: $label } }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: t
      image: busybox:1.37
      command: [sleep, "300"]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
done
kubectl -n "$NS" wait pod/np-rogue pod/np-fe --for=condition=Ready --timeout=120s >/dev/null
can() { kubectl -n "$NS" exec "$1" -- sh -c "$2" >/dev/null 2>&1; }
can np-rogue "nc -z -w3 weather-backend 8000" && fail "unlabelled pod reached backend" || pass "unlabelled pod cannot reach backend"
can np-rogue "nc -z -w3 weather-db-rw.weather-db.svc 5432" && fail "unlabelled pod reached Postgres" || pass "unlabelled pod cannot reach Postgres"
can np-fe "nc -z -w3 weather-backend 8000" && pass "frontend can reach backend" || fail "frontend cannot reach backend"
can np-fe "nc -z -w3 weather-db-rw.weather-db.svc 5432" && fail "frontend reached Postgres" || pass "frontend cannot reach Postgres"
kubectl -n "$NS" delete pod np-rogue np-fe --wait=false >/dev/null

echo "== Database least privilege"
out=$(kubectl -n "$NS" exec deploy/weather-backend -- python -c "
from weather import db
c = db.connect()
try:
    c.execute('DELETE FROM weather_observations'); print('ALLOWED')
except Exception as e: print(type(e).__name__)")
[ "$out" = InsufficientPrivilege ] && pass "API DB user cannot DELETE" || fail "API DB user DELETE -> $out"

echo "All smoke tests passed."
