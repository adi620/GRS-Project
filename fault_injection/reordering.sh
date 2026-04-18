#!/bin/bash
# fault_injection/reordering.sh
# Injects packet reordering on the web pod's veth using tc netem.
# 25% of packets are reordered with a 100ms base delay.
# Causes TCP duplicate ACKs and retransmit behaviour.
#
# Usage:
#   sudo ./fault_injection/reordering.sh inject [delay_ms] [reorder_pct]
#   sudo ./fault_injection/reordering.sh clear

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo $0 $*"; exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

MODE="${1:-inject}"
DELAY_MS="${2:-100}"
REORDER_PCT="${3:-25}"

# ── Resolve web pod veth ──────────────────────────────────────
POD_NAME=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
POD_IP=$(kubectl get pod -l app=web   -o jsonpath='{.items[0].status.podIP}'  2>/dev/null)
if [ -z "$POD_IP" ]; then
    echo "ERROR: Web pod not running."; kubectl get pods; exit 1
fi
echo "[reordering] Pod: ${POD_NAME}  IP: ${POD_IP}"

NODE_NAME=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')
echo "[reordering] Node: ${NODE_NAME}  PID: ${NODE_PID}"

ROUTE_OUT=$(nsenter -t "$NODE_PID" -n -- ip route get "$POD_IP" 2>/dev/null || true)
VETH=$(echo "$ROUTE_OUT" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

if [ -z "$VETH" ] || echo "$VETH" | grep -qE "^(cbr|br|kind|docker)"; then
    POD_MAC=$(nsenter -t "$NODE_PID" -n -- ip neigh show "$POD_IP" 2>/dev/null | awk '{print $5}' | head -1)
    if [ -n "$POD_MAC" ]; then
        for iface in $(nsenter -t "$NODE_PID" -n -- ip -o link show type veth 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1); do
            for p_dir in /proc/*/net/fib_trie; do
                p=$(echo "$p_dir" | cut -d'/' -f3)
                [[ "$p" =~ ^[0-9]+$ ]] || continue
                if grep -q "$POD_IP" "$p_dir" 2>/dev/null; then
                    PEER_MAC=$(nsenter -t "$p" -n -- cat /sys/class/net/eth0/address 2>/dev/null || true)
                    if [ "$PEER_MAC" = "$POD_MAC" ]; then VETH="$iface"; break 2; fi
                fi
            done
        done
    fi
fi

if [ -z "$VETH" ]; then
    echo "ERROR: Could not identify veth for ${POD_NAME}"
    nsenter -t "$NODE_PID" -n -- ip link show; exit 1
fi
echo "[reordering] Target veth: ${VETH}"

nsenter -t "$NODE_PID" -n -- tc qdisc del dev "$VETH" root 2>/dev/null || true

case "$MODE" in
    inject)
        # netem: delay base packets by DELAY_MS, then reorder REORDER_PCT% with 50% correlation
        nsenter -t "$NODE_PID" -n -- \
            tc qdisc add dev "$VETH" root netem delay "${DELAY_MS}ms" \
            reorder "${REORDER_PCT}%" 50%
        echo "[reordering] ✓ ${REORDER_PCT}% reorder + ${DELAY_MS}ms delay on ${VETH}"
        nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"
        ;;
    clear)
        echo "[reordering] ✓ Reordering rules cleared from ${VETH}"
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'. Use: inject | clear"; exit 1
        ;;
esac
