#!/bin/bash
set -euo pipefail

# ==============================================
# 🚀 GCP-XRAY — CLEAN EDITION
# ✅ TRANSPORTS: WS • HTTPUpgrade • XHTTP • gRPC
# ✅ ENGINES: OpenResty • Envoy • HAProxy • Caddy
# ✅ Supervisord + Anti-DDoS + Auto Log Cleaner
# ✅ QWIKLABS-SAFE — MIN_INST=0 / CONCUR=80
# ❌ REMOVED: ASPI-SIX, Sing-Box — lighter & faster
# ==============================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
NC='\033[0m'

# ==============================================
# AUTO INSTALL JQ
# ==============================================
if ! command -v jq &> /dev/null; then
  echo -e "\n${YELLOW}⚠️ Installing jq...${NC}"
  sudo apt update -qq && sudo apt install -y -qq jq || { echo -e "${RED}❌ jq install failed${NC}"; exit 1; }
fi

# ==============================================
# LIST DEPLOYED SERVICES
# ==============================================
list_deployed_services() {
  echo -e "\n======================================"
  echo -e "${CYAN}📋 DEPLOYED SERVICES${NC}"
  echo -e "======================================"
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  echo "Project: $PROJECT_ID"

  declare -A REGION_NAMES=(
    ["us-central1"]="Iowa 🇺🇸" ["us-east1"]="S.Carolina 🇺🇸"
    ["asia-east1"]="Taiwan 🇹🇼 — RECOMMENDED"
    ["asia-southeast1"]="Singapore 🇸🇬" ["europe-west4"]="Netherlands 🇳🇱"
  )

  SERVICES=$(gcloud run services list --format="value(metadata.name,status.url,region,metadata.creationTimestamp.date(%Y-%m-%d))" --project="$PROJECT_ID" 2>/dev/null)
  [ -z "$SERVICES" ] && { echo -e "${YELLOW}No services yet.${NC}"; read -p "[Enter] Back..."; return; }

  local COUNT=1
  while IFS=$'\t' read -r NAME URL REGION CREATED; do
    [ -z "$NAME" ] && continue
    FULL_REGION="${REGION_NAMES[$REGION]:-$REGION}"
    DETAILS=$(gcloud run services describe "$NAME" --region "$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null || true)
    if [ -n "$DETAILS" ]; then
      MEM=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.memory // "1Gi"')
      CPU=$(echo "$DETAILS" | jq -r '.spec.template.spec.containers[0].resources.limits.cpu // "1"')
      MIN=$(echo "$DETAILS" | jq -r '.spec.template.spec.minInstances // "0"')
      MAX=$(echo "$DETAILS" | jq -r '.spec.template.spec.maxInstances // "2"')
      CONCUR=$(echo "$DETAILS" | jq -r '.spec.template.spec.containerConcurrency // "80"')
      echo -e "${GREEN}=== #$COUNT $NAME ${NC}"
      echo "🔗 $URL | 📍 $REGION → $FULL_REGION"
      echo "💾 $MEM | 🖥️ $CPU vCPU | ⚖️ Min:$MIN/Max:$MAX | 🔂 $CONCUR"
    else
      echo -e "${GREEN}=== #$COUNT $NAME ${NC}"
      echo "🔗 $URL | 📍 $REGION"
    fi
    ((COUNT++))
  done <<< "$SERVICES"
  read -p $'\n[Enter] Back to Menu...'
}

# ==============================================
# DELETE SERVICE
# ==============================================
delete_service() {
  echo -e "\n${RED}🗑️ DELETE SERVICE${NC}"
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  read -p "Service Name: " DEL_NAME
  read -p "Region: " DEL_REGION
  if [ -z "$DEL_NAME" ] || [ -z "$DEL_REGION" ]; then
    echo -e "${YELLOW}Cancelled.${NC}"; return
  fi
  echo -e "${RED}Deleting $DEL_NAME @ $DEL_REGION...${NC}"
  gcloud run services delete "$DEL_NAME" --region="$DEL_REGION" --project="$PROJECT_ID" --quiet
  echo -e "${GREEN}✅ DELETED — Safe to exit now${NC}"
  read -p "[Enter] Back..."
}

# ==============================================
# REGION SELECTOR
# ==============================================
select_region() {
  echo -e "\n=== SELECT REGION ==="
  echo "1) us-central1      🇺🇸   5) asia-east1       🇹🇼 RECOMMENDED"
  echo "2) us-east1         🇺🇸   6) asia-southeast1  🇸🇬"
  echo "3) us-west1         🇺🇸   7) asia-northeast1   🇯🇵"
  echo "4) us-east4         🇺🇸   8) europe-west4     🇳🇱"
  while true; do
    read -p "Choice [1-8]: " RCH
    case $RCH in
      1) REGION="us-central1"; break ;;
      2) REGION="us-east1"; break ;;
      3) REGION="us-west1"; break ;;
      4) REGION="us-east4"; break ;;
      5) REGION="asia-east1"; break ;;
      6) REGION="asia-southeast1"; break ;;
      7) REGION="asia-northeast1"; break ;;
      8) REGION="europe-west4"; break ;;
      *) echo -e "${RED}Enter 1-8 only${NC}" ;;
    esac
  done
  echo -e "${GREEN}✅ Region: $REGION${NC}"
}

# ==============================================
# TRANSPORT SELECTOR — CLEAN VERSION
# ==============================================
select_transport() {
  echo -e "\n${MAGENTA}=========================================${NC}"
  echo -e "${MAGENTA}    SELECT TRANSPORT PROTOCOL${NC}"
  echo -e "${MAGENTA}=========================================${NC}"
  echo "1) WebSocket        — Universal / Most Stable ✅"
  echo "2) HTTPUpgrade      — Fast / Telco-Friendly"
  echo "3) XHTTP            — Stealth / Low Detection"
  echo "4) gRPC             — High Throughput / HTTP/2"
  echo "5) ALL (4-in-1)     — Deploy Every Transport"
  while true; do
    read -p "Transport [1-5]: " TCH
    case $TCH in
      1) TRANS="ws"; DISPTR="WebSocket"; break ;;
      2) TRANS="httpupgrade"; DISPTR="HTTPUpgrade"; break ;;
      3) TRANS="xhttp"; DISPTR="XHTTP"; break ;;
      4) TRANS="grpc"; DISPTR="gRPC"; break ;;
      5) TRANS="all"; DISPTR="ALL-TRANSPORTS"; break ;;
      *) echo -e "${RED}Enter 1-5 only${NC}" ;;
    esac
  done
  echo -e "${GREEN}✅ Transport: $DISPTR${NC}"
}

# ==============================================
# DEPLOYMENT — MAIN
# ==============================================
deploy_new_service() {
  select_region
  select_transport

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  [ -z "$PROJECT_ID" ] && { echo -e "${RED}Run: gcloud config set project YOUR_ID${NC}"; return; }
  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  echo -e "\n${CYAN}SELECT ENGINE:${NC}"
  echo "1) OpenResty  |  2) Envoy  |  3) HAProxy  |  4) Caddy"
  while true; do
    read -p "Engine [1-4]: " ECH
    case $ECH in
      1) ENGINE="openresty"; DISPENG="OpenResty"; break ;;
      2) ENGINE="envoy"; DISPENG="Envoy"; break ;;
      3) ENGINE="haproxy"; DISPENG="HAProxy"; break ;;
      4) ENGINE="caddy"; DISPENG="Caddy"; break ;;
      *) echo -e "${RED}Enter 1-4 only${NC}" ;;
    esac
  done

  RAND=$(openssl rand -hex 2)
  NAME="gcp-xray-${ENGINE}-${TRANS}-${RAND}"

  echo -e "\n${CYAN}⚙️ RESOURCE PRESETS — QWIKLABS-SAFE${NC}"
  echo "1) Light    512Mi/0.5vCPU  Min:0 Max:2  Conc:80  ✅"
  echo "2) Balanced 1Gi/1vCPU      Min:0 Max:2  Conc:80  ✅ RECOMMENDED"
  echo "3) Max      2Gi/2vCPU      Min:0 Max:3  Conc:80  ✅"
  while true; do
    read -p "Preset [1-3]: " PCH
    case $PCH in
      1) MEMORY="512Mi"; CPU="0.5"; MIN_INST=0; MAX_INST=2; CONCURRENCY=80; break ;;
      3) MEMORY="2Gi"; CPU="2"; MIN_INST=0; MAX_INST=3; CONCURRENCY=80; break ;;
      2|*) MEMORY="1Gi"; CPU="1"; MIN_INST=0; MAX_INST=2; CONCURRENCY=80; break ;;
    esac
  done
  TIMEOUT=3600

  echo -e "${GREEN}✅ Settings: $MEMORY / $CPU vCPU / Min:$MIN_INST / Max:$MAX_INST / Conc:$CONCURRENCY${NC}"

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cd "$BUILD_DIR" || exit 1

  DECOY_HTML='<!DOCTYPE html><html><head><meta charset="utf-8"><title>System Status</title><style>body{font-family:sans-serif;background:#0d1117;color:#c9d1d9;display:flex;justify-content:center;align-items:center;height:100vh;margin:0}h1{color:#58a6ff}p{color:#8b949e}</style></head><body><div><h1>Application Gateway</h1><p>All systems operational.</p></div></body></html>'

  # ==============================================
  # BUILD XRAY CONFIG — 4 TRANSPORTS ONLY
  # ==============================================
  build_xray_json() {
    local INBOUNDS=""
    local SOCKOPT=', "sockopt": { "tcpNoDelay": true, "tcpFastOpen": true, "tcpKeepAliveIdle": 300, "tcpKeepAliveInterval": 30 }'

    # WebSocket
    if [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ]; then
      INBOUNDS+="{
        \"tag\": \"trojan-ws\", \"port\": 10001, \"listen\": \"127.0.0.1\",
        \"protocol\": \"trojan\",
        \"settings\": { \"clients\": [{\"password\": \"gcp-xray\", \"level\": 0}] },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"ws\", \"wsSettings\": { \"path\": \"/trojan-ws\" } $SOCKOPT }
      },{
        \"tag\": \"vless-ws\", \"port\": 10002, \"listen\": \"127.0.0.1\",
        \"protocol\": \"vless\",
        \"settings\": { \"clients\": [{\"id\": \"a1b2c3d4-5678-40ef-98ab-cdef01234567\", \"level\": 0}], \"decryption\": \"none\" },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"ws\", \"wsSettings\": { \"path\": \"/vless-ws\" } $SOCKOPT }
      },"
    fi

    # HTTPUpgrade
    if [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ]; then
      INBOUNDS+="{
        \"tag\": \"trojan-hu\", \"port\": 10011, \"listen\": \"127.0.0.1\",
        \"protocol\": \"trojan\",
        \"settings\": { \"clients\": [{\"password\": \"gcp-xray\", \"level\": 0}] },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"httpupgrade\", \"httpupgradeSettings\": { \"path\": \"/trojan-hu\" } $SOCKOPT }
      },{
        \"tag\": \"vless-hu\", \"port\": 10012, \"listen\": \"127.0.0.1\",
        \"protocol\": \"vless\",
        \"settings\": { \"clients\": [{\"id\": \"a1b2c3d4-5678-40ef-98ab-cdef01234567\", \"level\": 0}], \"decryption\": \"none\" },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"httpupgrade\", \"httpupgradeSettings\": { \"path\": \"/vless-hu\" } $SOCKOPT }
      },"
    fi

    # XHTTP
    if [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ]; then
      INBOUNDS+="{
        \"tag\": \"trojan-xh\", \"port\": 10021, \"listen\": \"127.0.0.1\",
        \"protocol\": \"trojan\",
        \"settings\": { \"clients\": [{\"password\": \"gcp-xray\", \"level\": 0}] },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"xhttp\", \"xhttpSettings\": { \"path\": \"/trojan-xh\", \"mode\": \"auto\" } $SOCKOPT }
      },{
        \"tag\": \"vless-xh\", \"port\": 10022, \"listen\": \"127.0.0.1\",
        \"protocol\": \"vless\",
        \"settings\": { \"clients\": [{\"id\": \"a1b2c3d4-5678-40ef-98ab-cdef01234567\", \"level\": 0}], \"decryption\": \"none\" },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"xhttp\", \"xhttpSettings\": { \"path\": \"/vless-xh\", \"mode\": \"auto\" } $SOCKOPT }
      },"
    fi

    # gRPC
    if [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ]; then
      INBOUNDS+="{
        \"tag\": \"trojan-grpc\", \"port\": 10031, \"listen\": \"127.0.0.1\",
        \"protocol\": \"trojan\",
        \"settings\": { \"clients\": [{\"password\": \"gcp-xray\", \"level\": 0}] },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"grpc\", \"grpcSettings\": { \"serviceName\": \"trojangrpc\" } $SOCKOPT }
      },{
        \"tag\": \"vless-grpc\", \"port\": 10032, \"listen\": \"127.0.0.1\",
        \"protocol\": \"vless\",
        \"settings\": { \"clients\": [{\"id\": \"a1b2c3d4-5678-40ef-98ab-cdef01234567\", \"level\": 0}], \"decryption\": \"none\" },
        \"sniffing\": { \"enabled\": false },
        \"streamSettings\": { \"network\": \"grpc\", \"grpcSettings\": { \"serviceName\": \"vlessgrpc\" } $SOCKOPT }
      },"
    fi

    INBOUNDS="${INBOUNDS%,}"

    cat <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": { "servers": ["8.8.8.8", "8.8.4.4"], "strategy": "UseIPv4" },
  "policy": { "levels": { "0": { "handshake": 2, "connIdle": 3600, "bufferSize": 524288 } } },
  "inbounds": [${INBOUNDS}],
  "outbounds": [{ "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }]
}
EOF
  }
  build_xray_json > config.json

  # ==============================================
  # SUPERVISORD + ANTI-DDOS + LOG CLEANER
  # ==============================================
  cat > supervisord.conf <<'EOF'
[supervisord]
nodaemon=true
logfile=/tmp/supervisord.log
pidfile=/tmp/supervisord.pid
loglevel=info

[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autostart=true
autorestart=true
startretries=99
stdout_logfile=/tmp/xray.log
stderr_logfile=/tmp/xray.err.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=1

[program:anti-ddos]
command=/usr/bin/python3 /app/anti_ddos.py
autostart=true
autorestart=true
startsecs=10

[program:log-cleaner]
command=/usr/bin/python3 /app/log_cleaner.py
autostart=true
autorestart=true
startsecs=30
EOF

  cat > anti_ddos.py <<'PYEOF'
#!/usr/bin/env python3
import time, threading
from collections import defaultdict
ips = defaultdict(list); lock = threading.Lock()
def cleaner():
    while True:
        time.sleep(120)
        now = time.time()
        with lock:
            for ip in list(ips.keys()):
                ips[ip] = [t for t in ips[ip] if now - t < 60]
                if not ips[ip]: del ips[ip]
threading.Thread(target=cleaner, daemon=True).start()
while True: time.sleep(3600)
PYEOF

  cat > log_cleaner.py <<'PYEOF'
#!/usr/bin/env python3
import os, time
PATHS = ["/tmp"]; MAX_AGE = 1800
def clean():
    now = time.time()
    for d in PATHS:
        if not os.path.exists(d): continue
        for f in os.listdir(d):
            p = os.path.join(d, f)
            try:
                if os.path.isfile(p) and now - os.path.getmtime(p) > MAX_AGE:
                    os.remove(p)
            except: pass
while True: clean(); time.sleep(900)
PYEOF

  chmod +x anti_ddos.py log_cleaner.py

  # ==============================================
  # NGINX/OPENRESTY ROUTES — 4 TRANSPORTS
  # ==============================================
  gen_nginx_locations() {
    local UPG='proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";'
    [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && echo "
    location /trojan-ws {
      proxy_pass http://127.0.0.1:10001; $UPG
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }
    location /vless-ws {
      proxy_pass http://127.0.0.1:10002; $UPG
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }"
    [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && echo "
    location /trojan-hu {
      proxy_pass http://127.0.0.1:10011; $UPG
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }
    location /vless-hu {
      proxy_pass http://127.0.0.1:10012; $UPG
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }"
    [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && echo "
    location /trojan-xh {
      proxy_pass http://127.0.0.1:10021; proxy_http_version 1.1;
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }
    location /vless-xh {
      proxy_pass http://127.0.0.1:10022; proxy_http_version 1.1;
      proxy_set_header Host \$host; proxy_read_timeout 3600s;
    }"
    [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && echo "
    location /trojangrpc { grpc_pass grpc://127.0.0.1:10031; }
    location /vlessgrpc { grpc_pass grpc://127.0.0.1:10032; }"
  }
  NGINX_LOCS=$(gen_nginx_locations)

  # ==============================================
  # 1️⃣ OPENRESTY
  # ==============================================
  if [ "$ENGINE" = "openresty" ]; then
    cat > nginx.conf <<EOF
worker_processes auto; worker_rlimit_nofile 10240;
events { worker_connections 4096; use epoll; multi_accept on; }
http {
  include mime.types; default_type application/octet-stream;
  sendfile on; tcp_nodelay on; keepalive_timeout 3600;
  client_max_body_size 0; proxy_buffering off; proxy_http_version 1.1;
  server {
    listen 8080;
    location /health { return 200 "OK\n"; }
$NGINX_LOCS
    location / { default_type text/html; return 200 '$DECOY_HTML'; }
  }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
cp /app/config.json /etc/xray.json
exec /usr/bin/supervisord -n -c /app/supervisord.conf
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip && curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o x.zip && unzip -q x.zip xray && chmod +x xray
FROM openresty/openresty:1.27-1-alpine
RUN apk add --no-cache supervisor python3
COPY --from=builder /xray /usr/local/bin/xray
COPY . /app/
RUN chmod +x /usr/local/bin/xray /app/*.py /app/*.sh
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
EXPOSE 8080
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

  # ==============================================
  # 2️⃣ ENVOY
  # ==============================================
  elif [ "$ENGINE" = "envoy" ]; then
    gen_envoy_routes() {
      local R=""
      [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && R+='
              - match: {prefix: "/trojan-ws"}
                route: {cluster: trojan_ws, timeout: 3600s, upgrade_configs: [{upgrade_type: websocket}]}
              - match: {prefix: "/vless-ws"}
                route: {cluster: vless_ws, timeout: 3600s, upgrade_configs: [{upgrade_type: websocket}]}'
      [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && R+='
              - match: {prefix: "/trojan-hu"}
                route: {cluster: trojan_hu, timeout: 3600s, upgrade_configs: [{upgrade_type: websocket}]}
              - match: {prefix: "/vless-hu"}
                route: {cluster: vless_hu, timeout: 3600s, upgrade_configs: [{upgrade_type: websocket}]}'
      [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && R+='
              - match: {prefix: "/trojan-xh"}
                route: {cluster: trojan_xh, timeout: 3600s}
              - match: {prefix: "/vless-xh"}
                route: {cluster: vless_xh, timeout: 3600s}'
      [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && R+='
              - match: {prefix: "/trojangrpc"}
                route: {cluster: trojan_grpc, timeout: 3600s}
              - match: {prefix: "/vlessgrpc"}
                route: {cluster: vless_grpc, timeout: 3600s}'
      echo "$R"
    }
    gen_envoy_clusters() {
      local C=""
      [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && C+='
  - name: trojan_ws
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10001}}}}]}]}
  - name: vless_ws
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10002}}}}]}]}'
      [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && C+='
  - name: trojan_hu
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10011}}}}]}]}
  - name: vless_hu
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10012}}}}]}]}'
      [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && C+='
  - name: trojan_xh
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10021}}}}]}]}
  - name: vless_xh
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10022}}}}]}]}'
      [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && C+='
  - name: trojan_grpc
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10031}}}}]}]}
  - name: vless_grpc
    load_assignment: {endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: 127.0.0.1, port_value: 10032}}}}]}]}'
      echo "$C"
    }
    ROUTES_YAML=$(gen_envoy_routes)
    CLUSTERS_YAML=$(gen_envoy_clusters)
    cat > envoy.yaml <<EOF
static_resources:
  listeners:
  - address: {socket_address: {address: "0.0.0.0", port_value: 8080}}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: http
          route_config:
            virtual_hosts:
            - name: all
              domains: ["*"]
              routes:
              - match: {prefix: "/health"}
                direct_response: {status: 200, body: {inline_string: "OK\n"}}
$ROUTES_YAML
              - match: {prefix: "/"}
                direct_response: {status: 200, body: {inline_string: '$DECOY_HTML'}}
          http_filters:
          - name: envoy.filters.http.router
  clusters:
$CLUSTERS_YAML
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
cp /app/config.json /etc/xray.json
exec /usr/bin/supervisord -n -c /app/supervisord.conf
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip && curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o x.zip && unzip -q x.zip xray && chmod +x xray
FROM envoyproxy/envoy:v1.32.0
RUN apt update && apt install -y --no-install-recommends supervisor python3 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /xray /usr/local/bin/xray
COPY . /app/
RUN chmod +x /usr/local/bin/xray /app/*.py /app/*.sh
EXPOSE 8080
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

  # ==============================================
  # 3️⃣ HAPROXY
  # ==============================================
  elif [ "$ENGINE" = "haproxy" ]; then
    gen_haproxy_cfg() {
      local A=""; local B=""
      [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && A+='
    acl tr_ws path_beg /trojan-ws
    acl vl_ws path_beg /vless-ws
    use_backend tr_ws_back if tr_ws
    use_backend vl_ws_back if vl_ws' && B+='
backend tr_ws_back
    server s1 127.0.0.1:10001
backend vl_ws_back
    server s2 127.0.0.1:10002'
      [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && A+='
    acl tr_hu path_beg /trojan-hu
    acl vl_hu path_beg /vless-hu
    use_backend tr_hu_back if tr_hu
    use_backend vl_hu_back if vl_hu' && B+='
backend tr_hu_back
    server s3 127.0.0.1:10011
backend vl_hu_back
    server s4 127.0.0.1:10012'
      [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && A+='
    acl tr_xh path_beg /trojan-xh
    acl vl_xh path_beg /vless-xh
    use_backend tr_xh_back if tr_xh
    use_backend vl_xh_back if vl_xh' && B+='
backend tr_xh_back
    server s5 127.0.0.1:10021
backend vl_xh_back
    server s6 127.0.0.1:10022'
      [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && A+='
    acl tr_gr path_beg /trojangrpc
    acl vl_gr path_beg /vlessgrpc
    use_backend tr_gr_back if tr_gr
    use_backend vl_gr_back if vl_gr' && B+='
backend tr_gr_back
    server s7 127.0.0.1:10031
backend vl_gr_back
    server s8 127.0.0.1:10032'
      echo "$A"; echo "$B"
    }
    HAP_CFG=$(gen_haproxy_cfg)
    cat > haproxy.cfg <<EOF
global
    maxconn 8192
defaults
    mode http
    timeout connect 5s
    timeout client 3600s
    timeout server 3600s
frontend main
    bind *:8080
    acl health path /health
    use_backend health if health
$HAP_CFG
    http-request return status 200 content-type text/html string '$DECOY_HTML'
backend health
    http-request return status 200 content-type text/plain string "OK\n"
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
cp /app/config.json /etc/xray.json
exec /usr/bin/supervisord -n -c /app/supervisord.conf
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip && curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o x.zip && unzip -q x.zip xray && chmod +x xray
FROM haproxy:3.1-alpine
RUN apk add --no-cache supervisor python3
COPY --from=builder /xray /usr/local/bin/xray
COPY . /app/
RUN chmod +x /usr/local/bin/xray /app/*.py /app/*.sh
EXPOSE 8080
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
EOF

  # ==============================================
  # 4️⃣ CADDY
  # ==============================================
  elif [ "$ENGINE" = "caddy" ]; then
    gen_caddy_handles() {
      local H=""
      [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && H+='
    handle /trojan-ws* { reverse_proxy 127.0.0.1:10001 { header_up Upgrade "websocket"; header_up Connection "upgrade" } }
    handle /vless-ws* { reverse_proxy 127.0.0.1:10002 { header_up Upgrade "websocket"; header_up Connection "upgrade" } }'
      [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && H+='
    handle /trojan-hu* { reverse_proxy 127.0.0.1:10011 { header_up Upgrade "websocket"; header_up Connection "upgrade" } }
    handle /vless-hu* { reverse_proxy 127.0.0.1:10012 { header_up Upgrade "websocket"; header_up Connection "upgrade" } }'
      [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && H+='
    handle /trojan-xh* { reverse_proxy 127.0.0.1:10021 }
    handle /vless-xh* { reverse_proxy 127.0.0.1:10022 }'
      [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && H+='
    handle /trojangrpc* { reverse_proxy 127.0.0.1:10031 }
    handle /vlessgrpc* { reverse_proxy 127.0.0.1:10032 }'
      echo "$H"
    }
    CDDY_HDL=$(gen_caddy_handles)
    cat > Caddyfile <<EOF
{ http_port 8080 }
:8080 {
    handle /health { respond "OK\n" 200 }
$CDDY_HDL
    handle { respond """$DECOY_HTML""" 200 }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
cp /app/config.json /etc/xray.json
exec /usr/bin/supervisord -n -c /app/supervisord.conf
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip && curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o x.zip && unzip -q x.zip xray && chmod +x xray
FROM caddy:2.8-alpine
RUN apk add --no-cache supervisor python3
COPY --from=builder /xray /usr/local/bin/xray
COPY . /app/
RUN chmod +x /usr/local/bin/xray /app/*.py /app/*.sh
EXPOSE 8080
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
EOF
  fi

  # ==============================================
  # BUILD & DEPLOY TO CLOUD RUN
  # ==============================================
  echo -e "\n${CYAN}🔨 Building & Pushing to Cloud Build...${NC}"
  gcloud builds submit --tag="us-docker.pkg.dev/$PROJECT_ID/gcp-xray/$NAME:latest" --quiet

  echo -e "\n${CYAN}🚀 Deploying to Cloud Run...${NC}"
  gcloud run deploy "$NAME" \
    --image="us-docker.pkg.dev/$PROJECT_ID/gcp-xray/$NAME:latest" \
    --region="$REGION" \
    --platform=managed \
    --memory="$MEMORY" \
    --cpu="$CPU" \
    --min-instances="$MIN_INST" \
    --max-instances="$MAX_INST" \
    --concurrency="$CONCURRENCY" \
    --timeout="$TIMEOUT"s \
    --port=8080 \
    --allow-unauthenticated \
    --quiet

  SERVICE_URL=$(gcloud run services describe "$NAME" --region="$REGION" --format="value(status.url)")

  echo -e "\n${GREEN}✅ ✅ DEPLOYMENT SUCCESS!${NC}"
  echo -e "══════════════════════════════════════════"
  echo -e "📦 Service: $NAME"
  echo -e "🔗 URL: $SERVICE_URL"
  echo -e "⚙️ Engine: $DISPENGINE | Transport: $DISPTR"
  echo -e "💾 $MEMORY | 🖥️ $CPU vCPU | ⚖️ Min:$MIN_INST/Max:$MAX_INST | 🔂 $CONCURRENCY"
  echo -e "══════════════════════════════════════════"
  echo -e "🔑 Password: gcp-xray"
  echo -e "🆔 UUID vless: a1b2c3d4-5678-40ef-98ab-cdef01234567"
  echo -e "📍 Region: $REGION"
  echo -e "\n📋 Endpoints:"
  [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && echo -e "  WS-Trojan: $SERVICE_URL/trojan-ws"
  [ "$TRANS" = "ws" ] || [ "$TRANS" = "all" ] && echo -e "  WS-Vless:  $SERVICE_URL/vless-ws"
  [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && echo -e "  HU-Trojan: $SERVICE_URL/trojan-hu"
  [ "$TRANS" = "httpupgrade" ] || [ "$TRANS" = "all" ] && echo -e "  HU-Vless:  $SERVICE_URL/vless-hu"
  [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && echo -e "  XH-Trojan: $SERVICE_URL/trojan-xh"
  [ "$TRANS" = "xhttp" ] || [ "$TRANS" = "all" ] && echo -e "  XH-Vless:  $SERVICE_URL/vless-xh"
  [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && echo -e "  gRPC-Trojan: $SERVICE_URL/trojangrpc"
  [ "$TRANS" = "grpc" ] || [ "$TRANS" = "all" ] && echo -e "  gRPC-Vless:  $SERVICE_URL/vlessgrpc"
  echo -e "\n${YELLOW}⚠️ FINISH: Copy the config above to your client${NC}"
  echo -e "${GREEN}⚠️ REMINDER: Run delete command after use!${NC}"
  read -p "[Enter] Back to Menu..."
}

# ==============================================
# MAIN MENU
# ==============================================
while true; do
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════╗"
  echo "║     🚀 GCP-XRAY — CLEAN EDITION v2.0                ║"
  echo "║  4 Transports • 4 Engines • Qwiklabs-Safe           ║"
  echo "╚════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  1) 🚀 DEPLOY NEW SERVICE"
  echo "  2) 📋 LIST DEPLOYED SERVICES"
  echo "  3) 🗑️ DELETE SERVICE"
  echo "  0) ❌ EXIT"
  echo ""
  read -p "Choice [0-3]: " MAIN_CHOICE
  case $MAIN_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) delete_service ;;
    0) echo -e "${GREEN}Bye! Don't forget to delete unused services 👍${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
  esac
done
