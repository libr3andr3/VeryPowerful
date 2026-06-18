#!/usr/bin/env bash
# VeryPowerful - VPS Setup
# =========================
# curl -fsSL https://yaya.sh/vp-server-setup.sh | sudo bash
#
# Interactive wizard that sets up a VeryPowerful VPS:
#   - WireGuard hub (accepts peer connections)
#   - nginx L4 SNI stream proxy (routes by domain, never decrypts)
#   - Provisioning daemon (REST API for peer registration)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
info() { echo -e "  ${BLUE}ℹ${NC} $*"; }
step() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}\n"; }
prompt() { echo -ne "  ${BOLD}→${NC} $1 "; }

if [[ $EUID -ne 0 ]]; then
    err "This script must run as root. Use: sudo bash vp-server-setup.sh"
    exit 1
fi

# ── Banner ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${CYAN}║${NC}        ${BOLD}VeryPowerful - VPS Setup${NC}              ${BOLD}${CYAN}║${NC}"
echo -e "  ${BOLD}${CYAN}║${NC}    WireGuard hub + nginx L4 SNI proxy        ${BOLD}${CYAN}║${NC}"
echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}This sets up your VPS to accept WireGuard peers and${NC}"
echo -e "  ${DIM}route HTTPS traffic by domain - without decrypting anything.${NC}"
echo ""

# ── Config ──────────────────────────────────────────────────────────────────

WG_INTERFACE="${VP_WG_INTERFACE:-wg0}"
WG_SUBNET="${VP_WG_SUBNET:-10.0.0.0/24}"
WG_PORT="${VP_WG_PORT:-51820}"
VP_LISTEN_PORT="${VP_LISTEN_PORT:-9090}"
VP_STATE_DIR="${VP_STATE_DIR:-/var/lib/verypowerful}"

# ── Gather info ─────────────────────────────────────────────────────────────

step "Step 1 - Your VPS details"

if [[ -n "${VP_PUBLIC_ENDPOINT:-}" ]]; then
    PUBLIC_ENDPOINT="$VP_PUBLIC_ENDPOINT"
    info "Using VP_PUBLIC_ENDPOINT=${PUBLIC_ENDPOINT}"
else
    DETECTED=$(curl -fsSL --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
               curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$DETECTED" ]]; then
        info "Detected public IP: ${BOLD}${DETECTED}${NC}"
        prompt "Use this IP? [Y/n]:"
        read -r USE_DETECTED
        if [[ "${USE_DETECTED,,}" == "n" || "${USE_DETECTED,,}" == "no" ]]; then
            prompt "Enter your VPS public IP or hostname:"
            read -r PUBLIC_ENDPOINT
        else
            PUBLIC_ENDPOINT="$DETECTED"
        fi
    else
        prompt "Could not detect IP. Enter your VPS public IP or hostname:"
        read -r PUBLIC_ENDPOINT
    fi
fi

echo ""

step "Step 2 - API key"

if [[ -n "${VP_API_KEY:-}" ]]; then
    API_KEY=$( "Using VP_API_KEY from environment"
else
    echo -e "  ${DIM}The provision API needs an API key for authentication.${NC}"
    echo -e "  ${DIM}We can generate one for you, or you can provide your own.${NC}"
    echo ""
    prompt "Generate a random API key? [Y/n]:"
    read -r GEN_KEY
    if [[ "${GEN_KEY,,}" == "n" || "${GEN_KEY,,}" == "no" ]]; then
        prompt "Enter your API key:"
        read -r -s API_KEY
        echo ""
    else
        API_KEY=$( -c "import secrets; print(secrets.token_urlsafe(32))")
        log "Generated API key"
        echo ""
        echo -e "  ${BOLD}Your API key:${NC}"
        echo -e "  ${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
        echo -e "  ${CYAN}│${NC} ${BOLD}${GREEN}**...EN}${NC} ${CYAN}│${NC}"
        echo -e "  ${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  ${DIM}↑ Copy this key and save it. You will need it to register peers.${NC}"
        echo ""
    fi
fi

echo ""

step "Step 3 - Let's Encrypt email (for nginx fallback cert)"

if [[ -n "${VP_LETSENCRYPT_EMAIL:-}" ]]; then
    LE_EMAIL="$VP_LETSENCRYPT_EMAIL"
    info "Using VP_LETSENCRYPT_EMAIL=${LE_EMAIL}"
else
    prompt "Email for SSL certificate notifications:"
    read -r LE_EMAIL
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
step "Ready to install"
echo -e "  Public IP:    ${BOLD}${PUBLIC_ENDPOINT}${NC}"
echo -e "  WG subnet:    ${WG_SUBNET}"
echo -e "  WG port:      ${WG_PORT}"
echo -e "  API port:     ${VP_LISTEN_PORT}"
echo -e "  API key:      ${BOLD}**...DIM}(hidden)${NC}"
echo ""
prompt "Proceed with installation? [Y/n]:"
read -r CONFIRM
if [[ "${CONFIRM,,}" == "n" || "${CONFIRM,,}" == "no" ]]; then
    echo "Aborted."
    exit 0
fi

# ── 1. Install packages ─────────────────────────────────────────────────────

step "Step 4 - Installing packages"

if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq wireguard-tools nginx libnginx-mod-stream python3 curl coreutils
elif command -v dnf &>/dev/null; then
    dnf install -y wireguard-tools nginx python3 curl coreutils
elif command -v apk &>/dev/null; then
    apk add wireguard-tools nginx nginx-mod-stream python3 curl
else
    err "Unsupported package manager. Install: wireguard-tools, nginx, python3, curl"
    exit 1
fi
log "Packages installed"

# ── 2. WireGuard hub ────────────────────────────────────────────────────────

step "Step 5 - WireGuard hub"

if wg show "$WG_INTERFACE" &>/dev/null && [[ -z "${VP_FORCE:-}" ]]; then
    warn "WireGuard $WG_INTERFACE already exists. Set VP_FORCE=1 to overwrite."
else
    [[ -n "${VP_FORCE:-}" ]] && wg-quick down "$WG_INTERFACE" 2>/dev/null || true

    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/${WG_INTERFACE}.private | wg pubkey > /etc/wireguard/${WG_INTERFACE}.public
    VPS_PRIVATE=$(cat /etc/wireguard/${WG_INTERFACE}.private)
    VPS_PUBLIC=$(cat /etc/wireguard/${WG_INTERFACE}.public)

    cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
PrivateKey = ${VPS_PRIVATE}
Address    = $(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')/24
ListenPort = ${WG_PORT}
MTU        = 1420

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -I FORWARD -i %i -j ACCEPT
PostDown = nft delete rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
EOF

    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
    systemctl enable "wg-quick@${WG_INTERFACE}"
    systemctl restart "wg-quick@${WG_INTERFACE}"
    log "WireGuard hub started - VPS IP: 10.0.0.1"
fi

# Ensure IP forwarding
if ! grep -q '^net.ipv4.ip_forward.*=.*1' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-verypowerful.conf
    sysctl -p /etc/sysctl.d/99-verypowerful.conf
fi

VPS_PUBLIC=$(cat "/etc/wireguard/${WG_INTERFACE}.public" 2>/dev/null || wg show "$WG_INTERFACE" public-key 2>/dev/null || echo "")

echo ""
echo -e "  ${BOLD}Your VPS WireGuard public key:${NC}"
echo -e "  ${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${CYAN}│${NC} ${BOLD}${GREEN}${VPS_PUBLIC}${NC} ${CYAN}│${NC}"
echo -e "  ${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${DIM}↑ This is the VPS public key. Peers need this to connect.${NC}"
echo ""

# ── 3. nginx L4 SNI proxy ───────────────────────────────────────────────────

step "Step 6 - nginx stream proxy"

# Backup existing nginx.conf
if [[ -f /etc/nginx/nginx.conf ]] && ! grep -q "VeryPowerful" /etc/nginx/nginx.conf 2>/dev/null; then
    cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up existing nginx.conf"
fi

# Fallback cert
mkdir -p /etc/nginx/certs
if [[ ! -f /etc/nginx/certs/fallback.key ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/fallback.key \
        -out /etc/nginx/certs/fallback.crt \
        -subj "/CN=verypowerful-fallback" 2>/dev/null
fi

# Stream access log
touch /var/log/nginx/stream-access.log
chown www-data:www-data /var/log/nginx/stream-access.log
chmod 644 /var/log/nginx/stream-access.log

# SNI include files
NGINX_SNI_MAP="/etc/nginx/stream-sni-map.conf"
NGINX_SNI_MATRIX="/etc/nginx/stream-sni-map-8448.conf"

cat > "$NGINX_SNI_MAP" <<'EOF'
# VeryPowerful SNI map - managed by provision server
default 127.0.0.1:9443;
EOF

cat > "$NGINX_SNI_MATRIX" <<'EOF'
# VeryPowerful Matrix federation SNI map
default 127.0.0.1:9443;
EOF

# nginx.conf
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    log_format metrics '\$ssl_preread_server_name \$bytes_sent \$bytes_received '
                       '\$session_time \$time_iso8601 \$remote_addr';
    access_log /var/log/nginx/stream-access.log metrics buffer=64k flush=30s;

    map \$ssl_preread_server_name \$backend {
        include $NGINX_SNI_MAP;
    }

    map \$ssl_preread_server_name \$backend_8448 {
        include $NGINX_SNI_MATRIX;
    }

    server {
        listen 443;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 3600s;
    }

    server {
        listen 80;
        proxy_pass $(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".2"}'):80;
        proxy_connect_timeout 10s;
        proxy_timeout 60s;
    }

    server {
        listen 8448;
        proxy_pass \$backend_8448;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 3600s;
    }
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 127.0.0.1:9443 ssl;
        ssl_certificate     /etc/nginx/certs/fallback.crt;
        ssl_certificate_key /etc/nginx/certs/fallback.key;
        ssl_reject_handshake on;
    }

    server {
        listen 127.0.0.1:8080;
        location /health { return 200 "ok\\n"; add_header Content-Type text/plain; }
    }
}
EOF

if nginx -t 2>/dev/null; then
    systemctl enable nginx
    systemctl restart nginx
    log "nginx configured and running"
else
    err "nginx -t failed!"
    nginx -t 2>&1 || true
    exit 1
fi

# ── 4. Provision server ──────────────────────────────────────────────────────

step "Step 7 - Provisioning daemon"

PROVISION_SCRIPT="/usr/local/bin/verypowerful-provision"

# Check if provision.py is in the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/provision.py" ]]; then
    cp "$SCRIPT_DIR/provision.py" "$PROVISION_SCRIPT"
else
    curl -fsSL -o "$PROVISION_SCRIPT" \
        "https://raw.githubusercontent.com/libr3andr3/VeryPowerful/main/server/provision.py"
fi
chmod +x "$PROVISION_SCRIPT"

mkdir -p "$VP_STATE_DIR"
chmod 750 "$VP_STATE_DIR"

# Env file
mkdir -p /etc/verypowerful
cat > /etc/verypowerful/env <<EOF
VP_API_KEY=${API_K...IC_ENDPOINT=${PUBLIC_ENDPOINT}
VP_WG_INTERFACE=${WG_INTERFACE}
VP_WG_SUBNET=${WG_SUBNET}
VP_STATE_DIR=${VP_STATE_DIR}
VP_NGINX_SNI_MAP=${NGINX_SNI_MAP}
VP_NGINX_SNI_MATRIX=${NGINX_SNI_MATRIX}
VP_LISTEN_PORT=${VP_LISTEN_PORT}
EOF
chmod 600 /etc/verypowerful/env

# Systemd service
PYTHON3=$(command -v python3 || echo "/usr/bin/python3")

cat > /etc/systemd/system/verypowerful-provision.service <<EOF
[Unit]
Description=VeryPowerful Provisioning Server
After=network.target wg-quick@${WG_INTERFACE}.service nginx.service
Wants=wg-quick@${WG_INTERFACE}.service nginx.service

[Service]
Type=simple
ExecStart=${PYTHON3} ${PROVISION_SCRIPT}
EnvironmentFile=/etc/verypowerful/env
Restart=always
RestartSec=10
User=root
WorkingDirectory=${VP_STATE_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable verypowerful-provision
systemctl restart verypowerful-provision

sleep 2
if systemctl is-active --quiet verypowerful-provision; then
    log "Provision server running on port ${VP_LISTEN_PORT}"
else
    err "Provision server failed. Check: journalctl -u verypowerful-provision -n 20"
    exit 1
fi

# ── 5. Firewall ──────────────────────────────────────────────────────────────

step "Step 8 - Firewall"

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow ${WG_PORT}/udp comment "VeryPowerful WireGuard"
    ufw allow 80/tcp comment "VeryPowerful HTTP"
    ufw allow 443/tcp comment "VeryPowerful HTTPS"
    ufw allow 8448/tcp comment "VeryPowerful Matrix"
    ufw allow ${VP_LISTEN_PORT}/tcp comment "VeryPowerful API"
    log "UFW rules added"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port=${WG_PORT}/udp --add-port=443/tcp --add-port=80/tcp --add-port=8448/tcp --add-port=${VP_LISTEN_PORT}/tcp
    firewall-cmd --reload
    log "FirewallD rules added"
else
    warn "No firewall detected. Ensure ports are open:"
    warn "  ${WG_PORT}/udp (WireGuard), 80, 443, 8448, ${VP_LISTEN_PORT}/tcp"
fi

# ── 6. Done ──────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║${NC}        ${BOLD}VeryPowerful - VPS Ready!${NC}               ${BOLD}${GREEN}║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Endpoint:     ${BOLD}${PUBLIC_ENDPOINT}${NC}"
echo -e "  WG port:      ${BOLD}${WG_PORT}${NC}"
echo -e "  WG pubkey:    ${BOLD}${VPS_PUBLIC:0:16}...${NC}"
echo -e "  API port:     ${BOLD}${VP_LISTEN_PORT}${NC}"
echo ""
echo -e "  ${DIM}Share this with your users:${NC}"
echo -e "  ${BOLD}curl -fsSL https://yaya.sh/install.sh | bash${NC}"
echo ""
echo -e "  ${DIM}They will need:${NC}"
echo -e "  ${DIM}  Server:  ${PUBLIC_ENDPOINT}:${VP_LISTEN_PORT}${NC}"
echo -e "  ${DIM}  API key:  ${API_KE...DIM}${NC}"
echo ""
echo -e "  ${BOLD}${GREEN}Ready for peers.${NC}"
echo ""

# Save server info
mkdir -p "$VP_STATE_DIR"
cat > "${VP_STATE_DIR}/.server-info" <<EOF
VP_SERVER=${PUBLIC_ENDPOINT}:${VP_LISTEN_PORT}
VP_API_KEY=${API_KEY}
VP_VPS_PUBKEY=${VPS_PUBLIC}
VP_WG_PORT=${WG_PORT}
VP_WG_SUBNET=${WG_SUBNET}
EOF
