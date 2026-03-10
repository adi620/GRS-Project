#!/bin/bash

# Inject network delay using tc netem
# Usage: ./inject_delay.sh <interface> <delay_ms>

IFACE=$1
DELAY=$2

if [ -z "$IFACE" ] || [ -z "$DELAY" ]; then
    echo "Usage: ./inject_delay.sh <interface> <delay_ms>"
    exit 1
fi

echo "Injecting ${DELAY} ms delay on interface ${IFACE}"

sudo tc qdisc add dev $IFACE root netem delay ${DELAY}ms

echo "Delay injected."