#!/bin/bash
# scripts/install_metrics_server.sh
# Standalone script to install and patch metrics-server for KIND.
# Idempotent — safe to run multiple times.

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[metrics-server] Installing..."
METRICS_VERSION="v0.7.1"

kubectl apply -f \
    "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VERSION}/components.yaml"

echo "[metrics-server] Patching for KIND (insecure TLS + InternalIP)..."
sleep 3
kubectl patch deployment metrics-server -n kube-system \
    --type=json \
    -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
      {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}
    ]'

echo "[metrics-server] Waiting for ready..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

echo "[metrics-server] ✓ Installed and ready"
echo "[metrics-server] Test: kubectl top nodes && kubectl top pods -A"
