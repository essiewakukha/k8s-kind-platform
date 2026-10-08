#!/usr/bin/env bash
# Checks the deployed app answers correctly through the ingress. Exits non-zero on failure.
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8080}"

fail() { echo "FAIL: $1"; exit 1; }

echo ">> Waiting for the ingress route to answer (up to 120s)"
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$BASE/health" || true)" = "200" ] && break
  [ "$i" = "60" ] && fail "ingress did not start answering within 120s"
  sleep 2
done

echo ">> Waiting for the autoscaler minimum of 2 ready replicas (up to 120s)"
for i in $(seq 1 60); do
  READY="$(kubectl -n shop get deployment shop-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  [ "${READY:-0}" -ge 2 ] && break
  [ "$i" = "60" ] && fail "fewer than 2 replicas ready after 120s"
  sleep 2
done

echo ">> GET /health"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health")" = "200" ] || fail "/health did not return 200"