#!/bin/bash
# run_real_world_pipeline.sh
# FULL REAL-WORLD DEBUGGING PIPELINE — one command runs everything:
#   1. Cleans previous outputs automatically
#   2. Runs Scenario 1: Hidden CPU Contention
#   3. Runs Scenario 2: Application-Level Slowdown
#   4. Generates comparison plot
#   5. Generates HTML report
#   6. Prints Grafana URL (if observability stack is running)
#
# Usage: sudo ./real_world_implementation/run_real_world_pipeline.sh
#
# DOES NOT modify: results/, main pipeline scripts, or any existing files.

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="${SCRIPT_DIR}/measurement/logs"
PLOTS="${SCRIPT_DIR}/measurement/plots"
REPORT="${SCRIPT_DIR}/measurement/report"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   GRS — Real-World Debugging Module                          ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║   Part 2: Unknown causes diagnosed via eBPF                  ║"
echo "║   Started: $(date)"
echo "║"
echo "║   Scenario 1: Hidden CPU Contention"
echo "║   Scenario 2: Application-Level Slowdown"
echo "║"
echo "║   ⚠ This module does NOT use tc fault injection"
echo "║   ⚠ Outputs go to real_world_implementation/ only"
echo "╚═══════════════════════════════════════════════════════════════╝"

# ── Switch to correct context ─────────────────────────────
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
kubectl config use-context "kind-${KIND_CLUSTER}" 2>/dev/null || \
    kubectl config use-context "${KIND_CLUSTER}" 2>/dev/null || true
kubectl cluster-info &>/dev/null || { echo "ERROR: Cluster unreachable"; exit 1; }

# ── Step 1: Clean previous outputs ───────────────────────
echo ""
echo "━━━ STEP 1: Cleaning previous real-world outputs ━━━━━━━━━━━━━"
bash "${SCRIPT_DIR}/cleanup_environment.sh"

# ── Step 2: Ensure web pod is clean nginx ─────────────────
echo ""
echo "━━━ STEP 2: Verifying workloads ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
kubectl wait --for=condition=ready pod -l app=web --timeout=120s 2>/dev/null || \
    { echo "Deploying web pod..."; kubectl apply -f "${SCRIPT_DIR}/../deployment/web-deployment.yaml";
      kubectl apply -f "${SCRIPT_DIR}/../deployment/web-service.yaml";
      kubectl wait --for=condition=ready pod -l app=web --timeout=120s; }
kubectl wait --for=condition=ready pod/traffic --timeout=60s 2>/dev/null || \
    { echo "Deploying traffic pod..."; kubectl delete pod traffic --ignore-not-found=true;
      kubectl apply -f "${SCRIPT_DIR}/../traffic/traffic.yaml";
      kubectl wait --for=condition=ready pod/traffic --timeout=60s; }

HTTP=$(kubectl exec traffic -- curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 http://web/ 2>/dev/null || echo "000")
[ "$HTTP" = "200" ] && echo "✓ Web pod reachable (HTTP 200)" || \
    { echo "ERROR: Web pod not responding (HTTP ${HTTP})"; exit 1; }
echo "✓ Workloads ready"

# ── Step 3: Run CPU Scenario ──────────────────────────────
echo ""
echo "━━━ STEP 3: Scenario 1 — CPU Noise (90s + 20s baseline) ━━━━━"
CPU_NOISE_DURATION=90 bash "${SCRIPT_DIR}/run_cpu_scenario.sh"
echo "✓ CPU scenario complete → ${LOGS}/latency_cpu_noise.csv"

# ── Step 4: Run App Delay Scenario ───────────────────────
echo ""
echo "━━━ STEP 4: Scenario 2 — App Delay (60s + 20s baseline) ━━━━━"
APP_DELAY_DURATION=60 APP_DELAY_MS=200 bash "${SCRIPT_DIR}/run_app_delay_scenario.sh"
echo "✓ App delay scenario complete → ${LOGS}/latency_app_delay.csv"

# ── Step 5: Generate plot ─────────────────────────────────
echo ""
echo "━━━ STEP 5: Generating comparison plot ━━━━━━━━━━━━━━━━━━━━━━"
python3 "${PLOTS}/plot_real_world.py" 2>/dev/null && \
    echo "✓ Plot → ${PLOTS}/real_world_latency_comparison.png" || \
    echo "  (plot skipped — install: pip3 install matplotlib pandas)"

# ── Step 6: Generate HTML report ─────────────────────────
echo ""
echo "━━━ STEP 6: Generating HTML report ━━━━━━━━━━━━━━━━━━━━━━━━━"
bash "${REPORT}/generate_real_world_report.sh"
echo "✓ Report → ${REPORT}/real_world_report.html"

# ── Final summary ─────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  ✅  REAL-WORLD MODULE COMPLETE — $(date)"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║"
echo "║  Outputs (all inside real_world_implementation/):"
echo "║    measurement/logs/latency_cpu_noise.csv"
echo "║    measurement/logs/latency_app_delay.csv"
echo "║    measurement/logs/retransmissions_*.log"
echo "║    measurement/logs/sched_*.log"
echo "║    measurement/plots/real_world_latency_comparison.png"
echo "║    measurement/report/real_world_report.html"
echo "║"
echo "║  Key findings:"

# CPU noise stats
python3 << PYEOF 2>/dev/null || true
import statistics
rows = []
try:
    with open("${LOGS}/latency_cpu_noise.csv") as f:
        next(f)
        for line in f:
            p = line.strip().split(',')
            if len(p)==2:
                try:
                    ts = float(p[0])
                    rows.append((ts, float(p[1])*1000))
                except: pass
except: pass
if rows:
    t0 = rows[0][0]
    bl = [v for ts,v in rows if (ts-t0)/1000 <= 20]
    ft = [v for ts,v in rows if (ts-t0)/1000 > 20]
    if bl and ft:
        jitter = statistics.stdev(ft) if len(ft)>1 else 0
        print(f"║    CPU Noise:   baseline={sum(bl)/len(bl):.1f}ms → under noise={sum(ft)/len(ft):.1f}ms  jitter={jitter:.1f}ms")
PYEOF

python3 << PYEOF 2>/dev/null || true
import statistics
rows = []
try:
    with open("${LOGS}/latency_app_delay.csv") as f:
        next(f)
        for line in f:
            p = line.strip().split(',')
            if len(p)==2:
                try:
                    ts = float(p[0])
                    rows.append((ts, float(p[1])*1000))
                except: pass
except: pass
if rows:
    t0 = rows[0][0]
    bl = [v for ts,v in rows if (ts-t0)/1000 <= 20]
    ft = [v for ts,v in rows if (ts-t0)/1000 > 20]
    if bl and ft:
        jitter = statistics.stdev(ft) if len(ft)>1 else 0
        print(f"║    App Delay:   baseline={sum(bl)/len(bl):.1f}ms → under delay={sum(ft)/len(ft):.1f}ms  jitter={jitter:.1f}ms")
PYEOF

echo "║"
VM_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
echo "║  View HTML report:"
echo "║    python3 -m http.server 8081 --directory real_world_implementation/measurement/"
echo "║    http://${VM_IP}:8081/report/real_world_report.html"
echo "║"
echo "║  Main pipeline outputs are UNTOUCHED in results/"
echo "╚═══════════════════════════════════════════════════════════════╝"
