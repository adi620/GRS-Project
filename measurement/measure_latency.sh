#!/bin/bash
# measure_latency.sh — measures HTTP latency from traffic pod to web service
# Usage: ./measure_latency.sh <output_csv> <duration_seconds>

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

OUTPUT_CSV="${1:-/dev/stdout}"
DURATION="${2:-60}"

mkdir -p "$(dirname "$OUTPUT_CSV")" 2>/dev/null || true
echo "timestamp,latency_seconds" > "$OUTPUT_CSV"
echo "[measure] Output: ${OUTPUT_CSV}  Duration: ${DURATION}s"

START=$(date +%s)
while true; do
    NOW=$(date +%s)
    [ $((NOW - START)) -ge "$DURATION" ] && break
    TIMESTAMP=$(date +%s%3N)
    LATENCY=$(kubectl exec traffic -- \
        curl -o /dev/null -s -w "%{time_total}" \
        --max-time 10 http://web/ 2>/dev/null || echo "timeout")
    echo "${TIMESTAMP},${LATENCY}" >> "$OUTPUT_CSV"
    echo "[measure] ${TIMESTAMP}  ${LATENCY}s"
    sleep 1
done
echo "[measure] Complete → ${OUTPUT_CSV}"
