#!/bin/bash
# experiments/run_reordering.sh — 25% reorder + 100ms delay, 60s
# Writes eBPF boundary markers. Samples pod metrics every 5s (f).
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${REORDER_DURATION:-60}"
DELAY_MS="${REORDER_DELAY_MS:-100}"
REORDER_PCT="${REORDER_PCT:-25}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " REORDERING EXPERIMENT"
echo " Reorder:  ${REORDER_PCT}% + ${DELAY_MS}ms delay on web pod veth"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/reordering.csv"
echo "========================================"

_ebpf_marker() {
    local tag="$1"; local ns; ns=$(date +%s%N)
    for log in retransmissions.log packet_drops.log sched_latency.log; do
        [ -f "${RESULTS_DIR}/${log}" ] && \
            echo "=== ${tag} reorder_${REORDER_PCT}pct ts=${ns} ===" >> "${RESULTS_DIR}/${log}" || true
    done
    echo "[${tag}] reorder_${REORDER_PCT}pct marker written (ts=${ns})"
}

echo "timestamp,pod,cpu_millicores,memory_mi" > "${RESULTS_DIR}/pod_metrics_reordering.csv"
_pod_metrics_loop() {
    local end_ts=$(( $(date +%s) + DURATION + 5 ))
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        local ts; ts=$(date +%s%3N)
        kubectl top pods --no-headers 2>/dev/null | while IFS=' ' read -r pod cpu mem; do
            echo "${ts},${pod},${cpu%m},${mem%Mi}" >> "${RESULTS_DIR}/pod_metrics_reordering.csv"
        done || true
        sleep 5
    done
}
_pod_metrics_loop &
METRICS_PID=$!

"${PROJECT_ROOT}/fault_injection/reordering.sh" inject "$DELAY_MS" "$REORDER_PCT"
trap '"${PROJECT_ROOT}/fault_injection/reordering.sh" clear 2>/dev/null || true
     kill $METRICS_PID 2>/dev/null; wait $METRICS_PID 2>/dev/null || true' EXIT
_ebpf_marker "START"

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/reordering.csv" "$DURATION"

_ebpf_marker "END"
kill "$METRICS_PID" 2>/dev/null; wait "$METRICS_PID" 2>/dev/null || true
trap - EXIT

echo "[reordering] Done → ${RESULTS_DIR}/reordering.csv"
echo "[reordering]       → ${RESULTS_DIR}/pod_metrics_reordering.csv"
