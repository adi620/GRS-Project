#!/bin/bash
# scripts/sync_results.sh
# Copies results/ CSV and log files into the KIND node at /grs-results/
# so the GRS exporter can read them and expose them as Prometheus metrics.
# Run this after each pipeline execution.
#
# Usage: bash scripts/sync_results.sh

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${PROJECT_ROOT}/results"
KIND_CLUSTER="${KIND_CLUSTER:-grs}"

echo "[sync_results] Syncing results to KIND node..."

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$NODE_NAME" ]; then
    echo "ERROR: No Kubernetes nodes found. Is the cluster running?"
    exit 1
fi

echo "[sync_results] Node: ${NODE_NAME}"
docker exec "$NODE_NAME" mkdir -p /grs-results

COPIED=0
for f in "${RESULTS_DIR}"/*.csv "${RESULTS_DIR}"/*.log; do
    if [ -f "$f" ]; then
        docker cp "$f" "${NODE_NAME}:/grs-results/" && COPIED=$((COPIED+1))
    fi
done

echo "[sync_results] ✓ Copied ${COPIED} files to /grs-results on ${NODE_NAME}"
echo "[sync_results] Prometheus will pick up metrics within 10-15 seconds."

# Trigger exporter refresh if it's running
EXPORTER_POD=$(kubectl get pod -n monitoring -l app=grs-exporter \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$EXPORTER_POD" ]; then
    echo "[sync_results] Exporter pod: ${EXPORTER_POD}"
    echo "[sync_results] Test: kubectl exec -n monitoring ${EXPORTER_POD} -- curl -s localhost:9100/metrics | head -20"
fi
