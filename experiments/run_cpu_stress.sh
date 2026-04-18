#!/bin/bash
# experiments/run_cpu_stress.sh
# CPU stress (4 workers) + sched_latency eBPF probe + pod metrics.
# Outputs: results/cpu_stress.csv, results/sched_latency.log, results/pod_metrics_cpu_stress.csv
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${CPU_DURATION:-90}"
CPU_WORKERS="${CPU_WORKERS:-4}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " CPU STRESS EXPERIMENT"
echo " Workers:  ${CPU_WORKERS} CPU stressors"
echo " Duration: ${DURATION}s"
echo " Output:   ${RESULTS_DIR}/cpu_stress.csv"
echo "           ${RESULTS_DIR}/sched_latency.log"
echo "           ${RESULTS_DIR}/pod_metrics_cpu_stress.csv"
echo "========================================"

_ebpf_marker() {
    local tag="$1"; local ns; ns=$(date +%s%N)
    for log in retransmissions.log packet_drops.log sched_latency.log; do
        [ -f "${RESULTS_DIR}/${log}" ] && \
            echo "=== ${tag} cpu_stress_${CPU_WORKERS}workers ts=${ns} ===" >> "${RESULTS_DIR}/${log}" || true
    done
    echo "[${tag}] cpu_stress_${CPU_WORKERS}workers marker written (ts=${ns})"
}

# ── Start sched_latency eBPF tracer (c) ──────────────────────
SCHED_BT="${PROJECT_ROOT}/ebpf/sched_latency.bt"
SCHED_LOG="${RESULTS_DIR}/sched_latency.log"
SCHED_PID=""
if [ -f "$SCHED_BT" ] && command -v bpftrace &>/dev/null; then
    echo "[cpu_stress] Starting sched_latency eBPF tracer..."
    bpftrace "$SCHED_BT" > "$SCHED_LOG" 2>&1 &
    SCHED_PID=$!
    sleep 2
    echo "[cpu_stress] ✓ sched_latency tracer PID=${SCHED_PID}"
else
    echo "[cpu_stress] WARNING: bpftrace/sched_latency.bt not found — skipping scheduler tracing"
fi

# ── Pod metrics background sampler (f) ───────────────────────
echo "timestamp,pod,cpu_millicores,memory_mi" > "${RESULTS_DIR}/pod_metrics_cpu_stress.csv"
_pod_metrics_loop() {
    local end_ts=$(( $(date +%s) + DURATION + 5 ))
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        local ts; ts=$(date +%s%3N)
        kubectl top pods --no-headers 2>/dev/null | while IFS=' ' read -r pod cpu mem; do
            echo "${ts},${pod},${cpu%m},${mem%Mi}" >> "${RESULTS_DIR}/pod_metrics_cpu_stress.csv"
        done || true
        sleep 5
    done
}
_pod_metrics_loop &
METRICS_PID=$!

cleanup_all() {
    [ -n "$SCHED_PID" ] && { kill "$SCHED_PID" 2>/dev/null; wait "$SCHED_PID" 2>/dev/null || true; }
    kill "$METRICS_PID" 2>/dev/null; wait "$METRICS_PID" 2>/dev/null || true
    "${PROJECT_ROOT}/fault_injection/cpu_stress.sh" stop 2>/dev/null || true
}
trap cleanup_all EXIT

"${PROJECT_ROOT}/fault_injection/cpu_stress.sh" start "$CPU_WORKERS" "$DURATION"
_ebpf_marker "START"

bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/cpu_stress.csv" "$DURATION"

_ebpf_marker "END"
cleanup_all
trap - EXIT

# ── Scheduler summary ─────────────────────────────────────────
echo "[cpu_stress] Scheduler event summary from sched_latency.log:"
if [ -f "$SCHED_LOG" ]; then
    grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]\|^===" "$SCHED_LOG" 2>/dev/null | \
    awk '{comm=$2; rt=$4+0; count[comm]++; total[comm]+=rt}
         END{
             printf "  %-20s %8s %14s %14s\n","COMM","EVENTS","TOTAL_RT_MS","MEAN_RT_US"
             for(c in count)
                 printf "  %-20s %8d %14.2f %14.2f\n",c,count[c],total[c]/1e6,(total[c]/count[c])/1e3
         }' | sort -k2 -rn | head -12
fi

echo "[cpu_stress] Done → ${RESULTS_DIR}/cpu_stress.csv"
