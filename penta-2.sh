#!/bin/bash
set -euo pipefail

# ==============================================
# 🚀 GCP-XRAY — OPENRESTY = AUTO ALL PROTOCOLS
# ✅ Kung OpenResty → Awtomatikong WS+HU+XHTTP+gRPC
# ✅ Kung Envoy/HAProxy/Caddy → Mopili gihapon
# ✅ MOHUNONG SA PRESET — DILI MAG-DEPLOY
# ✅ Gitangtang: ASPI-SIX, Sing-Box
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
# TRANSPORT SELECTOR — conditional
# ==============================================
select_transport() {
  # Kung OpenResty → AUTO ALL, dili na mangutana
  if [ "$ENGINE" = "openresty" ]; then
    TRANS="all"
    DISPTR="WS+HU+XHTTP+gRPC (AUTO-ALL)"
    echo -e "\n${MAGENTA}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ OPENRESTY DETECTED → AUTO-ALL PROTOCOLS${NC}"
    echo -e "   ✅ WebSocket  ✅ HTTPUpgrade  ✅ XHTTP  ✅ gRPC"
    echo -e "${MAGENTA}═══════════════════════════════════════════${NC}"
    return 0
  fi

  # Kung lain nga engine → mopili ra gihapon
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
# DEPLOY — STOP AT PRESET ✅
# ==============================================
deploy_new_service() {
  select_region

  # First pilia ang ENGINE
  echo -e "\n${CYAN}SELECT ENGINE:${NC}"
  echo "──────────────────────────────────────────────"
  echo "  1) 🚀 OpenResty  → AUTO-ALL PROTOCOLS ✅"
  echo "     (WS + HTTPUpgrade + XHTTP + gRPC — tanan sabay)"
  echo "  2) Envoy         → Mopili og transport"
  echo "  3) HAProxy       → Mopili og transport"
  echo "  4) Caddy         → Mopili og transport"
  echo "──────────────────────────────────────────────"
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

  # Transport selector — AUTO kung OpenResty
  select_transport

  PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
  [ -z "$PROJECT_ID" ] && { echo -e "${RED}Run: gcloud config set project YOUR_ID${NC}"; return; }

  RAND=$(openssl rand -hex 2)
  NAME="gcp-xray-${ENGINE}-${TRANS}-${RAND}"

  echo -e "\n${CYAN}⚙️ RESOURCE PRESETS — QWIKLABS-SAFE${NC}"
  echo "──────────────────────────────────────────────"
  echo "  1) Light    → 512Mi/0.5vCPU | Min:0 Max:2 | Conc:80"
  echo "  2) Balanced → 1Gi/1vCPU     | Min:0 Max:2 | Conc:80  ✅ RECOMMENDED"
  echo "  3) Max      → 2Gi/2vCPU     | Min:0 Max:3 | Conc:80"
  echo "──────────────────────────────────────────────"
  while true; do
    read -p "Preset [1-3]: " PCH
    case $PCH in
      1) MEMORY="512Mi"; CPU="0.5"; MIN_INST=0; MAX_INST=2; CONCURRENCY=80; break ;;
      3) MEMORY="2Gi"; CPU="2"; MIN_INST=0; MAX_INST=3; CONCURRENCY=80; break ;;
      2|*) MEMORY="1Gi"; CPU="1"; MIN_INST=0; MAX_INST=2; CONCURRENCY=80; break ;;
    esac
  done

  # ==============================================
  # ✅ MOHUNONG DINHI — DILI MAG-BUILD/DEPLOY
  # ==============================================
  echo -e "\n${GREEN}════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}✅ ALL SETTINGS CONFIRMED — STOPPED HERE${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════${NC}"
  echo -e "📦 Service Name:   $NAME"
  echo -e "📍 Region:        $REGION"
  echo -e "⚙️ Engine:        $DISPENGINE"
  echo -e "🔌 Transport:     $DISPTR"
  echo -e "💾 Memory:        $MEMORY"
  echo -e "🖥️ CPU:           $CPU vCPU"
  echo -e "🔄 Min Instances: $MIN_INST"
  echo -e "🔄 Max Instances: $MAX_INST"
  echo -e "🔂 Concurrency:   $CONCURRENCY"
  if [ "$ENGINE" = "openresty" ]; then
    echo -e "${CYAN}📋 Endpoints:${NC}"
    echo -e "   WS-Trojan:    /trojan-ws"
    echo -e "   WS-Vless:     /vless-ws"
    echo -e "   HU-Trojan:    /trojan-hu"
    echo -e "   HU-Vless:     /vless-hu"
    echo -e "   XH-Trojan:    /trojan-xh"
    echo -e "   XH-Vless:     /vless-xh"
    echo -e "   gRPC-Trojan:  /trojangrpc"
    echo -e "   gRPC-Vless:   /vlessgrpc"
  fi
  echo -e "${YELLOW}⚠️ Build & Deploy step SKIPPED as requested${NC}"
  echo -e "${GREEN}════════════════════════════════════════════════${NC}"
  echo -e "\nPress Enter to return to Menu..."
  read -r
}

# ==============================================
# MAIN MENU
# ==============================================
while true; do
  clear
  echo -e "${CYAN}"
  echo "╔════════════════════════════════════════════════════╗"
  echo "║  🚀 GCP-XRAY — OPENRESTY=AUTO-ALL v2.2               ║"
  echo "║  OpenResty = TANAN PROTOCOLS awtomatik ✅            ║"
  echo "║  Stop at Preset — NO auto deploy                    ║"
  echo "╚════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "  1) 🚀 CONFIGURE SERVICE"
  echo "  2) 📋 LIST DEPLOYED SERVICES"
  echo "  3) 🗑️ DELETE SERVICE"
  echo "  0) ❌ EXIT"
  echo ""
  read -p "Choice [0-3]: " MAIN_CHOICE
  case $MAIN_CHOICE in
    1) deploy_new_service ;;
    2) list_deployed_services ;;
    3) delete_service ;;
    0) echo -e "${GREEN}Bye! 👋${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid choice${NC}"; sleep 1 ;;
  esac
done
