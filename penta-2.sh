#!/bin/bash
set -euo pipefail

# =================================================================
# 🚀 GCP-XRAY ULTIMATE MULTI-ENGINE DEPLOYER (AUTO-TUNED)
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY, SING-BOX
# ✅ PROTOCOLS: Trojan-WS, VLESS-WS, VLESS-XHTTP, VLESS-HTTPUpgrade
# =================================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

if ! command -v jq &> /dev/null; then
  echo -e "\n${YELLOW}⚠️ Installing required tool: jq...${NC}"
  sudo apt update -qq && sudo apt install -y -qq jq || {
    echo -e "${RED}❌ Failed to install jq!${NC}"
    exit 1
  }
fi

list_deployed_services() {
  echo -e "\n======================================"
  echo -e "${CYAN}📋 ALL DEPLOYED GCP-XRAY SERVICES${NC}"
  echo -e "======================================"
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  
  SERVICES=$(gcloud run services list \
    --format="value(metadata.name, status.url, region, metadata.creationTimestamp.date(%Y-%m-%d))" \
    --project="$PROJECT_ID" 2>/dev/null)

  if [ -z "$SERVICES" ]; then
    echo -e "${RED}❌ No services found.${NC}"
  else
    local COUNT=1
    while IFS=$'\t' read -r NAME URL REGION CREATED; do
      [ -z "$NAME" ] && continue
      echo -e "${GREEN}=== SERVICE #$COUNT ===${NC}"
      echo "🔹 Name:         $NAME"
      echo "🔹 URL:          $URL"
      echo "🔹 Region:       $REGION"
      echo "🔹 Created:      $CREATED"
      echo ""
      ((COUNT++))
    done <<< "$SERVICES"
  fi
  read -p "Press [Enter] to return..."
}

select_region() {
  echo -e "\n=== GCP CLOUD RUN REGION SELECTION ==="
  echo "1) asia-east1       (Taiwan 🇹🇼 — RECOMMENDED)"
  echo "2) asia-southeast1  (Singapore 🇸🇬)"
  echo "3) asia-northeast1  (Tokyo, Japan 🇯🇵)"
  echo "4) asia-northeast3  (Seoul, South Korea 🇰🇷)"
  echo "5) us-central1      (Iowa, US 🇺🇸)"
  echo "6) europe-west1     (Belgium 🇧🇪)"
  echo "0) Enter custom region code"
  read -p "Select region [0-6]: " REGION_NUM
  case $REGION_NUM in
    1) REGION="asia-east1" ;;
    2) REGION="asia-southeast1" ;;
    3) REGION="asia-northeast1" ;;
    4) REGION="asia-northeast3" ;;
    5) REGION="us-central1" ;;
    6) REGION="europe-west1" ;;
    0) read -p "Type full region code: " REGION ;;
    *) REGION="asia-east1" ;;
  esac
}

deploy_new_service() {
  select_region

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
      echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
      return
  fi

  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}          CHOOSE PROXY ENGINE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo "1) OpenResty          - [Anti-DDoS + Nginx Core]"
  echo "2) Envoy Proxy        - [High Throughput / gRPC/HTTP2]"
  echo "3) HAProxy            - [Ultra Low Latency]"
  echo "4) Caddy Proxy        - [Modern / Native HTTPUpgrade Support]"
  echo "5) Sing-Box Engine    - [Direct Core Server]"
  while true; do
      read -p "Select Engine [1-5]: " ENGINE_CHOICE
      case $ENGINE_CHOICE in
          1) ENGINE="openresty"; DISPLAY_ENGINE="OpenResty"; break ;;
          2) ENGINE="envoy"; DISPLAY_ENGINE="Envoy Proxy"; break ;;
          3) ENGINE="haproxy"; DISPLAY_ENGINE="HAProxy"; break ;;
          4) ENGINE="caddy"; DISPLAY_ENGINE="Caddy Proxy"; break ;;
          5) ENGINE="singbox"; DISPLAY_ENGINE="Sing-Box Engine"; break ;;
          *) echo -e "${RED}Enter 1-5 only${NC}" ;;
      esac
  done

  RAND=$(openssl rand -hex 3)
  CLOUD_RUN_SERVICE_NAME="gcp-xray-${ENGINE}-$RAND"

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}    RESOURCE CONFIG MODE (OPTIMIZED TUNING)${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}1) HIGH-PERFORMANCE PRESETS (Auto-Tuned CPU/RAM) ✅${NC}"
  echo -e "${YELLOW}2) MANUAL SETUP${NC}"
  while true; do
      read -p "Select Mode [1-2]: " RES_MODE
      case $RES_MODE in
          1)
              echo -e "\n${CYAN}--- AUTO OPTIMIZED PRESETS ---${NC}"
              echo "1) Ultra-Fast / Low Latency : 2 vCPU + 512Mi RAM (Concur: 1000) 🔥 [RECOMMENDED]"
              echo "2) Standard Daily Driver    : 1 vCPU + 512Mi RAM (Concur: 500)  ⚡ [Qwiklabs Safe]"
              echo "3) Multi-Stream / Heavy Duty: 2 vCPU + 1Gi RAM   (Concur: 1000, Min: 1) 🚀"
              read -p "Choose preset [1-3]: " AUTO_CHOICE
              
              BILLING_FLAG="--no-cpu-throttling"

              case $AUTO_CHOICE in
                  1) 
                    MEMORY="512Mi"; CPU="2"
                    MIN_INST=0; MAX_INST=3; CONCURRENCY=1000; TIMEOUT=3600
                    ;;
                  2) 
                    MEMORY="512Mi"; CPU="1"
                    MIN_INST=0; MAX_INST=2; CONCURRENCY=500; TIMEOUT=3600
                    ;;
                  3) 
                    MEMORY="1Gi"; CPU="2"
                    MIN_INST=1; MAX_INST=3; CONCURRENCY=1000; TIMEOUT=3600
                    ;;
                  *) 
                    MEMORY="512Mi"; CPU="2"
                    MIN_INST=0; MAX_INST=3; CONCURRENCY=1000; TIMEOUT=3600
                    ;;
              esac
              echo -e "${GREEN}✅ Applied Preset: $CPU vCPU | $MEMORY RAM | Concurrency: $CONCURRENCY${NC}"
              break
              ;;
          2)
              BILLING_FLAG="--no-cpu-throttling"
              read -p "Memory (e.g. 512Mi, 1Gi): " MEMORY
              read -p "vCPU (1 or 2): " CPU
              MIN_INST=0
              MAX_INST=2
              CONCURRENCY=1000
              TIMEOUT=3600
              break
              ;;
          *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
      esac
  done

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cd "$BUILD_DIR" || exit 1

  # Generate Xray Config
  cat > config.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "8.8.4.4"], "strategy": "UseIPv4" },
  "policy": {
    "levels": {
      "0": { "handshake": 10, "connIdle": 3600, "uplinkOnly": 0, "downlinkOnly": 0, "bufferSize": 2048 }
    }
  },
  "inbounds": [
    {
      "tag": "trojan-ws", "port": 10001, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{"password": "gcp-xray", "level": 0}] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-ws" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-ws", "port": 10002, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-ws" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-xhttp", "port": 10003, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/xhttp", "mode": "auto" }, "sockopt": { "tcpNoDelay": true } }
    },
    {
      "tag": "vless-httpupgrade", "port": 10004, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "streamSettings": { "network": "httpupgrade", "httpupgradeSettings": { "path": "/httpupgrade" }, "sockopt": { "tcpNoDelay": true } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }]
}
EOF

  cat > log_cleaner.sh <<'EOF'
#!/bin/sh
while true; do
  sleep 300
  rm -rf /tmp/* /var/log/*.log 2>/dev/null || true
done
EOF
  chmod +x log_cleaner.sh

  DECOY_HTML='<!DOCTYPE html><html><head><title>System Operational</title></head><body><h1>Service Ready</h1></body></html>'

  # Dockerfile & Container Config Selection
  if [ "$ENGINE" = "caddy" ]; then
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
}
:8080 {
    handle /health { respond "OK\n" 200 }
    @ws_trojan { path /trojan-ws* \n header Connection *Upgrade* \n header Upgrade websocket }
    reverse_proxy @ws_trojan 127.0.0.1:10001
    @ws_vless { path /vless-ws* \n header Connection *Upgrade* \n header Upgrade websocket }
    reverse_proxy @ws_vless 127.0.0.1:10002
    handle /xhttp* { reverse_proxy 127.0.0.1:10003 }
    handle /httpupgrade* { reverse_proxy 127.0.0.1:10004 }
    handle { respond "$DECOY_HTML" 200 }
}
EOF
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
[program:caddy]
command=caddy run --config /etc/Caddyfile --adapter caddyfile
autorestart=true
[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM caddy:2.8-alpine
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
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/trojan-ws" }
                route: { cluster: xray_trojan, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/vless-ws" }
                route: { cluster: xray_vless, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/xhttp" }
                route: { cluster: xray_xhttp }
              - match: { prefix: "/httpupgrade" }
                route: { cluster: xray_httpupgrade, upgrade_configs: [{ upgrade_type: "CONNECT" }] }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: xray_trojan
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: xray_trojan
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10001 } } }
  - name: xray_vless
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: xray_vless
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10002 } } }
  - name: xray_xhttp
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: xray_xhttp
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10003 } } }
  - name: xray_httpupgrade
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: xray_httpupgrade
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10004 } } }
EOF
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
[program:envoy]
command=envoy -c /etc/envoy.yaml
autorestart=true
[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
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

  elif [ "$ENGINE" = "haproxy" ]; then
    cat > haproxy.cfg <<EOF
global
    log type stderr format local daemon
    maxconn 10000

defaults
    log global
    mode http
    option httplog
    timeout connect 10s
    timeout client 3600s
    timeout server 3600s

frontend http_in
    bind *:8080
    acl is_trojan path_beg /trojan-ws
    acl is_vless path_beg /vless-ws
    acl is_xhttp path_beg /xhttp
    acl is_httpupgrade path_beg /httpupgrade
    
    use_backend bk_trojan if is_trojan
    use_backend bk_vless if is_vless
    use_backend bk_xhttp if is_xhttp
    use_backend bk_httpupgrade if is_httpupgrade
    default_backend bk_decoy

backend bk_trojan
    server xray1 127.0.0.1:10001

backend bk_vless
    server xray2 127.0.0.1:10002

backend bk_xhttp
    server xray3 127.0.0.1:10003

backend bk_httpupgrade
    server xray4 127.0.0.1:10004

backend bk_decoy
    http-request return status 200 content-type "text/html" string "$DECOY_HTML"
EOF
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
[program:haproxy]
command=haproxy -f /usr/local/etc/haproxy/haproxy.cfg
autorestart=true
[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
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

  elif [ "$ENGINE" = "singbox" ]; then
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
EOF
    sed -i 's/"port": 10001/"port": 8080/g' config.json
    sed -i 's/"listen": "127.0.0.1"/"listen": "0.0.0.0"/g' config.json

    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM alpine:3.20
RUN apk add --no-cache supervisor ca-certificates
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY supervisord.conf /etc/supervisord.conf
COPY log_cleaner.sh /usr/local/bin/log_cleaner.sh
RUN chmod +x /usr/local/bin/xray /usr/local/bin/log_cleaner.sh
EXPOSE 8080
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
EOF

  else
    # Default OpenResty Engine
    cat > nginx.conf <<EOF
worker_processes auto;
events { worker_connections 8192; }
http {
  keepalive_timeout 3600s;
  server {
    listen 8080;
    location /health { return 200 "OK\n"; }
    location /trojan-ws { proxy_pass http://127.0.0.1:10001; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_read_timeout 3600s; }
    location /vless-ws { proxy_pass http://127.0.0.1:10002; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_read_timeout 3600s; }
    location /xhttp { proxy_pass http://127.0.0.1:10003; proxy_http_version 1.1; proxy_read_timeout 3600s; }
    location /httpupgrade { proxy_pass http://127.0.0.1:10004; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_read_timeout 3600s; }
    location / { return 200 '$DECOY_HTML'; }
  }
}
EOF
    cat > supervisord.conf <<EOF
[supervisord]
nodaemon=true
logfile=/dev/null
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autorestart=true
[program:openresty]
command=/usr/local/openresty/bin/openresty -g "daemon off;"
autorestart=true
[program:logcleaner]
command=/usr/local/bin/log_cleaner.sh
autorestart=true
EOF
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
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
  fi

  echo -e "${CYAN}🔨 Building image ($ENGINE)...${NC}"
  gcloud builds submit --project="$PROJECT_ID" --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME . --quiet

  echo -e "${CYAN}🚀 Deploying to Cloud Run...${NC}"
  gcloud run deploy "$CLOUD_RUN_SERVICE_NAME" \
    --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
    --project="$PROJECT_ID" --platform managed --region "$REGION" --allow-unauthenticated \
    --port 8080 --memory "$MEMORY" --cpu "$CPU" --concurrency "$CONCURRENCY" \
    --timeout "$TIMEOUT" --min-instances "$MIN_INST" --max-instances "$MAX_INST" \
    --session-affinity --execution-environment gen2 $BILLING_FLAG --cpu-boost --quiet

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
  echo "🔹 Trojan WS:        /trojan-ws        | Pass: gcp-xray"
  echo "🔹 VLESS WS:         /vless-ws         | UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo "🔹 VLESS XHTTP:      /xhttp            | UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo "🔹 VLESS HTTPUpgrade: /httpupgrade      | UUID: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo -e "${CYAN}=========================================${NC}"

  read -p $'\nPress [Enter] to return to Main Menu...'
}

while true; do
  clear
  echo "======================================"
  echo "GCP-XRAY AUTO-TUNED DEPLOYER MENU"
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
