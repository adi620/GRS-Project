#!/bin/bash
# scenarios/app_delay/revert_app_delay.sh
# Removes the sleep-based delay from the web pod by redeploying
# the original clean nginx image without any modification.
set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

echo "[app_delay] Reverting web deployment to clean nginx..."

kubectl patch deployment web \
    --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"nginx:stable"},
         {"op":"replace","path":"/spec/template/spec/containers/0/command","value":[]},
         {"op":"replace","path":"/spec/template/spec/containers/0/args","value":[]}]' \
    2>/dev/null || \
kubectl set image deployment/web web=nginx:stable

kubectl rollout status deployment/web --timeout=60s
echo "[app_delay] ✓ Web pod reverted to clean nginx — no application delay"
