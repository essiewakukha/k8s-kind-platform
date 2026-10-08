#!/usr/bin/env bash
# Generates CPU load so the HorizontalPodAutoscaler adds pods, then prints replicas over time.
#   ./scripts/loadtest.sh [seconds] [workers]     default: 150 seconds, 16 workers
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8080}"
DURATION="${1:-150}"
WORKERS="${2:-16}"

echo ">> Starting load: $WORKERS workers for ${DURATION}s against $BASE/work"
END=$(( $(date +%s) + DURATION ))

worker() {
  while [ "$(date +%s)" -lt "$END" ]; do
    curl -s -o /dev/null "$BASE/work?ms=250" || true
  done
}

PIDS=()
for _ in $(seq 1 "$WORKERS"); do
  worker &
  PIDS+=($!)
done
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT

START=$(date +%s)
while [ "$(date +%s)" -lt "$END" ]; do
  ELAPSED=$(( $(date +%s) - START ))
  LINE="$(kubectl -n shop get hpa shop-api --no-headers 2>/dev/null | awk '{print "cpu="$3" replicas="$6}')"
  echo "   ${ELAPSED}s  ${LINE}"
  sleep 15
done

wait "${PIDS[@]}" 2>/dev/null || true
echo ">> Load stopped. Watch it scale back down with: kubectl -n shop get hpa -w"