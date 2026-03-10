#!/bin/bash

# Run baseline experiment without network faults

echo "Starting baseline experiment..."

echo "Measuring latency for 60 seconds"

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

echo "Baseline experiment completed."