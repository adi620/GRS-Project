# Fault Injection

This directory contains scripts used to introduce controlled network faults in the Kubernetes environment. The purpose is to simulate real networking issues so that kernel-level events can be observed using the eBPF tracing scripts.

## Flow of the Experiment

1. Start the Kubernetes cluster and deploy the workload (web pod and traffic pod).
2. Run the eBPF tracing scripts to monitor kernel networking events.
3. Inject a network fault using one of the fault injection scripts.
4. Observe how the kernel reacts through the eBPF traces (e.g., retransmissions or packet drops).
5. Clear the injected fault after the experiment.
