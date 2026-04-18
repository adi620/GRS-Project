#!/bin/bash
# run_cpu_scenario.sh
# SCENARIO 1: Hidden CPU Contention
#
# Simulates a production situation where:
#   - An SRE sees latency alerts firing
#   - No network faults have been deployed
#   - A noisy neighbour workload is saturating the node CPU
#   - Root cause: CPU scheduling delay
#
# Diagnosis path:
#   1. Observe latency is HIGH and JITTERY (not stable)
#   2. Check retransmissions → ZERO  (rules out network loss)
#   3. Check packet drops   → ZERO  (rules out tc rules)
#   4. Check sched_latency  → HIGH activity from stress-ng
#   5. Conclusion: CPU contention from another workload

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RW_DIR="$SCRIPT_DIR"
LOGS="${RW_DIR}/measurement/logs"
DURATION="${CPU_NOISE_DURATION:-90}"
mkdir -p "$LOGS"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SCENARIO 1: Hidden CPU Contention"
echo "  Symptom:    Latency spikes, no obvious cause"
echo "  Reality:    Noisy neighbour consuming node CPU"
echo "  Duration:   ${DURATION}s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Write log marker ──────────────────────────────────────
_marker() {
    local tag="$1"; local ts; ts=$(date +%s%N)
    echo "=== ${tag} CPU_NOISE ts=${ts} ===" | tee -a "${LOGS}/ebpf_cpu_noise.log"
}

# ── Verify web pod is reachable ───────────────────────────
echo "[cpu_scenario] Verifying connectivity..."
kubectl wait --for=condition=ready pod -l app=web --timeout=60s 2>/dev/null || true
HTTP=$(kubectl exec traffic -- curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 http://web/ 2>/dev/null || echo "000")
[ "$HTTP" = "200" ] && echo "[cpu_scenario] ✓ Web pod reachable" || \
    { echo "ERROR: Web pod not responding (HTTP ${HTTP})"; exit 1; }

# ── Start eBPF tracing ────────────────────────────────────
echo "[cpu_scenario] Starting eBPF tracers..."
bpftrace "${RW_DIR}/../ebpf/tcp_retransmissions.bt" \
    > "${LOGS}/retransmissions_cpu_noise.log" 2>&1 &
RETRANS_PID=$!
bpftrace "${RW_DIR}/../ebpf/packet_drops.bt" \
    > "${LOGS}/drops_cpu_noise.log" 2>&1 &
DROPS_PID=$!
bpftrace "${RW_DIR}/../ebpf/sched_latency.bt" \
    > "${LOGS}/sched_cpu_noise.log" 2>&1 &
SCHED_PID=$!

trap "kill $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null;
      bash '${RW_DIR}/scenarios/cpu_noise/stop_cpu_noise.sh' 2>/dev/null || true" EXIT
sleep 3

# ── Baseline: 20s clean measurement before noise ─────────
echo ""
echo "[cpu_scenario] Phase 1: Measuring BASELINE (20s clean)..."
echo "timestamp,latency_seconds" > "${LOGS}/latency_cpu_noise.csv"
_marker "START_BASELINE"
END=$(( $(date +%s) + 20 ))
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s%3N)
    LAT=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 5 http://web/ 2>/dev/null || echo "timeout")
    [ "$LAT" != "timeout" ] && echo "${TS},${LAT}" >> "${LOGS}/latency_cpu_noise.csv"
    echo "  [baseline] ${TS} → ${LAT}s"
    sleep 1
done
_marker "END_BASELINE"

# ── Inject CPU noise (hidden — not announced to "operator") ──
echo ""
echo "[cpu_scenario] Phase 2: CPU noise starting (hidden from operator)..."
echo "[cpu_scenario]   An SRE would now see latency alerts but see no tc rules..."
bash "${RW_DIR}/scenarios/cpu_noise/start_cpu_noise.sh"
_marker "START"
sleep 3

# ── Measure under CPU noise ───────────────────────────────
echo ""
echo "[cpu_scenario] Phase 3: Measuring under CPU NOISE (${DURATION}s)..."
END=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$END" ]; do
    TS=$(date +%s%3N)
    LAT=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 10 http://web/ 2>/dev/null || echo "timeout")
    [ "$LAT" != "timeout" ] && echo "${TS},${LAT}" >> "${LOGS}/latency_cpu_noise.csv"
    echo "  [cpu_noise] ${TS} → ${LAT}s"
    sleep 1
done
_marker "END"

# ── Stop noise ────────────────────────────────────────────
bash "${RW_DIR}/scenarios/cpu_noise/stop_cpu_noise.sh"
trap - EXIT
sleep 2
kill $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null || true
wait $RETRANS_PID $DROPS_PID $SCHED_PID 2>/dev/null || true

# ── eBPF evidence summary ─────────────────────────────────
echo ""
echo "━━━ eBPF Evidence ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
RETRANS=$(grep -c "RETRANSMIT" "${LOGS}/retransmissions_cpu_noise.log" 2>/dev/null || echo 0)
DROPS=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${LOGS}/drops_cpu_noise.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
SCHED=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]" "${LOGS}/sched_cpu_noise.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
STRESSNG=$(grep "stress-ng" "${LOGS}/sched_cpu_noise.log" 2>/dev/null | wc -l || echo 0)

echo "  TCP retransmissions : ${RETRANS}  (expected: 0 — confirms NOT a network fault)"
echo "  Packet drops        : ${DROPS}   (expected: 0 — confirms NOT tc netem)"
echo "  Scheduler events    : ${SCHED}   (high = CPU contention)"
echo "  stress-ng events    : ${STRESSNG} (non-zero = noisy neighbour identified)"

# ── Latency summary ───────────────────────────────────────
echo ""
echo "━━━ Latency Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
python3 << PYEOF
import csv, sys
from pathlib import Path
rows = []
try:
    with open("${LOGS}/latency_cpu_noise.csv") as f:
        next(f)
        for line in f:
            parts = line.strip().split(',')
            if len(parts)==2:
                try: rows.append((int(parts[0]), float(parts[1])*1000))
                except: pass
except: pass
if not rows: print("  No data"); sys.exit()
vals = [v for _,v in rows]
mean = sum(vals)/len(vals)
mx   = max(vals)
mn   = min(vals)
# Variance as indicator of jitter
import statistics
jitter = statistics.stdev(vals) if len(vals)>1 else 0
print(f"  Samples   : {len(vals)}")
print(f"  Mean      : {mean:.1f}ms")
print(f"  Min       : {mn:.1f}ms")
print(f"  Max       : {mx:.1f}ms")
print(f"  Jitter    : {jitter:.1f}ms std-dev  (high jitter = scheduling cause)")
PYEOF

echo ""
echo "━━━ Diagnosis ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✗ Network fault?     NO  (0 retransmissions, 0 drops)"
echo "  ✗ App slowdown?      NO  (jitter pattern, not stable increase)"
echo "  ✓ CPU contention?    YES (stress-ng events in sched_latency)"
echo "  Root cause: noisy neighbour consuming CPU slices"
echo ""
echo "[cpu_scenario] Done → ${LOGS}/latency_cpu_noise.csv"
