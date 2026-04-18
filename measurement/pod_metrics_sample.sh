#!/bin/bash
# measurement/pod_metrics_sample.sh
# Background pod metrics sampler — runs kubectl top pods every 5s for DURATION seconds.
# Usage: source this file, call start_pod_metrics <output_csv> <duration_s>
#        then stop_pod_metrics when done.
#
# The caller must set KUBECONFIG before sourcing this file.

_POD_METRICS_PID=""

start_pod_metrics() {
    local output_csv="$1"
    local duration="${2:-60}"
    echo "timestamp,pod,cpu_millicores,memory_mi" > "$output_csv"
    (
        local end_ts=$(( $(date +%s) + duration + 5 ))
        while [ "$(date +%s)" -lt "$end_ts" ]; do
            local ts; ts=$(date +%s%3N)
            # kubectl top pods may fail if metrics-server not installed — suppress errors
            kubectl top pods --no-headers 2>/dev/null | while IFS=' ' read -r pod cpu mem; do
                # cpu is "5m" format, strip the 'm' to get millicores
                local cpu_m; cpu_m="${cpu%m}"
                # mem is "10Mi" format, strip the 'Mi'
                local mem_m; mem_m="${mem%Mi}"
                echo "${ts},${pod},${cpu_m},${mem_m}" >> "$output_csv"
            done || true
            sleep 5
        done
    ) &
    _POD_METRICS_PID=$!
    echo "[pod_metrics] Sampler started (PID ${_POD_METRICS_PID}) → ${output_csv}"
}

stop_pod_metrics() {
    if [ -n "$_POD_METRICS_PID" ]; then
        kill "$_POD_METRICS_PID" 2>/dev/null || true
        wait "$_POD_METRICS_PID" 2>/dev/null || true
        echo "[pod_metrics] Sampler stopped"
        _POD_METRICS_PID=""
    fi
}
