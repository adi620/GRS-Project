#!/bin/bash
# cleanup_environment.sh
# Safely resets the real_world_implementation environment:
#   - Removes old logs, CSVs, plots, reports
#   - Stops any running CPU stressors
#   - Reverts web deployment to clean nginx
#   - Does NOT touch the main project (fault injection pipeline)
#
# Usage: bash real_world_implementation/cleanup_environment.sh

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  GRS Real-World Environment Cleanup"
echo "  Safe: does NOT touch main pipeline outputs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Stop CPU stressors ────────────────────────────────────
echo "[cleanup] Stopping any running CPU stressors..."
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$NODE" ]; then
    docker exec "$NODE" pkill -f stress-ng 2>/dev/null && \
        echo "[cleanup] ✓ stress-ng stopped" || \
        echo "[cleanup]   stress-ng not running"
fi

# ── Kill any hanging eBPF tracers from real_world runs ────
echo "[cleanup] Stopping any real_world eBPF tracers..."
pkill -f "tcp_retransmissions.bt" 2>/dev/null || true
pkill -f "packet_drops.bt" 2>/dev/null || true
pkill -f "sched_latency.bt" 2>/dev/null || true
echo "[cleanup] ✓ eBPF tracers stopped"

# ── Revert web deployment if it was patched ───────────────
echo "[cleanup] Checking web deployment..."
CUR=$(kubectl get deployment web \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
if echo "$CUR" | grep -qv "nginx"; then
    echo "[cleanup] Web pod is patched (${CUR}) — reverting to nginx..."
    kubectl set image deployment/web web=nginx:stable 2>/dev/null || \
    kubectl patch deployment web \
        --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:stable"},
             {"op":"replace","path":"/spec/template/spec/containers/0/command","value":[]},
             {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[]}]' \
        2>/dev/null || true
    kubectl rollout status deployment/web --timeout=60s 2>/dev/null || true
    echo "[cleanup] ✓ Web pod reverted to nginx"
else
    echo "[cleanup] ✓ Web pod already running nginx (no revert needed)"
fi

# ── Remove old real_world outputs (NOT main pipeline) ─────
echo "[cleanup] Removing old real_world outputs..."
MEASUREMENT="${SCRIPT_DIR}/measurement"
rm -f "${MEASUREMENT}/logs/"*.csv \
       "${MEASUREMENT}/logs/"*.log \
       "${MEASUREMENT}/plots/"*.png \
       "${MEASUREMENT}/plots/"*.pdf \
       "${MEASUREMENT}/report/"*.html 2>/dev/null || true
echo "[cleanup] ✓ Old logs, plots, reports removed"
echo "[cleanup]   Main pipeline outputs (results/) untouched"

# ── Verify cluster still healthy ──────────────────────────
echo ""
echo "[cleanup] Verifying cluster health..."
kubectl get pods 2>/dev/null | grep -E "NAME|web|traffic" || true
echo ""
echo "[cleanup] ✓ Environment clean — ready for new run"
echo ""
echo "  Run scenarios:"
echo "    sudo bash real_world_implementation/run_real_world_pipeline.sh"
echo "  Or individually:"
echo "    sudo bash real_world_implementation/run_cpu_scenario.sh"
echo "    sudo bash real_world_implementation/run_app_delay_scenario.sh"
