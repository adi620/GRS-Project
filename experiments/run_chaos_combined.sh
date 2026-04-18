#!/bin/bash
# experiments/run_chaos_combined.sh
# Runs the chaos scenario: 20% packet loss + 4 CPU stressors simultaneously.
# This is the most realistic fault — production failures rarely have a single cause.
#
# Expected results vs individual faults:
#   - Pure loss (20%):    mean ~386ms, TCP backoff spikes
#   - Pure CPU stress:    mean ~92ms, scheduling jitter
#   - Combined chaos:     WORSE than either alone — CPU delays amplify TCP backoff timers
#
# Outputs:
#   results/chaos_combined.csv         — HTTP latency
#   results/chaos_pod_metrics.csv      — pod CPU/memory during chaos
#   eBPF markers in retransmissions.log and packet_drops.log

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
DURATION="${CHAOS_DURATION:-90}"
LOSS_PCT="${CHAOS_LOSS_PCT:-20}"
CPU_WORKERS="${CHAOS_CPU_WORKERS:-4}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo " CHAOS SCENARIO: COMBINED FAULTS"
echo " Loss:     ${LOSS_PCT}% packet loss"
echo " CPU:      ${CPU_WORKERS} stressors"
echo " Duration: ${DURATION}s"
echo " Outputs:  ${RESULTS_DIR}/chaos_combined.csv"
echo "           ${RESULTS_DIR}/chaos_pod_metrics.csv"
echo "========================================"

# ── eBPF boundary markers ─────────────────────────────────────
_ebpf_marker() {
    local tag="$1"; local ns; ns=$(date +%s%N)
    for log in retransmissions.log packet_drops.log sched_latency.log; do
        [ -f "${RESULTS_DIR}/${log}" ] && \
            echo "=== ${tag} chaos_loss${LOSS_PCT}+cpu${CPU_WORKERS} ts=${ns} ===" >> "${RESULTS_DIR}/${log}" || true
    done
    echo "[${tag}] chaos marker written (ts=${ns})"
}

# ── Pod metrics background sampler (f) ───────────────────────
echo "timestamp,pod,cpu_cores,memory_mi" > "${RESULTS_DIR}/chaos_pod_metrics.csv"
pod_metrics_loop() {
    local end_ts=$(( $(date +%s) + DURATION + 5 ))
    while [ "$(date +%s)" -lt "$end_ts" ]; do
        local ts; ts=$(date +%s%3N)
        kubectl top pods --no-headers 2>/dev/null | while read -r pod cpu mem; do
            # cpu is like "5m" (millicores), mem is like "10Mi"
            echo "${ts},${pod},${cpu},${mem}" >> "${RESULTS_DIR}/chaos_pod_metrics.csv"
        done
        sleep 5
    done
}
pod_metrics_loop &
METRICS_PID=$!

# ── Inject both faults ────────────────────────────────────────
"${PROJECT_ROOT}/fault_injection/chaos_combined.sh" start \
    "$LOSS_PCT" "$CPU_WORKERS" "$((DURATION + 10))"

trap '"${PROJECT_ROOT}/fault_injection/chaos_combined.sh" stop 2>/dev/null || true
     kill $METRICS_PID 2>/dev/null || true
     wait $METRICS_PID 2>/dev/null || true' EXIT

_ebpf_marker "START"

# ── Measure latency under chaos ───────────────────────────────
bash "${PROJECT_ROOT}/measurement/measure_latency.sh" \
    "${RESULTS_DIR}/chaos_combined.csv" "$DURATION"

_ebpf_marker "END"

# Stop pod metrics sampler
kill "$METRICS_PID" 2>/dev/null || true
wait "$METRICS_PID" 2>/dev/null || true
trap - EXIT

# ── Print chaos summary ───────────────────────────────────────
echo "[chaos] Latency summary:"
tail -n +2 "${RESULTS_DIR}/chaos_combined.csv" 2>/dev/null | grep -v timeout | \
    awk -F',' '{s+=$2; n++; if($2>m)m=$2; if($2>1.0)spk++}
               END{printf "  Samples: %d  Mean: %.0fms  Max: %.0fms  Spikes>1s: %d\n",
                   n, s/n*1000, m*1000, spk+0}'

echo "[chaos] Pod metrics summary:"
tail -n +2 "${RESULTS_DIR}/chaos_pod_metrics.csv" 2>/dev/null | \
    awk -F',' '{pod=$2} END{print "  Rows captured: " NR}' || true

echo "[chaos] Done → ${RESULTS_DIR}/chaos_combined.csv"
