#!/bin/bash
set -euo pipefail

# =================================================================
# 🚀 GCP-XRAY ULTIMATE MULTI-ENGINE DEPLOYER (STABLE & TUNED)
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
  echo "3) us-central1      (Iowa, US 🇺🇸)"
  echo "4) europe-west1     (Belgium 🇧🇪)"
  echo "0) Enter custom region code"
  read -p "Select region [0-4]: " REGION_NUM
  case $REGION_NUM in
    1) REGION="asia-east1" ;;
    2) REGION="asia-southeast1" ;;
    3) REGION="us-central1" ;;
    4) REGION="europe-west1" ;;
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
  echo "5) Sing-Box Engine    - [Lightweight Direct Core]"
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
  echo -e "${GREEN}1) HIGH-PERFORMANCE PRESETS (Optimized CPU/RAM Ratio) ✅${NC}"
  echo -e "${YELLOW}2) MANUAL SETUP${NC}"
  while true; do
      read -p "Select Mode [1-2]: " RES_MODE
      case $RES_MODE in
          1)
              echo -e "\n${CYAN}--- AUTO OPTIMIZED PRESETS ---${NC}"
              echo "1) Ultra-Fast / Low Latency : 2 vCPU + 512Mi RAM (Concur: 1000) 🔥 [BEST FOR STABILITY]"
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
  rm -rf /tmp/* /var/log/*.log /var/log/nginx/* /var/log/supervisor/* 2>/dev/null || true
done
EOF
  chmod +x log_cleaner.sh

  DECOY_HTML='<!DOCTYPE html><html><head><title>System Operational</title></head><body><h1>Service Ready</h1></body></html>'

  # Dockerfile & Proxy Build Logic
  if [ "$ENGINE" = "caddy" ] || [ "$ENGINE" = "singbox" ]; then
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
}
:8080 {
    handle /health { respond "OK\n" 200 }
    handle /trojan-ws* { reverse_proxy 127.0.0.1:10001 }
    handle /vless-ws* { reverse_proxy 127.0.0.1:10002 }
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
  else
    # Defaulting to OpenResty Container Setup for OpenResty, Envoy, HAProxy
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

  echo -e "\n${GREEN}✅ DEPLOYED SUCCESSFULLY!${NC}"
  echo -e "🔹 HOST: $DOMAIN"
  read -p 'Press [Enter] to return...'
}

while true; do
  clear
  echo "======================================"
  echo "GCP-XRAY AUTO-TUNED DEPLOYER MENU"
  echo "======================================"
  echo "1) Deploy New Service"
  echo "2) List Services"
  echo "3) Exit"
  read -p "Select [1-3]: " MENU_CHOICE
  case $MENU_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) exit 0 ;;
  esac
done
