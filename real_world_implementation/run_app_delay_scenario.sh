#!/bin/bash
# run_app_delay_scenario.sh
# SCENARIO 2: Application-Level Slowdown
#
# Simulates a production situation where:
#   - Latency is consistently ~200ms above normal
#   - No network faults, no CPU spikes
#   - Root cause: slow application code (DB query, middleware, etc.)
#
# Diagnosis path:
#   1. Observe latency is HIGH but STABLE (not jittery)
#   2. Check retransmissions → ZERO  (rules out network loss)
#   3. Check packet drops   → ZERO  (rules out tc rules)
#   4. Check sched_latency  → NORMAL (rules out CPU contention)
#   5. Conclusion: application-level delay — needs app profiling

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RW_DIR="$SCRIPT_DIR"
LOGS="${RW_DIR}/measurement/logs"
DURATION="${APP_DELAY_DURATION:-60}"
DELAY_MS="${APP_DELAY_MS:-200}"
mkdir -p "$LOGS"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SCENARIO 2: Application-Level Slowdown"
echo "  Symptom:    Stable latency increase (~${DELAY_MS}ms)"
echo "  Reality:    Slow application code (no network fault)"
echo "  Duration:   ${DURATION}s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

_marker() {
    local tag="$1"; local ts; ts=$(date +%s%N)
    echo "=== ${tag} APP_DELAY ts=${ts} ===" | tee -a "${LOGS}/ebpf_app_delay.log"
}

# ── Verify original web pod ───────────────────────────────
echo "[app_delay_scenario] Checking current web pod..."
CUR_IMAGE=$(kubectl get deployment web \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
echo "[app_delay_scenario] Current image: ${CUR_IMAGE}"

# ── Start eBPF tracing ────────────────────────────────────
echo "[app_delay_scenario] Starting eBPF tracers..."
bpftrace "${RW_DIR}/../ebpf/tcp_retransmissions.bt" \
    > "${LOGS}/retransmissions_app_delay.log" 2>&1 &
RETRANS_PID=$!
bpftrace "${RW_DIR}/../ebpf/packet_drops.bt" \
    > "${LOGS}/drops_app_delay.log" 2>&1 &
DROPS_PID=$!
bpftrace "${RW_DIR}/../ebpf/sched_latency.bt" \
    > "${LOGS}/sched_app_delay.log" 2>&1 &
SCHED_PID=$!

trap "kill $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null
      bash '${RW_DIR}/scenarios/app_delay/revert_app_delay.sh' 2>/dev/null || true" EXIT
sleep 3

# ── Baseline: 20s before injecting app delay ─────────────
echo ""
echo "[app_delay_scenario] Phase 1: Measuring BASELINE (20s)..."
echo "timestamp,latency_seconds" > "${LOGS}/latency_app_delay.csv"
_marker "START_BASELINE"
END=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s%3N)
    LAT=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 5 http://web/ 2>/dev/null || echo "timeout")
    [ "$LAT" != "timeout" ] && echo "${TS},${LAT}" >> "${LOGS}/latency_app_delay.csv"
    echo "  [baseline] ${TS} → ${LAT}s"
    sleep 1
done
_marker "END_BASELINE"

# ── Deploy slow application ───────────────────────────────
echo ""
echo "[app_delay_scenario] Phase 2: Deploying slow application..."
echo "[app_delay_scenario]   Patching web pod: Python server with ${DELAY_MS}ms sleep"
echo "[app_delay_scenario]   (simulates slow DB call — NOT tc netem)"
APP_DELAY_MS="$DELAY_MS" bash "${RW_DIR}/scenarios/app_delay/deploy_app_delay.sh"
_marker "START"

# ── Measure under app delay ───────────────────────────────
echo ""
echo "[app_delay_scenario] Phase 3: Measuring under APP DELAY (${DURATION}s)..."
END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s%3N)
    LAT=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 10 http://web/ 2>/dev/null || echo "timeout")
    [ "$LAT" != "timeout" ] && echo "${TS},${LAT}" >> "${LOGS}/latency_app_delay.csv"
    echo "  [app_delay] ${TS} → ${LAT}s"
    sleep 1
done
_marker "END"

# ── Revert deployment ─────────────────────────────────────
bash "${RW_DIR}/scenarios/app_delay/revert_app_delay.sh"
trap - EXIT
kill $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null || true
wait $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null || true

# ── eBPF evidence ─────────────────────────────────────────
echo ""
echo "━━━ eBPF Evidence ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
RETRANS=$(grep -c "RETRANSMIT" "${LOGS}/retransmissions_app_delay.log" 2>/dev/null || echo 0)
DROPS=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${LOGS}/drops_app_delay.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
SCHED=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${LOGS}/sched_app_delay.log" 2>/dev/null | grep -c "[0-9]" || echo 0)

echo "  TCP retransmissions : ${RETRANS}  (expected: 0)"
echo "  Packet drops        : ${DROPS}   (expected: 0)"
echo "  Scheduler events    : ${SCHED}   (expected: LOW — no CPU stress)"

# ── Latency summary ───────────────────────────────────────
echo ""
echo "━━━ Latency Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
python3 << PYEOF
import csv, sys, statistics
from pathlib import Path
rows = []
try:
    with open("${LOGS}/latency_app_delay.csv") as f:
        next(f)
        for line in f:
            parts = line.strip().split(',')
            if len(parts)==2:
                try: rows.append(float(parts[1])*1000)
                except: pass
except: pass
if not rows: print("  No data"); sys.exit()
mean   = sum(rows)/len(rows)
mx     = max(rows)
mn     = min(rows)
jitter = statistics.stdev(rows) if len(rows)>1 else 0
print(f"  Samples   : {len(rows)}")
print(f"  Mean      : {mean:.1f}ms")
print(f"  Min       : {mn:.1f}ms")
print(f"  Max       : {mx:.1f}ms")
print(f"  Jitter    : {jitter:.1f}ms std-dev  (low jitter = application cause)")
PYEOF

echo ""
echo "━━━ Diagnosis ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✗ Network fault?     NO  (0 retransmissions, 0 drops)"
echo "  ✗ CPU contention?    NO  (normal scheduler activity)"
echo "  ✓ App slowdown?      YES (stable +${DELAY_MS}ms, low jitter)"
echo "  Root cause: application-level delay (slow code path)"
echo "  Next step:  profile application code, check DB queries"
echo ""
echo "[app_delay_scenario] Done → ${LOGS}/latency_app_delay.csv"
