cat <<'EOF' > deploy.sh && chmod +x deploy.sh && ./deploy.sh
#!/bin/bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# OPENRESTY + VLESS/TROJAN — WS + XHTTP
# IMONG CREDENTIALS | IMONG PATHS | DILI MO-TIMEOUT
# ============================================================

# === IMONG CREDENTIALS — WALAY USAB ===
TROJAN_PASS="gcp-xray"
VLESS_UUID="a1b2c3d4-5678-40ef-98ab-cdef01234567"

# === IMONG PATHS — WALAY USAB ===
PATH_TR_WS="/trojan-ws"
PATH_VL_WS="/vless-ws"
PATH_TR_XH="/tr-xhttp"
PATH_VL_XH="/vl-xhttp"

# === DEPLOY SETTINGS ===
SERVICE_NAME="gcp-openresty-proxy"
REGION="us-central1"
CPU="2"
MEMORY="4Gi"
CONCURRENCY="500"
MIN_INST=1
MAX_INST=2
TIMEOUT="3600"

# ============================================================
rm -rf ~/gcp-openresty-proxy && mkdir -p ~/gcp-openresty-proxy && cd ~/gcp-openresty-proxy

# ============================================================
# XRAY CONFIG — VLESS + TROJAN | WS + XHTTP
# ============================================================
cat > config.json <<JSONEND
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4"],
    "queryStrategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 3600,
        "bufferSize": 2097152
      }
    }
  },
  "inbounds": [
    {
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "tag": "trojan-ws",
      "settings": { "clients": [{"password": "$TROJAN_PASS"}] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$PATH_TR_WS" },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tcpKeepAliveIdle": 30
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag": "vless-ws",
      "settings": {
        "clients": [{"id": "$VLESS_UUID", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$PATH_VL_WS" },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tcpKeepAliveIdle": 30
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "port": 10009,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag": "vless-xhttp",
      "settings": {
        "clients": [{"id": "$VLESS_UUID", "level": 0}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$PATH_VL_XH",
          "mode": "stream",
          "noGRPC": true,
          "heartbeat": 30000
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tcpKeepAliveIdle": 30
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "port": 10010,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "tag": "trojan-xhttp",
      "settings": { "clients": [{"password": "$TROJAN_PASS"}] },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$PATH_TR_XH",
          "mode": "stream",
          "noGRPC": true,
          "heartbeat": 30000
        },
        "sockopt": {
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 15,
          "tcpKeepAliveIdle": 30
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["trojan-ws", "vless-ws", "vless-xhttp", "trojan-xhttp"],
        "outboundTag": "direct"
      }
    ]
  }
}
JSONEND

# ============================================================
# NGINX CONFIG — KEEPALIVE + NO TIMEOUT
# ============================================================
cat > nginx.conf <<'CONFEND'
worker_processes auto;
worker_rlimit_nofile 16384;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nodelay on;
    keepalive_timeout 3600s;
    keepalive_requests 100000;

    # UPSTREAM + KEEPALIVE
    upstream tr_ws  { server 127.0.0.1:10001; keepalive 64; keepalive_timeout 3600s; }
    upstream vl_ws  { server 127.0.0.1:10002; keepalive 64; keepalive_timeout 3600s; }
    upstream vl_xh  { server 127.0.0.1:10009; keepalive 64; keepalive_timeout 3600s; }
    upstream tr_xh  { server 127.0.0.1:10010; keepalive 64; keepalive_timeout 3600s; }

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' '';
    }

    server {
        listen 8080;

        location = /health {
            access_log off;
            return 200 "OK\n";
        }

        # TROJAN-WS
        location ^~ /trojan-ws {
            proxy_pass http://tr_ws;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
            proxy_request_buffering off;
        }

        # VLESS-WS
        location ^~ /vless-ws {
            proxy_pass http://vl_ws;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
            proxy_request_buffering off;
        }

        # VLESS-XHTTP
        location ^~ /vl-xhttp {
            proxy_pass http://vl_xh;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 15s;
            proxy_buffering off;
            proxy_request_buffering off;
        }

        # TROJAN-XHTTP
        location ^~ /tr-xhttp {
            proxy_pass http://tr_xh;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 15s;
            proxy_buffering off;
            proxy_request_buffering off;
        }

        # Decoy Page
        location / {
            return 200 '<html><body style="font-family:system-ui;text-align:center;padding:3em;"><h1>✅ GCP-Proxy Active</h1></body></html>';
        }
    }
}
CONFEND

# ============================================================
# DOCKERFILE — QWIKLABS-SAFE
# ============================================================
cat > Dockerfile <<'DOCKEND'
FROM alpine:3.20 AS builder
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip && \
    unzip -q xray.zip xray && \
    chmod +x xray

FROM openresty/openresty:1.21.4.1-0-alpine
RUN mkdir -p /usr/local/bin
COPY --from=builder /xray /usr/local/bin/xray
COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080

CMD ["/bin/sh", "-c", \
    "xray run -c /etc/xray/config.json & \
    exec /usr/local/openresty/bin/openresty -g 'daemon off;'"]
DOCKEND

# ============================================================
# DEPLOY
# ============================================================
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --quiet 2>/dev/null || true

echo "🚀 Deploying $SERVICE_NAME..."
gcloud run deploy "$SERVICE_NAME" \
  --source . \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INST" \
  --max-instances "$MAX_INST" \
  --timeout "${TIMEOUT}s" \
  --execution-environment=gen2 \
  --no-cpu-throttling \
  --cpu-boost \
  --session-affinity

DOMAIN=$(gcloud run services describe "$SERVICE_NAME" --region "$REGION" --format='value(status.url)')
DOMAIN_CLEAN=${DOMAIN#https://}

echo
echo "============================================================"
echo "✅ DEPLOYMENT SUCCESS ✅"
echo "============================================================"
echo "Domain:    $DOMAIN_CLEAN"
echo "Port:      443"
echo "TLS/SNI:   ON"
echo
echo "🥇 VLESS-XHTTP (RECOMMENDED):"
echo "Network:   XHTTP"
echo "Path:      /vl-xhttp"
echo "Mode:      stream"
echo "UUID:      $VLESS_UUID"
echo
echo "🥈 TROJAN-XHTTP:"
echo "Network:   XHTTP"
echo "Path:      /tr-xhttp"
echo "Mode:      stream"
echo "Password:  $TROJAN_PASS"
echo
echo "🟢 VLESS-WS:"
echo "Network:   WebSocket"
echo "Path:      /vless-ws"
echo "UUID:      $VLESS_UUID"
echo
echo "🟢 TROJAN-WS:"
echo "Network:   WebSocket"
echo "Path:      /trojan-ws"
echo "Password:  $TROJAN_PASS"
echo "============================================================"
EOF
