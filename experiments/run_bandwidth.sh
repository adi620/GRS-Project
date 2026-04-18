#!/bin/bash
# experiments/run_bandwidth.sh
# Limits bandwidth to 1mbit on web pod veth.
# Runs TWO parallel measurements:
#   1. Standard latency (curl /)              → results/bandwidth.csv
#   2. Throughput with 1MB file (curl /1mb.bin) → results/bandwidth_throughput.csv
# Writes eBPF boundary markers. Samples pod metrics every 5s (f).
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${BW_DURATION:-60}"
BW_RATE="${BW_RATE:-1mbit}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " BANDWIDTH EXPERIMENT"
echo " Rate:     ${BW_RATE} on web pod veth"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/bandwidth.csv"
echo "           ${RESULTS_DIR}/bandwidth_throughput.csv"
echo "           ${RESULTS_DIR}/pod_metrics_bandwidth.csv"
echo "========================================"

_ebpf_marker() {
    local tag="$1"; local ns; ns=$(date +%s%N)
    for log in retransmissions.log packet_drops.log sched_latency.log; do
        [ -f "${RESULTS_DIR}/${log}" ] && \
            echo "=== ${tag} bandwidth_${BW_RATE} ts=${ns} ===" >> "${RESULTS_DIR}/${log}" || true
    done
    echo "[${tag}] bandwidth_${BW_RATE} marker written (ts=${ns})"
}

# ── Ensure 1MB test file in web pod ──────────────────────────
WEB_POD=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$WEB_POD" ]; then
    kubectl exec "$WEB_POD" -- sh -c \
        'test -f /usr/share/nginx/html/1mb.bin || dd if=/dev/urandom of=/usr/share/nginx/html/1mb.bin bs=1024 count=1024 2>/dev/null' \
        && echo "[bandwidth] ✓ 1mb.bin ready in web pod" \
        || echo "[bandwidth] WARNING: Could not create 1mb.bin — throughput test skipped"
fi

# ── Pod metrics background sampler (f) ───────────────────────
echo "timestamp,pod,cpu_millicores,memory_mi" > "${RESULTS_DIR}/pod_metrics_bandwidth.csv"
_pod_metrics_loop() {
    local end_ts=$(( $(date +%s) + DURATION + 5 ))
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        local ts; ts=$(date +%s%3N)
        kubectl top pods --no-headers 2>/dev/null | while IFS=' ' read -r pod cpu mem; do
            echo "${ts},${pod},${cpu%m},${mem%Mi}" >> "${RESULTS_DIR}/pod_metrics_bandwidth.csv"
        done || true
        sleep 5
    done
}
_pod_metrics_loop &
METRICS_PID=$!

"${PROJECT_ROOT}/fault_injection/bandwidth.sh" inject "$BW_RATE"
trap '"${PROJECT_ROOT}/fault_injection/bandwidth.sh" clear 2>/dev/null || true
     kill $METRICS_PID 2>/dev/null; wait $METRICS_PID 2>/dev/null || true' EXIT
_ebpf_marker "START"

# ── Parallel throughput measurement ──────────────────────────
echo "timestamp,speed_bytes_per_sec" > "${RESULTS_DIR}/bandwidth_throughput.csv"
_throughput_loop() {
    local end_ts=$(( $(date +%s) + DURATION ))
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        local ts; ts=$(date +%s%3N)
        local speed
        speed=$(kubectl exec traffic -- \
            curl -s -o /dev/null -w "%{speed_download}" \
            --max-time 30 http://web/1mb.bin 2>/dev/null || echo "0")
        echo "${ts},${speed}" >> "${RESULTS_DIR}/bandwidth_throughput.csv"
        local kb; kb=$(awk "BEGIN{printf \"%.1f\", ${speed}/1024}" 2>/dev/null || echo "?")
        echo "[throughput] ${ts}  ${speed} B/s  (${kb} KB/s)"
        sleep 3
    done
}
_throughput_loop &
THROUGHPUT_PID=$!

# ── Standard latency measurement ─────────────────────────────
bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/bandwidth.csv" "$DURATION"

wait "$THROUGHPUT_PID" 2>/dev/null || true
_ebpf_marker "END"
kill "$METRICS_PID" 2>/dev/null; wait "$METRICS_PID" 2>/dev/null || true
trap - EXIT

# ── Throughput summary ────────────────────────────────────────
echo "[bandwidth] Throughput summary (1mbit cap = ~125 KB/s):"
tail -n +2 "${RESULTS_DIR}/bandwidth_throughput.csv" 2>/dev/null | \
    awk -F',' '$2>0{s+=$2;n++} END{
        if(n>0) printf "  Samples=%d  Mean=%.0f B/s (%.1f KB/s)\n",n,s/n,s/n/1024
        else print "  No throughput samples (1mb.bin may be missing)"}'

echo "[bandwidth] Done → ${RESULTS_DIR}/bandwidth.csv"
