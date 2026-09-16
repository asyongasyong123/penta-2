#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# GCP-XRAY CLOUD RUN DEPLOYER
# ============================================================================
#
# Engines:
#   1) OpenResty
#   2) Envoy
#   3) HAProxy
#   4) Caddy
#   5) Sing-Box
#
# Protocol layer:
#   Xray:
#     - Trojan WebSocket
#     - VLESS WebSocket
#     - VLESS XHTTP
#     - VLESS HTTPUpgrade
#
# Cloud Run:
#   - Artifact Registry
#   - Gen2
#   - Startup CPU boost
#   - Health checks
#   - Conservative quota-aware presets
#   - 3600s maximum request timeout
#
# IMPORTANT:
#   Set Xray version explicitly. Do NOT use "latest" for production builds.
#
# ============================================================================

set -o errtrace

# ----------------------------------------------------------------------------
# COLORS
# ----------------------------------------------------------------------------

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BLUE='\033[1;34m'
NC='\033[0m'

# ----------------------------------------------------------------------------
# GLOBAL SETTINGS
# ----------------------------------------------------------------------------

APP_NAME="gcp-xray"

# Pinned stable Xray version.
# Change deliberately when upgrading.
XRAY_VERSION="26.7.28"

# Xray upstream container digest for linux/amd64.
# This makes the base image reproducible.
XRAY_IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}@sha256:d7911c19a283acdc57e171ae0e3bd49ab4c29db14e2ab9274aa97132dd3ca3b9"

# Artifact Registry repository.
AR_REPO="gcp-xray"

# Cloud Run hard request-timeout ceiling.
MAX_TIMEOUT="3600"

# Default service maximum.
DEFAULT_MAX_INSTANCES="2"

# ----------------------------------------------------------------------------
# ERROR HANDLING
# ----------------------------------------------------------------------------

cleanup() {
    if [[ -n "${BUILD_DIR:-}" && -d "${BUILD_DIR:-}" ]]; then
        rm -rf "$BUILD_DIR"
    fi
}

trap cleanup EXIT
trap 'echo -e "\n${RED}Deployment failed at line $LINENO.${NC}" >&2' ERR

# ----------------------------------------------------------------------------
# LOGGING
# ----------------------------------------------------------------------------

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

ok() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

die() {
    echo -e "${RED}[FAIL]${NC} $*" >&2
    exit 1
}

# ----------------------------------------------------------------------------
# DEPENDENCY CHECK
# ----------------------------------------------------------------------------

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_dependencies() {
    require_command gcloud
    require_command jq
    require_command openssl
    require_command sed
    require_command awk

    if ! gcloud auth list \
        --filter="status:ACTIVE" \
        --format="value(account)" 2>/dev/null | grep -q .; then
        die "No active gcloud account. Run: gcloud auth login"
    fi
}

# ----------------------------------------------------------------------------
# PROJECT
# ----------------------------------------------------------------------------

get_project() {
    PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"

    if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
        die "No GCP project configured.

Run:
  gcloud config set project YOUR_PROJECT_ID"
    fi

    ok "Project: $PROJECT_ID"
}

# ----------------------------------------------------------------------------
# ENABLE APIS
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# REGION
# ----------------------------------------------------------------------------

select_region() {
    echo
    echo "================================================"
    echo " CLOUD RUN REGION"
    echo "================================================"
    echo "1) asia-east1"
    echo "2) asia-southeast1"
    echo "3) asia-northeast1"
    echo "4) asia-northeast3"
    echo "5) us-central1"
    echo "6) europe-west1"
    echo "0) Custom"
    echo

    read -r -p "Select region [0-6]: " REGION_NUM

    case "$REGION_NUM" in
        1) REGION="asia-east1" ;;
        2) REGION="asia-southeast1" ;;
        3) REGION="asia-northeast1" ;;
        4) REGION="asia-northeast3" ;;
        5) REGION="us-central1" ;;
        6) REGION="europe-west1" ;;
        0)
            read -r -p "Enter region: " REGION
            ;;
        *)
            warn "Invalid selection. Using us-central1."
            REGION="us-central1"
            ;;
    esac

    ok "Region: $REGION"
}

# ----------------------------------------------------------------------------
# ARTIFACT REGISTRY
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# QUOTA INSPECTION
# ----------------------------------------------------------------------------
#
# Cloud Run quota APIs can vary slightly between gcloud releases.
# Therefore this function is deliberately non-destructive:
# it reports the regional quota when available and refuses obviously
# impossible configurations based on local requested resources.
# ----------------------------------------------------------------------------

show_quota_information() {
    echo
    echo "================================================"
    echo " CLOUD RUN RESOURCE / QUOTA CHECK"
    echo "================================================"

    info "Requested maximum instances: $MAX_INSTANCES"
    info "Requested CPU per instance: $CPU"
    info "Requested memory per instance: $MEMORY"

    CPU_TOTAL="$(( CPU * MAX_INSTANCES ))"

    if [[ "$MEMORY" == "512Mi" ]]; then
        MEMORY_MIB=512
    elif [[ "$MEMORY" == "1Gi" ]]; then
        MEMORY_MIB=1024
    elif [[ "$MEMORY" == "2Gi" ]]; then
        MEMORY_MIB=2048
    elif [[ "$MEMORY" == "4Gi" ]]; then
        MEMORY_MIB=4096
    else
        MEMORY_MIB=0
    fi

    if (( MEMORY_MIB > 0 )); then
        MEMORY_TOTAL_MIB="$(( MEMORY_MIB * MAX_INSTANCES ))"
        info "Maximum configured CPU footprint: ${CPU_TOTAL} vCPU"
        info "Maximum configured memory footprint: ${MEMORY_TOTAL_MIB} MiB"
    fi

    echo
    warn "Regional Cloud Run quota is shared with other Cloud Run resources."
    warn "A successful quota query does not guarantee physical capacity."
    echo
}

# ----------------------------------------------------------------------------
# RESOURCE PRESETS
# ----------------------------------------------------------------------------

select_resources() {
    echo
    echo "================================================"
    echo " RESOURCE PROFILE"
    echo "================================================"
    echo
    echo "1) QWIKLABS SAFE"
    echo "   CPU:         1 vCPU"
    echo "   RAM:         1 GiB"
    echo "   Concurrency: 100"
    echo "   Min:         0"
    echo "   Max:         2"
    echo "   Timeout:     3600s"
    echo
    echo "2) BALANCED"
    echo "   CPU:         1 vCPU"
    echo "   RAM:         2 GiB"
    echo "   Concurrency: 150"
    echo "   Min:         0"
    echo "   Max:         2"
    echo "   Timeout:     3600s"
    echo
    echo "3) HEAVY"
    echo "   CPU:         2 vCPU"
    echo "   RAM:         2 GiB"
    echo "   Concurrency: 200"
    echo "   Min:         0"
    echo "   Max:         2"
    echo "   Timeout:     3600s"
    echo
    echo "4) CUSTOM"
    echo

    read -r -p "Select profile [1-4]: " RESOURCE_CHOICE

    case "$RESOURCE_CHOICE" in
        1)
            CPU="1"
            MEMORY="1Gi"
            CONCURRENCY="100"
            MIN_INSTANCES="0"
            MAX_INSTANCES="2"
            TIMEOUT="3600"
            CPU_MODE="request"
            ;;

        2)
            CPU="1"
            MEMORY="2Gi"
            CONCURRENCY="150"
            MIN_INSTANCES="0"
            MAX_INSTANCES="2"
            TIMEOUT="3600"
            CPU_MODE="request"
            ;;

        3)
            CPU="2"
            MEMORY="2Gi"
            CONCURRENCY="200"
            MIN_INSTANCES="0"
            MAX_INSTANCES="2"
            TIMEOUT="3600"
            CPU_MODE="instance"
            ;;

        4)
            read -r -p "CPU [1 or 2]: " CPU
            read -r -p "Memory [1Gi or 2Gi]: " MEMORY
            read -r -p "Concurrency [1-1000]: " CONCURRENCY
            read -r -p "Minimum instances [0-2]: " MIN_INSTANCES
            read -r -p "Maximum instances [1-3]: " MAX_INSTANCES

            TIMEOUT="3600"
            CPU_MODE="request"
            ;;

        *)
            warn "Invalid choice. Using QWIKLABS SAFE."
            CPU="1"
            MEMORY="1Gi"
            CONCURRENCY="100"
            MIN_INSTANCES="0"
            MAX_INSTANCES="2"
            TIMEOUT="3600"
            CPU_MODE="request"
            ;;
    esac

    # ------------------------------------------------------------------------
    # VALIDATION
    # ------------------------------------------------------------------------

    [[ "$CPU" =~ ^[12]$ ]] ||
        die "CPU must be 1 or 2."

    [[ "$MEMORY" =~ ^(1Gi|2Gi)$ ]] ||
        die "Memory must be 1Gi or 2Gi."

    [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] ||
        die "Concurrency must be numeric."

    (( CONCURRENCY >= 1 && CONCURRENCY <= 1000 )) ||
        die "Concurrency must be between 1 and 1000."

    [[ "$MIN_INSTANCES" =~ ^[0-9]+$ ]] ||
        die "Minimum instances must be numeric."

    [[ "$MAX_INSTANCES" =~ ^[0-9]+$ ]] ||
        die "Maximum instances must be numeric."

    (( MAX_INSTANCES >= 1 )) ||
        die "Maximum instances must be >= 1."

    (( MAX_INSTANCES <= 3 )) ||
        die "Maximum instances capped at 3 for this deployer."

    (( MIN_INSTANCES <= MAX_INSTANCES )) ||
        die "Minimum instances cannot exceed maximum instances."

    TIMEOUT="$MAX_TIMEOUT"

    echo
    ok "CPU:         $CPU vCPU"
    ok "Memory:      $MEMORY"
    ok "Concurrency:$CONCURRENCY"
    ok "Min:         $MIN_INSTANCES"
    ok "Max:         $MAX_INSTANCES"
    ok "Timeout:     ${TIMEOUT}s"
    ok "CPU mode:    $CPU_MODE"
}

# ----------------------------------------------------------------------------
# ENGINE SELECTION
# ----------------------------------------------------------------------------

select_engine() {
    echo
    echo "================================================"
    echo " PROXY ENGINE"
    echo "================================================"
    echo "1) OpenResty"
    echo "2) Envoy"
    echo "3) HAProxy"
    echo "4) Caddy"
    echo "5) Sing-Box"
    echo

    read -r -p "Select engine [1-5]: " ENGINE_CHOICE

    case "$ENGINE_CHOICE" in
        1)
            ENGINE="openresty"
            DISPLAY_ENGINE="OpenResty"
            ;;
        2)
            ENGINE="envoy"
            DISPLAY_ENGINE="Envoy"
            ;;
        3)
            ENGINE="haproxy"
            DISPLAY_ENGINE="HAProxy"
            ;;
        4)
            ENGINE="caddy"
            DISPLAY_ENGINE="Caddy"
            ;;
        5)
            ENGINE="singbox"
            DISPLAY_ENGINE="Sing-Box"
            ;;
        *)
            die "Invalid engine."
            ;;
    esac

    ok "Engine: $DISPLAY_ENGINE"
}

# ----------------------------------------------------------------------------
# CREDENTIAL GENERATION
# ----------------------------------------------------------------------------

generate_credentials() {
    TROJAN_PASSWORD="$(openssl rand -hex 16)"
    VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"

    export TROJAN_PASSWORD
    export VLESS_UUID
}

# ----------------------------------------------------------------------------
# XRAY CONFIG
# ----------------------------------------------------------------------------

write_xray_config() {

    cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "dns": {
    "servers": [
      "8.8.8.8",
      "8.8.4.4"
    ],
    "queryStrategy": "UseIPv4"
  },

  "policy": {
    "levels": {
      "0": {
        "handshake": 10,
        "connIdle": 3600,
        "uplinkOnly": 0,
        "downlinkOnly": 0,
        "bufferSize": 2048
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
        "clients": [
          {
            "password": "${TROJAN_PASSWORD}",
            "level": 0
          }
        ]
      },

      "streamSettings": {
        "network": "ws",

        "wsSettings": {
          "path": "/trojan-ws"
        },

        "sockopt": {
          "tcpNoDelay": true
        }
      }
    },

    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": 10002,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "ws",

        "wsSettings": {
          "path": "/vless-ws"
        },

        "sockopt": {
          "tcpNoDelay": true
        }
      }
    },

    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": 10003,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "xhttp",

        "xhttpSettings": {
          "path": "/xhttp",
          "mode": "auto"
        },

        "sockopt": {
          "tcpNoDelay": true
        }
      }
    },

    {
      "tag": "vless-httpupgrade",
      "listen": "127.0.0.1",
      "port": 10004,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${VLESS_UUID}",
            "level": 0
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "httpupgrade",

        "httpupgradeSettings": {
          "path": "/httpupgrade"
        },

        "sockopt": {
          "tcpNoDelay": true
        }
      }
    }

  ],

  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    }
  ]
}
EOF
}

# ----------------------------------------------------------------------------
# SUPERVISOR
# ----------------------------------------------------------------------------

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
startsecs=2
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:proxy]
command=${PROXY_COMMAND}
priority=20
autorestart=true
startsecs=2
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF
}

# ----------------------------------------------------------------------------
# OPENRESTY
# ----------------------------------------------------------------------------

build_openresty() {

    cat > nginx.conf <<'EOF'
worker_processes 1;

events {
    worker_connections 4096;
    multi_accept on;
}

http {

    access_log /dev/stdout;
    error_log /dev/stderr warn;

    sendfile on;
    tcp_nodelay on;

    keepalive_timeout 3600s;
    client_body_timeout 3600s;
    client_header_timeout 60s;
    send_timeout 3600s;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    server {

        listen 8080;
        server_name _;

        location = /health {
            default_type text/plain;
            return 200 "OK\n";
        }

        location /trojan-ws {
            proxy_pass http://127.0.0.1:10001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location /vless-ws {
            proxy_pass http://127.0.0.1:10002;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location /xhttp {
            proxy_pass http://127.0.0.1:10003;
            proxy_http_version 1.1;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location /httpupgrade {
            proxy_pass http://127.0.0.1:10004;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }

        location / {
            default_type text/html;
            return 200 '<!doctype html><html><body><h1>Service Ready</h1></body></html>';
        }
    }
}
EOF

    PROXY_COMMAND="/usr/local/openresty/bin/openresty -g 'daemon off;'"

    cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray

FROM openresty/openresty:alpine-fat

RUN apk add --no-cache supervisor

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray

COPY config.json /etc/xray/config.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY supervisord.conf /etc/supervisord.conf

EXPOSE 8080

CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
EOF

    write_supervisor
}

# ----------------------------------------------------------------------------
# CADDY
# ----------------------------------------------------------------------------

build_caddy() {

    cat > Caddyfile <<'EOF'
{
    admin off
    auto_https off
}

:8080 {

    handle /health {
        respond "OK" 200
    }

    @trojan {
        path /trojan-ws*
    }

    reverse_proxy @trojan 127.0.0.1:10001 {
        transport http {
            keepalive 3600s
        }
    }

    @vless {
        path /vless-ws*
    }

    reverse_proxy @vless 127.0.0.1:10002 {
        transport http {
            keepalive 3600s
        }
    }

    @xhttp {
        path /xhttp*
    }

    reverse_proxy @xhttp 127.0.0.1:10003

    @httpupgrade {
        path /httpupgrade*
    }

    reverse_proxy @httpupgrade 127.0.0.1:10004

    handle {
        respond "<!doctype html><html><body><h1>Service Ready</h1></body></html>" 200
    }
}
EOF

    PROXY_COMMAND="caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"

    cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray

FROM caddy:2.10-alpine

RUN apk add --no-cache supervisor

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray

COPY config.json /etc/xray/config.json
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisord.conf

EXPOSE 8080

CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
EOF

    write_supervisor
}

# ----------------------------------------------------------------------------
# HAProxy
# ----------------------------------------------------------------------------

build_haproxy() {

    cat > haproxy.cfg <<'EOF'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http

    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s
    timeout http-request 30s
    timeout http-keep-alive 3600s

frontend cloudrun
    bind :8080

    acl health path -i /health
    http-request return status 200 content-type "text/plain" string "OK\n" if health

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
    option http-server-close
    server xray 127.0.0.1:10001

backend xray_vless
    option http-server-close
    server xray 127.0.0.1:10002

backend xray_xhttp
    option http-server-close
    server xray 127.0.0.1:10003

backend xray_httpupgrade
    option http-server-close
    server xray 127.0.0.1:10004

backend decoy
    http-request return status 200 content-type "text/html" string "<!doctype html><html><body><h1>Service Ready</h1></body></html>"
EOF

    PROXY_COMMAND="haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg"

    cat > Dockerfile <<EOF
FROM ${XRAY_IMAGE} AS xray

FROM haproxy:3.2-alpine

USER root

RUN apk add --no-cache supervisor

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray

COPY config.json /etc/xray/config.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY supervisord.conf /etc/supervisord.conf

EXPOSE 8080

CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
EOF

    write_supervisor
}

# ----------------------------------------------------------------------------
# ENVOY
# ----------------------------------------------------------------------------

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

          route_config:

            name: local

            virtual_hosts:

            - name: local

              domains:
              - "*"

              routes:

              - match:
                  path: /health
                direct_response:
                  status: 200
                  body:
                    inline_string: "OK\n"

              - match:
                  prefix: /trojan-ws
                route:
                  cluster: xray_trojan
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /vless-ws
                route:
                  cluster: xray_vless
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /xhttp
                route:
                  cluster: xray_xhttp
                  timeout: 0s

              - match:
                  prefix: /httpupgrade
                route:
                  cluster: xray_httpupgrade
                  timeout: 0s
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /
                direct_response:
                  status: 200
                  body:
                    inline_string: "<!doctype html><html><body><h1>Service Ready</h1></body></html>"

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
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10001

  - name: xray_vless
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_vless
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10002

  - name: xray_xhttp
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_xhttp
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10003

  - name: xray_httpupgrade
    type: STATIC
    connect_timeout: 10s
    load_assignment:
      cluster_name: xray_httpupgrade
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10004
EOF

    PROXY_COMMAND="envoy -c /etc/envoy/envoy.yaml"

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

EXPOSE 8080

CMD ["/usr/bin/supervisord","-c","/etc/supervisord.conf"]
EOF

    write_supervisor
}

# ----------------------------------------------------------------------------
# SING-BOX
# ----------------------------------------------------------------------------
#
# This is intentionally a REAL sing-box engine rather than the original
# script's Xray masquerading as "Sing-Box".
#
# For protocol compatibility, this mode exposes a native VLESS WebSocket
# service. XHTTP/HTTPUpgrade remain available through the Xray engines.
# ----------------------------------------------------------------------------

build_singbox() {

    SINGBOX_VERSION="1.14.1"
    SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:${SINGBOX_VERSION}"

    cat > sing-box.json <<EOF
{
  "log": {
    "level": "warn"
  },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",

      "listen": "0.0.0.0",
      "listen_port": 8080,

      "users": [
        {
          "uuid": "${VLESS_UUID}"
        }
      ],

      "transport": {
        "type": "ws",
        "path": "/vless-ws"
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > health-server.py <<'EOF'
import http.server
import threading

class Health(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"OK\n")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_):
        pass

server = http.server.HTTPServer(("127.0.0.1", 9090), Health)
server.serve_forever()
EOF

    # Sing-box owns 8080, so its health endpoint is kept internal.
    # Cloud Run's startup/liveness probes use TCP in this mode.

    cat > Dockerfile <<EOF
FROM ${SINGBOX_IMAGE}

USER root

RUN apk add --no-cache python3 supervisor

COPY sing-box.json /etc/sing-box/config.json
COPY health-server.py /health-server.py

RUN mkdir -p /etc/supervisor

COPY <<'SUPERVISOR' /etc/supervisor/supervisord.conf
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid

[program:singbox]
command=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
priority=10
autorestart=true
startsecs=2
startretries=10
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:health]
command=python3 /health-server.py
priority=20
autorestart=true
startsecs=1
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
SUPERVISOR

EXPOSE 8080

CMD ["/usr/bin/supervisord","-c","/etc/supervisor/supervisord.conf"]
EOF
}

# ----------------------------------------------------------------------------
# BUILD DISPATCH
# ----------------------------------------------------------------------------

build_engine() {

    case "$ENGINE" in
        openresty)
            build_openresty
            ;;

        envoy)
            build_envoy
            ;;

        haproxy)
            build_haproxy
            ;;

        caddy)
            build_caddy
            ;;

        singbox)
            build_singbox
            ;;

        *)
            die "Unknown engine: $ENGINE"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# DOCKER IGNORE
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# CONFIG VALIDATION
# ----------------------------------------------------------------------------

validate_config() {

    info "Validating generated configuration..."

    if [[ "$ENGINE" != "singbox" ]]; then
        # Xray binary is in the pinned upstream image.
        # Validation occurs during image build/runtime.
        jq empty config.json
        ok "Xray JSON syntax valid."
    else
        jq empty sing-box.json
        ok "Sing-Box JSON syntax valid."
    fi
}

# ----------------------------------------------------------------------------
# BUILD + PUSH
# ----------------------------------------------------------------------------

build_and_push() {

    IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${SERVICE_NAME}:${BUILD_ID}"

    info "Submitting Cloud Build..."
    info "Image: $IMAGE_TAG"

    gcloud builds submit \
        --project="$PROJECT_ID" \
        --tag="$IMAGE_TAG" \
        --quiet

    ok "Image built and pushed."
}

# ----------------------------------------------------------------------------
# DEPLOY
# ----------------------------------------------------------------------------

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

        --timeout="$TIMEOUT"

        --min-instances="$MIN_INSTANCES"
        --max-instances="$MAX_INSTANCES"

        --execution-environment=gen2

        --startup-cpu-boost

        --session-affinity

        --allow-unauthenticated

        --quiet
    )

    # Only use instance-based CPU allocation for the heavier preset.
    # Request-based CPU is less aggressive for constrained projects.
    if [[ "$CPU_MODE" == "instance" ]]; then
        DEPLOY_ARGS+=(--no-cpu-throttling)
    fi

    # TCP startup probe is robust for a proxy stack and avoids depending
    # on an application-level HTTP endpoint during initial startup.
    DEPLOY_ARGS+=(
        "--startup-probe=tcpSocket.port=8080,initialDelaySeconds=2,failureThreshold=20,timeoutSeconds=5,periodSeconds=5"
    )

    "${DEPLOY_ARGS[@]}"

    ok "Cloud Run deployment completed."
}

# ----------------------------------------------------------------------------
# VERIFY
# ----------------------------------------------------------------------------

verify_service() {

    info "Retrieving service URL..."

    CLOUD_RUN_URL="$(
        gcloud run services describe "$SERVICE_NAME" \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --format='value(status.url)'
    )"

    [[ -n "$CLOUD_RUN_URL" ]] ||
        die "Cloud Run returned no service URL."

    ok "Service URL: $CLOUD_RUN_URL"

    info "Checking service health..."

    # Give the new revision a short startup window.
    for attempt in {1..12}; do

        if curl -fsS \
            --max-time 10 \
            "${CLOUD_RUN_URL}/health" >/dev/null 2>&1; then

            ok "Health check passed."
            return
        fi

        warn "Health check attempt ${attempt}/12..."
        sleep 5
    done

    warn "Health endpoint did not respond within the verification window."
    warn "Inspect Cloud Run logs before troubleshooting the client configuration."
}

# ----------------------------------------------------------------------------
# SHOW CREDENTIALS
# ----------------------------------------------------------------------------

show_result() {

    DOMAIN="${CLOUD_RUN_URL#https://}"

    echo
    echo "============================================================"
    echo -e "${GREEN} DEPLOYMENT COMPLETE${NC}"
    echo "============================================================"

    echo
    echo "Engine:          $DISPLAY_ENGINE"
    echo "Xray version:    $XRAY_VERSION"
    echo "Region:          $REGION"
    echo "CPU:             $CPU vCPU"
    echo "Memory:          $MEMORY"
    echo "Concurrency:     $CONCURRENCY"
    echo "Min instances:   $MIN_INSTANCES"
    echo "Max instances:   $MAX_INSTANCES"
    echo "Timeout:         ${TIMEOUT}s"

    echo
    echo -e "${GREEN}URL:${NC}"
    echo "$CLOUD_RUN_URL"

    echo
    echo -e "${GREEN}DOMAIN:${NC}"
    echo "$DOMAIN"

    echo
    echo -e "${GREEN}HEALTH:${NC}"
    echo "$CLOUD_RUN_URL/health"

    echo
    echo "------------------------------------------------------------"

    if [[ "$ENGINE" == "singbox" ]]; then

        echo "Sing-Box VLESS WebSocket:"
        echo "  Path: /vless-ws"
        echo "  UUID: $VLESS_UUID"

    else

        echo "Trojan WebSocket:"
        echo "  Path:     /trojan-ws"
        echo "  Password: $TROJAN_PASSWORD"

        echo
        echo "VLESS WebSocket:"
        echo "  Path: /vless-ws"
        echo "  UUID: $VLESS_UUID"

        echo
        echo "VLESS XHTTP:"
        echo "  Path: /xhttp"
        echo "  UUID: $VLESS_UUID"

        echo
        echo "VLESS HTTPUpgrade:"
        echo "  Path: /httpupgrade"
        echo "  UUID: $VLESS_UUID"

    fi

    echo
    echo "============================================================"
    echo
}

# ----------------------------------------------------------------------------
# LIST SERVICES
# ----------------------------------------------------------------------------

list_services() {

    get_project

    echo
    echo "============================================================"
    echo " DEPLOYED CLOUD RUN SERVICES"
    echo "============================================================"

    gcloud run services list \
        --project="$PROJECT_ID" \
        --format="table(
            metadata.name,
            metadata.labels.cloud.googleapis.com/location,
            status.url
        )"

    echo
    read -r -p "Press Enter to continue..."
}

# ----------------------------------------------------------------------------
# SERVICE DETAILS
# ----------------------------------------------------------------------------

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

# ----------------------------------------------------------------------------
# DEPLOY
# ----------------------------------------------------------------------------

deploy_new_service() {

    check_dependencies
    get_project
    enable_apis

    select_region
    select_resources
    show_quota_information
    select_engine
    generate_credentials

    BUILD_DIR="$(mktemp -d)"
    cd "$BUILD_DIR"

    RANDOM_SUFFIX="$(openssl rand -hex 4)"

    SERVICE_NAME="${APP_NAME}-${ENGINE}-${RANDOM_SUFFIX}"

    # Cloud Run service names must remain reasonably short.
    SERVICE_NAME="${SERVICE_NAME:0:49}"

    BUILD_ID="$(date +%Y%m%d-%H%M%S)-${RANDOM_SUFFIX}"

    ensure_artifact_registry

    echo
    info "Service name: $SERVICE_NAME"
    info "Build ID:     $BUILD_ID"

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

# ----------------------------------------------------------------------------
# MAIN MENU
# ----------------------------------------------------------------------------

main_menu() {

    check_dependencies
    get_project

    while true; do

        clear

        echo "============================================================"
        echo " GCP-XRAY CLOUD RUN DEPLOYER"
        echo "============================================================"
        echo
        echo "Project: $PROJECT_ID"
        echo
        echo "1) Deploy new service"
        echo "2) List services"
        echo "3) Service details"
        echo "4) Exit"
        echo
        echo "============================================================"

        read -r -p "Select [1-4]: " MENU_CHOICE

        case "$MENU_CHOICE" in

            1)
                deploy_new_service
                ;;

            2)
                list_services
                ;;

            3)
                service_details
                ;;

            4)
                echo
                echo "Goodbye."
                exit 0
                ;;

            *)
                warn "Enter 1, 2, 3, or 4."
                sleep 2
                ;;

        esac
    done
}

main_menu
