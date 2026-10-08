#!/usr/bin/env bash
# Checks the deployed app answers correctly through the ingress. Exits non-zero on failure.
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8080}"

fail() { echo "FAIL: $1"; exit 1; }

echo ">> GET /health"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health")" = "200" ] || fail "/health did not return 200"

echo ">> GET /ready"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/ready")" = "200" ] || fail "/ready did not return 200"

echo ">> GET /info"
INFO="$(curl -fs "$BASE/info")" || fail "/info request failed"
echo "   $INFO"
echo "$INFO" | grep -q '"api_key_configured": *true' || fail "the Secret did not reach the pod"
echo "$INFO" | grep -q '"greeting"' || fail "the ConfigMap did not reach the pod"
echo "$INFO" | grep -qi 'secret\|API_KEY=' && fail "response leaks secret material" || true

echo ">> Requests are spread across pods"
PODS="$(for _ in $(seq 1 20); do curl -fs "$BASE/info" | python3 -c 'import json,sys;print(json.load(sys.stdin)["pod"])'; done | sort -u | wc -l)"
echo "   distinct pods answering: $PODS"

echo ""
echo "Smoke test passed."