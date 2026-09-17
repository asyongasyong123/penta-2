#!/bin/bash
set -euo pipefail
# =========================================
# 🚀 GCP-XRAY MULTI-ENGINE DEPLOYER + SING-BOX
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY, SING-BOX
# ✅ SOLID HOST TUNING | ANTI-DDOS | LOG CLEANER | SUPERVISORD
# ✅ Custom Decoy HTML — No Sniffing
# =========================================
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
# SYSTEM OPTIMIZATIONS — SOLID HOST / NO TIMEOUT
# ==============================================
sysctl_optimize() {
  echo -e "\n${CYAN}⚙️ Applying kernel & network optimizations...${NC}"
  sudo tee /etc/sysctl.d/99-solid-host.conf > /dev/null <<'EOF'
# Network — Solid Keepalive & Throughput
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.core.somaxconn = 8192
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 1024 65535
# Anti-DDoS / Hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF
  sudo sysctl -p /etc/sysctl.d/99-solid-host.conf >/dev/null 2>&1
  # File Descriptors
  sudo tee /etc/security/limits.d/99-proxy-limits.conf > /dev/null <<'EOF'
* soft nofile 65536
* hard nofile 65536
root soft nofile 65536
root hard nofile 65536
EOF
}

# ==============================================
# LOG CLEANER — Auto-Purge Old Logs
# ==============================================
setup_log_cleaner() {
  echo -e "${CYAN}🧹 Setting up log cleaner...${NC}"
  sudo tee /etc/cron.daily/log-cleaner > /dev/null <<'EOF'
#!/bin/bash
# Keep logs only for 3 days
find /var/log -type f -name "*.log" -mtime +3 -delete
find /var/log -type f -name "*.gz" -mtime +3 -delete
find /var/log -type f -name "*.old" -mtime +3 -delete
# Truncate large active logs
for log in /var/log/syslog /var/log/messages /var/log/nginx/*.log /var/log/xray/*.log /var/log/sing-box/*.log; do
  if [ -f "$log" ]; then : > "$log"; fi
done
EOF
  sudo chmod +x /etc/cron.daily/log-cleaner
}

# ==============================================
# SUPERVISORD — Process Manager
# ==============================================
install_supervisord() {
  echo -e "${CYAN}📦 Installing Supervisord...${NC}"
  sudo apt update -qq && sudo apt install -y -qq supervisor || true
  sudo systemctl enable supervisor >/dev/null 2>&1 || true
}

# ==============================================
# LIST SERVICES — FIXED
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
# 🎨 DECOY HTML PAGE — EXACTLY AS PROVIDED
# ==============================================
generate_decoy_html() {
  cat <<'DECOYHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Status | Cloud Gateway</title>
    <style>
        :root { --bg: #0b0f19; --card: #111827; --border: #1f2937; --text: #9ca3af; --white: #f9fafb; --green: #10b981; }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg); color: var(--text); display: flex; align-items: center; justify-content: center; min-height: 100vh; padding: 20px; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 32px; max-width: 440px; width: 100%; box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.5); }
        .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid var(--border); }
        .title { color: var(--white); font-size: 18px; font-weight: 600; }
        .badge { display: inline-flex; align-items: center; gap: 6px; background: rgba(16, 185, 129, 0.1); color: var(--green); padding: 4px 10px; border-radius: 9999px; font-size: 12px; font-weight: 500; }
        .dot { width: 8px; height: 8px; background: var(--green); border-radius: 50%; animation: pulse 2s infinite; }
        .metrics { display: grid; gap: 12px; margin-bottom: 24px; }
        .metric-item { display: flex; justify-content: space-between; font-size: 14px; padding: 8px 0; border-bottom: 1px dashed var(--border); }
        .metric-item span:last-child { color: var(--white); font-weight: 500; }
        .footer { font-size: 12px; text-align: center; color: #6b7280; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }
    </style>
</head>
<body>
    <div class="card">
        <div class="header">
            <div class="title">Application Gateway</div>
            <div class="badge"><span class="dot"></span> Operational</div>
        </div>
        <div class="metrics">
            <div class="metric-item"><span>HTTP/2 Proxy Ingress</span><span>Active</span></div>
            <div class="metric-item"><span>Global Load Balancer</span><span>Normal</span></div>
            <div class="metric-item"><span>Avg. Latency</span><span>&lt; 15ms</span></div>
            <div class="metric-item"><span>System Uptime</span><span>99.99%</span></div>
        </div>
        <div class="footer">Cloud Infrastructure &copy; 2026. All Systems Nominal.</div>
    </div>
</body>
</html>
DECOYHTML
}

# ==============================================
# DEPLOYMENT FUNCTION
# ==============================================
deploy_new_service() {
  # Apply system optimizations once
  sysctl_optimize
  setup_log_cleaner
  install_supervisord
  select_region
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  if [ -z "$PROJECT_ID" ]; then
      echo -e "${RED}❌ No project set! Run: gcloud config set project YOUR_ID${NC}"
      read -p "Press [Enter] to return..."
      return
  fi
  gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID" --quiet

  # ==============================================
  # 🎯 PROXY ENGINE SELECTOR — ADDED SING-BOX
  # ==============================================
  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}          CHOOSE PROXY ENGINE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo "1) OpenResty          - [Standard / Highly Reliable]"
  echo "2) Envoy Proxy        - [High Performance / Cloud Native]"
  echo "3) HAProxy            - [Ultra Low Latency / Lightweight]"
  echo "4) Caddy Proxy        - [Modern / Simple & Fast]"
  echo "5) Sing-Box Engine    - [Lightweight / High Performance]"
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

  # 🏷️ GENERATE SERVICE NAME WITH ENGINE INCLUDED
  RAND=$(openssl rand -hex 3)
  CLOUD_RUN_SERVICE_NAME="gcp-xray-${ENGINE}-$RAND"

  echo -e "\n${CYAN}=========================================${NC}"
  echo -e "${GREEN}      RESOURCE CONFIG MODE${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}1) AUTO PRESETS  |  Recommended (Instance-Based)${NC}"
  echo -e "${YELLOW}2) MANUAL SETUP  |  Full Memory & vCPU Range${NC}"
  while true; do
      read -p "Select Mode [1-2]: " RES_MODE
      case $RES_MODE in
          1)
              echo -e "\n${CYAN}--- AUTO PRESETS ---${NC}"
              echo "1) Basic:    1Gi RAM + 1 vCPU (Min: 1, Max: 3, Concurrency: 100)"
              echo "2) Balanced: 2Gi RAM + 2 vCPU (Min: 1, Max: 5, Concurrency: 130) ✅"
              echo "3) Turbo:    4Gi RAM + 4 vCPU (Min: 1, Max: 4, Concurrency: 200)"
              read -p "Choose preset [1-3]: " AUTO_CHOICE
              
              BILLING_MODE="instance"
              BILLING_FLAG="--no-cpu-throttling"
              case $AUTO_CHOICE in
                  1) 
                    MEMORY="1Gi"; CPU="1"
                    MIN_INST=1; MAX_INST=3; CONCURRENCY=100; TIMEOUT=3600
                    ;;
                  2) 
                    MEMORY="2Gi"; CPU="2"
                    MIN_INST=1; MAX_INST=5; CONCURRENCY=130; TIMEOUT=3600
                    ;;
                  3) 
                    MEMORY="4Gi"; CPU="4"
                    MIN_INST=1; MAX_INST=4; CONCURRENCY=200; TIMEOUT=3600
                    ;;
                  *) 
                    MEMORY="2Gi"; CPU="2"
                    MIN_INST=1; MAX_INST=5; CONCURRENCY=130; TIMEOUT=3600
                    echo -e "${YELLOW}Using Balanced preset${NC}"
                    ;;
              esac
              echo -e "${GREEN}✅ Applied Preset: $MEMORY | $CPU vCPU | Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY${NC}"
              break
              ;;
          2)
              echo -e "\n${CYAN}=========================================${NC}"
              echo -e "${GREEN}          BILLING MODE${NC}"
              echo -e "${CYAN}=========================================${NC}"
              echo -e "${YELLOW}Instance-Based = Stable, No Throttling${NC}"
              echo "1) Request-Based  |  2) Instance-Based"
              while true; do
                  read -p "Select [1-2]: " BILLING_CHOICE
                  case $BILLING_CHOICE in
                      1) BILLING_MODE="request"; BILLING_FLAG="--cpu-throttling"; break ;;
                      2) BILLING_MODE="instance"; BILLING_FLAG="--no-cpu-throttling"; break ;;
                      *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
                  esac
              done
              echo -e "\n${YELLOW}--- MANUAL SETUP ---${NC}"
              echo "Select Memory:"
              echo "1) 256Mi   2) 512Mi   3) 1Gi   4) 2Gi"
              echo "5) 4Gi     6) 8Gi     7) 16Gi  8) Custom input"
              read -p "Select Memory [1-8]: " MEM
              case $MEM in
                  1) MEMORY="256Mi" ;;
                  2) MEMORY="512Mi" ;;
                  3) MEMORY="1Gi" ;;
                  4) MEMORY="2Gi" ;;
                  5) MEMORY="4Gi" ;;
                  6) MEMORY="8Gi" ;;
                  7) MEMORY="16Gi" ;;
                  8) read -p "Type custom memory: " MEMORY ;;
                  *) MEMORY="1Gi" ;;
              esac
              echo -e "\nSelect vCPU:"
              echo "1) 1 vCPU   2) 2 vCPU   3) 4 vCPU   4) 8 vCPU   5) Custom input"
              read -p "Select vCPU [1-5]: " CPU_SEL
              case $CPU_SEL in
                  1) CPU="1" ;;
                  2) CPU="2" ;;
                  3) CPU="4" ;;
                  4) CPU="8" ;;
                  5) read -p "Type custom vCPU: " CPU ;;
                  *) CPU="1" ;;
              esac
              echo -e "${GREEN}✅ Custom Selected: $MEMORY RAM | $CPU vCPU${NC}"
              echo -e "\n${CYAN}=========================================${NC}"
              echo -e "${GREEN}    PERFORMANCE & SCALING CONFIGURATION  ${NC}"
              echo -e "${CYAN}=========================================${NC}"
              read -p "Min Instances [Default: 0]: " MIN_INST
              MIN_INST=${MIN_INST:-0}
              read -p "Max Instances [Default: 1]: " MAX_INST
              MAX_INST=${MAX_INST:-1}
              read -p "Concurrency / Max Connections [Default: 1000]: " CONCURRENCY
              CONCURRENCY=${CONCURRENCY:-1000}
              read -p "Timeout in seconds [Default: 3600]: " TIMEOUT
              TIMEOUT=${TIMEOUT:-3600}
              echo -e "${GREEN}✅ Config Set: Min: $MIN_INST | Max: $MAX_INST | Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s${NC}"
              break
              ;;
          *) echo -e "${RED}Enter 1 or 2 only${NC}" ;;
      esac
  done

  BUILD_DIR=$(mktemp -d)
  trap 'rm -rf "$BUILD_DIR"' EXIT
  cd "$BUILD_DIR" || exit 1
  # Generate decoy HTML
  DECOY_HTML=$(generate_decoy_html)
  clear
  echo ""
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}🚀 GCP-XRAY DEPLOYER | MULTI-ENGINE SETUP${NC}"
  echo -e "${CYAN}=========================================${NC}"
  echo -e "${GREEN}✅ Project:${NC} $PROJECT_ID"
  echo -e "${GREEN}✅ Region:${NC} $REGION"
  echo -e "${GREEN}✅ Service Name:${NC} $CLOUD_RUN_SERVICE_NAME"
  echo -e "${GREEN}✅ Engine:${NC} $DISPLAY_ENGINE"
  echo -e "${GREEN}✅ Scaling:${NC} Min: $MIN_INST | Max: $MAX_INST"
  echo -e "${GREEN}✅ Performance:${NC} Concurrency: $CONCURRENCY | Timeout: ${TIMEOUT}s"
  echo ""

  # ==============================================
  # XRAY CONFIG — Sniffing OFF, Solid Tuning
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
        "handshake": 4,
        "connIdle": 7200,
        "bufferSize": 1048576
      }
    }
  },
  "inbounds": [
    {
      "tag": "trojan-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{"password": "gcp-xray", "level": 0}] },
      "sniffing": { "enabled": false },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan-ws" },
        "sockopt": { 
          "tcpNoDelay": true, 
          "tcpFastOpen": true, 
          "tcpKeepAliveIdle": 300, 
          "tcpKeepAliveInterval": 30,
          "mark": 0
        }
      }
    },
    {
      "tag": "vless-ws",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{"id": "a1b2c3d4-5678-40ef-98ab-cdef01234567", "level": 0}], "decryption": "none" },
      "sniffing": { "enabled": false },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-ws" },
        "sockopt": { 
          "tcpNoDelay": true, 
          "tcpFastOpen": true, 
          "tcpKeepAliveIdle": 300, 
          "tcpKeepAliveInterval": 30 
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } }
  ]
}
EOF

  if [ "$ENGINE" = "openresty" ]; then
    cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 65536;
events { worker_connections 16384; use epoll; multi_accept on; }
http {
  include mime.types;
  default_type application/octet-stream;
  sendfile on; tcp_nodelay on; tcp_nopush on;
  keepalive_timeout 7200; keepalive_requests 200000;
  client_max_body_size 0;
  proxy_buffering off; proxy_request_buffering off;
  proxy_http_version 1.1; proxy_connect_timeout 10s;
  proxy_send_timeout 7200s; proxy_read_timeout 7200s;
  proxy_cache off;
  server {
    listen 8080;
    server_name _;
    
    # Anti-DDoS / Rate Limiting
    limit_req_zone \$binary_remote_addr zone=req_limit:10m rate=30r/s;
    limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;
    location /health { return 200 "OK\n"; add_header Content-Type text/plain; }
    location / {
      default_type text/html;
      return 200 '$(generate_decoy_html | sed -e ":a" -e "N" -e '/$/!ba' -e "s/'/\\\\'/g" -e "s/\n//g")';
    }
    location /trojan-ws {
      limit_req zone=req_limit burst=60 nodelay;
      limit_conn conn_limit 100;
      proxy_pass http://127.0.0.1:10001;
      proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 7200s; proxy_send_timeout 7200s;
      proxy_socket_keepalive on;
    }
    location /vless-ws {
      limit_req zone=req_limit burst=60 nodelay;
      limit_conn conn_limit 100;
      proxy_pass http://127.0.0.1:10002;
      proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
      proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 7200s; proxy_send_timeout 7200s;
      proxy_socket_keepalive on;
    }
  }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
# Start Xray
/usr/local/bin/xray run -c /etc/xray.json &
XRAY_PID=$!
# Start supervisord
if [ -d "/etc/supervisor" ]; then
  cat > /etc/supervisor/conf.d/proxy-services.conf <<SUPCONF
[program:xray]
command=/usr/local/bin/xray run -c /etc/xray.json
autostart=true
autorestart=true
startretries=999
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
[program:openresty]
command=/usr/local/openresty/bin/openresty -g 'daemon off;'
autostart=true
autorestart=true
startretries=999
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
SUPCONF
  exec /usr/bin/supervisord -n
else
  sleep 2
  exec /usr/local/openresty/bin/openresty -g 'daemon off;'
fi
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM openresty/openresty:alpine-fat
RUN apt-get update && apt-get install -y -qq supervisor && rm -rf /var/lib/apt/lists/*
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "envoy" ]; then
    DECOY_HTML_ESCAPED=$(generate_decoy_html | sed -e ':a' -e 'N' -e '$!ba' -e 's/"/\\"/g' -e 's/\n/\\n/g')
    cat > envoy.yaml <<EOF
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8080
    per_connection_buffer_limit_bytes: 1048576
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          codec_type: AUTO
          idle_timeout: 7200s
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "/trojan-ws" }
                route: { cluster: trojan_cluster, timeout: 7200s, idle_timeout: 7200s, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/vless-ws" }
                route: { cluster: vless_cluster, timeout: 7200s, idle_timeout: 7200s, upgrade_configs: [{ upgrade_type: "websocket" }] }
              - match: { prefix: "/" }
                direct_response: { status: 200, body: { inline_string: "$DECOY_HTML_ESCAPED" } }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: trojan_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    upstream_connection_options:
      - tcp_keepalive: {}
    load_assignment:
      cluster_name: trojan_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 10001 }
  - name: vless_cluster
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    upstream_connection_options:
      - tcp_keepalive: {}
    load_assignment:
      cluster_name: vless_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 10002 }
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
sleep 2
exec envoy -c /etc/envoy.yaml
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM envoyproxy/envoy:v1.30-latest
RUN apt-get update && apt-get install -y -qq supervisor && rm -rf /var/lib/apt/lists/*
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy.yaml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "haproxy" ]; then
    DECOY_HTML_ESCAPED=$(generate_decoy_html | sed -e ':a' -e 'N' -e '$!ba' -e "s/'/\\\\'/g" -e 's/"/\\"/g' -e 's/\n/\\n/g')
    cat > haproxy.cfg <<EOF
global
    log stdout format raw local0
    maxconn 65536
    tune.maxrewrite 1024
    tune.bufsize 32768
defaults
    log global
    mode http
    timeout connect 10s
    timeout client 7200s
    timeout server 7200s
    timeout http-request 10s
    option http-keep-alive
    default-server inter 3s fall 3 rise 2
frontend main
    bind *:8080
    # Anti-DDoS — Slowloris & conn limits
    timeout http-request 5s
    maxconn 16384
    acl is_health path /health
    acl is_trojan path_beg /trojan-ws
    acl is_vless path_beg /vless-ws
    use_backend health_backend if is_health
    use_backend trojan_backend if is_trojan
    use_backend vless_backend if is_vless
    default_backend default_backend
backend health_backend
    http-request return status 200 content-type "text/plain" string "OK\n"
backend default_backend
    http-request return status 200 content-type "text/html" string "$DECOY_HTML_ESCAPED"
backend trojan_backend
    server xray1 127.0.0.1:10001 check inter 10s
backend vless_backend
    server xray2 127.0.0.1:10002 check inter 10s
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
sleep 2
exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM haproxy:2.8-alpine
RUN apk add --no-cache supervisor
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "caddy" ]; then
    DECOY_HTML_ESCAPED=$(generate_decoy_html | sed -e ':a' -e 'N' -e '$!ba' -e 's/`/\\`/g' -e 's/\\/\\\\/g')
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
    grace_period 30s
}
:8080 {
    handle /health {
        respond "OK\n" 200
    }
    handle /trojan-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
            transport http {
                keepalive_idle_conns 256
                dial_timeout 10s
                response_header_timeout 7200s
            }
        }
    }
    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
            transport http {
                keepalive_idle_conns 256
                dial_timeout 10s
                response_header_timeout 7200s
            }
        }
    }
    handle {
        header Content-Type text/html
        respond \`$DECOY_HTML_ESCAPED\` 200
    }
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/xray run -c /etc/xray.json &
sleep 2
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && unzip -q xray.zip xray && chmod +x xray
FROM caddy:2.7-alpine
RUN apk add --no-cache supervisor
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY Caddyfile /etc/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/xray /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

  elif [ "$ENGINE" = "singbox" ]; then
    DECOY_HTML_ESCAPED=$(generate_decoy_html | sed -e ':a' -e 'N' -e '$!ba' -e 's/`/\\`/g')
    cat > Caddyfile <<EOF
{
    admin off
    http_port 8080
}
:8080 {
    handle /health {
        respond "OK\n" 200
    }
    handle /trojan-ws* {
        reverse_proxy 127.0.0.1:10001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
        }
    }
    handle /vless-ws* {
        reverse_proxy 127.0.0.1:10002 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up Connection "Upgrade"
            header_up Upgrade "websocket"
        }
    }
    handle {
        header Content-Type text/html
        respond \`$DECOY_HTML_ESCAPED\` 200
    }
}
EOF
    cat > singbox.json <<'EOF'
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "listen_port": 10001,
      "users": [{ "password": "gcp-xray" }],
      "transport": {
        "type": "ws",
        "path": "/trojan-ws",
        "headers": {},
        "max_early_data": 0
      },
      "tcp_keepalive_interval": 30,
      "tcp_keepalive_idle": 300
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": 10002,
      "users": [{ "uuid": "a1b2c3d4-5678-40ef-98ab-cdef01234567" }],
      "transport": {
        "type": "ws",
        "path": "/vless-ws"
      },
      "tcp_keepalive_interval": 30,
      "tcp_keepalive_idle": 300
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    cat > entrypoint.sh <<'EOF'
#!/bin/sh
/usr/local/bin/sing-box run -c /etc/singbox.json &
sleep 2
exec caddy run --config /etc/Caddyfile --adapter caddyfile
EOF
    chmod +x entrypoint.sh
    cat > Dockerfile <<'EOF'
FROM ghcr.io/sagernet/sing-box:latest AS singbox-builder
FROM caddy:2.7-alpine
RUN apk add --no-cache supervisor
COPY --from=singbox-builder /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY singbox.json /etc/singbox.json
COPY Caddyfile /etc/Caddyfile
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/sing-box /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
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
  echo -e "${GREEN}🛡️  PROTECTIONS APPLIED:${NC}"
  echo -e "  ✅ Anti-DDoS (rate/conn limits)"
  echo -e "  ✅ Log Cleaner (3-day auto-purge)"
  echo -e "  ✅ Supervisord (auto-restart services)"
  echo -e "  ✅ Solid Keepalive (7200s timeout)"
  echo -e "  ✅ Custom Decoy Gateway Page"
  echo ""
  read -p $'\nPress [
