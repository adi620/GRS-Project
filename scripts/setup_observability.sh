#!/bin/bash
# scripts/setup_observability.sh
# Sets up the full observability stack:
#   1. Installs metrics-server (with KIND-compatible patch)
#   2. Builds and loads the GRS Prometheus exporter image into KIND
#   3. Deploys Prometheus + Grafana + exporter in the monitoring namespace
#   4. Waits for all pods to be Ready
#   5. Prints access URLs
#
# Usage: sudo bash scripts/setup_observability.sh
# Or:    bash scripts/setup_observability.sh   (if kubectl works without sudo)

set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
KIND_CLUSTER="${KIND_CLUSTER:-grs}"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   GRS Observability Stack Setup                          ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Cluster:    ${KIND_CLUSTER}"
echo "║  Components: metrics-server + Prometheus + Grafana + Exporter"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# ── Verify cluster ─────────────────────────────────────────────
echo "[1/8] Verifying Kubernetes cluster..."
kubectl config use-context "kind-${KIND_CLUSTER}" 2>/dev/null || \
    kubectl config use-context "${KIND_CLUSTER}" 2>/dev/null || \
    { echo "ERROR: Cannot find context for cluster '${KIND_CLUSTER}'"; exit 1; }
kubectl cluster-info &>/dev/null || { echo "ERROR: API server unreachable"; exit 1; }
echo "  ✓ Cluster '${KIND_CLUSTER}' is reachable"

# ── Step 1: Create results directory on KIND node ─────────────
echo ""
echo "[2/8] Creating /grs-results on KIND node (for exporter hostPath)..."
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
docker exec "$NODE_NAME" mkdir -p /grs-results || true
echo "  ✓ /grs-results created on node ${NODE_NAME}"

# Sync any existing results into the node
RESULTS_DIR="${PROJECT_ROOT}/results"
if [ -d "$RESULTS_DIR" ] && [ "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
    echo "  Copying existing results into KIND node..."
    for f in "${RESULTS_DIR}"/*.csv "${RESULTS_DIR}"/*.log; do
        [ -f "$f" ] && docker cp "$f" "${NODE_NAME}:/grs-results/" 2>/dev/null || true
    done
    echo "  ✓ Results synced"
fi

# ── Step 2: Install metrics-server ────────────────────────────
echo ""
echo "[3/8] Installing metrics-server..."
if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
    echo "  metrics-server already installed — patching for KIND..."
else
    echo "  Downloading metrics-server manifest..."
    METRICS_VERSION="v0.7.1"
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_VERSION}/components.yaml" 2>/dev/null || \
    kubectl apply -f "${PROJECT_ROOT}/observability/metrics-server-components.yaml" 2>/dev/null || \
    { echo "  WARNING: Could not install metrics-server (no internet). Pod metrics will be empty."; }
fi

# Patch for KIND: disable TLS verification (self-signed kubelet certs)
echo "  Patching metrics-server for KIND (--kubelet-insecure-tls)..."
kubectl patch deployment metrics-server -n kube-system \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},
         {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP"}]' \
    2>/dev/null && echo "  ✓ metrics-server patched" || echo "  (patch already applied or metrics-server not available)"

# ── Step 3: Build exporter image ──────────────────────────────
echo ""
echo "[4/8] Building GRS exporter Docker image..."
if command -v docker &>/dev/null; then
    docker build -t grs-exporter:latest \
        "${PROJECT_ROOT}/observability/exporters/" \
        --quiet 2>/dev/null && echo "  ✓ grs-exporter:latest built" || \
        echo "  WARNING: Docker build failed — exporter will not be available"

    echo "  Loading image into KIND cluster '${KIND_CLUSTER}'..."
    kind load docker-image grs-exporter:latest --name "${KIND_CLUSTER}" 2>/dev/null && \
        echo "  ✓ Image loaded into KIND" || \
        echo "  WARNING: kind load failed — exporter pod will stay in ImagePullBackOff"
else
    echo "  WARNING: Docker not found — skipping image build"
fi

# ── Step 4: Create monitoring namespace ───────────────────────
echo ""
echo "[5/8] Creating monitoring namespace..."
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/namespace.yaml"
echo "  ✓ monitoring namespace ready"

# ── Step 5: Deploy Prometheus ─────────────────────────────────
echo ""
echo "[6/8] Deploying Prometheus..."
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/rbac.yaml"
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/configmap.yaml"
kubectl apply -f "${PROJECT_ROOT}/observability/prometheus/deployment.yaml"
echo "  ✓ Prometheus manifests applied"

# ── Step 6: Deploy Grafana ────────────────────────────────────
echo ""
echo "[7/8] Deploying Grafana..."
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/datasources.yaml"
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/dashboard-provider.yaml"
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/dashboard-configmap.yaml"
kubectl apply -f "${PROJECT_ROOT}/observability/grafana/deployment.yaml"
echo "  ✓ Grafana manifests applied"

# ── Step 7: Deploy exporter ───────────────────────────────────
kubectl apply -f "${PROJECT_ROOT}/observability/exporters/deployment.yaml"
echo "  ✓ GRS exporter manifests applied"

# ── Step 8: Wait for pods ─────────────────────────────────────
echo ""
echo "[8/8] Waiting for monitoring pods to be Ready (up to 3 min)..."
kubectl wait --for=condition=ready pod -l app=prometheus \
    -n monitoring --timeout=180s 2>/dev/null && echo "  ✓ Prometheus ready" || \
    echo "  WARNING: Prometheus not ready yet — check: kubectl get pods -n monitoring"

kubectl wait --for=condition=ready pod -l app=grafana \
    -n monitoring --timeout=180s 2>/dev/null && echo "  ✓ Grafana ready" || \
    echo "  WARNING: Grafana not ready yet"

# ── Get access info ───────────────────────────────────────────
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "localhost")

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Observability Stack Ready                               ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║"
echo "║  Prometheus:  http://${NODE_IP}:30090"
echo "║  Grafana:     http://${NODE_IP}:30030"
echo "║               Login: admin / grs-admin"
echo "║"
echo "║  Port-forward alternatives (if NodePort not reachable):"
echo "║    kubectl port-forward -n monitoring svc/prometheus 9090:9090 &"
echo "║    kubectl port-forward -n monitoring svc/grafana 3000:3000 &"
echo "║    Then: http://localhost:9090  and  http://localhost:3000"
echo "║"
echo "║  Dashboard auto-loaded: GRS — eBPF Fault Injection Dashboard"
echo "║"
echo "║  To sync results after a pipeline run:"
echo "║    bash scripts/sync_results.sh"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
kubectl get pods -n monitoring
