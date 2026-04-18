#!/bin/bash
# debug_network.sh — tests fault injection end-to-end before the full pipeline
# Usage: sudo ./fault_injection/debug_network.sh

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
kubectl config use-context "kind-${KIND_CLUSTER:-grs}" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "════════════════════════════════════════"
echo " Network Fault Injection Debug Tool"
echo "════════════════════════════════════════"
echo ""
echo "── 1. Pod status ──"
kubectl get pods -o wide
echo ""
echo "── 2. Baseline latency (expect ~1-5ms) ──"
for i in 1 2 3; do
    R=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 10 http://web/ 2>/dev/null)
    echo "  Request ${i}: ${R}s"
done
echo ""
echo "── 3. Injecting 500ms delay ──"
"${SCRIPT_DIR}/inject_fault.sh" delay 500
echo ""
echo "── 4. Latency WITH 500ms delay (expect ~1.0s) ──"
for i in 1 2 3; do
    R=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 15 http://web/ 2>/dev/null)
    echo "  Request ${i}: ${R}s"
done
echo ""
echo "── 5. Clearing fault ──"
"${SCRIPT_DIR}/inject_fault.sh" clear
echo ""
echo "── 6. Latency after clear (expect ~1-5ms) ──"
for i in 1 2 3; do
    R=$(kubectl exec traffic -- curl -s -o /dev/null \
        -w "%{time_total}" --max-time 10 http://web/ 2>/dev/null)
    echo "  Request ${i}: ${R}s"
done
echo ""
echo "════ RESULT ════════════════════════════"
echo "Step 4 ~1.0s → injection WORKING ✓"
echo "Step 4 ~0.001s → injection NOT working ✗"
echo "════════════════════════════════════════"
