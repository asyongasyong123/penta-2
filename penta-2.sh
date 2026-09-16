#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================================
# GCP-XRAY — FIXED STARTUP PROBE FOR QWIKLABS
# ============================================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

APP_NAME="gcp-xray"
XRAY_VERSION="26.7.28"
XRAY_IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}@sha256:d7911c19a283acdc57e171ae0e3bd49ab4c29db14e2ab9274aa97132dd3ca3b9"

TROJAN_PASSWORD="gcp-xray"
VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"
AR_REPO="gcp-xray"
MAX_TIMEOUT="3600"

cleanup() { [[ -n "${BUILD_DIR:-}" ]] && rm -rf "$BUILD_DIR"; }
trap cleanup EXIT
trap 'echo -e "\n${RED}Failed at line $LINENO${NC}" >&2' ERR

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

require_command() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
check_dependencies() {
  require_command gcloud; require_command jq; require_command openssl
  gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null | grep -q . || die "Run: gcloud auth login"
}
get_project() {
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
  [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]] && die "Run: gcloud config set project YOUR_ID"
  ok "Project: $PROJECT_ID"
}
enable_apis() {
  info "Enabling APIs..."
  gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet
  ok "APIs enabled"
}
select_region() {
  echo
  echo "1) asia-east1   (Taiwan — Fastest 🇹🇼)"
  echo "2) asia-southeast1 (Singapore 🇸🇬)"
  echo "3) us-central1  (USA — Default Qwiklabs 🇺🇸)"
  echo "0) Custom"
  read -rp "Select region [0-3]: " REGION_CHOICE
  case "$REGION_CHOICE" in
    1) REGION="asia-east1" ;;
    2) REGION="asia-southeast1" ;;
    3) REGION="us-central1" ;;
    0) read -rp "Enter region: " REGION ;;
    *) warn "Invalid → using us-central1"; REGION="us-central1" ;;
  esac
  ok "Region: $REGION"
}
ensure_artifact_registry() {
  gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || {
    info "Creating Artifact Registry..."
    gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" --project="$PROJECT_ID" --quiet
  }
  ok "Registry ready"
}
select_resources() {
  echo
  echo "1) QWIKLABS SAFE — 1vCPU/1Gi/Concur 100/Max 2 ✅"
  echo "2) BALANCED      — 1vCPU/2Gi/Concur 150/Max 2"
  echo "3) HEAVY         — 2vCPU/2Gi/Concur 200/Max 2"
  echo "4) CUSTOM"
  read -rp "Select profile [1-4]: " RESOURCE_CHOICE
  case "$RESOURCE_CHOICE" in
    1) CPU=1; MEMORY=1Gi; CONCURRENCY=100; MIN_INSTANCES=0; MAX_INSTANCES=2; CPU_MODE="request" ;;
    2) CPU=1; MEMORY=2Gi; CONCURRENCY=150; MIN_INSTANCES=0; MAX_INSTANCES=2; CPU_MODE="request" ;;
    3) CPU=2; MEMORY=2Gi; CONCURRENCY=200; MIN_INSTANCES=0; MAX_INSTANCES=2; CPU_MODE="instance" ;;
    4) read -rp "CPU [1/2]: " CPU; read -rp "Memory: " MEMORY; read -rp "Concur: " CONCURRENCY; read -rp "Min: " MIN_INSTANCES; read -rp "Max: " MAX_INSTANCES; CPU_MODE="request" ;;
    *) warn "Using QWIKLABS SAFE"; CPU=1; MEMORY=1Gi; CONCURRENCY=100; MIN_INSTANCES=0; MAX_INSTANCES=2; CPU_MODE="request" ;;
  esac
  TIMEOUT=$MAX_TIMEOUT
  ok "Resources: $CPU vCPU / $MEMORY / Concurrency: $CONCURRENCY"
}
select_engine() {
  echo
  echo "1) OpenResty  — ✅ RECOMMENDED"
  echo "2) Envoy"
  echo "3) HAProxy"
  echo "4) Caddy"
  echo "5) Sing-Box   — (WS only)"
  read -rp "Engine [1-5]: " EC
  case $EC in
    1) ENGINE=openresty; DE=OpenResty ;;
    2) ENGINE=envoy; DE=Envoy ;;
    3) ENGINE=haproxy; DE=HAProxy ;;
    4) ENGINE=caddy; DE=Caddy ;;
    5) ENGINE=singbox; DE=Sing-Box ;;
    *) die "Invalid engine" ;;
  esac
  ok "Engine: $DE"
}
generate_credentials() {
  TROJAN_PASSWORD="gcp-xray"
  VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"
  export TROJAN_PASSWORD VLESS_UUID
}

write_xray_config() {
  cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "8.8.4.4"], "queryStrategy": "UseIPv4" },
  "policy": { "levels": { "0": { "handshake": 10, "connIdle": 3600, "bufferSize": 4194304 } } },
  "inbounds": [
    {
      "tag": "trojan-ws", "listen": "127.0.0.1", "port": 10001, "protocol": "trojan",
      "settings": { "clients": [{"password": "$TROJAN_PASSWORD"}] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-ws", "listen": "127.0.0.1", "port": 10002, "protocol": "vless",
      "settings": { "clients": [{"id": "$VLESS_UUID"}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-xhttp", "listen": "127.0.0.1", "port": 10003, "protocol": "vless",
      "settings": { "clients": [{"id": "$VLESS_UUID"}], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/xhttp", "mode": "auto" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-httpupgrade", "listen": "127.0.0.1", "port": 10004, "protocol": "vless",
      "settings": { "clients": [{"id": "$VLESS_UUID"}], "decryption": "none" },
      "streamSettings": { "network": "httpupgrade", "httpupgradeSettings": { "path": "/httpupgrade" }, "sockopt": { "tcpNoDelay": true } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } }]
}
EOF
}

write_supervisor() {
  cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
user=root
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray/config.json
autorestart=true
startsecs=1
stdout_logfile=/dev/fd/1
stderr_logfile=/dev/fd/2
[program:proxy]
command=${PROXY_COMMAND}
autorestart=true
startsecs=1
stdout_logfile=/dev/fd/1
stderr_logfile=/dev/fd/2
EOF
}

build_openresty() {
  cat > nginx.conf <<'EOF'
worker_processes auto;
events { worker_connections 4096; }
http {
  sendfile on; tcp_nodelay on; keepalive_timeout 3600s;
  map $http_upgrade $conn_upg { default upgrade; '' close; }
  server {
    listen 8080;
    location = /health { access_log off; return 200 "OK\n"; }
    location /trojan-ws {
      proxy_pass http://127.0.0.1:10001;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $conn_upg;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
      proxy_buffering off;
    }
    location /vless-ws {
      proxy_pass http://127.0.0.1:10002;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $conn_upg;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
      proxy_buffering off;
    }
    location /xhttp {
      proxy_pass http://127.0.0.1:10003;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
      proxy_buffering off;
    }
    location /httpupgrade {
      proxy_pass http://127.0.0.1:10004;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $conn_upg;
      proxy_set_header Host $host;
      proxy_read_timeout 3600s;
      proxy_buffering off;
    }
    location / { return 200 '<html><body>Ready</body></html>'; }
  }
}
EOF
  PROXY_COMMAND="/usr/local/openresty/bin/openresty -g 'daemon off;'"
  write_supervisor
  cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray
FROM openresty/openresty:alpine-fat
RUN apk add --no-cache supervisor
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY supervisord.conf /etc/supervisord.conf
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_caddy() {
  cat > Caddyfile <<'EOF'
{ admin off; auto_https off }
:8080 {
  handle /health { respond "OK" 200 }
  @trojan path /trojan-ws*
  reverse_proxy @trojan 127.0.0.1:10001
  @vless path /vless-ws*
  reverse_proxy @vless 127.0.0.1:10002
  @xhttp path /xhttp*
  reverse_proxy @xhttp 127.0.0.1:10003
  @httpupgrade path /httpupgrade*
  reverse_proxy @httpupgrade 127.0.0.1:10004
  handle { respond "<html><body>Ready</body></html>" 200 }
}
EOF
  PROXY_COMMAND="caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
  write_supervisor
  cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray
FROM caddy:2.10.0-alpine
RUN apk add --no-cache supervisor
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisord.conf
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_haproxy() {
  cat > haproxy.cfg <<'EOF'
global
  maxconn 4096
defaults
  mode http
  timeout connect 10s
  timeout client 3600s
  timeout server 3600s
frontend in
  bind :8080
  acl health path -i /health
  http-request return status 200 string "OK\n" if health
  acl trojan path_beg /trojan-ws
  acl vless path_beg /vless-ws
  acl xhttp path_beg /xhttp
  acl httpupgrade path_beg /httpupgrade
  use_backend xray_trojan if trojan
  use_backend xray_vless if vless
  use_backend xray_xhttp if xhttp
  use_backend xray_httpupgrade if httpupgrade
  default_backend decoy
backend xray_trojan  { server s 127.0.0.1:10001 }
backend xray_vless   { server s 127.0.0.1:10002 }
backend xray_xhttp   { server s 127.0.0.1:10003 }
backend xray_httpupgrade { server s 127.0.0.1:10004 }
backend decoy { http-request return status 200 string "Ready" }
EOF
  PROXY_COMMAND="haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg"
  write_supervisor
  cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray
FROM haproxy:3.2.23-alpine
USER root
RUN apk add --no-cache supervisor
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY supervisord.conf /etc/supervisord.conf
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_envoy() {
  cat > envoy.yaml <<'EOF'
static_resources:
  listeners:
  - name: http
    address: { socket_address: { address: 0.0.0.0, port_value: 8080 } }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress
          stream_idle_timeout: 3600s
          route_config:
            name: local
            virtual_hosts:
            - name: local
              domains: ["*"]
              routes:
              - match: { path: /health }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: /trojan-ws }
                route: { cluster: xray_trojan, timeout: 0s, upgrade_configs: [{upgrade_type: websocket}] }
              - match: { prefix: /vless-ws }
                route: { cluster: xray_vless, timeout: 0s, upgrade_configs: [{upgrade_type: websocket}] }
              - match: { prefix: /xhttp }
                route: { cluster: xray_xhttp, timeout: 0s }
              - match: { prefix: /httpupgrade }
                route: { cluster: xray_httpupgrade, timeout: 0s, upgrade_configs: [{upgrade_type: websocket}] }
              - match: { prefix: / }
                direct_response: { status: 200, body: { inline_string: "Ready" } }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: {}
  clusters:
  - name: xray_trojan    { connect_timeout: 10s, load_assignment: { endpoints: [{lb_endpoints: [{endpoint: {socket_address: {address: 127.0.0.1, port_value: 10001}}]}]}} }
  - name: xray_vless     { connect_timeout: 10s, load_assignment: { endpoints: [{lb_endpoints: [{endpoint: {socket_address: {address: 127.0.0.1, port_value: 10002}}]}]}} }
  - name: xray_xhttp     { connect_timeout: 10s, load_assignment: { endpoints: [{lb_endpoints: [{endpoint: {socket_address: {address: 127.0.0.1, port_value: 10003}}]}]}} }
  - name: xray_httpupgrade { connect_timeout: 10s, load_assignment: { endpoints: [{lb_endpoints: [{endpoint: {socket_address: {address: 127.0.0.1, port_value: 10004}}]}]}} }
EOF
  PROXY_COMMAND="envoy -c /etc/envoy/envoy.yaml"
  write_supervisor
  cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray
FROM envoyproxy/envoy:v1.30-latest
USER root
RUN apt-get update && apt-get install -y supervisor && rm -rf /var/lib/apt/lists/*
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY supervisord.conf /etc/supervisord.conf
RUN /usr/local/bin/xray run -test -c /etc/xray/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_singbox() {
  SINGBOX_VERSION="1.14.1"
  cat > sing-box.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "trojan", "tag": "trojan-ws", "listen": "127.0.0.1", "listen_port": 10001, "users": [{"password": "$TROJAN_PASSWORD"}], "transport": { "type": "ws", "path": "/trojan-ws" } },
    { "type": "vless", "tag": "vless-ws", "listen": "127.0.0.1", "listen_port": 10002, "users": [{"uuid": "$VLESS_UUID"}], "transport": { "type": "ws", "path": "/vless-ws" } }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF
  cat > Caddyfile <<'EOF'
{ admin off }
:8080 {
  handle /health { respond "OK" 200 }
  @trojan path /trojan-ws*; reverse_proxy @trojan 127.0.0.1:10001
  @vless path /vless-ws*; reverse_proxy @vless 127.0.0.1:10002
  handle { respond "Ready" 200 }
}
EOF
  cat > supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
[program:singbox]
command=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
autorestart=true
[program:proxy]
command=caddy run --config /etc/caddy/Caddyfile
autorestart=true
EOF
  cat > Dockerfile <<EOF
FROM ghcr.io/sagernet/sing-box:${SINGBOX_VERSION} AS sb
FROM caddy:2.10.0-alpine
RUN apk add --no-cache supervisor
COPY --from=sb /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY sing-box.json /etc/sing-box/config.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisord.conf
RUN /usr/local/bin/sing-box check -c /etc/sing-box/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_engine() {
  case $ENGINE in
    openresty) build_openresty ;;
    envoy) build_envoy ;;
    haproxy) build_haproxy ;;
    caddy) build_caddy ;;
    singbox) build_singbox ;;
    *) die "Unknown engine" ;;
  esac
}

write_dockerignore() {
  cat > .dockerignore <<'EOF'
.git
*.log
*.tmp
EOF
}

validate_config() {
  if [[ "$ENGINE" == "singbox" ]]; then jq empty sing-box.json || die "JSON invalid";
  else jq empty config.json || die "JSON invalid"; fi
  [[ -f Dockerfile ]] || die "No Dockerfile"
}

build_and_push() {
  IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${BUILD_ID}"
  info "Building: $IMAGE_TAG"
  gcloud builds submit --project="$PROJECT_ID" --tag="$IMAGE_TAG" --quiet
  ok "Image pushed"
}

deploy_cloud_run() {
  info "Deploying Cloud Run..."
  DEPLOY_ARGS=(
    gcloud run deploy "$SERVICE_NAME"
    --image="$IMAGE_TAG"
    --project="$PROJECT_ID"
    --region="$REGION"
    --platform=managed
    --port=8080
    --cpu="$CPU"
    --memory="$MEMORY"
    --concurrency="$CONCURRENCY"
    --timeout="${TIMEOUT}s"
    --min-instances="$MIN_INSTANCES"
    --max-instances="$MAX_INSTANCES"
    --execution-environment=gen2
    --cpu-boost
    --session-affinity
    --allow-unauthenticated
    # ✅ FIXED: TCP probe format — compatible sa tanang gcloud versions
    --startup-probe=tcpSocket.port=8080,initialDelaySeconds=5,periodSeconds=5,failureThreshold=12,timeoutSeconds=3
    --quiet
  )
  [[ "$CPU_MODE" == "instance" ]] && DEPLOY_ARGS+=(--no-cpu-throttling)
  "${DEPLOY_ARGS[@]}"
  ok "Deployment OK"
}

verify_service() {
  CLOUD_RUN_URL="$(gcloud run services describe "$SERVICE_NAME" --region="$REGION" --format='value(status.url)')"
  [[ -z "$CLOUD_RUN_URL" ]] && die "No URL returned"
  for i in {1..10}; do
    if curl -fsS --max-time 8 "$CLOUD_RUN_URL/health" 2>/dev/null; then
      ok "✅ Health OK — $CLOUD_RUN_URL"
      return
    fi
    info "Waiting... $i/10"
    sleep 5
  done
  warn "Health check delayed — check Cloud Run Logs"
}

show_result() {
  DOMAIN="${CLOUD_RUN_URL#https://}"
  echo
  echo "============================================================"
  echo -e "${GREEN}✅ SUCCESS ✅${NC}"
  echo "============================================================"
  echo "URL:      $CLOUD_RUN_URL"
  echo "Domain:   $DOMAIN"
  echo "Region:   $REGION"
  echo "Engine:   $DE"
  echo
  echo "=== NETMOD SETTINGS ==="
  echo "Host:     $DOMAIN"
  echo "Port:     443"
  echo "Network:  WebSocket"
  echo
  echo "VLESS-WS:"
  echo "  Path:   /vless-ws"
  echo "  UUID:   $VLESS_UUID"
  echo
  echo "Trojan-WS:"
  echo "  Path:   /trojan-ws"
  echo "  Pass:   $TROJAN_PASSWORD"
  echo
  if [[ "$ENGINE" != "singbox" ]]; then
    echo "XHTTP:        /xhttp"
    echo "HTTPUpgrade:  /httpupgrade"
  fi
  echo "============================================================"
}

deploy_new_service() {
  check_dependencies; get_project; enable_apis
  select_region; ensure_artifact_registry; select_resources; select_engine; generate_credentials
  BUILD_DIR="$(mktemp -d)"; cd "$BUILD_DIR"
  SERVICE_NAME="${APP_NAME}-${ENGINE}-$(openssl rand -hex 3)"
  BUILD_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"
  info "Service: $SERVICE_NAME"
  write_xray_config; write_dockerignore; build_engine; validate_config
  build_and_push; deploy_cloud_run; verify_service; show_result
  read -rp "Enter to continue..."
}

list_services() {
  get_project
  gcloud run services list --project="$PROJECT_ID" --format="table(metadata.name,status.url,region)"
  read -rp "Enter..."
}

main_menu() {
  check_dependencies; get_project
  while true; do
    clear
    echo "==== GCP-XRAY — PROBE FIXED ===="
    echo "Project: $PROJECT_ID"
    echo "1) Deploy New"
    echo "2) List Services"
    echo "3) Exit"
    read -rp "Choice [1-3]: " MC
    case $MC in
      1) deploy_new_service ;;
      2) list_services ;;
      3) exit 0 ;;
    esac
  done
}

main_menu
