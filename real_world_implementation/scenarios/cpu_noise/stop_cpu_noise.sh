#!/bin/bash
# scenarios/cpu_noise/stop_cpu_noise.sh
# Stops the background CPU stressors on the KIND node.
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$NODE" ]; then echo "[cpu_noise] No node found — nothing to stop"; exit 0; fi

echo "[cpu_noise] Stopping stress-ng on node ${NODE}..."
docker exec "$NODE" pkill -f stress-ng 2>/dev/null && \
    echo "[cpu_noise] ✓ stress-ng stopped" || \
    echo "[cpu_noise] stress-ng was not running (already stopped)"
rm -f /tmp/grs_cpu_noise.pid 2>/dev/null || true
