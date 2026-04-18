#!/bin/bash
# scenarios/app_delay/deploy_app_delay.sh
# Simulates an application-level slowdown by patching the web pod to
# run a shell that sleeps 200ms before starting nginx on each request.
#
# In real production this represents: a slow database query, a blocking
# middleware call, or a misconfigured connection pool.
# The key difference from tc delay: NO kernel network events fire.
# Retransmissions = 0, drops = 0, but latency is still high.
# This is the hardest class of bug to diagnose without app-level tracing.
#
# Method: patch the nginx deployment to use a wrapper that adds sleep
# using lua-nginx-module style (we use a simple nginx conf with
# access_by_lua_block, or a simpler approach: replace with a netcat
# server that sleeps before responding)

set -euo pipefail
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
export KUBECONFIG="${KUBECONFIG:-${REAL_HOME}/.kube/config}"

DELAY_MS="${APP_DELAY_MS:-200}"
DELAY_S=$(echo "scale=3; $DELAY_MS / 1000" | bc 2>/dev/null || echo "0.2")

echo "[app_delay] Patching web pod to introduce ${DELAY_MS}ms application-level delay"
echo "[app_delay] Method: nginx with sleep wrapper (NOT tc netem)"
echo "[app_delay] Expected: latency ↑ ~${DELAY_MS}ms, retransmissions = 0, drops = 0"

# Create a ConfigMap with a custom nginx config that uses a Lua-free sleep trick:
# We use a sub-request to a local endpoint that sleeps via a cgi-like wrapper.
# Simplest approach: replace nginx with a Python HTTP server that sleeps.
kubectl apply -f - <<YAMLEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: python:3.11-slim
          command: ["python3", "-c"]
          args:
            - |
              import http.server, time, socket
              DELAY = ${DELAY_S}
              class SlowHandler(http.server.BaseHTTPRequestHandler):
                  def do_GET(self):
                      time.sleep(DELAY)
                      body = b'<html><body><h1>OK</h1></body></html>'
                      self.send_response(200)
                      self.send_header('Content-Type','text/html')
                      self.send_header('Content-Length', str(len(body)))
                      self.end_headers()
                      self.wfile.write(body)
                  def log_message(self, *a): pass
              print(f'[app_delay] Slow server: {DELAY*1000:.0f}ms delay per request')
              http.server.HTTPServer(('0.0.0.0', 80), SlowHandler).serve_forever()
          ports:
            - containerPort: 80
YAMLEOF

echo "[app_delay] Waiting for new pod to be ready..."
kubectl rollout status deployment/web --timeout=90s
echo "[app_delay] ✓ App delay active — web pod now adds ${DELAY_MS}ms per request"
echo "[app_delay]   This simulates slow database/middleware — no network faults"
