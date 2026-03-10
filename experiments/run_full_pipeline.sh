#!/bin/bash

# Run full experiment pipeline

echo "Starting eBPF monitoring..."

sudo bpftrace ../ebpf/tcp_retransmissions.bt &
TRACE_PID=$!

echo "Running packet loss experiment..."

./run_packet_loss_experiment.sh

echo "Stopping eBPF tracing..."

kill $TRACE_PID

echo "Full experiment completed."