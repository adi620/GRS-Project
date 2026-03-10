#!/bin/bash

# Run experiment with packet loss

INTERFACE=vethc130740

echo "Injecting 10% packet loss..."

sudo tc qdisc add dev $INTERFACE root netem loss 10%

echo "Running traffic and measuring latency..."

START=$(date +%s)

while true
do
    kubectl exec traffic -- curl -o /dev/null -s -w "%{time_total}\n" web
    sleep 1

    NOW=$(date +%s)

    if [ $((NOW - START)) -gt 60 ]; then
        break
    fi
done

echo "Removing packet loss..."

sudo tc qdisc del dev $INTERFACE root

echo "Packet loss experiment completed."