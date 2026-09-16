#!/bin/bash
set -euo pipefail

# =================================================================
# 🚀 GCP-XRAY DEPLOYER | VLESS-WS + VLESS-XHTTP ONLY
# ✅ ENGINES: OPENRESTY / ENVOY / HAPROXY / CADDY / SING-BOX
# ✅ PROTOCOLS: VLESS-WS, VLESS-XHTTP
# ✅ FEATURES: Supervisord, Anti-DDoS, Auto Log Cleaner, Mux Tuned
# ✅ FIXED: Path mismatches, config consistency, Sing-Box xhttp support
# =================================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ==============================================
# AUTO INSTALL JQ IF MISSING
# ==============================================
if ! command -v jq &> /dev/null; then
  echo -e "\n${YELLOW}⚠️ Installing required tool: jq...${NC}"
  sudo apt update -qq && sudo apt install -y -qq jq || {
    echo -e "${RED}❌ Failed to install jq!${NC}"
    exit 1
  }
  echo -e "${GREEN}✅ jq installed successfully!${NC}"
fi

# ==============================================
# LIST SERVICES
# ==============================================
list_deployed_services() {
  echo -e "\n======================================"
  echo -e "${CYAN}📋 ALL DEPLOYED GCP-XRAY SERVICES${NC}"
  echo -e "======================================"
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  echo "Project: $PROJECT_ID"
  echo ""

  declare -A REGION_NAMES=(
    ["us-central1"]="Iowa, United States 🇺🇸"
    ["us-east1"]="South Carolina, United States 🇺🇸"
    ["us-east4"]="N. Virginia, United States 🇺🇸"
    ["us-west1"]="Oregon, United States 🇺🇸"
    ["asia-east1"]="Taiwan 🇹🇼"
    ["asia-southeast1"]="Singapore 🇸🇬"
    ["asia-northeast1"]="Tokyo, Japan 🇯🇵"
    ["asia-northeast3"]="Seoul, South Korea 🇰🇷"
    ["europe-west1"]="Belgium 🇧🇪"
    ["europe-west4"]="Netherlands 🇳🇱"
    ["europe-west9"]="Paris, France 🇫🇷"
    ["asia-south1"]="Mumbai, India 🇮🇳"
  )

  SERVICES=$(gcloud run services list \
    --format="value(metadata.name, status.url, region, metadata.creationTimestamp.date(%Y-%m-%d))" \
    --project="$PROJECT_ID" 2>/dev/null)

  if [ -z "$SERVICES" ]; then
    echo -e "${RED}❌ No services found.${NC}"
  else
    local COUNT=1
    while IFS=$'\t' read -r NAME URL REGION CREATED; do
      [ -z "$NAME" ] && continue
      FULL_REGION="${REGION_NAMES[$REGION]:-$REGION}"

      DETAILS=$(gcloud run services describe "$NAME" --region "$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null || true)
      if [ -z "$DETAILS" ]; then
        echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
        echo "🔹 Name:         $NAME"
        echo "🔹 URL:          $URL"
        echo "🔹 Region:       $REGION → $FULL_REGION"
        echo "🔹 Created:      $CREATED"
        echo ""
        ((COUNT++))
        continue
      fi

      MEMORY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // "1Gi"')
      CPU=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.cpu // "1"')
      BILLING=$(echo "$DETAILS" | jq -r '.spec.template.spec.billingMode // "Instance Based"' | sed 's/_/ /g;s/^./\U&/')
      MIN_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.minInstances // "0"')
      MAX_INST=$(echo "$DETAILS" | jq -r '.spec.template.spec.maxInstances // "1"')
      CONCURRENCY=$(echo "$DETAILS" | jq -r '.spec.template.spec.containerConcurrency // "300"')
      TIMEOUT=$(echo "$DETAILS" | jq -r '.spec.template.spec.timeoutSeconds // "300"')

      echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
      echo "🔹 Name:         $NAME"
      echo "🔹 URL:          $URL"
      echo "🔹 Region:       $REGION → $FULL_REGION"
      echo "🔹 Created:      $CREATED"
      echo "🔹 Resources:    $MEMORY RAM | $CPU vCPU"
      echo "🔹 Billing:      $BILLING"
      echo "🔹 Instances:    Min $MIN_INST / Max $MAX_INST"
      echo "🔹 Connections:  Max $CONCURRENCY"
      echo "🔹 Timeout:      ${TIMEOUT}s"
      echo ""
      ((COUNT++))
    done <<< "$SERVICES"
  fi
  
  echo -e "\n======================================"
  read -p "Press [Enter] to return..."
}

# ==============================================
# REGION SELECTOR
# ==============================================
select_region() {
  echo -e "\n=== GCP CLOUD RUN REGION SELECTION ==="
  echo "--- North America ---"
  echo "1) us-central1      (Iowa, US 🇺🇸)"
  echo "2) us-east1         (South Carolina, US 🇺🇸)"
  echo "3) us-east4         (N. Virginia, US 🇺🇸)"
  echo "4) us-west1         (Oregon, US 🇺🇸)"
  echo ""
  echo "--- Asia Pacific ---"
  echo "5) asia-east1       (Taiwan 🇹🇼 — RECOMMENDED!)"
  echo "6) asia-southeast1  (Singapore 🇸🇬)"
  echo "7) asia-northeast1   (Tokyo, Japan 🇯🇵)"
  echo "8) asia-northeast3   (Seoul, South Korea 🇰🇷)"
  echo "9) asia-south1      (Mumbai, India 🇮🇳)"
  echo ""
  echo "--- Europe ---"
  echo "10) europe-west1     (Belgium 🇧🇪)"
  echo "11) europe-west4    (Netherlands 🇳🇱)"
  echo "12) europe-west9    (Paris, France 🇫🇷)"
  echo ""
  echo "0) Enter custom region code"
  echo ""

  read -p "Enter region number: " REGION_NUM

  case $REGION_NUM in
    1) REGION="us-central1" ;;
    2) REGION="us-east1" ;;
    3) REGION="us-east4" ;;
    4) REGION="us-west1" ;;
    5) REGION="asia-east1" ;;
    6) REGION="asia-southeast1" ;;
    7) REGION="asia-northeast1" ;;
    8) REGION="asia-northeast3" ;;
    9) REGION="asia-south1" ;;
    10) REGION="europe-west1" ;;
    11) REGION="europe-west4" ;;
    12) REGION="europe-west9" ;;
    0) read -p "Type full region code: " REGION ;;
    *) echo -e "${YELLOW}⚠️ Invalid! Using us-central1${NC}"; REGION="us-central1" ;;
  esac

  echo -e "${GREEN}✅ Selected Region:${NC} $REGION"
}

# ==============================================
# DEPLOYMENT FUNCTION
# ==============================================
deploy_new_service() {
  select_region

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
      echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
      read -p "Press [Enter] to return..."
      return
  fi

  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}          CHOOSE PROXY ENGINE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo "1) OpenResty          - [Anti-DDoS + Nginx Core]"
  echo "2) Envoy Proxy        - [High Throughput / gRPC/HTTP2]"
  echo "3) HAProxy            - [Ultra Low Latency / Connection Pooling]"
  echo "4) Caddy Proxy        - [Modern / Native HTTPUpgrade Support]"
  echo "5) Sing-Box Engine    - [Lightweight / Direct Core Integration]"
  while true; do
      read -p "Select Engine [1-5]: " ENGINE_CHOICE
      case $ENGINE_CHOICE in
          1) ENGINE="openresty"; DISPLAY_ENGINE="OpenResty"; echo -e "${GREEN}✅ Selected: OpenResty${NC}"; break ;;
          2) ENGINE="envoy"; DISPLAY_ENGINE="Envoy Proxy"; echo -e "${GREEN}✅ Selected: Envoy Proxy${NC}"; break ;;
          3) ENGINE="haproxy"; DISPLAY_ENGINE="HAProxy"; echo -e "${GREEN}✅ Selected: HAProxy${NC}"; break ;;
          4) ENGINE="caddy"; DISPLAY_ENGINE="Caddy Proxy"; echo -e "${GREEN}✅ Selected: Caddy Proxy${NC}"; break ;;
          5) ENGINE="singbox"; DISPLAY_ENGINE="Sing-Box Engine"; echo -e "${GREEN}✅ Selected: Sing-Box Engine${NC}"; break ;;
          *) echo -e "${RED}Enter 1, 2, 3, 4, or 5 only${NC}" ;;
      esac
  done

  RAND=$(openssl rand -hex 3)
  CLOUD_RUN_SERVICE_NAME="gcp-xray-${ENGINE}-$RAND"

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}      RESOURCE CONFIG MODE (STABLE TUNED)${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}1) AUTO PRESETS  |  Safe & Stable (Qwiklabs Safe)${NC}"
  echo -e "${YELLOW}2) MANUAL SETUP  |  Custom Config${NC}"
  while true; do
      read -p "Select Mode [1-2]: " RES_MODE
      case $RES_MODE in
          1)
              echo -e "\n${CYAN}--- AUTO PRESETS ---${NC}"
              echo "1) Qwiklabs Safe: 1Gi RAM + 1 vCPU (Min: 0, Max: 2, Concurrency: 500) ✅"
              echo "2) Balanced:      2Gi RAM + 2 vCPU (Min: 0, Max: 3, Concurrency: 800)"
              echo "3) High Performance: 4Gi RAM + 2 vCPU (Min: 1, Max: 3, Concurrency: 1000)"
              read -p "Choose preset [1-3]: " AUTO_CHOICE
              
              BILLING_MODE="instance"
              BILLING_FLAG="--no-cpu-throttling"

              case $AUTO_CHOICE in
                  1) 
                    MEMORY="1Gi"; CPU="1"
                    MIN_INST=0; MAX_INST=2; CONCURRENCY=500; TIMEOUT=3600
                    ;;
                  2) 
                    MEMORY="2Gi"; CPU="2"
                    MIN_INST=0; MAX_INST=3; CONCURRENCY=800; TIMEOUT=3600
                    ;;
                  3) 
                    MEMORY="4Gi"; CPU="2"
                    MIN_INST=1; MAX_INST=3; CONCURRENCY=1000; TIMEOUT=3600
                    ;;
                  *) 
                    MEMORY="1Gi"; CPU="1"
                    MIN_INST=0; MAX_INST=2; CONCURRENCY=500; TIMEOUT=3600
                    echo -e "${YELLOW}Using Qwiklabs Safe preset${NC}"
                    ;;
              esac
              echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY${NC}"
              break
              ;;
          2)
              BILLING_MODE="instance"
              BILLING_FLAG="--no-cpu-throttling"

              echo -e "\n${YELLOW}--- MANUAL SETUP ---${NC}"
              echo "Select Memory:"
              echo "1) 512Mi   2) 1Gi   3) 2Gi   4) 4Gi"
              read -p "Select Memory [1-4]: " MEM
              case $MEM in
                  1) MEMORY="512Mi" ;;
                  2) MEMORY="1Gi" ;;
                  3) MEMORY="2Gi" ;;
                  4) MEMORY="4Gi" ;;
                  *) MEMORY="1Gi" ;;
              esac

              echo -e "\nSelect vCPU:"
              echo "1) 1 vCPU   2) 2 vCPU"
              read -p "Select vCPU [1-2]: " CPU_SEL
              case $CPU_SEL in
                  1) CPU="1" ;;
                  2) CPU="2" ;;
                  *) CPU="1" ;;
              esac

              MIN_INST=0
              MAX_INST=2
              CONCURRENCY=1000
              TIMEOUT=3600

              echo -e "${GREEN}✅ Config Set: $MEMORY RAM | $CPU vCPU | Max Inst: $MAX_INST${NC}"
              break
              ;;
          *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
      esac
  done

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cd "$BUILD_DIR" || exit 1

  clear
  echo ""
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🚀 GCP-XRAY DEPLOYER | VLESS-WS + VLESS-XHTTP${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ Project:${NC} $PROJECT_ID"
  echo -e "${GREEN}✅ Region:${NC} $REGION"
  echo -e "${GREEN}✅ Service Name:${NC} $CLOUD_RUN_SERVICE_NAME"
  echo -e "${GREEN}✅ Engine:${NC} $DISPLAY_ENGINE"
  echo ""

  # ==============================================
  # XRAY CONFIG — VLESS-WS + VLESS-XHTTP ONLY
  # ==============================================
  cat > config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4"],
    "strategy": "UseIPv4"
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
      "tag": "vless-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}],
        "decryption": "none"
      },
      "sniffing": { "enabled": false },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-ws" },
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 300 }
      }
    },
    {
      "tag": "vless-xhttp",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}],
        "decryption": "none"
      },
      "sniffing": { "enabled": false },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "/vless-xhttp", "mode": "auto" },
        "sockopt": { "tcpNoDelay": true, "tcpKeepAliveIdle": 300 }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }
  ]
}
EOF

  # ==============================================
  # LOG CLEANER DAEMON
  # ==============================================
  cat > log_cleaner.sh <<'EOF'
#!/bin/sh
while true; do
  sleep 300
  rm -rf /tmp/* /var/log/*.log /var/log/nginx/* /var/log/supervisor/* 2>/dev/null || true
done
EOF
  chmod +x log_cleaner.sh

  DECOY_HTML='<!DOCTYPE html><html><head><title>System Status</title><style>body{font-family:sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;text-align:center;}h1{color:#58a6ff;font-size:24px;}p{color:#8b949e;}</style></head><body><div><h1>Welcome to my Cloud Application Gateway.</h1><p>Everything is operational.</p></div></body></html>'

  # ==============================================
  # 1. OPENRESTY ENGINE
  # ==============================================
  if [ "$ENGINE" = "openresty" ]; then
    cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 65535;
events { worker_connections 8192; use epoll; multi_accept on; }
http {
  include mime.types;
  default_type application/octet-stream;
  sendfile on; tcp_nodelay on; tcp_nopush on;
  keepalive_timeout 3600; keepalive_requests 100000;
  client_max_body_size 0;
  proxy_buffering off; proxy_request_buffering off;
  proxy_http_version 1.1;

  limit_req_zone \$binary_remote_addr zone=ddos_limit:10m rate=100r/s;
  limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

  server {
    listen 8080;
    server_name _;
    
    limit_req zone=ddos_limit burst=200 nodelay;
    limit_conn conn_limit 100;

    location /health { return 200 "OK\n"; add_header Content-Type text/plain; }
    
    location /vless-ws {
      proxy_pass http://127.0.0.1:10001;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
    
    location /vless-xhttp {
      proxy_pass http://127.0.0.1:10002;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    }
    
    location / {
      default_type text/html;
      return 200 '$DECOY_HTML';
    }
  }
}
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
priority=1

[program:openresty]
command=/usr/local/openresty/bin/openresty -g "daemon off;"
autorestart=true
priority=2

[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
priority=3
EOF

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && chmod +x xray
FROM openresty/openresty:alpine-fat
RUN apk add --no-cache supervisor
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/xray /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  # ==============================================
  # 2. ENVOY PROXY ENGINE
  # ==============================================
  elif [ "$ENGINE" = "envoy" ]; then
    cat > envoy.yaml <<EOF
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: 8080 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          codec_type: AUTO
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "/vless-ws" }
                route: { cluster: vless_ws_cluster, timeout: 3600s, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/vless-xhttp" }
                route: { cluster: vless_xhttp_cluster, timeout: 3600s }
              - match: { prefix: "/" }
                direct_response: { status: 200, body: { inline_string: '$DECOY_HTML' } }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: vless_ws_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_ws_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10001 } } } }] }]
  - name: vless_xhttp_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_xhttp_cluster
      endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10002 } } } }] }]
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
priority=1

[program:envoy]
command=envoy -c /etc/envoy.yaml
autorestart=true
priority=2

[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
priority=3
EOF

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && chmod +x xray
FROM envoyproxy/envoy:v1.30-latest
USER root
RUN apt-get update && apt-get install -y supervisor && rm -rf /var/lib/apt/lists/*
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy.yaml
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/xray /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  # ==============================================
  # 3. HAPROXY ENGINE
  # ==============================================
  elif [ "$ENGINE" = "haproxy" ]; then
    cat > haproxy.cfg <<EOF
global
    log stdout format raw local0
    maxconn 20000
defaults
    log global
    mode http
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
frontend main
    bind *:8080
    acl is_health path /health
    acl is_vless_ws path_beg /vless-ws
    acl is_vless_xhttp path_beg /vless-xhttp
    use_backend health_backend if is_health
    use_backend vless_ws_backend if is_vless_ws
    use_backend vless_xhttp_backend if is_vless_xhttp
    default_backend default_backend
backend health_backend
    http-request return status 200 content-type "text/plain" string "OK\n"
backend default_backend
    http-request return status 200 content-type "text/html" string '$DECOY_HTML'
backend vless_ws_backend
    server xray_ws 127.0.0.1:10001
backend vless_xhttp_backend
    server xray_xhttp 127.0.0.1:10002
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
priority=1

[program:haproxy]
command=haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db
autorestart=true
priority=2

[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
priority=3
EOF

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && chmod +x xray
FROM haproxy:2.8-alpine
USER root
RUN apk add --no-cache supervisor
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/xray /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  # ==============================================
  # 4. CADDY PROXY ENGINE
  # ==============================================
  elif [ "$ENGINE" = "caddy" ]; then
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
    servers {
        max_header_size 1MB
    }
}
:8080 {
    handle /health {
        respond "OK\n" 200
    }
    
    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
        }
    }
    
    handle /vless-xhttp* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }
    
    handle {
        header Content-Type text/html
        respond \`$DECOY_HTML\` 200
    }
}
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
priority=1

[program:caddy]
command=caddy run --config /etc/Caddyfile --adapter caddyfile
autorestart=true
priority=2

[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
priority=3
EOF

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && chmod +x xray
FROM caddy:2.7-alpine
RUN apk add --no-cache supervisor
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY Caddyfile /etc/Caddyfile
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/xray /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  # ==============================================
  # 5. SING-BOX ENGINE
  # ==============================================
  elif [ "$ENGINE" = "singbox" ]; then
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
}
:8080 {
    handle /health {
        respond "OK\n" 200
    }
    
    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
        }
    }
    
    handle /vless-xhttp* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
        }
    }
    
    handle {
        header Content-Type text/html
        respond \`$DECOY_HTML\` 200
    }
}
EOF

    cat > singbox.json <<'EOF'
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [{ "uuid": "a1b2c3d4-5678-40ef-98ab-cdef01234567" }],
      "transport": {
        "type": "ws",
        "path": "/vless-ws"
      }
    },
    {
      "type": "vless",
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "listen_port": 10002,
      "users": [{ "uuid": "a1b2c3d4-5678-40ef-98ab-cdef01234567" }],
      "transport": {
        "type": "xhttp",
        "path": "/vless-xhttp",
        "mode": "auto"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
logfile_maxbytes=0

[program:singbox]
command=/usr/local/bin/sing-box run -c /etc/singbox.json
autorestart=true
priority=1

[program:caddy]
command=caddy run --config /etc/Caddyfile --adapter caddyfile
autorestart=true
priority=2

[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
priority=3
EOF

    cat > Dockerfile <<'EOF'
FROM ghcr.io/sagernet/sing-box:latest AS singbox-builder
FROM caddy:2.7-alpine
RUN apk add --no-cache supervisor
COPY --from=singbox-builder /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY singbox.json /etc/singbox.json
COPY Caddyfile /etc/Caddyfile
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/sing-box /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF
  fi

  echo -e "${CYAN}🔨 Building image ($ENGINE engine)...${NC}"
  gcloud builds submit --project="$PROJECT_ID" --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME . --quiet

  echo -e "${CYAN}🚀 Deploying to Cloud Run...${NC}"
  gcloud run deploy "$CLOUD_RUN_SERVICE_NAME" \
    --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
    --project="$PROJECT_ID" --platform managed --region "$REGION" --allow-unauthenticated \
    --port 8080 --memory "$MEMORY" --cpu "$CPU" --concurrency "$CONCURRENCY" \
    --timeout "$TIMEOUT" --min-instances "$MIN_INST" --max-instances "$MAX_INST" \
    --session-affinity \
    --execution-environment gen2 $BILLING_FLAG --cpu-boost --quiet

  CLOUD_RUN_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE_NAME" --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
  DOMAIN=$(echo "$CLOUD_RUN_URL" | sed 's|https://||')
  CANONICAL_LINK="https://$DOMAIN"

  clear
  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ DEPLOYMENT SUCCESS! (${ENGINE^^})${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🔗 SHORT LINK:${NC} $CANONICAL_LINK"
  echo -e "${GREEN}🌐 NETMOD HOST:${NC} $DOMAIN"
  echo -e "${GREEN}💚 HEALTH CHECK:${NC} $CANONICAL_LINK/health"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${YELLOW}🔑 PROTOCOL PATHS & CREDENTIALS:${NC}"
  echo "🔹 VLESS-WS:        /vless-ws        | UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo "🔹 VLESS-XHTTP:     /vless-xhttp     | UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo -e "${CYAN}=========================================${NC}"

  read -p $'\nPress [Enter] to return to Main Menu...'
}

while true; do
  clear
  echo "======================================"
  echo "PENTA-ENGINE GCP-XRAY DEPLOYER MENU"
  echo "======================================"
  echo "1) Deploy New Service"
  echo "2) List All Services & Full Details"
  echo "3) Exit"
  echo "======================================"
  read -p "Select Option [1-3]: " MENU_CHOICE

  case $MENU_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) echo -e "\n👋 Goodbye!"; exit 0 ;;
    *) echo -e "${RED}❌ Enter 1/2/3 only${NC}"; sleep 2 ;;
  esac
done
