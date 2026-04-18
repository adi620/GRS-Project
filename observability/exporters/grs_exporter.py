#!/usr/bin/env python3
"""
grs_exporter.py — Prometheus metrics exporter for GRS project.

Reads results CSVs and eBPF log files, exposes them as Prometheus metrics
at http://0.0.0.0:9100/metrics so Grafana can scrape them.

Metrics exposed:
  grs_latency_milliseconds{experiment}       — per-sample latency gauge
  grs_latency_mean_milliseconds{experiment}  — rolling mean
  grs_latency_p95_milliseconds{experiment}   — p95
  grs_latency_max_milliseconds{experiment}   — max
  grs_tcp_retransmissions_total              — counter from retransmissions.log
  grs_packet_drops_total{reason}             — counter from packet_drops.log
  grs_sched_events_total                     — counter from sched_latency.log
  grs_sched_runtime_ns{comm,pid}             — latest sched runtime per process
  grs_pod_cpu_millicores{pod,experiment}     — from pod_metrics_*.csv
  grs_pod_memory_mi{pod,experiment}          — from pod_metrics_*.csv
  grs_bandwidth_speed_bytes_per_sec          — from bandwidth_throughput.csv
  grs_current_experiment                     — which experiment ran last

Usage:
  python3 grs_exporter.py [--results-dir /path/to/results] [--port 9100]
  Then: curl http://localhost:9100/metrics
"""

import os
import re
import time
import csv
import argparse
import threading
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict

# ── Install prometheus_client if missing ──────────────────────
try:
    from prometheus_client import (
        Gauge, Counter, Histogram, CollectorRegistry,
        generate_latest, CONTENT_TYPE_LATEST
    )
except ImportError:
    import subprocess, sys
    subprocess.check_call([sys.executable, "-m", "pip", "install",
                           "prometheus_client", "--break-system-packages", "-q"])
    from prometheus_client import (
        Gauge, Counter, CollectorRegistry,
        generate_latest, CONTENT_TYPE_LATEST
    )

# ── Prometheus metrics registry ───────────────────────────────
REGISTRY = CollectorRegistry()

# Latency metrics
g_latency      = Gauge("grs_latency_milliseconds",
                        "HTTP latency per experiment (ms)",
                        ["experiment"], registry=REGISTRY)
g_lat_mean     = Gauge("grs_latency_mean_milliseconds",
                        "Mean latency per experiment (ms)",
                        ["experiment"], registry=REGISTRY)
g_lat_p95      = Gauge("grs_latency_p95_milliseconds",
                        "p95 latency per experiment (ms)",
                        ["experiment"], registry=REGISTRY)
g_lat_max      = Gauge("grs_latency_max_milliseconds",
                        "Max latency per experiment (ms)",
                        ["experiment"], registry=REGISTRY)
g_lat_samples  = Gauge("grs_latency_sample_count",
                        "Number of latency samples",
                        ["experiment"], registry=REGISTRY)

# eBPF metrics
g_retrans      = Gauge("grs_tcp_retransmissions_total",
                        "Total TCP retransmissions from eBPF log",
                        registry=REGISTRY)
g_drops        = Gauge("grs_packet_drops_total",
                        "Packet drops from kfree_skb eBPF log",
                        ["reason"], registry=REGISTRY)
g_sched_total  = Gauge("grs_sched_events_total",
                        "Total scheduler events captured",
                        registry=REGISTRY)
g_sched_rt     = Gauge("grs_sched_runtime_ns",
                        "Latest scheduler runtime per process (ns)",
                        ["comm", "pid"], registry=REGISTRY)

# Pod metrics
g_pod_cpu      = Gauge("grs_pod_cpu_millicores",
                        "Pod CPU usage in millicores",
                        ["pod", "experiment"], registry=REGISTRY)
g_pod_mem      = Gauge("grs_pod_memory_mi",
                        "Pod memory usage in Mi",
                        ["pod", "experiment"], registry=REGISTRY)

# Bandwidth metrics
g_bw_speed     = Gauge("grs_bandwidth_speed_bytes_per_sec",
                        "Download speed from bandwidth experiment (B/s)",
                        registry=REGISTRY)

# Status
g_current_exp  = Gauge("grs_current_experiment",
                        "Index of the last completed experiment (0=baseline, 6=chaos)",
                        registry=REGISTRY)
g_last_update  = Gauge("grs_exporter_last_update_timestamp",
                        "Unix timestamp of last metrics update",
                        registry=REGISTRY)


EXPERIMENT_NAMES = [
    "baseline", "delay", "loss", "bandwidth",
    "reordering", "cpu_stress", "chaos_combined"
]

EXPERIMENT_INDEX = {n: i for i, n in enumerate(EXPERIMENT_NAMES)}


def safe_float(s, default=0.0):
    try:
        return float(s)
    except (ValueError, TypeError):
        return default


def load_latency_csv(path: Path, experiment: str):
    """Parse a latency CSV and update Prometheus gauges."""
    if not path.exists():
        return
    rows = []
    try:
        with open(path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                v = safe_float(row.get("latency_seconds", ""))
                if v > 0:
                    rows.append(v * 1000.0)  # → ms
    except Exception:
        return

    if not rows:
        return

    rows_sorted = sorted(rows)
    n = len(rows_sorted)
    mean = sum(rows_sorted) / n
    p95  = rows_sorted[int(n * 0.95)]
    mx   = rows_sorted[-1]
    last = rows_sorted[-1]

    g_latency.labels(experiment=experiment).set(last)
    g_lat_mean.labels(experiment=experiment).set(mean)
    g_lat_p95.labels(experiment=experiment).set(p95)
    g_lat_max.labels(experiment=experiment).set(mx)
    g_lat_samples.labels(experiment=experiment).set(n)


def load_retransmissions(path: Path):
    """Count RETRANSMIT lines in retransmissions.log."""
    if not path.exists():
        return
    try:
        count = 0
        with open(path) as f:
            for line in f:
                if "RETRANSMIT" in line:
                    count += 1
        g_retrans.set(count)
    except Exception:
        pass


def load_packet_drops(path: Path):
    """Count drops by reason code from packet_drops.log."""
    if not path.exists():
        return
    reason_counts = defaultdict(int)
    try:
        with open(path) as f:
            for line in f:
                # Format: timestamp  tracepoint:skb:kfree_skb  reason_code  DROP
                parts = line.split()
                if len(parts) >= 4 and parts[-1] == "DROP":
                    try:
                        reason = int(parts[2])
                        reason_counts[reason] += 1
                    except ValueError:
                        pass
    except Exception:
        pass
    for reason, count in reason_counts.items():
        g_drops.labels(reason=str(reason)).set(count)


def load_sched_latency(path: Path):
    """Parse sched_latency.log — last value per comm/pid pair."""
    if not path.exists():
        return
    last_rt = {}   # (comm, pid) → runtime_ns
    total   = 0
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 4:
                    try:
                        comm = parts[1]
                        pid  = parts[2]
                        rt   = int(parts[3])
                        last_rt[(comm, pid)] = rt
                        total += 1
                    except (ValueError, IndexError):
                        pass
    except Exception:
        pass

    g_sched_total.set(total)
    # Only expose top-10 by runtime to avoid label explosion
    top = sorted(last_rt.items(), key=lambda x: x[1], reverse=True)[:10]
    for (comm, pid), rt in top:
        g_sched_rt.labels(comm=comm, pid=pid).set(rt)


def load_pod_metrics(results_dir: Path):
    """Load pod_metrics_<experiment>.csv files."""
    for exp in EXPERIMENT_NAMES:
        path = results_dir / f"pod_metrics_{exp}.csv"
        if not path.exists():
            continue
        try:
            with open(path) as f:
                reader = csv.DictReader(f)
                rows = list(reader)
            if not rows:
                continue
            # Use last row per pod
            last_by_pod = {}
            for row in rows:
                pod = row.get("pod", "")
                if pod:
                    last_by_pod[pod] = row
            for pod, row in last_by_pod.items():
                cpu = safe_float(row.get("cpu_millicores", "0"))
                mem = safe_float(row.get("memory_mi", "0"))
                if cpu > 0:
                    g_pod_cpu.labels(pod=pod, experiment=exp).set(cpu)
                if mem > 0:
                    g_pod_mem.labels(pod=pod, experiment=exp).set(mem)
        except Exception:
            pass


def load_bandwidth_throughput(results_dir: Path):
    """Load bandwidth_throughput.csv."""
    path = results_dir / "bandwidth_throughput.csv"
    if not path.exists():
        return
    try:
        values = []
        with open(path) as f:
            reader = csv.DictReader(f)
            for row in reader:
                v = safe_float(row.get("speed_bytes_per_sec", "0"))
                if v > 0:
                    values.append(v)
        if values:
            # Report the mean (representative of the experiment)
            g_bw_speed.set(sum(values) / len(values))
    except Exception:
        pass


def detect_current_experiment(results_dir: Path) -> int:
    """Return the index of the latest completed experiment."""
    latest = -1
    for exp in EXPERIMENT_NAMES:
        path = results_dir / f"{exp}.csv"
        if path.exists() and path.stat().st_size > 100:
            latest = EXPERIMENT_INDEX[exp]
    return max(latest, 0)


def collect_all_metrics(results_dir: Path):
    """Main collection loop — reads all files and updates gauges."""
    for exp in EXPERIMENT_NAMES:
        load_latency_csv(results_dir / f"{exp}.csv", exp)

    load_retransmissions(results_dir / "retransmissions.log")
    load_packet_drops(results_dir / "packet_drops.log")
    load_sched_latency(results_dir / "sched_latency.log")
    load_pod_metrics(results_dir)
    load_bandwidth_throughput(results_dir)

    g_current_exp.set(detect_current_experiment(results_dir))
    g_last_update.set(time.time())


# ── HTTP handler ───────────────────────────────────────────────
class MetricsHandler(BaseHTTPRequestHandler):
    results_dir: Path = Path("/results")

    def do_GET(self):
        if self.path in ("/metrics", "/"):
            try:
                collect_all_metrics(self.results_dir)
                output = generate_latest(REGISTRY)
                self.send_response(200)
                self.send_header("Content-Type", CONTENT_TYPE_LATEST)
                self.end_headers()
                self.wfile.write(output)
            except Exception as e:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(f"Error: {e}\n".encode())
        elif self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        # Suppress access log noise
        pass


def main():
    parser = argparse.ArgumentParser(description="GRS Prometheus Exporter")
    parser.add_argument("--results-dir", default=os.environ.get("RESULTS_DIR", "/results"),
                        help="Path to GRS results directory")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("EXPORTER_PORT", "9100")),
                        help="Port to listen on")
    parser.add_argument("--scrape-interval", type=int, default=10,
                        help="Background refresh interval (seconds)")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    print(f"[grs_exporter] Results dir: {results_dir}")
    print(f"[grs_exporter] Listening on port {args.port}")

    if not results_dir.exists():
        print(f"[grs_exporter] WARNING: {results_dir} does not exist yet — waiting for pipeline to run")

    # Background refresh thread
    def bg_refresh():
        while True:
            try:
                if results_dir.exists():
                    collect_all_metrics(results_dir)
            except Exception as e:
                print(f"[grs_exporter] refresh error: {e}")
            time.sleep(args.scrape_interval)

    t = threading.Thread(target=bg_refresh, daemon=True)
    t.start()

    # Attach results_dir to handler
    MetricsHandler.results_dir = results_dir

    server = HTTPServer(("0.0.0.0", args.port), MetricsHandler)
    print(f"[grs_exporter] Ready — scrape at http://0.0.0.0:{args.port}/metrics")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[grs_exporter] Stopped.")


if __name__ == "__main__":
    main()
