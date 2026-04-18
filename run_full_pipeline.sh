#!/bin/bash
# run_full_pipeline.sh — ONE COMMAND TO RUN EVERYTHING
#
# What this does automatically:
#   1. Checks all dependencies
#   2. Creates KIND cluster (if not exists)
#   3. Installs metrics-server
#   4. Deploys Prometheus + Grafana + exporter
#   5. Runs all 7 fault injection experiments
#   6. Syncs results to Grafana
#   7. Pushes dashboard with correct datasource UID
#   8. Prints ONE URL to open in Windows browser
#
# Usage: sudo ./run_full_pipeline.sh

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗ ERROR:${NC} $*"; exit 1; }
step() { echo ""; echo -e "${CYAN}══════════════════════════════════════${NC}"; \
         echo -e "${CYAN}  $*${NC}"; \
         echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# ── Paths ─────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS="${PROJECT_ROOT}/results"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"
KIND_CLUSTER="${KIND_CLUSTER:-grs}"
KIND_CONTEXT="kind-${KIND_CLUSTER}"

mkdir -p "$RESULTS"
exec > >(tee -a "${RESULTS}/pipeline_full.log") 2>&1

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   GRS — Kubernetes eBPF Fault Injection System          ║${NC}"
echo -e "${CYAN}║   Full Pipeline: Experiments + Prometheus + Grafana      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ══════════════════════════════════════════════════════════════
# STEP 1: Check dependencies
# ══════════════════════════════════════════════════════════════
step "STEP 1/7 — Checking dependencies"

for cmd in docker kubectl kind bpftrace python3; do
    command -v "$cmd" &>/dev/null && ok "$cmd found" || \
        fail "$cmd not found. Run: sudo apt install -y $cmd"
done
command -v stress-ng &>/dev/null && ok "stress-ng found" || \
    warn "stress-ng not found — CPU stress experiments will be skipped"

# ══════════════════════════════════════════════════════════════
# STEP 2: Create or reuse KIND cluster
# ══════════════════════════════════════════════════════════════
step "STEP 2/7 — Kubernetes cluster"

if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER}$"; then
    ok "KIND cluster '${KIND_CLUSTER}' already exists"
else
    info "Creating KIND cluster '${KIND_CLUSTER}' with NodePort mappings..."
    cat > /tmp/kind-config.yaml << EOF
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
    kind create cluster --name "${KIND_CLUSTER}" \
        --config /tmp/kind-config.yaml
    ok "KIND cluster created"
fi

# Set context
kubectl config use-context "${KIND_CONTEXT}" 2>/dev/null || \
    fail "Cannot switch to context ${KIND_CONTEXT}"

# Wait for API server
for i in $(seq 1 10); do
    kubectl cluster-info &>/dev/null && ok "API server ready" && break
    [ "$i" -eq 10 ] && fail "API server not ready after 50s"
    sleep 5
done

# ══════════════════════════════════════════════════════════════
# STEP 3: Install metrics-server
# ══════════════════════════════════════════════════════════════
step "STEP 3/7 — Metrics server"

if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    ok "metrics-server already installed"
else
    info "Installing metrics-server..."
    kubectl apply -f \
        https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.1/components.yaml \
        2>/dev/null && ok "metrics-server installed" || \
        warn "metrics-server install failed (no internet?) — pod metrics will be empty"
fi

# Patch for KIND (idempotent)
kubectl patch deployment metrics-server -n kube-system \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
         {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}]' \
    2>/dev/null && ok "metrics-server patched for KIND" || true

# ══════════════════════════════════════════════════════════════
# STEP 4: Deploy observability stack
# ══════════════════════════════════════════════════════════════
step "STEP 4/7 — Deploying Prometheus + Grafana"

# Create monitoring namespace
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/namespace.yaml" --validate=false

# Deploy Prometheus
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/rbac.yaml" --validate=false
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/configmap.yaml" --validate=false
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/deployment.yaml" --validate=false
ok "Prometheus deployed"

# Deploy Grafana (without dashboard ConfigMap — we push via API instead)
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/datasources.yaml" --validate=false
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/dashboard-provider.yaml" --validate=false
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/deployment.yaml" --validate=false
ok "Grafana deployed"

# Build and deploy exporter
info "Building grs-exporter Docker image..."
docker build -t grs-exporter:latest \
    "${PROJECT_ROOT}/observability/exporters/" --quiet 2>/dev/null && \
    ok "grs-exporter image built" || warn "Docker build failed"

kind load docker-image grs-exporter:latest \
    --name "${KIND_CLUSTER}" 2>/dev/null && \
    ok "grs-exporter image loaded into KIND" || warn "kind load failed"

# Deploy exporter with correct path
kubectl apply -f - --validate=false << 'EOF'
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
          image: grs-exporter:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 9100
          env:
            - name: RESULTS_DIR
              value: "/grs-results"
            - name: EXPORTER_PORT
              value: "9100"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
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
EOF
ok "grs-exporter deployed"

# Create results dir on node
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
docker exec "$NODE" mkdir -p /grs-results 2>/dev/null
ok "/grs-results directory created on node"

# Wait for Prometheus (required before pipeline)
info "Waiting for Prometheus to be ready..."
kubectl wait --for=condition=ready pod -l app=prometheus \
    -n monitoring --timeout=180s 2>/dev/null && \
    ok "Prometheus ready" || warn "Prometheus not ready yet — continuing"

# Wait for Grafana (with longer timeout — it's slow to start)
info "Waiting for Grafana to be ready (up to 3 min)..."
kubectl wait --for=condition=ready pod -l app=grafana \
    -n monitoring --timeout=180s 2>/dev/null && \
    ok "Grafana ready" || warn "Grafana still starting — will check after pipeline"

# ══════════════════════════════════════════════════════════════
# STEP 5: Run experiments
# ══════════════════════════════════════════════════════════════
step "STEP 5/7 — Running fault injection experiments (~13 min)"

bash "${PROJECT_ROOT}/run_full_pipeline_extended.sh"

# ══════════════════════════════════════════════════════════════
# STEP 6: Sync results + push dashboard
# ══════════════════════════════════════════════════════════════
step "STEP 6/7 — Syncing results to Grafana"

# Copy files to KIND node (skip huge sched_latency.log)
info "Copying results to KIND node..."
COPIED=0
for f in "${RESULTS}"/*.csv; do
    [ -f "$f" ] && docker cp "$f" "${NODE}:/grs-results/" 2>/dev/null && \
        COPIED=$((COPIED+1))
done
# Copy logs but not sched_latency (87MB causes OOM)
for f in retransmissions.log packet_drops.log; do
    [ -f "${RESULTS}/$f" ] && \
        docker cp "${RESULTS}/$f" "${NODE}:/grs-results/" 2>/dev/null && \
        COPIED=$((COPIED+1))
done
ok "Copied ${COPIED} files to KIND node"

# Wait for Grafana to be fully ready
info "Ensuring Grafana is ready..."
for i in $(seq 1 24); do
    STATUS=$(kubectl get pod -n monitoring -l app=grafana \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
    [ "$STATUS" = "true" ] && ok "Grafana ready" && break
    [ "$i" -eq 24 ] && warn "Grafana still not ready — dashboard push may fail"
    sleep 5
done

# Get the actual datasource UID from Grafana
info "Getting Grafana datasource UID..."
GRAFANA_POD=$(kubectl get pod -n monitoring -l app=grafana \
    -o jsonpath='{.items[0].metadata.name}')

DS_UID=""
for attempt in $(seq 1 6); do
    DS_UID=$(kubectl exec -n monitoring "$GRAFANA_POD" -- \
        wget -qO- 'http://admin:grs-admin@localhost:3000/api/datasources' \
        2>/dev/null | python3 -c "
import json,sys
try:
    ds=json.load(sys.stdin)
    print(ds[0]['uid'] if ds else '')
except: print('')
" 2>/dev/null)
    [ -n "$DS_UID" ] && break
    sleep 5
done

if [ -z "$DS_UID" ]; then
    DS_UID="PBFA97CFB590B2093"
    warn "Could not get datasource UID — using default: ${DS_UID}"
else
    ok "Datasource UID: ${DS_UID}"
fi

# ── Push dashboard directly via API with correct UID ──────────
info "Pushing dashboard to Grafana API..."

python3 << PYEOF
import json, urllib.request, urllib.error

ds_uid = "${DS_UID}"

dashboard = {
  "dashboard": {
    "id": None,
    "uid": "grs-ebpf-v3",
    "title": "GRS — eBPF Fault Injection Dashboard",
    "refresh": "10s",
    "time": {"from": "now-1h", "to": "now"},
    "schemaVersion": 38,
    "panels": [
      {
        "id": 1, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
        "title": "HTTP Latency — All Experiments", "type": "row"
      },
      {
        "id": 2, "gridPos": {"h": 8, "w": 16, "x": 0, "y": 1},
        "title": "Mean Latency by Experiment (ms)",
        "type": "bargauge",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {
          "reduceOptions": {"calcs": ["lastNotNull"]},
          "orientation": "horizontal",
          "displayMode": "gradient",
          "text": {}
        },
        "fieldConfig": {
          "defaults": {
            "unit": "ms",
            "thresholds": {"mode": "absolute", "steps": [
              {"color": "green", "value": None},
              {"color": "yellow", "value": 50},
              {"color": "orange", "value": 200},
              {"color": "red", "value": 1000}
            ]}
          }
        },
        "targets": [{
          "datasource": {"type": "prometheus", "uid": ds_uid},
          "expr": "grs_latency_mean_milliseconds",
          "legendFormat": "{{experiment}}",
          "refId": "A"
        }]
      },
      {
        "id": 3, "gridPos": {"h": 4, "w": 4, "x": 16, "y": 1},
        "title": "Baseline Mean",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "yellow", "value": 5}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_mean_milliseconds{experiment=\"baseline\"}", "legendFormat": "Baseline", "refId": "A"}]
      },
      {
        "id": 4, "gridPos": {"h": 4, "w": 4, "x": 20, "y": 1},
        "title": "Delay Mean",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 200}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_mean_milliseconds{experiment=\"delay\"}", "legendFormat": "Delay", "refId": "A"}]
      },
      {
        "id": 5, "gridPos": {"h": 4, "w": 4, "x": 16, "y": 5},
        "title": "Loss Mean",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 100}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_mean_milliseconds{experiment=\"loss\"}", "legendFormat": "Loss", "refId": "A"}]
      },
      {
        "id": 6, "gridPos": {"h": 4, "w": 4, "x": 20, "y": 5},
        "title": "Chaos Mean",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "ms", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 500}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_mean_milliseconds{experiment=\"chaos_combined\"}", "legendFormat": "Chaos", "refId": "A"}]
      },
      {
        "id": 7, "gridPos": {"h": 8, "w": 12, "x": 0, "y": 9},
        "title": "p95 Latency by Experiment",
        "type": "bargauge",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "horizontal", "displayMode": "gradient"},
        "fieldConfig": {"defaults": {"unit": "ms"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_p95_milliseconds", "legendFormat": "{{experiment}}", "refId": "A"}]
      },
      {
        "id": 8, "gridPos": {"h": 8, "w": 12, "x": 12, "y": 9},
        "title": "Max Latency by Experiment",
        "type": "bargauge",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "horizontal", "displayMode": "gradient"},
        "fieldConfig": {"defaults": {"unit": "ms"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_max_milliseconds", "legendFormat": "{{experiment}}", "refId": "A"}]
      },
      {
        "id": 9, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 17},
        "title": "eBPF Kernel Events", "type": "row"
      },
      {
        "id": 10, "gridPos": {"h": 3, "w": 6, "x": 0, "y": 18},
        "title": "TCP Retransmissions",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_tcp_retransmissions_total", "legendFormat": "Retransmits", "refId": "A"}]
      },
      {
        "id": 11, "gridPos": {"h": 3, "w": 6, "x": 6, "y": 18},
        "title": "Packet Drops (tc netem)",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
        "fieldConfig": {"defaults": {"unit": "short", "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 100}]}}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_packet_drops_total{reason=\"82\"}", "legendFormat": "TC drops", "refId": "A"}]
      },
      {
        "id": 12, "gridPos": {"h": 3, "w": 6, "x": 12, "y": 18},
        "title": "Bandwidth Speed",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value"},
        "fieldConfig": {"defaults": {"unit": "Bps"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_bandwidth_speed_bytes_per_sec", "legendFormat": "Speed", "refId": "A"}]
      },
      {
        "id": 13, "gridPos": {"h": 3, "w": 6, "x": 18, "y": 18},
        "title": "Scheduler Events",
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value"},
        "fieldConfig": {"defaults": {"unit": "short"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_sched_events_total", "legendFormat": "Events", "refId": "A"}]
      },
      {
        "id": 14, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 21},
        "title": "Pod CPU & Memory", "type": "row"
      },
      {
        "id": 15, "gridPos": {"h": 8, "w": 12, "x": 0, "y": 22},
        "title": "Container CPU Usage",
        "type": "timeseries",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2}}},
        "options": {"legend": {"displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "rate(container_cpu_usage_seconds_total{namespace=\"default\",container!=\"\",container!=\"POD\"}[1m])*1000", "legendFormat": "{{pod}}", "refId": "A"}]
      },
      {
        "id": 16, "gridPos": {"h": 8, "w": 12, "x": 12, "y": 22},
        "title": "Container Memory Usage",
        "type": "timeseries",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"lineWidth": 2}}},
        "options": {"legend": {"displayMode": "table", "placement": "bottom"}},
        "targets": [{"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "container_memory_working_set_bytes{namespace=\"default\",container!=\"\",container!=\"POD\"}", "legendFormat": "{{pod}}", "refId": "A"}]
      },
      {
        "id": 17, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 30},
        "title": "Correlation — Latency vs CPU vs Retransmissions", "type": "row"
      },
      {
        "id": 18, "gridPos": {"h": 9, "w": 24, "x": 0, "y": 31},
        "title": "Correlation: Latency vs Retransmissions vs Drops",
        "type": "timeseries",
        "datasource": {"type": "prometheus", "uid": ds_uid},
        "fieldConfig": {
          "defaults": {"custom": {"lineWidth": 2}},
          "overrides": [
            {"matcher": {"id": "byFrameRefID", "options": "A"}, "properties": [{"id": "unit", "value": "ms"}]},
            {"matcher": {"id": "byFrameRefID", "options": "B"}, "properties": [{"id": "unit", "value": "short"}, {"id": "custom.axisPlacement", "value": "right"}]},
            {"matcher": {"id": "byFrameRefID", "options": "C"}, "properties": [{"id": "unit", "value": "short"}, {"id": "custom.axisPlacement", "value": "right"}]}
          ]
        },
        "options": {"legend": {"displayMode": "table", "calcs": ["mean", "max"], "placement": "bottom"}, "tooltip": {"mode": "multi"}},
        "targets": [
          {"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_latency_mean_milliseconds", "legendFormat": "Latency {{experiment}} (ms)", "refId": "A"},
          {"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_tcp_retransmissions_total * 10", "legendFormat": "Retransmissions x10", "refId": "B"},
          {"datasource": {"type": "prometheus", "uid": ds_uid}, "expr": "grs_packet_drops_total{reason=\"82\"} / 100", "legendFormat": "TC Drops /100", "refId": "C"}
        ]
      }
    ]
  },
  "folderId": 0,
  "overwrite": True
}

# Push via port-forward to localhost:3000
payload = json.dumps(dashboard).encode()
req = urllib.request.Request(
    'http://localhost:3000/api/dashboards/db',
    data=payload,
    headers={'Content-Type': 'application/json',
             'Authorization': 'Basic YWRtaW46Z3JzLWFkbWlu'}
)
try:
    resp = urllib.request.urlopen(req, timeout=15)
    result = json.loads(resp.read())
    print(f"Dashboard push: {result.get('status')} — URL: {result.get('url','')}")
except Exception as e:
    print(f"Dashboard push failed: {e}")
    print("Will try again after port-forward is established")
PYEOF

# ══════════════════════════════════════════════════════════════
# STEP 7: Start port-forwards and print URL
# ══════════════════════════════════════════════════════════════
step "STEP 7/7 — Starting port-forwards"

# Kill any existing port-forwards
pkill -f "port-forward.*grafana" 2>/dev/null || true
pkill -f "port-forward.*prometheus" 2>/dev/null || true
sleep 2

# Start fresh port-forwards as the real user (not root)
su - "$REAL_USER" -c "kubectl port-forward -n monitoring svc/grafana 3000:3000 --address 0.0.0.0 > /tmp/grafana-pf.log 2>&1 &"
su - "$REAL_USER" -c "kubectl port-forward -n monitoring svc/prometheus 9090:9090 --address 0.0.0.0 > /tmp/prometheus-pf.log 2>&1 &"

sleep 3

# Try pushing dashboard again now that port-forward is up
python3 << PYEOF2
import json, urllib.request

ds_uid = "${DS_UID}"

# minimal re-push to ensure it's there
dashboard = {
  "dashboard": {"id": None, "uid": "grs-ebpf-v3", "title": "GRS — eBPF Fault Injection Dashboard",
    "refresh": "10s", "time": {"from": "now-1h", "to": "now"}, "schemaVersion": 38, "panels": []},
  "folderId": 0, "overwrite": True
}

try:
    req = urllib.request.Request(
        'http://localhost:3000/api/dashboards/db',
        data=json.dumps(dashboard).encode(),
        headers={'Content-Type': 'application/json',
                 'Authorization': 'Basic YWRtaW46Z3JzLWFkbWlu'}
    )
    urllib.request.urlopen(req, timeout=10)
    print("Port-forward to Grafana: OK")
except Exception as e:
    print(f"Port-forward check: {e}")
PYEOF2

# Get VM IP
VM_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✓ PIPELINE COMPLETE — ALL RESULTS IN GRAFANA           ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Open in Windows browser:"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${CYAN}http://${VM_IP}:3000${NC}    ← Grafana Dashboard"
echo -e "${GREEN}║${NC}  ${CYAN}http://${VM_IP}:9090${NC}   ← Prometheus"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Login: ${YELLOW}admin${NC} / ${YELLOW}grs-admin${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Dashboard: Dashboards → GRS → GRS eBPF Dashboard"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Results: ${RESULTS}/"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  To re-run experiments later:"
echo -e "${GREEN}║${NC}    ${YELLOW}sudo ./run_full_pipeline.sh${NC}"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
