#!/usr/bin/env bash
# VeryPowerful VPS Setup
# curl -fsSL https://yaya.sh/vp-server-setup.sh | sudo bash
#
# Two terminals. Copy keys. Done.
# Terminal 1 (this one): VPS — shows its pubkey, accepts peer key + domain
# Terminal 2:          local machine — shows its pubkey, accepts VPS key

set -euo pipefail
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; W='\033[1m'; D='\033[2m'; N='\033[0m'
ok()  { echo -e "  ${G}OK${N}  $*"; }
warn(){ echo -e "  ${Y}!!${N}  $*"; }
die() { echo -e "  ${R}ERR${N} $*"; exit 1; }
hdr() { echo -e "\n${W}${C}=== $* ===${N}\n"; }

[ "$EUID" -ne 0 ] && die "Must run as root. Use: sudo bash"

clear 2>/dev/null || true
echo -e "${W}${C}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║     VeryPowerful — VPS Setup        ║"
echo "  ║   WireGuard hub + nginx SNI proxy   ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${N}"
echo -e "  ${D}You'll need a second terminal with the client script open.${N}"
echo -e "  ${D}Copy keys between terminals. No API. No accounts. Just keys.${N}"
echo ""

# ── Config ────────────────────────────────────────────────────────
WG_IFACE="${VP_WG_IFACE:-wg0}"
WG_PORT="${VP_WG_PORT:-51820}"
WG_SUBNET="${VP_WG_SUBNET:-10.0.0.0/24}"
VPS_IP=$(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3".1"}')
HOME_IP_BASE=$(echo "$WG_SUBNET" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')

# ── Install packages ──────────────────────────────────────────────
hdr "Installing packages"
if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y -qq wireguard-tools nginx libnginx-mod-stream curl
elif command -v dnf &>/dev/null; then
    dnf install -y wireguard-tools nginx curl
else
    die "Unsupported OS. Install wireguard-tools, nginx, curl manually."
fi
ok "Packages installed"

# ── WireGuard hub ─────────────────────────────────────────────────
hdr "WireGuard hub"

if wg show "$WG_IFACE" &>/dev/null; then
    warn "WireGuard $WG_IFACE already running — reusing"
    VPS_PUB=$(wg show "$WG_IFACE" public-key)
else
    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/${WG_IFACE}.private | wg pubkey > /etc/wireguard/${WG_IFACE}.public
    VPS_PRIV=$(cat /etc/wireguard/${WG_IFACE}.private)
    VPS_PUB=$(cat /etc/wireguard/${WG_IFACE}.public)

    cat > /etc/wireguard/${WG_IFACE}.conf <<WGCONF
[Interface]
PrivateKey = ${VPS_PRIV}
Address    = ${VPS_IP}/24
ListenPort = ${WG_PORT}
MTU        = 1420
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = nft add rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -I FORWARD -i %i -j ACCEPT
PostDown = nft delete rule ip filter FORWARD iifname %i accept 2>/dev/null || iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true
WGCONF
    chmod 600 /etc/wireguard/${WG_IFACE}.conf
    systemctl enable wg-quick@${WG_IFACE} && systemctl restart wg-quick@${WG_IFACE}
    ok "WireGuard hub started — ${VPS_IP}"
fi

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-verypowerful.conf 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-verypowerful.conf 2>/dev/null || true

# Show VPS key for copying
echo ""
echo -e "  ${W}COPY THIS KEY to the other terminal:${N}"
echo -e "  ${C}┌────────────────────────────────────────────────────────────┐${C}"
echo -e "  ${C}│${N} ${G}${VPS_PUB}${N} ${C}│${C}"
echo -e "  ${C}└────────────────────────────────────────────────────────────┘${C}"
echo ""

# Detect public endpoint
PUBLIC_EP="${VP_PUBLIC_ENDPOINT:-}"
[ -z "$PUBLIC_EP" ] && PUBLIC_EP=$(curl -fsSL --max-time 5 https://checkip.amazonaws.com 2>/dev/null || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
[ -z "$PUBLIC_EP" ] && { read -r -p "  Enter VPS public IP: " PUBLIC_EP; }

echo -e "  VPS endpoint: ${W}${PUBLIC_EP}:${WG_PORT}${N}"
echo ""
echo -e "  ${D}Share this too. The other terminal needs it.${N}"

# ── nginx stream proxy ────────────────────────────────────────────
hdr "nginx L4 SNI stream proxy"

# Backup
[ -f /etc/nginx/nginx.conf ] && ! grep -q VeryPowerful /etc/nginx/nginx.conf && \
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%s) 2>/dev/null

# Fallback cert
mkdir -p /etc/nginx/certs
[ ! -f /etc/nginx/certs/fallback.key ] && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/certs/fallback.key \
        -out /etc/nginx/certs/fallback.crt \
        -subj /CN=fallback 2>/dev/null

# Stream access log
touch /var/log/nginx/stream-access.log
chown www-data:www-data /var/log/nginx/stream-access.log 2>/dev/null || true
chmod 644 /var/log/nginx/stream-access.log

# SNI include files (peer domains get added here)
cat > /etc/nginx/stream-sni-map.conf <<'EOF'
# VeryPowerful SNI map — add domains below
default 127.0.0.1:9443;
EOF

cat > /etc/nginx/stream-sni-map-8448.conf <<'EOF'
# VeryPowerful Matrix federation SNI map
default 127.0.0.1:9443;
EOF

# nginx config
cat > /etc/nginx/nginx.conf <<NGX
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 1024; }
stream {
    log_format m '\$ssl_preread_server_name \$bytes_sent \$bytes_received \$session_time \$time_iso8601 \$remote_addr';
    access_log /var/log/nginx/stream-access.log m buffer=64k flush=30s;
    map \$ssl_preread_server_name \$bk { include /etc/nginx/stream-sni-map.conf; }
    map \$ssl_preread_server_name \$bk8 { include /etc/nginx/stream-sni-map-8448.conf; }
    server { listen 443; proxy_pass \$bk; ssl_preread on; proxy_connect_timeout 10s; proxy_timeout 3600s; }
    server { listen 80; proxy_pass ${HOME_IP_BASE}.2:80; proxy_connect_timeout 10s; proxy_timeout 60s; }
    server { listen 8448; proxy_pass \$bk8; ssl_preread on; proxy_connect_timeout 10s; proxy_timeout 3600s; }
}
http {
    include /etc/nginx/mime.types; default_type application/octet-stream;
    server { listen 127.0.0.1:9443 ssl; ssl_certificate /etc/nginx/certs/fallback.crt; ssl_certificate_key /etc/nginx/certs/fallback.key; ssl_reject_handshake on; }
}
NGX

nginx -t && systemctl enable nginx && systemctl restart nginx && ok "nginx ready" || die "nginx config failed"

# ── Accept peers ──────────────────────────────────────────────────
NEXT_IP=2

while true; do
    echo ""
    hdr "Add a peer"

    echo -e "  ${D}Paste the peer's WireGuard PUBLIC key from the other terminal:${N}"
    read -r -p "  Peer public key: " PEER_KEY
    [ -z "$PEER_KEY" ] && { echo -e "  ${D}No more peers. Done.${N}"; break; }

    # Validate base64 key format
    if ! echo "$PEER_KEY" | grep -qE '^[A-Za-z0-9+/]{42,44}=?$'; then
        warn "Invalid WireGuard key format. Try again."
        continue
    fi

    echo ""
    echo -e "  ${D}Domain for this peer (for SNI routing, optional):${N}"
    read -r -p "  Domain: " PEER_DOMAIN

    PEER_IP="${HOME_IP_BASE}.${NEXT_IP}"

    # Add to WireGuard
    wg set "$WG_IFACE" peer "$PEER_KEY" allowed-ips "${PEER_IP}/32" 2>/dev/null || {
        warn "wg set failed, trying syncconf..."
        wg addconf "$WG_IFACE" <(echo "[Peer]"; echo "PublicKey = $PEER_KEY"; echo "AllowedIPs = ${PEER_IP}/32") 2>/dev/null || die "Failed to add WireGuard peer"
    }
    wg-quick save "$WG_IFACE" 2>/dev/null || true

    # Add SNI route if domain provided
    if [ -n "$PEER_DOMAIN" ]; then
        # Insert before the default line
        sed -i "/^default/i ${PEER_DOMAIN} ${PEER_IP}:443;" /etc/nginx/stream-sni-map.conf
        nginx -t && nginx -s reload && ok "SNI: ${PEER_DOMAIN} -> ${PEER_IP}:443" || warn "nginx reload failed"
    fi

    ok "Peer added — IP: ${PEER_IP}  Key: ${PEER_KEY:0:12}..."
    echo -e "  ${D}Tell them their IP: ${W}${PEER_IP}${N}"

    NEXT_IP=$((NEXT_IP + 1))

    echo ""
    read -r -p "  Add another peer? [y/N]: " MORE
    [ "${MORE,,}" != "y" ] && [ "${MORE,,}" != "yes" ] && break
done

# ── Firewall ──────────────────────────────────────────────────────
hdr "Firewall"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q active; then
    ufw allow ${WG_PORT}/udp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 8448/tcp
    ok "UFW rules added"
else
    echo -e "  ${Y}Ensure ports are open: ${WG_PORT}/udp, 80/tcp, 443/tcp, 8448/tcp${N}"
fi

# ── Optional: Egress proxy (tinyproxy) ────────────────────────────
echo ""
hdr "Optional — Egress proxy for peers"
echo -e "  ${D}Install a forward proxy so peers can route outbound traffic${N}"
echo -e "  ${D}(API calls, web requests) through this VPS.${N}"
echo -e "  ${D}Useful when peers want their traffic to exit from this IP.${N}"
echo ""
read -r -p "  Install tinyproxy egress proxy? [y/N]: " DO_PROXY

if [ "${DO_PROXY,,}" = "y" ] || [ "${DO_PROXY,,}" = "yes" ]; then
    PROXY_PORT="${VP_PROXY_PORT:-8888}"

    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq tinyproxy
    elif command -v dnf &>/dev/null; then
        dnf install -y tinyproxy
    else
        warn "Unknown package manager — install tinyproxy manually"
    fi

    if command -v tinyproxy &>/dev/null; then
        # Backup original config
        [ ! -f /etc/tinyproxy/tinyproxy.conf.bak ] && \
            cp /etc/tinyproxy/tinyproxy.conf /etc/tinyproxy/tinyproxy.conf.bak

        # Listen on VPS WG IP only
        sed -i "s/^#Listen .*/Listen ${VPS_IP}/; s/^Listen .*/Listen ${VPS_IP}/" /etc/tinyproxy/tinyproxy.conf

        # Replace default Allow with WG subnet
        sed -i '/^Allow 127.0.0.1/d; /^Allow ::1/d' /etc/tinyproxy/tinyproxy.conf
        echo "Allow ${WG_SUBNET}" >> /etc/tinyproxy/tinyproxy.conf

        # Set port
        sed -i "s/^Port .*/Port ${PROXY_PORT}/" /etc/tinyproxy/tinyproxy.conf

        systemctl enable tinyproxy && systemctl restart tinyproxy
        ok "Egress proxy running on ${VPS_IP}:${PROXY_PORT}"
        echo -e "  ${D}Peers set: HTTP_PROXY=http://${VPS_IP}:${PROXY_PORT}${N}"
        echo -e "  ${D}           HTTPS_PROXY=http://${VPS_IP}:${PROXY_PORT}${N}"
    else
        warn "tinyproxy not found after install — skipping"
    fi
else
    echo -e "  ${D}Skipping egress proxy.${N}"
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${G}${W}VeryPowerful VPS is ready.${N}"
echo ""
echo -e "  ${D}Next: on the other terminal, run:${N}"
echo -e "  ${W}curl -fsSL https://yaya.sh/install.sh | bash${N}"
echo ""
