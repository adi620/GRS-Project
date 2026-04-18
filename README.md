# GRS — Kubernetes eBPF Networking Observability System

**Full fault injection → kernel tracing → application impact → real-time dashboard pipeline.**

```
Fault Injection (tc/stress-ng)
    ↓
Kernel Events (eBPF: kprobe, tracepoint, sched)
    ↓
Application Metrics (HTTP latency CSVs)
    ↓
Prometheus + Grafana (real-time dashboard)
```

---

## Quick Start (TL;DR)

```bash
# 1. Install everything
sudo apt update && sudo apt install -y docker.io kubectl bpftrace stress-ng iproute2 python3-pip curl iperf3
curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64 && chmod +x /usr/local/bin/kind

# 2. Create cluster
kind create cluster --name grs
kubectl config use-context kind-grs

# 3. Fix permissions
chmod -R +x .
chmod -R 777 results/

# 4. Set up observability (Prometheus + Grafana)
bash scripts/setup_observability.sh

# 5. Run the full pipeline
sudo ./run_full_pipeline_extended.sh

# 6. Open Grafana
# http://<VM_IP>:30030  |  admin / grs-admin
```

---

## Table of Contents

1. [System Requirements](#1-system-requirements)
2. [Installation](#2-installation)
3. [Kubernetes Setup](#3-kubernetes-setup)
4. [Permissions Fix](#4-permissions-fix)
5. [Metrics Server](#5-metrics-server)
6. [Observability Stack](#6-observability-stack)
7. [Running the Pipeline](#7-running-the-pipeline)
8. [Grafana Access](#8-grafana-access)
9. [Project Structure](#9-project-structure)
10. [Experiments](#10-experiments)
11. [Results Reference](#11-results-reference)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. System Requirements

| Tool | Version | Purpose |
|---|---|---|
| Ubuntu | 22.04+ | Host OS |
| Docker | 24+ | KIND node runtime |
| kubectl | 1.29+ | Kubernetes CLI |
| kind | 0.23+ | Local Kubernetes cluster |
| bpftrace | 0.19+ | eBPF kernel tracing |
| stress-ng | 0.15+ | CPU fault injection |
| iproute2 / tc | any | Network fault injection |
| python3 | 3.10+ | Reports + exporter |
| python3-pip | any | Python dependencies |
| curl | any | HTTP latency measurement |
| iperf3 | 3+ | Bandwidth validation (optional) |

Minimum hardware: **2 CPU cores, 4 GB RAM, 10 GB disk**

---

## 2. Installation

### All dependencies — one command

```bash
sudo apt update && sudo apt install -y \
    docker.io \
    kubectl \
    bpftrace \
    stress-ng \
    iproute2 \
    python3 \
    python3-pip \
    curl \
    iperf3 \
    linux-headers-$(uname -r) \
    clang \
    llvm \
    libelf-dev

# kind (not in apt)
curl -Lo /usr/local/bin/kind \
    https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x /usr/local/bin/kind

# Python packages
pip3 install matplotlib pandas prometheus_client --break-system-packages
```

### Add user to docker group (avoids sudo for docker commands)

```bash
sudo usermod -aG docker $USER
newgrp docker
```

---

## 3. Kubernetes Setup

### Create the KIND cluster

```bash
kind create cluster --name grs --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30090
        hostPort: 30090
        protocol: TCP
      - containerPort: 30030
        hostPort: 30030
        protocol: TCP
EOF
```

> The `extraPortMappings` expose NodePort 30090 (Prometheus) and 30030 (Grafana)
> directly on the host machine.

### Verify cluster

```bash
kubectl cluster-info --context kind-grs
kubectl get nodes
# Expected: grs-control-plane   Ready
```

### Set context

```bash
kubectl config use-context kind-grs
```

---

## 4. Permissions Fix

**Run this before every pipeline execution:**

```bash
chmod -R +x .
chmod -R 777 results/
```

This ensures all shell scripts are executable and the results directory is writable
by both the pipeline (run as sudo) and any post-processing scripts.

---

## 5. Metrics Server

Required for `kubectl top pods` to work (pod CPU/memory metrics).

### Install and patch for KIND

```bash
bash scripts/install_metrics_server.sh
```

This script:
1. Applies the official metrics-server manifest
2. Patches it with `--kubelet-insecure-tls` (required for KIND self-signed certs)
3. Patches it with `--kubelet-preferred-address-types=InternalIP`
4. Waits for the rollout to complete

### Verify

```bash
kubectl top nodes
kubectl top pods -A
```

If `kubectl top` returns `error: Metrics API not available` — wait 60s and retry.

---

## 6. Observability Stack

### Deploy Prometheus + Grafana + Exporter

```bash
bash scripts/setup_observability.sh
```

This script:
1. Creates `/grs-results/` on the KIND node
2. Installs and patches metrics-server
3. Builds the `grs-exporter` Docker image and loads it into KIND
4. Deploys Prometheus (NodePort 30090)
5. Deploys Grafana (NodePort 30030) with pre-configured datasource and dashboard
6. Deploys the GRS Prometheus exporter

### After each pipeline run, sync results

```bash
bash scripts/sync_results.sh
```

This copies CSV/log files from `results/` into the KIND node so the exporter
can read them. Grafana updates within 10-15 seconds.

### Verify deployment

```bash
kubectl get pods -n monitoring
# Expected:
# NAME                           READY   STATUS
# prometheus-xxx                 1/1     Running
# grafana-xxx                    1/1     Running
# grs-exporter-xxx               1/1     Running
```

---

## 7. Running the Pipeline

### Full pipeline (recommended)

```bash
sudo ./run_full_pipeline_extended.sh
```

Runs all 7 experiments sequentially (~12 minutes total):

| Step | Experiment | Duration |
|---|---|---|
| 4 | Baseline (no fault) | 60s |
| 5 | 200ms network delay | 60s |
| 6 | 20% packet loss | 60s |
| 7 | 1mbit bandwidth cap | 60s |
| 8 | 25% packet reordering | 60s |
| 9 | CPU stress (4 workers) | **90s** |
| 10 | Chaos: loss + CPU stress | **90s** |

After completion, results are automatically synced to Grafana.

### Individual experiments

```bash
sudo bash experiments/run_baseline.sh
sudo bash experiments/run_delay.sh
sudo bash experiments/run_loss.sh
sudo bash experiments/run_bandwidth.sh
sudo bash experiments/run_reordering.sh
sudo bash experiments/run_cpu_stress.sh
sudo bash experiments/run_chaos_combined.sh
```

### Environment overrides

```bash
# Longer CPU experiment
CPU_DURATION=120 sudo bash experiments/run_cpu_stress.sh

# Different loss percentage
LOSS_PCT=30 sudo bash experiments/run_loss.sh

# Specify a different kind cluster
KIND_CLUSTER=mylab sudo ./run_full_pipeline_extended.sh
```

---

## 8. Grafana Access

### URLs

```
Grafana:    http://<VM_IP>:30030   (NodePort)
Prometheus: http://<VM_IP>:30090   (NodePort)

Default credentials: admin / grs-admin
```

Find your VM IP:
```bash
ip addr show | grep 'inet ' | grep -v 127 | awk '{print $2}' | cut -d/ -f1
```

### Port-forward (if NodePort not reachable from host)

```bash
# Run in background
kubectl port-forward -n monitoring svc/grafana 3000:3000 --address 0.0.0.0 &
kubectl port-forward -n monitoring svc/prometheus 9090:9090 --address 0.0.0.0 &

# Access
http://localhost:3000   # Grafana
http://localhost:9090   # Prometheus
```

### Dashboard

The **GRS — eBPF Fault Injection Dashboard** is auto-provisioned on startup.
It includes 18 panels covering:

| Panel | Data Source |
|---|---|
| HTTP Latency per experiment (time series) | GRS exporter |
| Mean/max/p95 latency gauges | GRS exporter |
| Mean latency bar gauge (all experiments) | GRS exporter |
| TCP retransmissions over time | GRS exporter (retransmissions.log) |
| Packet drops by reason code | GRS exporter (packet_drops.log) |
| Container CPU (cAdvisor) | Prometheus |
| Container memory (cAdvisor) | Prometheus |
| Pod CPU from kubectl top | GRS exporter (pod_metrics_*.csv) |
| Pod memory from kubectl top | GRS exporter |
| Bandwidth throughput vs 1mbit cap | GRS exporter (bandwidth_throughput.csv) |
| Scheduler runtime per process | GRS exporter (sched_latency.log) |
| **Correlation: Latency + CPU + Retransmissions** | GRS exporter |

### Import dashboard manually (if not auto-loaded)

1. Open Grafana → Dashboards → Import
2. Upload `observability/grafana/dashboard-configmap.yaml`
   (extract the JSON from the `grs-dashboard.json:` key)
3. Select Prometheus as data source → Import

---

## 9. Project Structure

```
GRS-Project/
├── run_full_pipeline_extended.sh   # Main pipeline (7 experiments + reports)
├── generate_report_extended.sh     # HTML report with embedded Chart.js
├── generate_fault_matrix.sh        # Markdown fault→kernel→app table
├── generate_diff_report.sh         # Regression comparison report
├── plot_results_extended.py        # Static PNG chart (3-panel)
│
├── deployment/
│   ├── web-deployment.yaml         # nginx web pod
│   └── web-service.yaml            # ClusterIP service
│
├── traffic/
│   └── traffic.yaml                # curl traffic generator pod
│
├── ebpf/
│   ├── tcp_retransmissions.bt      # kprobe:tcp_retransmit_skb
│   ├── packet_drops.bt             # tracepoint:skb:kfree_skb
│   └── sched_latency.bt            # tracepoint:sched:sched_stat_runtime (ALL procs)
│
├── experiments/
│   ├── run_baseline.sh
│   ├── run_delay.sh
│   ├── run_loss.sh
│   ├── run_bandwidth.sh            # + 1MB throughput test
│   ├── run_reordering.sh
│   ├── run_cpu_stress.sh           # + sched_latency eBPF
│   └── run_chaos_combined.sh       # loss 20% + CPU stress
│
├── fault_injection/
│   ├── inject_fault.sh             # delay / loss / clear (dynamic veth)
│   ├── bandwidth.sh                # tc tbf rate 1mbit burst 1500 latency 50ms
│   ├── reordering.sh               # tc netem reorder
│   ├── cpu_stress.sh               # stress-ng in KIND node container
│   ├── chaos_combined.sh           # loss + CPU simultaneously
│   └── debug_network.sh
│
├── measurement/
│   ├── measure_latency.sh          # curl-based HTTP timing
│   └── pod_metrics_sample.sh       # kubectl top pods sampler
│
├── observability/
│   ├── prometheus/
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml               # ClusterRole for pod/node scraping
│   │   ├── configmap.yaml          # prometheus.yml with all scrape jobs
│   │   └── deployment.yaml         # NodePort 30090
│   ├── grafana/
│   │   ├── deployment.yaml         # NodePort 30030
│   │   ├── datasources.yaml        # Prometheus auto-provisioning
│   │   ├── dashboard-provider.yaml # Dashboard folder provisioning
│   │   └── dashboard-configmap.yaml # GRS dashboard JSON (18 panels)
│   └── exporters/
│       ├── grs_exporter.py         # Python Prometheus exporter
│       ├── Dockerfile
│       └── deployment.yaml         # HostPath mount to /grs-results
│
├── scripts/
│   ├── setup_observability.sh      # Deploy entire stack
│   ├── sync_results.sh             # Copy results/ to KIND node
│   └── install_metrics_server.sh   # metrics-server + KIND patch
│
└── results/                        # Generated by pipeline
    ├── baseline.csv / delay.csv / loss.csv ...
    ├── bandwidth_throughput.csv
    ├── sched_latency.log
    ├── retransmissions.log
    ├── packet_drops.log
    ├── pod_metrics_*.csv
    ├── report_extended.html        # Self-contained HTML dashboard
    ├── diff_report.html            # Regression comparison
    ├── fault_matrix.md
    ├── latency_comparison_extended.png
    └── baseline_reference.json
```

---

## 10. Experiments

### Fault injection methods

| Experiment | Command | Kernel Signal | Expected Impact |
|---|---|---|---|
| Baseline | none | none | ~2ms latency |
| Delay 200ms | `tc netem delay 200ms` | none | 402ms latency (200×2) |
| Loss 20% | `tc netem loss 20%` | `tcp_retransmit_skb` | Bimodal: fast OR 200ms/1s/2s backoff |
| Bandwidth 1mbit | `tc tbf rate 1mbit burst 1500 latency 50ms` | queue buildup | Throttled throughput on large transfers |
| Reorder 25% | `tc netem delay 100ms reorder 25% 50%` | duplicate ACKs | 100ms base + fast-retransmit path |
| CPU Stress | `stress-ng --cpu 4 --timeout 90s` | `sched_stat_runtime` | 900ms+ jitter |
| Chaos | loss 20% + stress-ng | both | 2.6s+ mean (amplification effect) |

### eBPF probes

| Probe | File | When it fires |
|---|---|---|
| `kprobe:tcp_retransmit_skb` | retransmissions.log | Any TCP segment retransmit |
| `tracepoint:skb:kfree_skb` | packet_drops.log | Kernel packet discard (reason 82 = tc netem) |
| `tracepoint:sched:sched_stat_runtime` | sched_latency.log | Every scheduling quantum for all processes |

### Log boundary markers

All log files contain experiment markers:
```
=== START loss_20pct ts=1775591163751000000 ===
... events during experiment ...
=== END loss_20pct ts=1775591223751000000 ===
```

---

## 11. Results Reference

### Typical results (validated run)

| Experiment | Mean | Max | Samples | Notes |
|---|---|---|---|---|
| Baseline | 1.8ms | 3.8ms | 48 | Clean floor |
| Delay | 402.7ms | 405.2ms | 37 | 200ms×2, deterministic |
| Loss 20% | 243ms | 2058ms | 40 | Bimodal, TCP backoff visible |
| Bandwidth | 2.1ms | 4.4ms | 47 | Small payload unaffected; 1MB shows throttling |
| Reordering | 187.7ms | 203.5ms | 41 | Two tiers: 100ms (fast-retransmit) + 200ms |
| CPU Stress | 966ms | 1997ms | 7 | n=7 due to slow curl under stress |
| Chaos | 2643ms | 3810ms | 5 | 2.2× additive prediction — amplification confirmed |

### Key findings

1. **Delay ≠ Loss**: Delay produces zero retransmissions; loss produces exponential backoff spikes
2. **TCP backoff tiers**: 200ms → 1s → 2s pattern is the kernel RTO doubling algorithm
3. **Chaos amplification**: Combined loss+CPU = 2643ms vs additive prediction of 1210ms
4. **Bandwidth TBF burst**: After fixing burst from 32kbit to 1500, single-MTU limiting is enforced

### Diff report usage

```bash
# Save current run as reference baseline
bash generate_diff_report.sh --save-as-reference

# After any changes, run pipeline then compare
sudo ./run_full_pipeline_extended.sh
bash generate_diff_report.sh
# Open results/diff_report.html — red ▲ = regression
```

---

## 12. Troubleshooting

### Pipeline fails with "kubeconfig not found"
```bash
# Run as ubuntu user with sudo (not as root directly)
sudo ./run_full_pipeline_extended.sh
# If still failing:
export KUBECONFIG=/home/ubuntu/.kube/config
sudo -E ./run_full_pipeline_extended.sh
```

### "Context kind-grs not found"
```bash
kind get clusters           # check cluster name
kubectl config get-contexts # check available contexts
# Fix: KIND_CLUSTER=<name> sudo ./run_full_pipeline_extended.sh
```

### CPU stress experiment has only n=5–7 samples
This is expected — stress-ng saturates the CPU so each curl request
takes 7–8 seconds. Increase duration:
```bash
CPU_DURATION=120 sudo bash experiments/run_cpu_stress.sh
```

### Pod metrics CSVs are empty
metrics-server is not installed or not ready:
```bash
bash scripts/install_metrics_server.sh
kubectl top pods  # should show CPU/memory
```

### Bandwidth throughput still too high
Verify the TBF rule is applied:
```bash
# Find the veth
POD_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
NODE_PID=$(docker inspect grs-control-plane --format '{{.State.Pid}}')
nsenter -t $NODE_PID -n -- tc qdisc show
# Should show: qdisc tbf 8001: root rate 1Mbit burst 1500b lat 50ms
```

### Grafana shows "No data"
1. Run the pipeline: `sudo ./run_full_pipeline_extended.sh`
2. Sync results: `bash scripts/sync_results.sh`
3. Wait 15 seconds
4. Check exporter:
```bash
kubectl port-forward -n monitoring svc/grs-exporter 9100:9100 &
curl http://localhost:9100/metrics | grep grs_
```

### Grafana not accessible at NodePort
KIND NodePort requires the cluster to have been created with extraPortMappings.
Use port-forward instead:
```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000 --address 0.0.0.0 &
# Then access: http://localhost:3000
```

### bpftrace: "Error attaching probe"
Requires root and kernel debug symbols:
```bash
sudo apt install linux-headers-$(uname -r) -y
# Run with sudo
sudo bpftrace ebpf/tcp_retransmissions.bt
```

### "Image pull backoff" for grs-exporter
The exporter image must be built and loaded into KIND:
```bash
docker build -t grs-exporter:latest observability/exporters/
kind load docker-image grs-exporter:latest --name grs
kubectl rollout restart deployment/grs-exporter -n monitoring
```

### Reset everything
```bash
kubectl delete namespace monitoring
kind delete cluster --name grs
kind create cluster --name grs
bash scripts/setup_observability.sh
```
