# GRS — Real-World Debugging Module

**Part 2 of the GRS project.** Where Part 1 (fault injection pipeline) demonstrates
controlled experiments with *known* causes, this module simulates a real production
on-call scenario: latency is elevated, the cause is unknown, and eBPF is the tool
that identifies it.

---

## The Core Problem

In production, an SRE sees a Grafana alert: **HTTP latency is 10x normal**.
They must answer: is this a network fault? CPU contention? A slow DB query?
All three produce the same symptom from the user's perspective.

This module shows how **eBPF eliminates wrong hypotheses** one by one until only
the real cause remains.

---

## How This Differs from the Fault Injection Pipeline

| | Fault Injection Pipeline | Real-World Module |
|---|---|---|
| Cause known upfront? | Yes — we inject it | No — must diagnose |
| Uses tc netem? | Yes | **Never** |
| Retransmissions expected? | Yes (on loss/reorder) | 0 — proves NOT network |
| Goal | Verify kernel events match fault | Find unknown root cause |
| Realistic? | Lab experiment | Production on-call simulation |

---

## Scenarios

### Scenario 1 — Hidden CPU Contention

A background workload (`stress-ng`) consumes all CPU cores on the node.
The HTTP service is not broken — but its requests have to wait for CPU slices.

**What you see:**
- Latency is **HIGH and JITTERY** — spikes vary between 10ms and 2000ms
- TCP retransmissions: **0**
- Packet drops: **0**
- Scheduler events: **HIGH** — stress-ng processes visible in `sched_stat_runtime`

**eBPF tells you:** Not network. The scheduler is overloaded. Find the process consuming CPU.

---

### Scenario 2 — Application-Level Slowdown

The web pod is patched to sleep 200ms before every response — simulating a slow
database query, a blocking HTTP call, or misconfigured connection pool.

**What you see:**
- Latency is **HIGH but STABLE** — consistently ~200ms above baseline
- TCP retransmissions: **0**
- Packet drops: **0**
- Scheduler events: **Normal** — no CPU contention

**eBPF tells you:** Not network, not CPU. The application itself is slow. Profile the code.

---

## Setup

```bash
# Permissions (run once)
chmod -R +x .

# Verify cluster is running
kubectl cluster-info
kubectl get pods
```

No additional installation needed — uses the same bpftrace and kubectl as the main pipeline.

---

## Running

### Option 1 — Full pipeline (recommended)

```bash
sudo ./real_world_implementation/run_real_world_pipeline.sh
```

Runs both scenarios sequentially (~5 minutes total), generates plot and report.

### Option 2 — Individual scenarios

```bash
# Scenario 1 only
sudo bash real_world_implementation/run_cpu_scenario.sh

# Scenario 2 only
sudo bash real_world_implementation/run_app_delay_scenario.sh
```

### Cleanup (reset environment)

```bash
bash real_world_implementation/cleanup_environment.sh
```

This removes all real-world outputs and reverts the web pod to clean nginx.
It does **not** touch `results/` or any main pipeline files.

---

## Demo Flow (Recommended Order)

```bash
# Step 1: Run the controlled fault injection experiments
sudo ./run_full_pipeline_extended.sh

# Step 2: Run the real-world debugging module
sudo ./real_world_implementation/run_real_world_pipeline.sh

# Step 3: View results
python3 -m http.server 8081 --directory real_world_implementation/measurement/
# Open: http://<VM_IP>:8081/report/real_world_report.html
```

---

## Outputs

All outputs are inside `real_world_implementation/measurement/` — **never** in `results/`.

```
measurement/
├── logs/
│   ├── latency_cpu_noise.csv        ← HTTP latency under CPU noise
│   ├── latency_app_delay.csv        ← HTTP latency under app delay
│   ├── retransmissions_cpu_noise.log ← eBPF: 0 retransmissions expected
│   ├── retransmissions_app_delay.log ← eBPF: 0 retransmissions expected
│   ├── drops_cpu_noise.log          ← eBPF: 0 drops expected
│   ├── drops_app_delay.log          ← eBPF: 0 drops expected
│   ├── sched_cpu_noise.log          ← eBPF: HIGH scheduler events
│   ├── sched_app_delay.log          ← eBPF: normal scheduler events
│   ├── ebpf_cpu_noise.log           ← boundary markers
│   └── ebpf_app_delay.log           ← boundary markers
├── plots/
│   └── real_world_latency_comparison.png
└── report/
    └── real_world_report.html
```

---

## Expected Results

| Scenario | Baseline | Under Fault | Jitter | Retransmissions | Sched Events |
|---|---|---|---|---|---|
| CPU Noise | ~2ms | ~500-2000ms | HIGH | 0 | HIGH (stress-ng visible) |
| App Delay | ~2ms | ~202ms | LOW | 0 | Normal |

The jitter difference is the key diagnostic signal:
- **High jitter = scheduling cause** → find the noisy process
- **Low jitter = application cause** → profile the code
