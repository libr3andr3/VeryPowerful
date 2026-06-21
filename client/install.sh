#!/usr/bin/env bash
# VeryPowerful Client Install
# curl -fsSL https://yaya.sh/install.sh | bash
#
# Two terminals. Copy keys. Done.
# Terminal 1: VPS — shows its pubkey and endpoint
# Terminal 2 (this one): local machine — shows its pubkey, accepts VPS key

set -euo pipefail
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; W='\033[1m'; D='\033[2m'; N='\033[0m'
ok()  { echo -e "  ${G}OK${N}  $*"; }
warn(){ echo -e "  ${Y}!!${N}  $*"; }
die() { echo -e "  ${R}ERR${N} $*"; exit 1; }
hdr() { echo -e "\n${W}${C}=== $* ===${N}\n"; }

clear 2>/dev/null || true
echo -e "${W}${C}"
echo "  ╔══════════════════════════════════════╗"
echo "  ║   VeryPowerful — Client Install     ║"
echo "  ║   VPN ingress for your home lab     ║"
echo "  ╚══════════════════════════════════════╝"
echo -e "${N}"
echo -e "  ${D}You'll need a second terminal with the VPS setup script open.${N}"
echo -e "  ${D}Copy keys between terminals. No accounts. Just keys.${N}"
echo ""

# ── Detect OS ─────────────────────────────────────────────────────
hdr "Checking your system"
. /etc/os-release 2>/dev/null || true
OS="${ID:-unknown}"
echo -e "  OS: ${W}${OS}${N}"

# ── Install WireGuard ─────────────────────────────────────────────
hdr "Installing WireGuard"
if command -v wg &>/dev/null; then
    ok "WireGuard already installed"
else
    case "$OS" in
        debian|ubuntu|linuxmint|pop) sudo apt-get update -qq && sudo apt-get install -y -qq wireguard-tools resolvconf curl ;;
        fedora|rhel|centos|rocky)    sudo dnf install -y wireguard-tools curl ;;
        arch|manjaro)                sudo pacman -S --noconfirm wireguard-tools curl ;;
        *) die "Unsupported OS. Install wireguard-tools + curl manually." ;;
    esac
    ok "WireGuard installed"
fi

# ── Check existing ─────────────────────────────────────────────────
if wg show wg0 &>/dev/null 2>&1 && [ -z "${VP_FORCE:-}" ]; then
    die "WireGuard wg0 already running. Set VP_FORCE=1 to overwrite, or clean up: sudo wg-quick down wg0"
fi

# ── Generate keys ─────────────────────────────────────────────────
hdr "Your WireGuard keys"
mkdir -p ~/.wireguard && chmod 700 ~/.wireguard

if [ ! -f ~/.wireguard/verypowerful.private ]; then
    umask 077
    wg genkey > ~/.wireguard/verypowerful.private
    wg pubkey < ~/.wireguard/verypowerful.private > ~/.wireguard/verypowerful.public
    echo -e "  ${G}New keypair generated${N}"
else
    echo -e "  ${D}Using existing keypair${N}"
fi

CLIENT_PUB=$(cat ~/.wireguard/verypowerful.public)
CLIENT_PRIV=$(cat ~/.wireguard/verypowerful.private)

echo ""
echo -e "  ${W}COPY THIS KEY to the VPS terminal:${N}"
echo -e "  ${C}┌────────────────────────────────────────────────────────────┐${C}"
echo -e "  ${C}│${N} ${G}${CLIENT_PUB}${N} ${C}│${C}"
echo -e "  ${C}└────────────────────────────────────────────────────────────┘${C}"
echo ""

# ── Get VPS info ──────────────────────────────────────────────────
hdr "VPS connection details"
echo -e "  ${D}Now look at the VPS terminal. Copy these values from there:${N}"
echo ""

read -r -p "  Paste VPS public key: " VPS_PUB
[ -z "$VPS_PUB" ] && die "VPS public key is required"

read -r -p "  Paste VPS endpoint (IP:port, e.g. 103.89.12.145:51820): " VPS_EP
[ -z "$VPS_EP" ] && die "VPS endpoint is required"
VPS_HOST="${VPS_EP%:*}"
VPS_PORT="${VPS_EP##*:}"
[ "$VPS_PORT" = "$VPS_EP" ] && VPS_PORT=51820

echo ""
read -r -p "  Your WireGuard IP (from VPS terminal, e.g. 10.0.0.2): " CLIENT_IP
[ -z "$CLIENT_IP" ] && die "WG IP is required"

echo ""
read -r -p "  Your domain for SNI routing (optional, e.g. myhomelab.com): " DOMAIN

# ── Write config ───────────────────────────────────────────────────
hdr "Configuring WireGuard"
sudo mkdir -p /etc/wireguard

sudo tee /etc/wireguard/wg0.conf > /dev/null <<WGCONF
# VeryPowerful — Home Node WireGuard Spoke
# VPS: ${VPS_HOST}:${VPS_PORT}  |  Your IP: ${CLIENT_IP}

[Interface]
PrivateKey = ${CLIENT_PRIV}
Address    = ${CLIENT_IP}/24
MTU        = 1420

[Peer]
PublicKey           = ${VPS_PUB}
Endpoint            = ${VPS_HOST}:${VPS_PORT}
AllowedIPs          = 10.0.0.0/24
PersistentKeepalive = 25
WGCONF

sudo chmod 600 /etc/wireguard/wg0.conf
ok "Config written to /etc/wireguard/wg0.conf"

# ── Start tunnel ───────────────────────────────────────────────────
hdr "Starting the tunnel"
sudo wg-quick down wg0 2>/dev/null || true
sudo wg-quick up wg0

sleep 2
if wg show wg0 &>/dev/null 2>&1; then
    ok "Tunnel established!"
    wg show wg0 | grep -E "interface|peer|endpoint|handshake|transfer" || true
else
    die "Tunnel failed to start. Check: sudo journalctl -u wg-quick@wg0 -n 20"
fi
sudo systemctl enable wg-quick@wg0 2>/dev/null || true

# ── Optional: Egress proxy through VPS ─────────────────────────────
echo ""
hdr "Optional — Route outbound traffic through VPS"
echo -e "  ${D}If the VPS has tinyproxy installed, you can route${N}"
echo -e "  ${D}your outbound HTTP/HTTPS traffic through the VPS.${N}"
echo -e "  ${D}All API calls will appear to come from the VPS IP.${N}"
echo ""
read -r -p "  Use VPS egress proxy? [y/N]: " USE_PROXY

if [ "${USE_PROXY,,}" = "y" ] || [ "${USE_PROXY,,}" = "yes" ]; then
    PROXY_PORT="${VP_PROXY_PORT:-8888}"
    PROXY_URL="http://10.0.0.1:${PROXY_PORT}"

    echo ""
    echo -e "  ${W}Proxy URL: ${C}${PROXY_URL}${N}"
    echo ""
    echo -e "  ${D}Add these to your services (Docker, systemd, shell):${N}"
    echo -e "  ${W}  HTTP_PROXY=${PROXY_URL}${N}"
    echo -e "  ${W}  HTTPS_PROXY=${PROXY_URL}${N}"
    echo -e "  ${W}  NO_PROXY=localhost,127.0.0.1,10.0.0.0/24${N}"
    echo ""

    # Test the proxy
    if command -v curl &>/dev/null; then
        echo -e "  ${D}Testing proxy connection...${N}"
        if HTTP_CODE=$(curl -x "$PROXY_URL" -s -o /dev/null -w '%{http_code}' --max-time 5 http://httpbin.org/ip 2>/dev/null); then
            if [ "$HTTP_CODE" = "200" ]; then
                IP=$(curl -x "$PROXY_URL" -s --max-time 5 http://httpbin.org/ip 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('origin','?'))" 2>/dev/null || echo "?")
                ok "Proxy working — egress IP: ${IP}"
            else
                warn "Proxy returned HTTP ${HTTP_CODE} — check VPS setup"
            fi
        else
            warn "Could not reach proxy at ${PROXY_URL} — is tinyproxy running on VPS?"
        fi
    fi

    # Offer to set system-wide proxy
    echo ""
    read -r -p "  Set system-wide proxy in /etc/environment? [y/N]: " SET_SYSTEM
    if [ "${SET_SYSTEM,,}" = "y" ] || [ "${SET_SYSTEM,,}" = "yes" ]; then
        sudo tee -a /etc/environment > /dev/null <<ENVEOF
HTTP_PROXY=${PROXY_URL}
HTTPS_PROXY=${PROXY_URL}
NO_PROXY=localhost,127.0.0.1,10.0.0.0/24
ENVEOF
        ok "Proxy set in /etc/environment (applies on next login)"
        echo -e "  ${Y}Run 'source /etc/environment' to apply now.${N}"
    fi
else
    echo -e "  ${D}Skipping egress proxy.${N}"
fi

# ── Optional: Caddy for TLS ───────────────────────────────────────
if [ -n "$DOMAIN" ]; then
    echo ""
    hdr "Optional — Caddy for auto TLS"
    echo -e "  ${D}Caddy will get Let's Encrypt certs for ${DOMAIN}.${N}"
    echo -e "  ${D}Traffic arrives through the WireGuard tunnel.${N}"
    read -r -p "  Install Caddy? [Y/n]: " ANS
    if [ "${ANS,,}" != "n" ] && [ "${ANS,,}" != "no" ]; then
        case "$OS" in
            debian|ubuntu|linuxmint|pop)
                sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https 2>/dev/null || true
                curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
                curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
                sudo apt-get update -qq && sudo apt-get install -y -qq caddy ;;
            fedora|rhel|centos|rocky)
                sudo dnf install -y 'dnf-command(copr)' && sudo dnf copr enable -y @caddy/caddy && sudo dnf install -y caddy ;;
            arch|manjaro)
                sudo pacman -S --noconfirm caddy ;;
        esac

        read -r -p "  Email for Let's Encrypt notifications: " CADDY_EMAIL
        IP_CLEAN="${CLIENT_IP%/*}"
        sudo mkdir -p /etc/caddy
        sudo tee /etc/caddy/Caddyfile > /dev/null <<CADDYEOF
{
    email ${CADDY_EMAIL:-admin@localhost}
}
:80 {
    bind ${IP_CLEAN}
    redir https://{host}{uri} permanent
}
${DOMAIN} {
    bind ${IP_CLEAN}
    handle {
        respond "VeryPowerful node - TLS OK" 200
    }
}
CADDYEOF
        sudo systemctl enable caddy && sudo systemctl restart caddy
        ok "Caddy installed. Edit /etc/caddy/Caddyfile to add your services."
    fi
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo -e "  ${G}${W}VeryPowerful — Connected!${N}"
echo ""
echo -e "  Your WG IP:   ${W}${CLIENT_IP}${N}"
echo -e "  VPS endpoint: ${W}${VPS_HOST}:${VPS_PORT}${N}"
[ -n "$DOMAIN" ] && echo -e "  Domain:       ${W}${DOMAIN}${N}"
echo ""
echo -e "  ${G}Your home lab has a public face.${N}"
[ -n "$DOMAIN" ] && echo -e "  ${D}Next: point DNS A record for ${DOMAIN} -> ${VPS_HOST}${N}"
echo ""
