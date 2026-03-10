#!/bin/bash

# Remove traffic control rules

IFACE=$1

if [ -z "$IFACE" ]; then
    echo "Usage: ./clear_rules.sh <interface>"
    exit 1
fi

echo "Clearing tc rules on ${IFACE}"

sudo tc qdisc del dev $IFACE root

echo "Rules cleared."