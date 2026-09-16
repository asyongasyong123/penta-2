#!/bin/bash
set -euo pipefail

# ===================================================
# 🚀 GCP-XHTTP DUAL-STACK DEPLOYER — MUX AUTO ON/OFF
# ✅ ENGINES: OPENRESTY, ENVOY, HAPROXY, CADDY
# ✅ SAME PATH = Works with Mux.Cool ON or OFF automatically
# ✅ FIXED CREDENTIALS as requested
# ===================================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# ==============================================
# FIXED CREDENTIALS — NO RANDOMIZATION
# ==============================================
VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"
TROJAN_PASS="gcp-xray"
PATH_TROJAN="/trojan-xhttp"
PATH_VLESS="/vless-xhttp"

echo -e "\n${GREEN}🔐 Credentials:${NC}"
echo "VLESS UUID:      $VLESS_UUID"
echo "Trojan Password: $TROJAN_PASS"
echo "Trojan Path:     $PATH_TROJAN"
echo "VLESS Path:      $PATH_VLESS"

# ==============================================
# AUTO INSTALL JQ IF MISSING
# ==============================================
if ! command -v jq &> /dev/null; then
  echo -e "\n${YELLOW}⚠️ Installing jq...${NC}"
  sudo apt update -qq && sudo apt install -y jq
fi

# ==============================================
# SELECT ENGINE
# ==============================================
echo -e "\n${CYAN}Select Reverse-Proxy Engine:${NC}"
echo "1) OpenResty (Nginx-based)"
echo "2) Envoy"
echo "3) HAProxy"
echo "4) Caddy"
read -p "Enter choice [1-4]: " ENGINE_CHOICE

case $ENGINE_CHOICE in
  1) ENGINE="openresty" ;;
  2) ENGINE="envoy" ;;
  3) ENGINE="haproxy" ;;
  4) ENGINE="caddy" ;;
  *) echo -e "${RED}❌ Invalid choice${NC}"; exit 1 ;;
esac

# ==============================================
# SELECT REGION
# ==============================================
echo -e "\n${CYAN}Select Region:${NC}"
echo "1) us-central1   🇺🇸 Iowa"
echo "2) asia-southeast1 🇸🇬 Singapore"
echo "3) asia-northeast1 🇯🇵 Tokyo"
echo "4) us-east1       🇺🇸 South Carolina"
read -p "Enter choice [1-4]: " REGION_CHOICE

case $REGION_CHOICE in
  1) REGION="us-central1" ;;
  2) REGION="asia-southeast1" ;;
  3) REGION="asia-northeast1" ;;
  4) REGION="us-east1" ;;
  *) echo -e "${RED}❌ Invalid choice${NC}"; exit 1 ;;
esac

SERVICE_NAME="gcp-xhttp-dual-${ENGINE}"

# ==============================================
# XRAY CONFIG — DUAL MUX MODE
# ==============================================
cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "none"
  },
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
    "strategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 3600,
        "bufferSize": 524288
      }
    }
  },
  "inbounds": [
    {
      "tag": "trojan-xhttp",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "$TROJAN_PASS", "level": 0}]
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$PATH_TROJAN",
          "mux": {
            "enabled": true,
            "concurrency": 4,
            "maxConnections": 4,
            "padding": true
          },
          "no_mux": {
            "enabled": true,
            "concurrency": 1,
            "padding": false
          }
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 30
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "vless-xhttp",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$VLESS_UUID", "flow": "xtls-rprx-vision", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$PATH_VLESS",
          "mux": {
            "enabled": true,
            "concurrency": 4,
            "maxConnections": 4,
            "padding": true
          },
          "no_mux": {
            "enabled": true,
            "concurrency": 1,
            "padding": false
          }
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 30
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "blackhole", "tag": "blocked", "settings": {"response": {"type": "none"}}}
  ]
}
EOF

# ==============================================
# DECOY PAGE
# ==============================================
cat > decoy.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Service Status</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#f5f7fa;color:#333;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
.card{background:#fff;border-radius:12px;box-shadow:0 4px 20px rgba(0,0,0,.08);padding:32px;max-width:480px;width:100%;text-align:center}
h1{font-size:22px;margin-bottom:12px;color:#1a1a1a}
p{color:#666;line-height:1.6;margin-bottom:8px}
.status{display:inline-flex;align-items:center;gap:8px;background:#e8f5e9;color:#2e7d32;padding:6px 14px;border-radius:20px;font-weight:500;margin:16px 0}
.dot{width:8px;height:8px;background:#2e7d32;border-radius:50%}
</style>
</head>
<body>
<div class="card">
<h1>All Systems Operational</h1>
<span class="status"><span class="dot"></span> Running Normally</span>
<p>Service is online and available.</p>
</div>
</body>
</html>
EOF

# ==============================================
# ENGINE CONFIGS
# ==============================================
if [ "$ENGINE" = "openresty" ]; then
  cat > nginx.conf <<'EOF'
worker_processes auto;
worker_rlimit_nofile 10240;
events { worker_connections 4096; multi_accept on; use epoll; }
http {
  sendfile on; tcp_nodelay on; tcp_nopush off;
  keepalive_timeout 3600; keepalive_requests 100000;
  client_max_body_size 0; proxy_max_temp_file_size 0;
  proxy_connect_timeout 10s; proxy_send_timeout 3600s; proxy_read_timeout 3600s;
  proxy_buffering off; proxy_request_buffering off; proxy_socket_keepalive on;
  proxy_http_version 1.1; proxy_cache off;
  server {
    listen 8080;
    location /health { return 200 "OK\n"; }
    location /trojan-xhttp {
      proxy_pass http://127.0.0.1:10001;
      proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
      proxy_read_timeout 3600s; proxy_send_timeout 3600s;
    }
    location /vless-xhttp {
      proxy_pass http://127.0.0.1:10002;
      proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
      proxy_read_timeout 3600s; proxy_send_timeout 3600s;
    }
    location / { root /usr/share/nginx/html; try_files $uri /decoy.html; }
  }
}
EOF

elif [ "$ENGINE" = "envoy" ]; then
  cat > envoy.yaml <<'EOF'
static_resources:
  listeners:
  - name: listener_0
    address: { socket_address: { address: 0.0.0.0, port_value: 8080 } }
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
              - match: { path: "/health" }
                direct_response: { status: 200, body: { inline_string: "OK\n" } }
              - match: { prefix: "/trojan-xhttp" }
                route: { cluster: trojan_xhttp, timeout: 3600s }
              - match: { prefix: "/vless-xhttp" }
                route: { cluster: vless_xhttp, timeout: 3600s }
              - match: { prefix: "/" }
                direct_response: { status: 200, body: { filename: "/etc/decoy.html" } }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: {}
  clusters:
  - name: trojan_xhttp
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: trojan_xhttp
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10001 } } }
  - name: vless_xhttp
    connect_timeout: 10s
    type: STATIC
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: vless_xhttp
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10002 } } }
EOF

elif [ "$ENGINE" = "haproxy" ]; then
  cat > haproxy.cfg <<'EOF'
global
  log stdout format raw local0
  maxconn 10000
defaults
  log global
  mode http
  timeout connect 10s
  timeout client 3600s
  timeout server 3600s
frontend main
  bind *:8080
  acl is_health path /health
  acl is_trojan path_beg /trojan-xhttp
  acl is_vless path_beg /vless-xhttp
  use_backend health_backend if is_health
  use_backend trojan_backend if is_trojan
  use_backend vless_backend if is_vless
  default_backend decoy_backend
backend health_backend
  http-request return status 200 content-type text/plain string "OK"
backend trojan_backend
  server s1 127.0.0.1:10001
backend vless_backend
  server s1 127.0.0.1:10002
backend decoy_backend
  errorfile 200 /etc/decoy.http
EOF
  printf "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n%s" "$(cat decoy.html)" > decoy.http

elif [ "$ENGINE" = "caddy" ]; then
  cat > Caddyfile <<'EOF'
{
  admin off
  http_port 8080
  servers {
    strict_sni off
    max_header_size 1MB
  }
}
:8080 {
  handle /health { respond "OK" 200 }
  handle /trojan-xhttp* {
    reverse_proxy 127.0.0.1:10001 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      flush_interval -1
    }
  }
  handle /vless-xhttp* {
    reverse_proxy 127.0.0.1:10002 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      flush_interval -1
    }
  }
  handle {
    header Content-Type text/html
    respond `<!DOCTYPE html><html><head><title>Service Status</title></head><body style="font-family:system-ui;padding:2rem;text-align:center"><h1>All Systems Operational</h1><p>Service online — latency normal</p></body></html>`
  }
}
EOF
fi

# ==============================================
# DOCKERFILE
# ==============================================
XRAY_VERSION="1.8.24"

if [ "$ENGINE" = "openresty" ]; then
  cat > Dockerfile <<EOF
FROM alpine:3.20
RUN apk add --no-cache openresty wget ca-certificates tzdata
RUN wget -qO- https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip | unzip -d /usr/local/bin/ - && chmod +x /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY decoy.html /usr/share/nginx/html/decoy.html
EXPOSE 8080
CMD ["/bin/sh", "-c", "xray run -c /etc/xray/config.json & exec openresty -g 'daemon off;'"]
EOF

elif [ "$ENGINE" = "envoy" ]; then
  cat > Dockerfile <<EOF
FROM teddysun/xray:latest AS xray-bin
FROM envoyproxy/envoy:v1.31.10
COPY --from=xray-bin /usr/bin/xray /usr/local/bin/
COPY config.json /etc/xray.json
COPY envoy.yaml /etc/envoy/envoy.yaml
COPY decoy.html /etc/decoy.html
EXPOSE 8080
CMD ["/bin/sh", "-c", "xray run -c /etc/xray.json & sleep 2 && exec envoy -c /etc/envoy/envoy.yaml"]
EOF

elif [ "$ENGINE" = "haproxy" ]; then
  cat > Dockerfile <<EOF
FROM alpine:3.20
RUN apk add --no-cache haproxy wget ca-certificates tzdata
RUN wget -qO- https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip | unzip -d /usr/local/bin/ - && chmod +x /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY decoy.http /etc/decoy.http
EXPOSE 8080
CMD ["/bin/sh", "-c", "xray run -c /etc/xray/config.json & exec haproxy -f /etc/haproxy/haproxy.cfg"]
EOF

elif [ "$ENGINE" = "caddy" ]; then
  cat > Dockerfile <<EOF
FROM alpine:3.20
RUN apk add --no-cache caddy wget ca-certificates tzdata
RUN wget -qO- https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip | unzip -d /usr/local/bin/ - && chmod +x /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY Caddyfile /etc/Caddyfile
EXPOSE 8080
CMD ["/bin/sh", "-c", "xray run -c /etc/xray/config.json & exec caddy run --config /etc/Caddyfile"]
EOF
fi

# ==============================================
# DEPLOY TO CLOUD RUN
# ==============================================
echo -e "\n${CYAN}☁️ Building & Deploying to Cloud Run — $REGION...${NC}"
gcloud builds submit --tag gcr.io/$(gcloud config get project)/$SERVICE_NAME
gcloud run deploy $SERVICE_NAME \
  --image gcr.io/$(gcloud config get project)/$SERVICE_NAME \
  --platform managed \
  --region $REGION \
  --port 8080 \
  --memory 2Gi \
  --cpu 1 \
  --min-instances 0 \
  --max-instances 4 \
  --concurrency 80 \
  --allow-unauthenticated

SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format 'value(status.url)')
DOMAIN=$(echo "$SERVICE_URL" | sed 's|https://||')

# ==============================================
# READY-TO-COPY NETMOD LINKS
# ==============================================
echo -e "\n${GREEN}✅ DEPLOYMENT SUCCESS${NC}"
echo "Service URL: $SERVICE_URL"
echo -e "\n${CYAN}📱 NetMod Links — Same Path Works Mux ON or OFF${NC}"

echo -e "\n${YELLOW}─── TROJAN ───${NC}"
echo "Mux ON  → trojan://$TROJAN_PASS@$DOMAIN:443?security=tls&sni=$DOMAIN&type=xhttp&path=$PATH_TROJAN&mux=1#Trojan-Mux"
echo "Mux OFF → trojan://$TROJAN_PASS@$DOMAIN:443?security=tls&sni=$DOMAIN&type=xhttp&path=$PATH_TROJAN#Trojan-NoMux"

echo -e "\n${YELLOW}─── VLESS ───${NC}"
echo "Mux ON  → vless://$VLESS_UUID@$DOMAIN:443?security=tls&sni=$DOMAIN&type=xhttp&path=$PATH_VLESS&mux=1&flow=xtls-rprx-vision#VLESS-Mux"
echo "Mux OFF → vless://$VLESS_UUID@$DOMAIN:443?security=tls&sni=$DOMAIN&type=xhttp&path=$PATH_VLESS&flow=xtls-rprx-vision#VLESS-NoMux"

echo -e "\n${GREEN}💡 Master Tip: Toggle Mux in NetMod anytime — no config change needed!${NC}"
