#!/bin/bash

# Measure HTTP response time from traffic pod to web service

echo "Starting latency measurement..."

while true
do
    kubectl exec traffic -- curl -o /dev/null -s -w "%{time_total}\n" web
    sleep 1
done