#!/bin/bash

# Run experiment with artificial network delay

INTERFACE=vethc130740

echo "Injecting 100ms network delay..."

sudo tc qdisc add dev $INTERFACE root netem delay 100ms

echo "Running latency measurement..."

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

echo "Removing delay rule..."

sudo tc qdisc del dev $INTERFACE root

echo "Delay experiment completed."