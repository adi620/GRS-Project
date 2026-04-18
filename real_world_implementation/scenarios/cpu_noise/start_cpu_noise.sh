#!/bin/bash
# scenarios/cpu_noise/start_cpu_noise.sh
# Simulates a "noisy neighbour" situation on the Kubernetes node.
# In real production, this represents another workload consuming CPU —
# the ops team sees latency spikes but has NO idea why (no network faults).
#
# Method: run stress-ng directly on the KIND node via docker exec.
# This is NOT the fault injection path — it bypasses all tc rules entirely.
# The degradation shows up as scheduling jitter, not network drops.

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

KIND_CLUSTER="${KIND_CLUSTER:-grs}"
WORKERS="${CPU_WORKERS:-4}"
DURATION="${CPU_NOISE_DURATION:-90}"

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE" ]; then
    echo "ERROR: No Kubernetes nodes found. Is the cluster running?"; exit 1
fi

echo "[cpu_noise] Starting ${WORKERS} CPU stressors on node ${NODE} for ${DURATION}s"
echo "[cpu_noise] This simulates a noisy neighbour — no network faults injected"

# Install stress-ng on node if not present
docker exec "$NODE" sh -c "command -v stress-ng &>/dev/null || \
    (apt-get update -qq && apt-get install -y -qq stress-ng)" 2>/dev/null || true

# Start stress-ng in background on the node
docker exec -d "$NODE" \
    stress-ng --cpu "$WORKERS" --timeout "${DURATION}s" --quiet

# Record the PID file for stop script
docker exec "$NODE" sh -c \
    "pgrep stress-ng | head -1 > /tmp/grs_cpu_noise.pid 2>/dev/null; \
     echo 'stress-ng PIDs:'; pgrep stress-ng || echo none"

echo "[cpu_noise] ✓ CPU noise active (${WORKERS} workers, ${DURATION}s)"
echo "[cpu_noise]   Node load will increase — latency jitter expected"
echo "[cpu_noise]   Stop early: bash scenarios/cpu_noise/stop_cpu_noise.sh"
