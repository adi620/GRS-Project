#!/bin/bash
# run_full_pipeline_extended.sh
# ONE COMMAND does everything:
#   1. Checks/installs all dependencies
#   2. Starts Prometheus + Grafana if not running
#   3. Runs all 7 experiments
#   4. Pushes results to Grafana automatically
#   5. Prints the Grafana URL at the end
#
# Usage: sudo ./run_full_pipeline_extended.sh

set -euo pipefail

# ── SUDO-SAFE KUBECONFIG ──────────────────────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${PROJECT_ROOT}/results"
mkdir -p "$RESULTS"

# ─────────────────────────────────────────────────────────────
# HELPER: print a coloured banner
# ─────────────────────────────────────────────────────────────
banner() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─────────────────────────────────────────────────────────────
# STEP 0: Switch to correct KIND context
# ─────────────────────────────────────────────────────────────
banner "STEP 0 — Kubernetes context"
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

if ! kubectl config use-context "$KIND_CONTEXT" 2>/dev/null; then
    echo "ERROR: Context '${KIND_CONTEXT}' not found."
    echo "Available contexts:"; kubectl config get-contexts 2>/dev/null || true
    echo "Available KIND clusters:"; kind get clusters 2>/dev/null || true
    echo "Tip: KIND_CLUSTER=<name> sudo ./run_full_pipeline_extended.sh"
    exit 1
fi
echo "✓ Context: ${KIND_CONTEXT}"

for i in $(seq 1 6); do
    kubectl cluster-info &>/dev/null && echo "✓ API server reachable." && break
    [ "$i" -eq 6 ] && { echo "ERROR: API server unreachable."; exit 1; }
    echo "  Waiting... (${i}/6)"; sleep 5
done

exec > >(tee -a "${RESULTS}/pipeline_extended.log") 2>&1

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║   GRS v4 — Kubernetes eBPF Fault Injection + Observability   ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  Started: $(date)"
echo "║  Cluster: ${KIND_CLUSTER}"
echo "╚═══════════════════════════════════════════════════════════════╝"

# ─────────────────────────────────────────────────────────────
# STEP 1: Deploy / verify workloads
# ─────────────────────────────────────────────────────────────
banner "STEP 1 — Deploying workloads"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-deployment.yaml"
kubectl apply --validate=false -f "${PROJECT_ROOT}/deployment/web-service.yaml"
kubectl delete pod traffic --ignore-not-found=true
kubectl apply --validate=false -f "${PROJECT_ROOT}/traffic/traffic.yaml"
kubectl wait --for=condition=ready pod -l app=web --timeout=120s
kubectl wait --for=condition=ready pod/traffic    --timeout=120s
echo "✓ Pods ready"
kubectl get pods -o wide

# ─────────────────────────────────────────────────────────────
# STEP 2: Auto-setup observability (idempotent — safe to re-run)
# ─────────────────────────────────────────────────────────────
banner "STEP 2 — Observability stack"

_ensure_observability() {
    local NODE; NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

    # Create /grs-results on KIND node
    docker exec "$NODE" mkdir -p /grs-results 2>/dev/null || true

    # Deploy monitoring namespace + stack if not present
    kubectl get namespace monitoring &>/dev/null || \
        kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/namespace.yaml"

    # Prometheus
    if ! kubectl get deployment prometheus -n monitoring &>/dev/null; then
        echo "  Deploying Prometheus..."
        kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/rbac.yaml"
        kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/configmap.yaml"
        kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/deployment.yaml"
    fi

    # Grafana
    if ! kubectl get deployment grafana -n monitoring &>/dev/null; then
        echo "  Deploying Grafana..."
        kubectl apply -f "${PROJECT_ROOT}/observability/grafana/datasources.yaml"
        kubectl apply -f "${PROJECT_ROOT}/observability/grafana/dashboard-provider.yaml"
        kubectl apply -f "${PROJECT_ROOT}/observability/grafana/dashboard-configmap.yaml"
        kubectl apply -f "${PROJECT_ROOT}/observability/grafana/deployment.yaml"
    fi

    # GRS Exporter — always use the inline version (no Docker build needed)
    kubectl delete deployment grs-exporter -n monitoring 2>/dev/null || true
    kubectl apply -f - <<'EXPEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grs-exporter
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grs-exporter
  template:
    metadata:
      labels:
        app: grs-exporter
    spec:
      containers:
        - name: grs-exporter
          image: python:3.11-slim
          command: ["python3", "-c"]
          args:
            - |
              import os, time, threading
              from pathlib import Path
              from http.server import HTTPServer, BaseHTTPRequestHandler

              RESULTS_DIR = Path("/grs-results")
              PORT = 9100

              def read_csv_stats(path):
                  rows = []
                  try:
                      with open(path) as f:
                          next(f)
                          for line in f:
                              parts = line.strip().split(',')
                              if len(parts) >= 2:
                                  try:
                                      v = float(parts[1])
                                      if v > 0:
                                          rows.append(v * 1000)
                                  except:
                                      pass
                  except:
                      pass
                  return rows

              def collect():
                  lines = []
                  exps = ["baseline","delay","loss","bandwidth","reordering","cpu_stress","chaos_combined"]
                  for exp in exps:
                      rows = read_csv_stats(RESULTS_DIR / f"{exp}.csv")
                      if rows:
                          s = sorted(rows); n = len(s)
                          mean = sum(s)/n
                          p95  = s[int(n*0.95)]
                          mx   = s[-1]
                          last = s[-1]
                          lines.append(f'grs_latency_milliseconds{{experiment="{exp}"}} {last}')
                          lines.append(f'grs_latency_mean_milliseconds{{experiment="{exp}"}} {mean}')
                          lines.append(f'grs_latency_p95_milliseconds{{experiment="{exp}"}} {p95}')
                          lines.append(f'grs_latency_max_milliseconds{{experiment="{exp}"}} {mx}')
                          lines.append(f'grs_latency_sample_count{{experiment="{exp}"}} {n}')
                  # retransmissions
                  try:
                      c = sum(1 for l in open(RESULTS_DIR/"retransmissions.log") if "RETRANSMIT" in l)
                      lines.append(f'grs_tcp_retransmissions_total {c}')
                  except:
                      lines.append('grs_tcp_retransmissions_total 0')
                  # packet drops
                  try:
                      from collections import defaultdict
                      rc = defaultdict(int)
                      for l in open(RESULTS_DIR/"packet_drops.log"):
                          p = l.split()
                          if len(p) >= 4 and p[-1] == "DROP":
                              try: rc[int(p[2])] += 1
                              except: pass
                      for reason, count in rc.items():
                          lines.append(f'grs_packet_drops_total{{reason="{reason}"}} {count}')
                      if not rc:
                          lines.append('grs_packet_drops_total{reason="0"} 0')
                  except:
                      lines.append('grs_packet_drops_total{reason="0"} 0')
                  lines.append(f'grs_exporter_last_update {time.time()}')
                  return "\n".join(lines) + "\n"

              class Handler(BaseHTTPRequestHandler):
                  def do_GET(self):
                      if self.path in ("/metrics", "/"):
                          body = collect().encode()
                          self.send_response(200)
                          self.send_header("Content-Type","text/plain; version=0.0.4")
                          self.end_headers()
                          self.wfile.write(body)
                      elif self.path == "/health":
                          self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
                      else:
                          self.send_response(404); self.end_headers()
                  def log_message(self, *a): pass

              print(f"[grs-exporter] Listening on port {PORT}, results dir: {RESULTS_DIR}")
              HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
          ports:
            - containerPort: 9100
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          volumeMounts:
            - name: results
              mountPath: /grs-results
      volumes:
        - name: results
          hostPath:
            path: /grs-results
            type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: grs-exporter
  namespace: monitoring
spec:
  type: ClusterIP
  ports:
    - port: 9100
      targetPort: 9100
  selector:
    app: grs-exporter
EXPEOF

    # Wait for exporter
    kubectl rollout status deployment/grs-exporter -n monitoring --timeout=120s
    echo "  ✓ GRS exporter ready"

    # Patch Prometheus config to scrape exporter with correct cluster DNS
    kubectl patch configmap prometheus-config -n monitoring --type=merge -p \
'{"data":{"prometheus.yml":"global:\n  scrape_interval: 10s\n  evaluation_interval: 10s\n\nscrape_configs:\n  - job_name: prometheus\n    static_configs:\n      - targets: [\"localhost:9090\"]\n\n  - job_name: grs-exporter\n    static_configs:\n      - targets: [\"grs-exporter.monitoring.svc.cluster.local:9100\"]\n    scrape_interval: 10s\n\n  - job_name: kubernetes-cadvisor\n    scheme: https\n    tls_config:\n      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt\n      insecure_skip_verify: true\n    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token\n    kubernetes_sd_configs:\n      - role: node\n    relabel_configs:\n      - action: labelmap\n        regex: __meta_kubernetes_node_label_(.+)\n      - target_label: __address__\n        replacement: kubernetes.default.svc:443\n      - source_labels: [__meta_kubernetes_node_name]\n        regex: (.+)\n        target_label: __metrics_path__\n        replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor\n"}}' \
    2>/dev/null || true

    # Restart Prometheus to pick up new config
    kubectl rollout restart deployment/prometheus -n monitoring 2>/dev/null || true

    echo "  Waiting for monitoring pods..."
    kubectl wait --for=condition=ready pod -l app=prometheus \
        -n monitoring --timeout=120s 2>/dev/null && echo "  ✓ Prometheus ready" || \
        echo "  ⚠ Prometheus still starting — will be ready by end of pipeline"
    kubectl wait --for=condition=ready pod -l app=grafana \
        -n monitoring --timeout=120s 2>/dev/null && echo "  ✓ Grafana ready" || \
        echo "  ⚠ Grafana still starting"
}

_ensure_observability

# ─────────────────────────────────────────────────────────────
# Fix Grafana datasource UID in dashboard (runs after Grafana starts)
# ─────────────────────────────────────────────────────────────
_fix_grafana_dashboard() {
    local GRAFANA_POD
    GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    [ -z "$GRAFANA_POD" ] && return

    # Get real datasource UID
    local DS_UID
    DS_UID=$(kubectl exec -n monitoring "$GRAFANA_POD" -- \
        wget -qO- 'http://admin:grs-admin@localhost:3000/api/datasources' 2>/dev/null | \
        python3 -c "
import json,sys
try:
    ds=json.load(sys.stdin)
    for d in ds:
        if d.get('type')=='prometheus':
            print(d.get('uid',''))
            break
except: pass
" 2>/dev/null || echo "")

    [ -z "$DS_UID" ] && return
    echo "  Grafana datasource UID: ${DS_UID}"

    # Push a working dashboard directly via API
    kubectl exec -n monitoring "$GRAFANA_POD" -- python3 -c "
import urllib.request, json, urllib.error

UID = '${DS_UID}'
ds  = {'type': 'prometheus', 'uid': UID}

def panel(id_, title, ptype, expr, unit='ms', y=0, w=24, h=8, extra=None):
    p = {
        'id': id_, 'title': title, 'type': ptype,
        'gridPos': {'h': h, 'w': w, 'x': 0, 'y': y},
        'datasource': ds,
        'fieldConfig': {'defaults': {'unit': unit}, 'overrides': []},
        'targets': [{'expr': e, 'legendFormat': lbl, 'refId': chr(65+i), 'datasource': ds}
                    for i, (e, lbl) in enumerate(expr)],
        'options': {}
    }
    if extra: p.update(extra)
    return p

panels = [
    panel(1,'Mean Latency by Experiment','bargauge',
          [('grs_latency_mean_milliseconds','{{experiment}}')],
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},
                            'orientation':'horizontal','displayMode':'gradient'}}),
    panel(2,'Latency p95 by Experiment','bargauge',
          [('grs_latency_p95_milliseconds','{{experiment}}')],
          y=8,
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},
                            'orientation':'horizontal','displayMode':'gradient'}}),
    panel(3,'Max Latency by Experiment','bargauge',
          [('grs_latency_max_milliseconds','{{experiment}}')],
          y=16,
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},
                            'orientation':'horizontal','displayMode':'gradient'}}),
    panel(4,'Baseline Mean','stat',
          [('grs_latency_mean_milliseconds{experiment=\"baseline\"}','Baseline')],
          y=24,w=6,h=4,
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},'colorMode':'background'}}),
    panel(5,'Chaos Mean','stat',
          [('grs_latency_mean_milliseconds{experiment=\"chaos_combined\"}','Chaos')],
          y=24,w=6,h=4,
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},'colorMode':'background'}}),
    panel(6,'TCP Retransmissions','stat',
          [('grs_tcp_retransmissions_total','Total')],
          y=24,w=6,h=4,unit='short',
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},'colorMode':'background'}}),
    panel(7,'Packet Drops (tc netem reason=82)','stat',
          [('grs_packet_drops_total{reason=\"82\"}','TC Drops')],
          y=24,w=6,h=4,unit='short',
          extra={'options':{'reduceOptions':{'calcs':['lastNotNull']},'colorMode':'background'}}),
    panel(8,'Container CPU (cAdvisor)','timeseries',
          [('rate(container_cpu_usage_seconds_total{namespace=\"default\",container!=\"\",container!=\"POD\"}[1m])*1000','{{pod}}')],
          y=28,unit='short'),
    panel(9,'Container Memory (cAdvisor)','timeseries',
          [('container_memory_working_set_bytes{namespace=\"default\",container!=\"\",container!=\"POD\"}','{{pod}}')],
          y=36,unit='bytes'),
    panel(10,'Correlation: Latency + Retransmissions','timeseries',
          [('grs_latency_mean_milliseconds','Latency {{experiment}} ms'),
           ('grs_tcp_retransmissions_total * 20','Retransmissions x20'),
           ('grs_packet_drops_total{reason=\"82\"} / 50','TC Drops /50')],
          y=44),
]

dash = {
    'dashboard': {
        'id': None, 'uid': 'grs-ebpf-v4',
        'title': 'GRS — eBPF Fault Injection Dashboard',
        'refresh': '10s',
        'time': {'from': 'now-1h', 'to': 'now'},
        'schemaVersion': 38,
        'panels': panels
    },
    'folderId': 0, 'overwrite': True
}

body = json.dumps(dash).encode()
req  = urllib.request.Request(
    'http://localhost:3000/api/dashboards/db',
    data=body,
    headers={'Content-Type':'application/json',
             'Authorization':'Basic YWRtaW46Z3JzLWFkbWlu'})
try:
    r = urllib.request.urlopen(req, timeout=10)
    resp = json.loads(r.read())
    print('Dashboard pushed:', resp.get('status'), '— URL:', resp.get('url',''))
except urllib.error.HTTPError as e:
    print('HTTP error:', e.code, e.read().decode()[:200])
except Exception as e:
    print('Error:', e)
" 2>/dev/null && echo "  ✓ Dashboard pushed to Grafana" || echo "  ⚠ Dashboard push failed — will retry after pipeline"
}

_fix_grafana_dashboard

# ─────────────────────────────────────────────────────────────
# STEP 3: Connectivity check
# ─────────────────────────────────────────────────────────────
banner "STEP 3 — Connectivity check"
HTTP_CODE=$(kubectl exec traffic -- \
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://web/ 2>/dev/null)
[ "$HTTP_CODE" = "200" ] && echo "✓ HTTP ${HTTP_CODE}" || \
    { echo "ERROR: HTTP ${HTTP_CODE}"; exit 1; }
WEB_IP=$(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
echo "  Web pod IP: ${WEB_IP}"

# ─────────────────────────────────────────────────────────────
# STEP 4: Start eBPF tracers
# ─────────────────────────────────────────────────────────────
banner "STEP 4 — Starting eBPF tracers"
bpftrace "${PROJECT_ROOT}/ebpf/tcp_retransmissions.bt" \
    > "${RESULTS}/retransmissions.log" 2>&1 &
RETRANS_PID=$!
bpftrace "${PROJECT_ROOT}/ebpf/packet_drops.bt" \
    > "${RESULTS}/packet_drops.log" 2>&1 &
DROPS_PID=$!
echo "  tcp_retransmit_skb PID: ${RETRANS_PID}"
echo "  kfree_skb          PID: ${DROPS_PID}"
sleep 3

cleanup_ebpf() {
    kill "$RETRANS_PID" 2>/dev/null || true
    kill "$DROPS_PID"   2>/dev/null || true
    wait "$RETRANS_PID" 2>/dev/null || true
    wait "$DROPS_PID"   2>/dev/null || true
}
trap cleanup_ebpf EXIT

# ─────────────────────────────────────────────────────────────
# STEPS 5-11: Experiments
# ─────────────────────────────────────────────────────────────
banner "STEP 5 — Baseline (60s)"
bash "${PROJECT_ROOT}/experiments/run_baseline.sh"

banner "STEP 6 — Delay 200ms (60s)"
bash "${PROJECT_ROOT}/experiments/run_delay.sh"

banner "STEP 7 — Packet Loss 20% (60s)"
bash "${PROJECT_ROOT}/experiments/run_loss.sh"

banner "STEP 8 — Bandwidth 1mbit (60s)"
bash "${PROJECT_ROOT}/experiments/run_bandwidth.sh"

banner "STEP 9 — Reordering 25% (60s)"
bash "${PROJECT_ROOT}/experiments/run_reordering.sh"

banner "STEP 10 — CPU Stress 4 workers (90s)"
bash "${PROJECT_ROOT}/experiments/run_cpu_stress.sh"

banner "STEP 11 — Chaos: Loss + CPU (90s)"
bash "${PROJECT_ROOT}/experiments/run_chaos_combined.sh"

# ─────────────────────────────────────────────────────────────
# STEP 12: Stop eBPF + generate reports
# ─────────────────────────────────────────────────────────────
banner "STEP 12 — Stopping eBPF + generating reports"
cleanup_ebpf
trap - EXIT
sleep 2

bash "${PROJECT_ROOT}/generate_report_extended.sh"
python3 "${PROJECT_ROOT}/plot_results_extended.py" 2>/dev/null && \
    echo "  ✓ PNG chart saved" || echo "  (plot skipped)"
bash "${PROJECT_ROOT}/generate_fault_matrix.sh"
bash "${PROJECT_ROOT}/generate_diff_report.sh" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# STEP 13: Sync results to Grafana
# ─────────────────────────────────────────────────────────────
banner "STEP 13 — Syncing results to Grafana"
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
COPIED=0
for f in "${RESULTS}"/*.csv "${RESULTS}"/retransmissions.log "${RESULTS}"/packet_drops.log; do
    [ -f "$f" ] && docker cp "$f" "${NODE}:/grs-results/" 2>/dev/null && \
        COPIED=$((COPIED+1))
done
echo "  ✓ Copied ${COPIED} files to KIND node"

# Retry dashboard push now that all data is present
sleep 5
_fix_grafana_dashboard

# ─────────────────────────────────────────────────────────────
# STEP 14: Port-forward and print URL
# ─────────────────────────────────────────────────────────────
banner "STEP 14 — Starting port-forwards"

# Kill any existing port-forwards on these ports
fuser -k 3000/tcp 2>/dev/null || true
fuser -k 9090/tcp 2>/dev/null || true
sleep 1

kubectl port-forward -n monitoring svc/grafana \
    3000:3000 --address 0.0.0.0 >> "${RESULTS}/portforward.log" 2>&1 &
PF_GRAFANA=$!
kubectl port-forward -n monitoring svc/prometheus \
    9090:9090 --address 0.0.0.0 >> "${RESULTS}/portforward.log" 2>&1 &
PF_PROM=$!

echo "  Port-forward PIDs: Grafana=${PF_GRAFANA} Prometheus=${PF_PROM}"
sleep 3

# Get VM IP automatically
VM_IP=$(hostname -I | awk '{print $1}')

# ─────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  ✅  PIPELINE COMPLETE — $(date)"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║"
echo "║  Open in your Windows browser:"
echo "║"
echo "║  📊 Grafana:    http://${VM_IP}:3000"
echo "║                 Login: admin / grs-admin"
echo "║                 Dashboard: GRS — eBPF Fault Injection Dashboard"
echo "║"
echo "║  📈 Prometheus: http://${VM_IP}:9090"
echo "║"
echo "║  📁 HTML Report (offline):"
echo "║     results/report_extended.html"
echo "║"
echo "║  Results summary:"
echo "╠═══════════════════════════════════════════════════════════════╣"

for exp in baseline delay loss bandwidth reordering cpu_stress chaos_combined; do
    FILE="${RESULTS}/${exp}.csv"
    if [ -f "$FILE" ]; then
        STATS=$(tail -n +2 "$FILE" | grep -v timeout | \
            awk -F',' '{s+=$2;n++;if($2>m)m=$2} \
            END{printf "n=%-3d mean=%6.0fms max=%7.0fms",n,s/n*1000,m*1000}')
        printf "║  %-18s %s\n" "${exp}" "${STATS}"
    fi
done

RETRANS=$(grep -c "RETRANSMIT" "${RESULTS}/retransmissions.log" 2>/dev/null || echo 0)
DROPS=$(grep -v "^TIME\|^Tracing\|^$\|\[eBPF\]\|^===" \
    "${RESULTS}/packet_drops.log" 2>/dev/null | grep -c "[0-9]" || echo 0)
echo "║"
echo "║  eBPF: ${RETRANS} TCP retransmissions  |  ${DROPS} packet drops"
echo "║"
echo "║  Port-forwards running in background."
echo "║  To stop them: kill ${PF_GRAFANA} ${PF_PROM}"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""
