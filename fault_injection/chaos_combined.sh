#!/bin/bash
# fault_injection/chaos_combined.sh
# Applies TWO faults simultaneously: packet loss + CPU stress.
# This simulates a realistic production failure where a node is both
# resource-starved and experiencing network degradation at the same time.
#
# Usage:
#   sudo ./fault_injection/chaos_combined.sh start [loss_pct] [cpu_workers] [duration_s]
#   sudo ./fault_injection/chaos_combined.sh stop

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo $0 $*"; exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-start}"
LOSS_PCT="${2:-20}"
CPU_WORKERS="${3:-4}"
DURATION="${4:-65}"

case "$MODE" in
    start)
        echo "[chaos] ═══ CHAOS SCENARIO: loss ${LOSS_PCT}% + ${CPU_WORKERS} CPU stressors ═══"

        # 1. Inject packet loss
        echo "[chaos] Injecting ${LOSS_PCT}% packet loss..."
        "${SCRIPT_DIR}/inject_fault.sh" loss "$LOSS_PCT"
        echo "[chaos] ✓ Packet loss active"

        # 2. Start CPU stress
        echo "[chaos] Starting CPU stress (${CPU_WORKERS} workers)..."
        "${SCRIPT_DIR}/cpu_stress.sh" start "$CPU_WORKERS" "$DURATION"
        echo "[chaos] ✓ CPU stress active"

        echo "[chaos] ═══ Both faults active — measuring chaos scenario ═══"
        ;;

    stop)
        echo "[chaos] Stopping chaos scenario..."

        # Stop CPU stress
        "${SCRIPT_DIR}/cpu_stress.sh" stop 2>/dev/null || true

        # Clear network faults
        "${SCRIPT_DIR}/inject_fault.sh" clear 2>/dev/null || true

        echo "[chaos] ✓ All faults cleared"
        ;;

    *)
        echo "ERROR: Unknown mode '${MODE}'. Use: start | stop"
        exit 1
        ;;
esac
