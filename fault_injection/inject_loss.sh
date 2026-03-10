#!/bin/bash

# Inject packet loss using tc netem
# Usage: ./inject_loss.sh <interface> <loss_percentage>

IFACE=$1
LOSS=$2

if [ -z "$IFACE" ] || [ -z "$LOSS" ]; then
    echo "Usage: ./inject_loss.sh <interface> <loss_percentage>"
    exit 1
fi

echo "Injecting ${LOSS}% packet loss on interface ${IFACE}"

sudo tc qdisc add dev $IFACE root netem loss ${LOSS}%

echo "Packet loss injected."