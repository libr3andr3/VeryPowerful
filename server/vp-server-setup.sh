#!/usr/bin/env bash
# VeryPowerful — VPS Setup Script
# ================================
# Run this ONCE on your VPS to set up the provisioning server.
# It installs the WireGuard hub, nginx L4 SNI proxy, and the
# provisioning daemon that accepts peer registrations.
#
# Usage:
#   curl -fsSL https://campusgenie.ai/vp-server-setup.sh | sudo bash
#
# Or locally:
#   sudo bash server/vp-server-setup.sh
#
# What this does:
#   1. Installs wireguard-tools, nginx with stream module
#   2. Sets up WireGuard hub interface
#   3. Configures nginx as L4 SNI stream proxy
#   4. Installs the provisioning daemon (systemd service)
#   5. Prints your public key + endpoint for the client script

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

# ── Config (override via environment) ──────────────────────────────────────

WG_INTERFACE="${VP_WG_INTERFACE:-wg0}"
WG_SUBNET="${VP_WG_SUBNET:-10.0.0.0/24}"
WG_PORT="${VP_WG_PORT:-51820}"
WG_MTU="${VP_WG_MTU:-1420}"
VP_STATE_DIR="${VP_STATE_DIR:-/var/lib/verypowerful}"
VP_PROVISION_SCRIPT="${VP_PROVISION_SCRIPT:-/usr/local/bin/verypowerful-provision}"
NGINX_SNI_MAP="${VP_NGINX_SNI_MAP:-/etc/nginx/stream-sni-map.conf}"
NGINX_SNI_MATRIX="${VP_NGINX_SNI_MATRIX:-/etc/nginx/stream-sni-map-8448.conf}"
VP_LISTEN_PORT="${VP_LISTEN_PORT:-9090}"

# Detect public endpoint (can be overridden via VP_PUBLIC_ENDPOINT)
if [[ -n "${VP_PUBLIC_ENDPOINT:-}" ]]; then
    PUBLIC_ENDPOINT="$VP_PUBLIC_ENDPOINT"
else
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://checkip.amazonaws.com 2>/dev/null || \
                curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || \
                echo "DETECT_FAILED")
    if [[ "$PUBLIC_IP" == "DETECT_FAILED" ]]; then
        warn "Could not auto-detect public IP. Set VP_PUBLIC_ENDPOINT env var."
        warn "Usage: VP_PUBLIC_ENDPOINT=your.vps.ip sudo bash $0"
        PUBLIC_ENDPOINT="YOUR_VPS_IP"
    else
        PUBLIC_ENDPOINT="${PUBLIC_IP}"
    fi
fi

info "VeryPowerful VPS Setup"
info "──────────────────────"
info "WG Interface : $WG_INTERFACE"
info "WG Subnet    : $WG_SUBNET"
info "WG Port      : $WG_PORT"
info "Public IP    : $PUBLIC_ENDPOINT"
info "State Dir    : $VP_STATE_DIR"
info "API Port     : $VP_LISTEN_PORT"
echo ""

# ── Requirement check ──────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

# ── 1. Install packages ────────────────────────────────────────────────────

log "Installing packages..."

if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq wireguard-tools nginx libnginx-mod-stream python3 curl coreutils
elif command -v dnf &>/dev/null; then
    dnf install -y wireguard-tools nginx python3 curl coreutils
elif command -v yum &>/dev/null; then
    yum install -y wireguard-tools nginx python3 curl coreutils
elif command -v apk &>/dev/null; then
    apk add wireguard-tools nginx nginx-mod-stream python3 curl
else
    err "Unsupported package manager. Install manually: wireguard-tools, nginx, python3, curl"
    exit 1
fi

# ── 2. WireGuard Hub Setup ─────────────────────────────────────────────────

log "Setting up WireGuard hub..."

# Check if already configured
if wg show "$WG_INTERFACE" &>/dev/null; then
    warn "WireGuard interface $WG_INTERFACE already exists."
    warn "Skipping WireGuard setup. To redo: wg-quick down $WG_INTERFACE && rm /etc/wireguard/$WG_INTERFACE.conf"
else
    # Generate keys
    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/${WG_INTERFACE}.private | wg pubkey > /etc/wireguard/${WG_INTERFACE}.public
    VPS_PRIVATE=$(cat /etc/wireguard/${WG_INTERFACE}.private)
    VPS_PUBLIC=$(cat /etc/wireguard/${WG_INTERFACE}.public)

    # Create hub config
    cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
# VeryPowerful — VPS WireGuard Hub
# Managed by VeryPowerful provisioning server.
# Peers are added dynamically via the provision API.

[Interface]
PrivateKey = ${VPS_PRIVATE}
Address    = $(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')/24
ListenPort = ${WG_PORT}
MTU        = ${WG_MTU}

# Enable IP forwarding so nginx can open connections to spoke IPs
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -I FORWARD -i %i -j ACCEPT
PostDown = nft delete rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true

# No MASQUERADE — nginx opens connections FROM the VPS,
# return traffic routes back through the tunnel without NAT.

# Peers are added dynamically by VeryPowerful provision server.
# Run: wg set wg0 peer <PUBKEY> allowed-ips <IP>/32
EOF

    chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"

    # Enable and start
    systemctl enable "wg-quick@${WG_INTERFACE}"
    systemctl start "wg-quick@${WG_INTERFACE}"

    log "WireGuard hub started — VPS IP: $(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')"
    log "VPS public key: ${VPS_PUBLIC}"
fi

# Ensure IP forwarding is persistent
if ! grep -q '^net.ipv4.ip_forward.*=.*1' /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-verypowerful.conf
    sysctl -p /etc/sysctl.d/99-verypowerful.conf
fi

# ── 3. Nginx L4 SNI Stream Proxy ────────────────────────────────────────────

log "Setting up nginx L4 SNI stream proxy..."

# Back up existing nginx.conf if it looks important
if [[ -f /etc/nginx/nginx.conf ]] && ! grep -q "VeryPowerful" /etc/nginx/nginx.conf 2>/dev/null; then
    cp /etc/nginx/nginx.conf "/etc/nginx/nginx.conf.bak.$(date +%Y%m%d%H%M%S)"
    log "Backed up existing nginx.conf"
fi

# Generate fallback SSL cert (for unknown SNI hosts)
mkdir -p /etc/nginx/certs
if [[ ! -f /etc/nginx/certs/fallback.key ]]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/fallback.key \
        -out /etc/nginx/certs/fallback.crt \
        -subj "/CN=verypowerful-fallback" 2>/dev/null
    log "Generated fallback SSL certificate"
fi

# Pre-create stream access log with correct permissions
touch /var/log/nginx/stream-access.log
chown www-data:www-data /var/log/nginx/stream-access.log
chmod 644 /var/log/nginx/stream-access.log

# Create SNI map include files (managed by provision server)
cat > "$NGINX_SNI_MAP" <<'EOF'
# VeryPowerful SNI map — managed by provision.py
default 127.0.0.1:9443;
EOF

cat > "$NGINX_SNI_MATRIX" <<'EOF'
# VeryPowerful Matrix federation SNI map — managed by provision.py
default 127.0.0.1:9443;
EOF

# Write nginx.conf with stream includes
cat > /etc/nginx/nginx.conf <<EOF
# VeryPowerful — VPS L4 SNI Stream Proxy
# Reads SNI from TLS ClientHello (no decryption), forwards raw TCP
# to home nodes through the WireGuard tunnel.
#
# SNI entries are managed by the provision server:
#   $NGINX_SNI_MAP
#   $NGINX_SNI_MATRIX

user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    # Per-domain usage tracking
    log_format metrics '\$ssl_preread_server_name \$bytes_sent \$bytes_received '
                       '\$session_time \$time_iso8601 \$remote_addr';
    access_log /var/log/nginx/stream-access.log metrics buffer=64k flush=30s;

    # SNI hostname → WireGuard tunnel IP:port
    map \$ssl_preread_server_name \$backend {
        include $NGINX_SNI_MAP;
    }

    # Matrix federation (port 8448)
    map \$ssl_preread_server_name \$backend_8448 {
        include $NGINX_SNI_MATRIX;
    }

    # HTTPS — SNI routing
    server {
        listen 443;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_connect_timeout 10s;
        proxy_timeout 3600s;
    }

    # HTTP — forward to home node for ACME HTTP-01 + redirects
    server {
        listen 80;
        proxy_pass $(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".2"}'):80;
        proxy_connect_timeout 10s;
        proxy_timeout 60s;
    }

    # Matrix federation
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

    # Fallback TLS block — rejects unknown SNI hosts gracefully
    server {
        listen 127.0.0.1:9443 ssl;
        ssl_certificate     /etc/nginx/certs/fallback.crt;
        ssl_certificate_key /etc/nginx/certs/fallback.key;
        ssl_reject_handshake on;
    }

    # Health check
    server {
        listen 127.0.0.1:8080;
        location /health { return 200 "ok\\n"; add_header Content-Type text/plain; }
    }
}
EOF

# Test and reload nginx
if nginx -t 2>/dev/null; then
    systemctl enable nginx
    systemctl restart nginx
    log "Nginx configured and running"
else
    err "nginx -t failed! Check /etc/nginx/nginx.conf"
    nginx -t 2>&1 || true
    exit 1
fi

# ── 4. Provisioning Server Setup ────────────────────────────────────────────

log "Installing provisioning daemon..."

# Copy the provision script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/provision.py" ]]; then
    cp "$SCRIPT_DIR/provision.py" "$VP_PROVISION_SCRIPT"
elif [[ -f "/tmp/verypowerful-setup/server/provision.py" ]]; then
    cp "/tmp/verypowerful-setup/server/provision.py" "$VP_PROVISION_SCRIPT"
else
    # Download from GitHub
    warn "provision.py not found locally, downloading from GitHub..."
    curl -fsSL -o "$VP_PROVISION_SCRIPT" \
        "https://raw.githubusercontent.com/libr3andr3/VeryPowerful/main/server/provision.py"
fi
chmod +x "$VP_PROVISION_SCRIPT"

# Create state directory
mkdir -p "$VP_STATE_DIR"
chmod 750 "$VP_STATE_DIR"

# Generate API key if not set
if [[ -z "${VP_API_KEY:-}" ]]; then
    VP_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || \
                 openssl rand -base64 32 | tr -d '\n/+=')
    warn "Generated API key: ${VP_API_KEY}"
    warn "Save this! You'll need it for registering peers."
fi

# Create environment file
mkdir -p /etc/verypowerful
cat > /etc/verypowerful/env <<EOF
# VeryPowerful provisioning server environment
VP_API_KEY=${VP_API_KEY}
VP_PUBLIC_ENDPOINT=${PUBLIC_ENDPOINT}
VP_WG_INTERFACE=${WG_INTERFACE}
VP_WG_SUBNET=${WG_SUBNET}
VP_STATE_DIR=${VP_STATE_DIR}
VP_NGINX_SNI_MAP=${NGINX_SNI_MAP}
VP_NGINX_SNI_MATRIX=${NGINX_SNI_MATRIX}
VP_LISTEN_PORT=${VP_LISTEN_PORT}
EOF
chmod 600 /etc/verypowerful/env

# Create systemd service

# Determine python3 path
PYTHON3=$(command -v python3 || command -v python || echo "/usr/bin/python3")

cat > /etc/systemd/system/verypowerful-provision.service <<EOF
[Unit]
Description=VeryPowerful Provisioning Server
Documentation=https://github.com/libr3andr3/VeryPowerful
After=network.target wg-quick@${WG_INTERFACE}.service nginx.service
Wants=wg-quick@${WG_INTERFACE}.service nginx.service

[Service]
Type=simple
ExecStart=${PYTHON3} ${VP_PROVISION_SCRIPT}
EnvironmentFile=/etc/verypowerful/env
Restart=always
RestartSec=10
User=root
WorkingDirectory=${VP_STATE_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
MemoryMax=64M
CPUQuota=10%

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable verypowerful-provision
systemctl restart verypowerful-provision

sleep 1
if systemctl is-active --quiet verypowerful-provision; then
    log "Provisioning server running on 127.0.0.1:${VP_LISTEN_PORT}"
else
    err "Provisioning server failed to start."
    journalctl -u verypowerful-provision --no-pager -n 20
    exit 1
fi

# ── 5. Firewall ─────────────────────────────────────────────────────────────

log "Configuring firewall..."

# Try to detect firewall and open ports
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow ${WG_PORT}/udp comment "VeryPowerful WireGuard"
    ufw allow 80/tcp comment "VeryPowerful HTTP"
    ufw allow 443/tcp comment "VeryPowerful HTTPS"
    ufw allow 8448/tcp comment "VeryPowerful Matrix Federation"
    ufw allow ${VP_LISTEN_PORT}/tcp comment "VeryPowerful Provision API"
    log "UFW rules added"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
    firewall-cmd --permanent --add-port=${WG_PORT}/udp --add-port=443/tcp --add-port=80/tcp --add-port=8448/tcp --add-port=${VP_LISTEN_PORT}/tcp
    firewall-cmd --reload
    log "FirewallD rules added"
else
    warn "No active firewall detected or unrecognized firewall."
    warn "Ensure these ports are open: ${WG_PORT}/udp, 80/tcp, 443/tcp, 8448/tcp, ${VP_LISTEN_PORT}/tcp"
fi

# ── 6. Summary ──────────────────────────────────────────────────────────────

VP_SUBNET_BASE=$(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
VPS_PUBLIC_KEY=$(cat "/etc/wireguard/${WG_INTERFACE}.public" 2>/dev/null || wg show "$WG_INTERFACE" public-key 2>/dev/null || echo "UNKNOWN")

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VeryPowerful VPS Setup Complete!"
echo "══════════════════════════════════════════════════════════════════"
echo ""
echo "  API Key:    ${VP_API_KEY}"
echo "  Endpoint:   ${PUBLIC_ENDPOINT}"
echo "  WG Port:    ${WG_PORT}"
echo "  WG PubKey:  ${VPS_PUBLIC_KEY}"
echo "  WG Subnet:  ${WG_SUBNET}"
echo "  API Port:   ${VP_LISTEN_PORT} (public)"
echo ""
echo "  The provision API is exposed publicly on port ${VP_LISTEN_PORT}."
echo "  Set VP_LISTEN_HOST=127.0.0.1 in /etc/verypowerful/env to restrict it."
echo ""
echo "  Client install command (share this):"
echo "    curl -fsSL https://campusgenie.ai/install.sh | bash"
echo ""
echo "  Or with explicit server info:"
echo "    curl -fsSL https://campusgenie.ai/install.sh | VP_SERVER=${PUBLIC_ENDPOINT}:${VP_LISTEN_PORT} VP_API_KEY=${VP_API_KEY} bash"
echo ""
echo "  Manage peers:"
echo "    curl -H 'Authorization: Bearer ${VP_API_KEY}' http://127.0.0.1:${VP_LISTEN_PORT}/api/v1/peers | python3 -m json.tool"
echo "    curl -X DELETE -H 'Authorization: Bearer ${VP_API_KEY}' http://127.0.0.1:${VP_LISTEN_PORT}/api/v1/peers/10.0.0.3"
echo ""
echo "══════════════════════════════════════════════════════════════════"

# Save endpoint info for install.sh to reference
mkdir -p "$VP_STATE_DIR"
cat > "${VP_STATE_DIR}/.server-info" <<EOF
VP_SERVER=${PUBLIC_ENDPOINT}:${VP_LISTEN_PORT}
VP_API_KEY=${VP_API_KEY}
VP_VPS_PUBKEY=${VPS_PUBLIC_KEY}
VP_WG_PORT=${WG_PORT}
VP_WG_SUBNET=${WG_SUBNET}
EOF
