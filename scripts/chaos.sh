#!/usr/bin/env bash
# Resilience experiments. Each one sends steady traffic and counts failed requests.
#   ./scripts/chaos.sh kill-pod    delete a pod while traffic flows
#   ./scripts/chaos.sh rollout     rolling restart while traffic flows
#   ./scripts/chaos.sh unready     make one pod fail readiness; it must leave the Service
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8080}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"; [ -n "${LOADPID:-}" ] && kill "$LOADPID" 2>/dev/null || true' EXIT

start_traffic() {
  : > "$OUT"
  ( while true; do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 "$BASE/health" >> "$OUT" || echo "000" >> "$OUT"
      sleep 0.05
    done ) &
  LOADPID=$!
  sleep 2
}

report() {
  kill "$LOADPID" 2>/dev/null || true
  LOADPID=""
  TOTAL="$(wc -l < "$OUT")"
  BAD="$(grep -vc '^200$' "$OUT" || true)"
  echo ">> Requests sent: $TOTAL, failed: $BAD"
  if [ "$BAD" -eq 0 ]; then echo ">> RESULT: zero failed requests"; else echo ">> RESULT: $BAD failed requests"; fi
}

case "${1:-}" in
  kill-pod)
    start_traffic
    POD="$(kubectl -n shop get pods -l app=shop-api -o name | head -1)"
    echo ">> Deleting $POD"
    kubectl -n shop delete "$POD" --wait=false
    kubectl -n shop rollout status deployment/shop-api --timeout=120s
    sleep 5
    report
    ;;
  rollout)
    start_traffic
    echo ">> Rolling restart of deployment/shop-api"
    kubectl -n shop rollout restart deployment/shop-api
    kubectl -n shop rollout status deployment/shop-api --timeout=180s
    sleep 5
    report
    ;;
  unready)
    POD="$(kubectl -n shop get pods -l app=shop-api -o jsonpath='{.items[0].metadata.name}')"
    echo ">> Before: endpoints = $(kubectl -n shop get endpoints shop-api -o jsonpath='{.subsets[0].addresses[*].ip}' | wc -w)"
    kubectl -n shop exec "$POD" -- python -c "import urllib.request;urllib.request.urlopen('http://localhost:8080/unready')"
    echo ">> $POD now fails readiness. Waiting 15s for the probe..."
    sleep 15
    echo ">> After:  endpoints = $(kubectl -n shop get endpoints shop-api -o jsonpath='{.subsets[0].addresses[*].ip}' | wc -w) (the pod was removed from the Service)"
    kubectl -n shop exec "$POD" -- python -c "import urllib.request;urllib.request.urlopen('http://localhost:8080/ready-on')"
    echo ">> $POD marked ready again"
    ;;
  *)
    echo "Usage: $0 kill-pod|rollout|unready"
    exit 1
    ;;
esac