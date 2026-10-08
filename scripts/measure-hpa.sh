#!/usr/bin/env bash
# Times the HorizontalPodAutoscaler: load starts -> first scale-up -> max replicas ready,
# then load stops -> back to the minimum.   ./scripts/measure-hpa.sh [load_seconds] [workers]
# Defaults: 180 seconds of load, 16 workers. Polls every 2 seconds.
set -euo pipefail
BASE="${BASE_URL:-http://localhost:8080}"
LOAD_SECONDS="${1:-180}"
WORKERS="${2:-16}"
DOWN_TIMEOUT=600

jp() { kubectl -n shop get "$1" shop-api -o jsonpath="$2" 2>/dev/null || true; }

MIN="$(jp hpa '{.spec.minReplicas}')"
MAX="$(jp hpa '{.spec.maxReplicas}')"
[ -n "$MIN" ] && [ -n "$MAX" ] || { echo "Cannot read the HPA. Is the cluster up?"; exit 1; }

echo ">> HPA bounds: min=$MIN max=$MAX. Waiting for the deployment to settle at $MIN replicas..."
for _ in $(seq 1 150); do
  [ "$(jp deployment '{.status.replicas}')" = "$MIN" ] && [ "$(jp deployment '{.status.readyReplicas}')" = "$MIN" ] && break
  sleep 2
done
[ "$(jp deployment '{.status.replicas}')" = "$MIN" ] || { echo "Did not settle at $MIN replicas; aborting."; exit 1; }
echo ">> Settled. Starting load: $WORKERS workers for ${LOAD_SECONDS}s"

START=$(date +%s)
END=$(( START + LOAD_SECONDS ))
worker() { while [ "$(date +%s)" -lt "$END" ]; do curl -s -o /dev/null --max-time 5 "$BASE/work?ms=250" || true; done; }
PIDS=()
for _ in $(seq 1 "$WORKERS"); do worker & PIDS+=($!); done
trap 'kill "${PIDS[@]}" 2>/dev/null || true' EXIT

T_UP=""; T_MAX=""; T_DOWN=""; PEAK_CPU=0; LOAD_STOPPED=""
echo "time_s  phase  cpu%  current  desired  ready"
while true; do
  NOW=$(date +%s); T=$(( NOW - START ))
  CPU="$(jp hpa '{.status.currentMetrics[0].resource.current.averageUtilization}')"
  CUR="$(jp hpa '{.status.currentReplicas}')"
  DES="$(jp hpa '{.status.desiredReplicas}')"
  RDY="$(jp deployment '{.status.readyReplicas}')"
  CUR="${CUR:-0}"; DES="${DES:-0}"; RDY="${RDY:-0}"; CPU="${CPU:-0}"
  [ "$NOW" -lt "$END" ] && PHASE="load" || PHASE="idle"
  echo "$T  $PHASE  $CPU  $CUR  $DES  $RDY"
  [ "$CPU" -gt "$PEAK_CPU" ] && PEAK_CPU="$CPU"
  [ -z "$T_UP" ]  && [ "$DES" -gt "$MIN" ] && T_UP="$T"
  [ -z "$T_MAX" ] && [ "$RDY" -ge "$MAX" ] && T_MAX="$T"
  if [ "$PHASE" = "idle" ]; then
    [ -z "$LOAD_STOPPED" ] && LOAD_STOPPED="$T"
    [ -z "$T_DOWN" ] && [ "$CUR" -le "$MIN" ] && [ "$(jp deployment '{.status.replicas}')" = "$MIN" ] && T_DOWN="$T" && break
    [ $(( T - LOAD_STOPPED )) -ge "$DOWN_TIMEOUT" ] && break
  fi
  sleep 2
done

echo ""
echo "=== HPA timing summary (single run, laptop) ==="
echo "Peak CPU vs target:             ${PEAK_CPU}%"
echo "Load started at:                0s"
echo "First scale-up decision:        ${T_UP:-not reached}s after load start"
echo "All $MAX replicas ready:        ${T_MAX:-not reached}s after load start"
echo "Load stopped at:                ${LOAD_STOPPED:-n/a}s"
if [ -n "$T_DOWN" ]; then
  echo "Back to $MIN replicas:           ${T_DOWN}s after load start ($(( T_DOWN - LOAD_STOPPED ))s after load stopped)"
else
  echo "Back to $MIN replicas:           not reached within ${DOWN_TIMEOUT}s of load stopping"
fi