#!/usr/bin/env bash
# Run all 6 demo scenarios against the Istio ingress gateway.
# Prerequisites: terraform applied, scripts/setup-contexts.sh run, jq installed.
# From Cloud Shell: bash scripts/demo.sh
set -euo pipefail

for cmd in kubectl jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' not found. Install it first."
    exit 1
  fi
done

# Override with INGRESS_CONTEXT / WORKLOAD_CONTEXT env vars if needed.
INGRESS_CONTEXT="${INGRESS_CONTEXT:-ingress-cluster}"
WORKLOAD_CONTEXT="${WORKLOAD_CONTEXT:-workload-cluster}"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1 (got $2, expected $3)"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

echo "=== Istio ExtAuthz Schema Validation Demo ==="
echo ""

# ── Get ingress LB IP ─────────────────────────────────────────────────────────
LB_IP=$(kubectl --context "$INGRESS_CONTEXT" -n istio-ingress \
  get svc istio-ingressgateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$LB_IP" ]; then
  echo "ERROR: IngressGateway has no external IP yet. Try again in a few minutes."
  exit 1
fi

echo "IngressGateway IP: $LB_IP"

# ── Get CA cert for curl ──────────────────────────────────────────────────────
CA_CERT_FILE=$(mktemp /tmp/demo-ca-XXXXXX.pem)
kubectl --context "$INGRESS_CONTEXT" -n cert-manager \
  get secret demo-ca-secret \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_CERT_FILE"

cleanup() { rm -f "$CA_CERT_FILE"; }
trap cleanup EXIT

# ── Get JWT mock ClusterIP ────────────────────────────────────────────────────
# Port-forward jwt-mock so we can call /token from outside the cluster
JWT_LOCAL_PORT=18080
kubectl --context "$INGRESS_CONTEXT" port-forward \
  -n jwt-mock svc/jwt-mock "$JWT_LOCAL_PORT":8080 &>/dev/null &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; rm -f $CA_CERT_FILE" EXIT
sleep 2

JWT_URL="http://localhost:${JWT_LOCAL_PORT}"

echo "Fetching tokens from JWT mock..."

# Valid token (5 min expiry)
VALID_TOKEN=$(curl -sf -X POST "${JWT_URL}/token" \
  -H "Content-Type: application/json" \
  -d '{"sub":"demo-user","aud":"api.demo.local","exp_minutes":5}' \
  | jq -r .access_token)

# Expired token (already expired)
EXPIRED_TOKEN=$(curl -sf -X POST "${JWT_URL}/token" \
  -H "Content-Type: application/json" \
  -d '{"sub":"demo-user","aud":"api.demo.local","exp_minutes":-1}' \
  | jq -r .access_token)

echo "Tokens acquired."
echo ""

# ── Helper ────────────────────────────────────────────────────────────────────
run_test() {
  local desc="$1"
  local expected="$2"
  shift 2

  local status
  status=$(curl -sk \
    --cacert "$CA_CERT_FILE" \
    -o /dev/null \
    -w "%{http_code}" \
    -H "Host: api.demo.local" \
    "$@" \
    "https://${LB_IP}/post" 2>/dev/null || echo "000")

  if [ "$status" = "$expected" ]; then
    pass "$desc → HTTP $status"
  else
    fail "$desc" "$status" "$expected"
  fi
}

# ── Scenario 1: Valid JWT + valid body → 200 ─────────────────────────────────
run_test "1. Valid JWT + valid body" "200" \
  -X POST \
  -H "Authorization: Bearer ${VALID_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"widget","description":"a test item"}'

# ── Scenario 2: No JWT → 401 ─────────────────────────────────────────────────
run_test "2. No JWT header" "401" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"name":"widget"}'

# ── Scenario 3: Expired JWT → 401 ────────────────────────────────────────────
run_test "3. Expired JWT" "401" \
  -X POST \
  -H "Authorization: Bearer ${EXPIRED_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"widget"}'

# ── Scenario 4: Valid JWT + invalid body (missing required field) → 400 ───────
run_test "4. Valid JWT + invalid body (missing 'name')" "400" \
  -X POST \
  -H "Authorization: Bearer ${VALID_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"wrong_field":"oops"}'

# ── Scenario 5: Valid JWT + unknown path → 404 ────────────────────────────────
# /nonexistent is not in the OpenAPI spec
UNKNOWN_STATUS=$(curl -sk \
  --cacert "$CA_CERT_FILE" \
  -o /dev/null \
  -w "%{http_code}" \
  -H "Host: api.demo.local" \
  -H "Authorization: Bearer ${VALID_TOKEN}" \
  "https://${LB_IP}/nonexistent" 2>/dev/null || echo "000")
if [ "$UNKNOWN_STATUS" = "404" ]; then
  pass "5. Valid JWT + unknown path /nonexistent → HTTP 404"
else
  fail "5. Valid JWT + unknown path /nonexistent" "$UNKNOWN_STATUS" "404"
fi

# ── Scenario 6: Valid JWT + body too large → 413 ─────────────────────────────
LARGE_BODY=$(python3 -c "import json; print(json.dumps({'name': 'x' * 1048577}))" 2>/dev/null \
  || node -e "console.log(JSON.stringify({name: 'x'.repeat(1048577)}))" 2>/dev/null \
  || printf '{"name":"%s"}' "$(head -c 1048577 /dev/urandom | base64 | tr -d '\n')")

run_test "6. Valid JWT + body > 1 MiB" "413" \
  -X POST \
  -H "Authorization: Bearer ${VALID_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$LARGE_BODY"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo -e "${GREEN}All scenarios passed.${NC}"
else
  echo -e "${RED}${FAILURES} scenario(s) failed.${NC}"
  exit 1
fi
