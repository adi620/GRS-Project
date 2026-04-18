#!/bin/bash
# inject_fault.sh
# Injects tc netem faults on the web pod's veth (host-side, inside node netns).
# Usage:
#   sudo ./inject_fault.sh delay <ms>
#   sudo ./inject_fault.sh loss <percent>
#   sudo ./inject_fault.sh clear

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run with sudo: sudo $0 $*"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

MODE="${1:-}"
if [ -z "$MODE" ]; then
    echo "Usage: sudo $0 delay <ms> | loss <percent> | clear"
    exit 1
fi

POD_NAME=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
POD_IP=$(kubectl get pod -l app=web \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
    echo "ERROR: Web pod not running or has no IP."
    kubectl get pods
    exit 1
fi
echo "[inject] Pod: ${POD_NAME}  IP: ${POD_IP}"

NODE_NAME=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.nodeName}')
NODE_PID=$(docker inspect "$NODE_NAME" --format '{{.State.Pid}}')
echo "[inject] Node: ${NODE_NAME}  PID: ${NODE_PID}"

ROUTE_OUT=$(nsenter -t "$NODE_PID" -n -- \
    ip route get "$POD_IP" 2>/dev/null || true)
echo "[inject] Route: ${ROUTE_OUT}"

VETH=$(echo "$ROUTE_OUT" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

if [ -z "$VETH" ] || echo "$VETH" | grep -qE "^(cbr|br|kind|docker)"; then
    echo "[inject] Route via bridge, using ARP fallback..."
    POD_MAC=$(nsenter -t "$NODE_PID" -n -- \
        ip neigh show "$POD_IP" 2>/dev/null | awk '{print $5}' | head -1)
    if [ -n "$POD_MAC" ]; then
        for iface in $(nsenter -t "$NODE_PID" -n -- \
                ip -o link show type veth 2>/dev/null | \
                awk -F': ' '{print $2}' | cut -d'@' -f1); do
            PEER_IDX=$(nsenter -t "$NODE_PID" -n -- \
                cat /sys/class/net/"$iface"/iflink 2>/dev/null || echo "")
            for p_dir in /proc/*/net/fib_trie; do
                p=$(echo "$p_dir" | cut -d'/' -f3)
                [[ "$p" =~ ^[0-9]+$ ]] || continue
                if grep -q "$POD_IP" "$p_dir" 2>/dev/null; then
                    PEER_MAC=$(nsenter -t "$p" -n -- \
                        cat /sys/class/net/eth0/address 2>/dev/null || true)
                    if [ "$PEER_MAC" = "$POD_MAC" ]; then
                        VETH="$iface"; break 2
                    fi
                fi
            done
        done
    fi
fi

if [ -z "$VETH" ]; then
    echo "ERROR: Could not identify veth for pod ${POD_NAME}"
    nsenter -t "$NODE_PID" -n -- ip link show
    exit 1
fi
echo "[inject] Target veth: ${VETH}"

nsenter -t "$NODE_PID" -n -- \
    tc qdisc del dev "$VETH" root 2>/dev/null || true

case "$MODE" in
    delay)
        DELAY_MS="${2:-200}"
        nsenter -t "$NODE_PID" -n -- \
            tc qdisc add dev "$VETH" root netem delay "${DELAY_MS}ms"
        echo "[inject] ✓ ${DELAY_MS}ms delay on ${VETH}"
        nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"
        ;;
    loss)
        LOSS_PCT="${2:-20}"
        nsenter -t "$NODE_PID" -n -- \
            tc qdisc add dev "$VETH" root netem loss "${LOSS_PCT}%"
        echo "[inject] ✓ ${LOSS_PCT}% packet loss on ${VETH}"
        nsenter -t "$NODE_PID" -n -- tc qdisc show dev "$VETH"
        ;;
    clear)
        echo "[inject] ✓ Rules cleared from ${VETH}"
        ;;
    *)
        echo "ERROR: Unknown mode '${MODE}'"
        exit 1
        ;;
esac
