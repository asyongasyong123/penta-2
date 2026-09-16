#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================================
# GCP-XRAY CLOUD RUN DEPLOYER — ORIGINAL PRESERVED + FIXED
# Credentials: UNCHANGED
# ============================================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

APP_NAME="gcp-xray"

# ✅ KEPT ORIGINAL — DO NOT CHANGE
XRAY_VERSION="26.7.28"
XRAY_IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}@sha256:d7911c19a283acdc57e171ae0e3bd49ab4c29db14e2ab9274aa97132dd3ca3b9"

TROJAN_PASSWORD="gcp-xray"
VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"

AR_REPO="gcp-xray"
MAX_TIMEOUT="3600"

cleanup() {
    if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR:-}" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}
trap cleanup EXIT
trap 'echo -e "\n${RED}Deployment failed at line $LINENO.${NC}" >&2' ERR

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_dependencies() {
    require_command gcloud
    require_command jq
    require_command openssl
    require_command curl

    if ! gcloud auth list \
        --filter="status:ACTIVE" \
        --format="value(account)" 2>/dev/null | grep -q .; then
        die "No active gcloud account. Run: gcloud auth login"
    fi
}

get_project() {
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
    if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
        die "No GCP project configured. Run: gcloud config set project YOUR_PROJECT_ID"
    fi
    ok "Project: $PROJECT_ID"
}

enable_apis() {
    info "Enabling required APIs..."
    gcloud services enable \
        run.googleapis.com \
        artifactregistry.googleapis.com \
        cloudbuild.googleapis.com \
        serviceusage.googleapis.com \
        --project="$PROJECT_ID" \
        --quiet
    ok "Required APIs enabled."
}

select_region() {
    echo
    echo "================================================"
    echo " CLOUD RUN REGION"
    echo "================================================"
    echo "1) asia-east1   (Taiwan — Recommended 🇹🇼)"
    echo "2) asia-southeast1 (Singapore 🇸🇬)"
    echo "3) us-central1  (USA 🇺🇸)"
    echo "0) Custom"
    echo
    read -r -p "Select region [0-3]: " REGION_CHOICE

    case "$REGION_CHOICE" in
        1) REGION="asia-east1" ;;
        2) REGION="asia-southeast1" ;;
        3) REGION="us-central1" ;;
        0) read -r -p "Enter region: " REGION ;;
        *) warn "Invalid selection. Using asia-east1."; REGION="asia-east1" ;;
    esac

    [[ "$REGION" =~ ^[a-z0-9-]+$ ]] || die "Invalid region: $REGION"
    ok "Region: $REGION"
}

ensure_artifact_registry() {
    info "Checking Artifact Registry repository..."
    if gcloud artifacts repositories describe "$AR_REPO" \
        --location="$REGION" \
        --project="$PROJECT_ID" >/dev/null 2>&1; then
        ok "Artifact Registry repository exists: $AR_REPO"
        return
    fi

    info "Creating Artifact Registry repository..."
    gcloud artifacts repositories create "$AR_REPO" \
        --repository-format=docker \
        --location="$REGION" \
        --description="GCP-Xray Cloud Run images" \
        --project="$PROJECT_ID" \
        --quiet
    ok "Artifact Registry repository created."
}

select_resources() {
    echo
    echo "================================================"
    echo " RESOURCE PROFILE"
    echo "================================================"
    echo "1) QWIKLABS SAFE  - 1 vCPU / 1Gi / Concur 100 / max 2"
    echo "2) BALANCED       - 1 vCPU / 2Gi / Concur 150 / max 2"
    echo "3) HEAVY          - 2 vCPU / 2Gi / Concur 200 / max 2"
    echo "4) CUSTOM"
    echo

    read -r -p "Select profile [1-4]: " RESOURCE_CHOICE

    case "$RESOURCE_CHOICE" in
        1)
            CPU="1"; MEMORY="1Gi"; CONCURRENCY="100"
            MIN_INSTANCES="0"; MAX_INSTANCES="2"; CPU_MODE="request"
            ;;
        2)
            CPU="1"; MEMORY="2Gi"; CONCURRENCY="150"
            MIN_INSTANCES="0"; MAX_INSTANCES="2"; CPU_MODE="request"
            ;;
        3)
            CPU="2"; MEMORY="2Gi"; CONCURRENCY="200"
            MIN_INSTANCES="0"; MAX_INSTANCES="2"; CPU_MODE="instance"
            ;;
        4)
            read -r -p "CPU [1 or 2]: " CPU
            read -r -p "Memory [1Gi or 2Gi]: " MEMORY
            read -r -p "Concurrency [1-1000]: " CONCURRENCY
            read -r -p "Minimum instances [0-2]: " MIN_INSTANCES
            read -r -p "Maximum instances [1-3]: " MAX_INSTANCES
            CPU_MODE="request"
            ;;
        *)
            warn "Invalid choice. Using QWIKLABS SAFE."
            CPU="1"; MEMORY="1Gi"; CONCURRENCY="100"
            MIN_INSTANCES="0"; MAX_INSTANCES="2"; CPU_MODE="request"
            ;;
    esac

    [[ "$CPU" =~ ^[12]$ ]] || die "CPU must be 1 or 2."
    [[ "$MEMORY" =~ ^(1Gi|2Gi)$ ]] || die "Memory must be 1Gi or 2Gi."
    [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "Concurrency must be numeric."
    (( CONCURRENCY >= 1 && CONCURRENCY <= 1000 )) || die "Concurrency must be 1-1000."
    [[ "$MIN_INSTANCES" =~ ^[0-9]+$ ]] || die "Minimum instances must be numeric."
    [[ "$MAX_INSTANCES" =~ ^[0-9]+$ ]] || die "Maximum instances must be numeric."
    (( MAX_INSTANCES >= 1 && MAX_INSTANCES <= 3 )) || die "Maximum instances must be 1-3."
    (( MIN_INSTANCES <= MAX_INSTANCES )) || die "Minimum cannot exceed maximum."

    TIMEOUT="$MAX_TIMEOUT"

    echo
    ok "CPU:          $CPU vCPU"
    ok "Memory:       $MEMORY"
    ok "Concurrency:  $CONCURRENCY"
    ok "Min:          $MIN_INSTANCES"
    ok "Max:          $MAX_INSTANCES"
    ok "Timeout:      ${TIMEOUT}s"
}

show_quota_information() {
    echo
    echo "================================================"
    echo " CLOUD RUN QUOTA CHECK"
    echo "================================================"

    CPU_TOTAL=$((CPU * MAX_INSTANCES))
    case "$MEMORY" in
        1Gi) MEMORY_MIB=1024 ;;
        2Gi) MEMORY_MIB=2048 ;;
        *) MEMORY_MIB=0 ;;
    esac
    MEMORY_TOTAL_MIB=$((MEMORY_MIB * MAX_INSTANCES))

    info "Max CPU footprint:    ${CPU_TOTAL} vCPU"
    info "Max Memory footprint: ${MEMORY_TOTAL_MIB} MiB"

    if gcloud quotas info list \
        --service=run.googleapis.com \
        --project="$PROJECT_ID" \
        --format="table(name,metric)" 2>/dev/null; then
        ok "Cloud Quotas metadata queried."
    else
        warn "Cloud Quotas unavailable; continuing with local limits."
    fi
}

select_engine() {
    echo
    echo "================================================"
    echo " PROXY ENGINE"
    echo "================================================"
    echo "1) OpenResty  — ✅ RECOMMENDED (stable WS)"
    echo "2) Envoy"
    echo "3) HAProxy"
    echo "4) Caddy"
    echo "5) Sing-Box   — (WS only, no XHTTP)"
    echo
    read -r -p "Select engine [1-5]: " ENGINE_CHOICE

    case "$ENGINE_CHOICE" in
        1) ENGINE="openresty"; DISPLAY_ENGINE="OpenResty" ;;
        2) ENGINE="envoy";     DISPLAY_ENGINE="Envoy" ;;
        3) ENGINE="haproxy";   DISPLAY_ENGINE="HAProxy" ;;
        4) ENGINE="caddy";     DISPLAY_ENGINE="Caddy" ;;
        5) ENGINE="singbox";   DISPLAY_ENGINE="Sing-Box" ;;
        *) die "Invalid engine selection." ;;
    esac

    ok "Engine: $DISPLAY_ENGINE"
}

generate_credentials() {
    # ✅ KEPT ORIGINAL — NO RANDOMIZATION
    TROJAN_PASSWORD="gcp-xray"
    VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"
    export TROJAN_PASSWORD VLESS_UUID
}

write_xray_config() {
    cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4"],
    "queryStrategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 10,
        "connIdle": 3600,
        "uplinkOnly": 0,
        "downlinkOnly": 0,
        "bufferSize": 4194304
      }
    }
  },
  "inbounds": [
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "${TROJAN_PASSWORD}", "level": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/trojan-ws",
          "headers": {}
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless-ws",
          "headers": {}
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": 10003,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto",
          "noGRPC": true
        },
        "sockopt": { "tcpNoDelay": true }
      }
    },
    {
      "tag": "vless-httpupgrade",
      "listen": "127.0.0.1",
      "port": 10004,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/httpupgrade"
        },
        "sockopt": { "tcpNoDelay": true }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" }
    }
  ]
}
EOF
}

write_supervisor() {
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid
user=root

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray/config.json
priority=10
autorestart=true
startsecs=1
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:proxy]
command=${PROXY_COMMAND}
priority=20
autorestart=true
startsecs=1
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

build_openresty() {
    cat > nginx.conf <<'EOF'
worker_processes auto;
worker_rlimit_nofile 8192;
events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}
http {
    sendfile on;
    tcp_nodelay on;
    keepalive_timeout 3600s;
    reset_timedout_connection on;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 8080;
        server_name _;

        # ✅ FIXED: Health check — Cloud Run starts faster
        location = /health {
            access_log off;
            return 200 "OK\n";
        }

        # ✅ FIXED: Proper WS headers → no timeout
        location /trojan-ws {
            proxy_pass http://127.0.0.1:10001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 10s;
            proxy_buffering off;
            proxy_cache off;
            proxy_request_buffering off;
        }

        location /vless-ws {
            proxy_pass http://127.0.0.1:10002;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 10s;
            proxy_buffering off;
            proxy_cache off;
            proxy_request_buffering off;
        }

        location /xhttp {
            proxy_pass http://127.0.0.1:10003;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header Connection '';
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }

        location /httpupgrade {
            proxy_pass http://127.0.0.1:10004;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }

        location / {
            default_type text/html;
            return 200 '<!doctype html><html><body style="font-family:system-ui;text-align:center;padding:2em;"><h1>Service Ready ✅</h1><p>GCP-Xray Cloud Run</p></body></html>';
        }
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
{
    admin off
    auto_https off
    http_port 8080
}

:8080 {
    handle /health {
        respond "OK" 200
    }

    @trojan path /trojan-ws*
    reverse_proxy @trojan 127.0.0.1:10001 {
        header_up Upgrade
        header_up Connection {header.Connection}
        header_up Host {host}
        transport http { keepalive_idle_conns 32 }
    }

    @vless path /vless-ws*
    reverse_proxy @vless 127.0.0.1:10002 {
        header_up Upgrade
        header_up Connection {header.Connection}
        header_up Host {host}
        transport http { keepalive_idle_conns 32 }
    }

    @xhttp path /xhttp*
    reverse_proxy @xhttp 127.0.0.1:10003 {
        header_up Host {host}
    }

    @httpupgrade path /httpupgrade*
    reverse_proxy @httpupgrade 127.0.0.1:10004 {
        header_up Upgrade
        header_up Connection {header.Connection}
        header_up Host {host}
    }

    handle {
        respond "<!doctype html><html><body><h1>Service Ready</h1></body></html>" 200
    }
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
    log stdout format raw local0
    maxconn 4096
    nbthread 2

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s

frontend in
    bind :8080

    acl health path -i /health
    http-request return status 200 content-type text/plain string "OK\n" if health

    acl trojan path_beg /trojan-ws
    acl vless path_beg /vless-ws
    acl xhttp path_beg /xhttp
    acl httpupgrade path_beg /httpupgrade

    use_backend xray_trojan if trojan
    use_backend xray_vless if vless
    use_backend xray_xhttp if xhttp
    use_backend xray_httpupgrade if httpupgrade

    default_backend decoy

backend xray_trojan
    server xray 127.0.0.1:10001

backend xray_vless
    server xray 127.0.0.1:10002

backend xray_xhttp
    server xray 127.0.0.1:10003

backend xray_httpupgrade
    server xray 127.0.0.1:10004

backend decoy
    http-request return status 200 content-type text/html string "<!doctype html><html><body><h1>Ready</h1></body></html>"
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
  - name: cloudrun_http
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8080
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress
          stream_idle_timeout: 3600s
          request_timeout: 0s
          upgrade_configs:
          - upgrade_type: websocket
            enabled: true
          route_config:
            name: local
            virtual_hosts:
            - name: local
              domains: ["*"]
              routes:
              - match: { path: /health }
                direct_response:
                  status: 200
                  body: { inline_string: "OK\n" }
              - match: { prefix: /trojan-ws }
                route:
                  cluster: xray_trojan
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket
                    enabled: true
              - match: { prefix: /vless-ws }
                route:
                  cluster: xray_vless
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket
                    enabled: true
              - match: { prefix: /xhttp }
                route: { cluster: xray_xhttp, timeout: 0s }
              - match: { prefix: /httpupgrade }
                route:
                  cluster: xray_httpupgrade
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket
                    enabled: true
              - match: { prefix: / }
                direct_response:
                  status: 200
                  body: { inline_string: "<!doctype html><html><body><h1>Ready</h1></body></html>" }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: xray_trojan
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_trojan
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: 127.0.0.1, port_value: 10001 } }
  - name: xray_vless
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_vless
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: 127.0.0.1, port_value: 10002 } }
  - name: xray_xhttp
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_xhttp
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: 127.0.0.1, port_value: 10003 } }
  - name: xray_httpupgrade
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_httpupgrade
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: 127.0.0.1, port_value: 10004 } }
EOF

    PROXY_COMMAND="envoy -c /etc/envoy/envoy.yaml"
    write_supervisor

    cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray
FROM envoyproxy/envoy:v1.30-latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends supervisor \
    && rm -rf /var/lib/apt/lists/*

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
    {
      "type": "trojan",
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [{"password": "${TROJAN_PASSWORD}"}],
      "transport": { "type": "ws", "path": "/trojan-ws" }
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": 10002,
      "users": [{"uuid": "${VLESS_UUID}"}],
      "transport": { "type": "ws", "path": "/vless-ws" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    cat > Caddyfile <<'EOF'
{
    admin off
    auto_https off
}

:8080 {
    handle /health { respond "OK" 200 }

    @trojan path /trojan-ws*
    reverse_proxy @trojan 127.0.0.1:10001 {
        header_up Upgrade
        header_up Connection {header.Connection}
    }

    @vless path /vless-ws*
    reverse_proxy @vless 127.0.0.1:10002 {
        header_up Upgrade
        header_up Connection {header.Connection}
    }

    handle { respond "<html><body>Ready</body></html>" 200 }
}
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
user=root

[program:singbox]
command=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
priority=10
autorestart=true
startsecs=1
stdout_logfile=/dev/fd/1
stderr_logfile=/dev/fd/2

[program:proxy]
command=caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
priority=20
autorestart=true
stdout_logfile=/dev/fd/1
stderr_logfile=/dev/fd/2
EOF

    cat > Dockerfile <<EOF
FROM ghcr.io/sagernet/sing-box:${SINGBOX_VERSION} AS singbox
FROM caddy:2.10.0-alpine

RUN apk add --no-cache supervisor
COPY --from=singbox /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY sing-box.json /etc/sing-box/config.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisord.conf

RUN /usr/local/bin/sing-box check -c /etc/sing-box/config.json
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
}

build_engine() {
    case "$ENGINE" in
        openresty) build_openresty ;;
        envoy)     build_envoy ;;
        haproxy)   build_haproxy ;;
        caddy)     build_caddy ;;
        singbox)   build_singbox ;;
        *) die "Unknown engine: $ENGINE" ;;
    esac
}

write_dockerignore() {
    cat > .dockerignore <<'EOF'
.git
.gitignore
*.log
*.tmp
*.swp
.DS_Store
EOF
}

validate_config() {
    info "Validating generated configuration..."

    if [[ "$ENGINE" == "singbox" ]]; then
        jq empty sing-box.json || die "Sing-Box JSON invalid."
        ok "Sing-Box config valid."
    else
        jq empty config.json || die "Xray JSON invalid."
        ok "Xray config valid."
    fi

    [[ -f Dockerfile ]] || die "Dockerfile not generated."
    ok "Dockerfile present."
}

build_and_push() {
    IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${BUILD_ID}"

    info "Building & pushing image..."
    info "Image: $IMAGE_TAG"

    gcloud builds submit \
        --project="$PROJECT_ID" \
        --tag="$IMAGE_TAG" \
        --quiet

    ok "Image built and pushed successfully."
}

deploy_cloud_run() {
    info "Deploying Cloud Run service..."

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
        # ✅ FIXED: Health probe — faster startup, less timeout
        --startup-probe="http.path=/health,initialDelaySeconds=3,periodSeconds=4,failureThreshold=8,timeoutSeconds=5"
        --quiet
    )

    if [[ "$CPU_MODE" == "instance" ]]; then
        DEPLOY_ARGS+=(--no-cpu-throttling)
    fi

    "${DEPLOY_ARGS[@]}"
    ok "Cloud Run deployment completed."
}

verify_service() {
    info "Retrieving service URL..."

    CLOUD_RUN_URL="$(
        gcloud run services describe "$SERVICE_NAME" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --format='value(status.url)'
    )"

    [[ -n "$CLOUD_RUN_URL" ]] || die "Cloud Run returned no URL."
    ok "Service URL: $CLOUD_RUN_URL"

    info "Verifying /health endpoint..."
    for attempt in {1..12}; do
        if curl -fsS --max-time 10 "${CLOUD_RUN_URL}/health" >/dev/null 2>&1; then
            ok "✅ Health check passed — service ready!"
            return
        fi
        warn "Health check attempt ${attempt}/12..."
        sleep 5
    done

    warn "⚠️ Health check delayed — but service may be starting."
    warn "Check Cloud Run Logs → before testing NetMod."
}

show_result() {
    DOMAIN="${CLOUD_RUN_URL#https://}"

    echo
    echo "============================================================"
    echo -e "${GREEN}✅ DEPLOYMENT COMPLETE ✅${NC}"
    echo "============================================================"
    echo
    echo "Engine:          $DISPLAY_ENGINE"
    echo "Region:          $REGION"
    echo "CPU:             $CPU vCPU"
    echo "Memory:          $MEMORY"
    echo "Concurrency:     $CONCURRENCY"
    echo "Min/Max:         $MIN_INSTANCES / $MAX_INSTANCES"
    echo
    echo "Service URL:     $CLOUD_RUN_URL"
    echo "Domain:          $DOMAIN"
    echo "Health:          ${CLOUD_RUN_URL}/health"
    echo
    echo "--- CREDENTIALS (ORIGINAL PRESERVED) ---"
    echo "Trojan Password: $TROJAN_PASSWORD"
    echo "VLESS UUID:      $VLESS_UUID"
    echo
    echo "--- NETMOD SETTINGS ---"
    echo "Host:            $DOMAIN"
    echo "Port:            443"
    echo "Network:         WebSocket"
    echo "Security:        TLS / none"
    echo "SNI:             $DOMAIN"
    echo
    echo "VLESS-WS:"
    echo "  Path:          /vless-ws"
    echo "  UUID:          $VLESS_UUID"
    echo
    echo "Trojan-WS:"
    echo "  Path:          /trojan-ws"
    echo "  Password:      $TROJAN_PASSWORD"
    echo

    if [[ "$ENGINE" != "singbox" ]]; then
        echo "XHTTP:"
        echo "  Path:          /xhttp"
        echo "HTTPUpgrade:"
        echo "  Path:          /httpupgrade"
    fi

    echo
    echo "============================================================"
}

list_services() {
    check_dependencies
    get_project
    echo
    gcloud run services list \
        --project="$PROJECT_ID" \
        --format="table(metadata.name,status.url,region)"
    echo
    read -r -p "Press Enter to continue..."
}

service_details() {
    get_project
    read -r -p "Service name: " SERVICE_NAME
    read -r -p "Region: " REGION

    gcloud run services describe "$SERVICE_NAME" \
        --project="$PROJECT_ID" \
        --region="$REGION"

    echo
    read -r -p "Press Enter to continue..."
}

deploy_new_service() {
    check_dependencies
    get_project
    enable_apis

    select_region
    ensure_artifact_registry
    select_resources
    show_quota_information
    select_engine
    generate_credentials

    BUILD_DIR="$(mktemp -d)"
    cd "$BUILD_DIR" || die "Failed to enter build directory."

    SERVICE_NAME="${APP_NAME}-${ENGINE}-$(openssl rand -hex 3)"
    SERVICE_NAME="${SERVICE_NAME:0:49}"
    BUILD_ID="$(date +%Y%m%d-%H%M%S)-$(openssl rand -hex 2)"

    echo
    info "Service name: $SERVICE_NAME"
    info "Build ID:     $BUILD_ID"
    info "Trojan Pass:  $TROJAN_PASSWORD"
    info "VLESS UUID:   $VLESS_UUID"

    write_xray_config
    write_dockerignore
    build_engine
    validate_config
    build_and_push
    deploy_cloud_run
    verify_service
    show_result

    echo
    read -r -p "Press Enter to return to menu..."
}

main_menu() {
    check_dependencies
    get_project

    while true; do
        clear
        echo "============================================================"
        echo " GCP-XRAY CLOUD RUN DEPLOYER — ORIGINAL + NETMOD FIXED"
        echo "============================================================"
        echo "Project: $PROJECT_ID"
        echo
        echo "1) Deploy new service"
        echo "2) List all services"
        echo "3) Service details"
        echo "4) Exit"
        echo
        read -r -p "Select [1-4]: " MENU_CHOICE

        case "$MENU_CHOICE" in
            1) deploy_new_service ;;
            2) list_services ;;
            3) service_details ;;
            4) echo "Goodbye."; exit 0 ;;
            *) warn "Enter 1, 2, 3, or 4."; sleep 2 ;;
        esac
    done
}

main_menu
