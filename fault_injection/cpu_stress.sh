#!/bin/bash
# fault_injection/cpu_stress.sh
# Applies CPU stress on the KIND node using stress-ng.
# Runs stress-ng inside the node container via docker exec so it affects
# the same scheduling domain as the pods — not on the host.
# Falls back to running on the host if stress-ng is not in the container.
#
# Usage:
#   sudo ./fault_injection/cpu_stress.sh start [cpus] [duration_s]
#   sudo ./fault_injection/cpu_stress.sh stop

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo $0 $*"; exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

MODE="${1:-start}"
CPUS="${2:-4}"
DURATION="${3:-65}"    # slightly longer than experiment to cover full measurement

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

case "$MODE" in
    start)
        echo "[cpu_stress] Starting stress-ng: ${CPUS} CPUs for ${DURATION}s on node ${NODE_NAME}"

        # Try docker exec into KIND node first (stress-ng may be available)
        if docker exec "$NODE_NAME" which stress-ng &>/dev/null 2>&1; then
            docker exec -d "$NODE_NAME" \
                stress-ng --cpu "$CPUS" --timeout "${DURATION}s" --quiet
            echo "[cpu_stress] ✓ stress-ng running inside KIND node container"
        elif which stress-ng &>/dev/null 2>&1; then
            # Fall back to host — still creates scheduling pressure visible to the node
            stress-ng --cpu "$CPUS" --timeout "${DURATION}s" --quiet &
            STRESS_PID=$!
            echo "[cpu_stress] ✓ stress-ng running on host (PID ${STRESS_PID})"
            echo "$STRESS_PID" > /tmp/grs_stress.pid
        else
            echo "[cpu_stress] WARNING: stress-ng not found."
            echo "[cpu_stress]   Install: sudo apt install stress-ng -y"
            echo "[cpu_stress]   Continuing without CPU stress — experiment will run but no CPU fault."
        fi
        ;;
    stop)
        echo "[cpu_stress] Stopping stress-ng..."
        # Kill inside node
        docker exec "$NODE_NAME" pkill -f stress-ng 2>/dev/null || true
        # Kill on host if we started it there
        if [ -f /tmp/grs_stress.pid ]; then
            STRESS_PID=$(cat /tmp/grs_stress.pid)
            kill "$STRESS_PID" 2>/dev/null || true
            rm -f /tmp/grs_stress.pid
        fi
        # Belt-and-suspenders: kill any stray stress-ng on host
        pkill -f stress-ng 2>/dev/null || true
        echo "[cpu_stress] ✓ stress-ng stopped"
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'. Use: start | stop"; exit 1
        ;;
esac
