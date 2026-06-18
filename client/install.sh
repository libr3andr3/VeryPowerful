#!/usr/bin/env bash
# VeryPowerful - One-Command Install
# ===================================
# curl -fsSL https://yaya.sh/install.sh | bash
#
# Interactive wizard that sets up a persistent WireGuard VPN tunnel
# to a VeryPowerful VPS. The VPS never sees your plaintext.
#
# What this does:
#   1. Detects your OS, installs wireguard-tools
#   2. Generates a WireGuard keypair (shows public key for copying)
#   3. Asks for your VPS address, API key, and domain
#   4. Registers with the VPS provisioning server
#   5. Configures and starts the WireGuard tunnel
#   6. Optionally installs Caddy for auto-TLS

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
heading() { echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ── Banner ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${CYAN}║${NC}         ${BOLD}VeryPowerful${NC} - VPN Ingress           ${BOLD}${CYAN}║${NC}"
echo -e "  ${BOLD}${CYAN}║${NC}     one command, your home lab goes live    ${BOLD}${CYAN}║${NC}"
echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}The VPS is a dumb L4 pipe. TLS terminates on YOUR machine.${NC}"
echo -e "  ${DIM}Nobody sees your plaintext. Ever.${NC}"
echo ""

# ── Detect OS ───────────────────────────────────────────────────────────────

step "Step 1 - Checking your system"

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_FAMILY=""
        case "$OS_ID" in
            debian|ubuntu|linuxmint|pop|elementary|zorin) OS_FAMILY="debian" ;;
            fedora|rhel|centos|rocky|almalinux|ol) OS_FAMILY="redhat" ;;
            arch|manjaro|endeavouros) OS_FAMILY="arch" ;;
            alpine) OS_FAMILY="alpine" ;;
            opensuse*|sles) OS_FAMILY="suse" ;;
            *) OS_FAMILY="unknown" ;;
        esac
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        OS_ID="macos"; OS_FAMILY="macos"
    else
        OS_ID="unknown"; OS_FAMILY="unknown"
    fi
}

detect_os
info "Detected: ${BOLD}${OS_ID}${NC}"

if [[ "$OS_FAMILY" == "macos" ]]; then
    err "macOS is not supported for VeryPowerful home nodes."
    err "Use a Linux server or VM instead."
    exit 1
fi

if [[ "$OS_FAMILY" == "unknown" ]]; then
    warn "Unrecognized OS - will try generic Linux approach."
fi

# ── Install WireGuard ────────────────────────────────────────────────────────

install_wireguard() {
    info "Installing wireguard-tools..."
    case "$OS_FAMILY" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq wireguard-tools resolvconf curl ;;
        redhat)
            sudo dnf install -y wireguard-tools curl ;;
        arch)
            sudo pacman -S --noconfirm wireguard-tools curl ;;
        alpine)
            sudo apk add wireguard-tools curl ;;
        suse)
            sudo zypper install -y wireguard-tools curl ;;
        *)
            warn "Cannot auto-install WireGuard."
            warn "Install wireguard-tools + curl manually: https://www.wireguard.com/install/"
            exit 1 ;;
    esac
}

if command -v wg &>/dev/null && command -v wg-quick &>/dev/null; then
    log "WireGuard already installed"
else
    install_wireguard
    log "WireGuard installed"
fi

# ── Check for existing tunnel ────────────────────────────────────────────────

for iface in wg0; do
    if wg show "$iface" &>/dev/null 2>&1; then
        warn "WireGuard interface '$iface' is already running."
        warn "This script uses wg0. Remove the existing one first:"
        warn "  sudo wg-quick down $iface"
        if [[ -z "${VP_FORCE:-}" ]]; then
            err "Set VP_FORCE=1 to overwrite, or clean up manually."
            exit 1
        fi
        info "VP_FORCE set - will overwrite existing $iface"
    fi
done

# ── Generate keys ────────────────────────────────────────────────────────────

step "Step 2 - Generating your WireGuard keys"

WG_DIR="${HOME}/.wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

PRIVATE_KEY_FILE="${WG_DIR}/verypowerful.private"
PUBLIC_KEY_FILE="${WG_DIR}/verypowerful.public"

if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    umask 077
    wg genkey > "$PRIVATE_KEY_FILE"
    wg pubkey < "$PRIVATE_KEY_FILE" > "$PUBLIC_KEY_FILE"
    log "New keypair generated"
else
    log "Using existing keypair"
fi

CLIENT_PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
CLIENT_PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")

echo ""
echo -e "  ${BOLD}Your WireGuard public key:${NC}"
echo -e "  ${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "  ${CYAN}│${NC} ${BOLD}${GREEN}${CLIENT_PUBLIC_KEY}${NC} ${CYAN}│${NC}"
echo -e "  ${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${DIM}↑ Copy this key. You will need it to register with the VPS.${NC}"
echo -e "  ${DIM}  Select the key with your mouse and press Ctrl+Shift+C${NC}"
echo ""

# ── Gather connection info ──────────────────────────────────────────────────

step "Step 3 - Where is your VPS?"

echo -e "  ${DIM}You need the address of the VeryPowerful VPS provision server.${NC}"
echo -e "  ${DIM}Example: vps.example.com:9090  or  103.89.12.145:9090${NC}"
echo ""

if [[ -n "${VP_SERVER:-}" ]]; then
    SERVER="${VP_SERVER}"
    info "Using VP_SERVER=${SERVER}"
else
    prompt "VPS server address (host:port):"
    read -r SERVER
fi

if [[ -z "$SERVER" ]]; then
    err "Server address is required."
    exit 1
fi

echo ""

step "Step 4 - API key (optional)"

echo -e "  ${DIM}If the VPS requires an API key, paste it here.${NC}"
echo -e "  ${DIM}Leave blank if the server allows open registration.${NC}"
echo ""

if [[ -n "${VP_API_KEY:-}" ]]; then
    API_KEY="${VP_AP...nfo "Using VP_API_KEY from environment"
else
    prompt "API key (hidden input):"
    read -r -s API_KEY
    echo ""
fi

echo ""

step "Step 5 - Your domain (optional)"

echo -e "  ${DIM}If you have a domain, the VPS will route HTTPS traffic to you.${NC}"
echo -e "  ${DIM}Leave blank if you only need the VPN tunnel.${NC}"
echo ""

if [[ -n "${VP_DOMAIN:-}" ]]; then
    DOMAIN="${VP_DOMAIN}"
    info "Using VP_DOMAIN=${DOMAIN}"
else
    prompt "Your domain (e.g. myhomelab.com) or leave blank:"
    read -r DOMAIN
fi

HOSTNAME_NAME="${VP_HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"
MATRIX_FED="${VP_MATRIX:-0}"

# ── Register with VPS ────────────────────────────────────────────────────────

step "Step 6 - Registering with the VPS"

REGISTER_BODY=$(cat <<EOF
{
    "public_key": "${CLIENT_PUBLIC_KEY}",
    "domain": "${DOMAIN:-}",
    "hostname": "${HOSTNAME_NAME}",
    "matrix_federation": $([[ "$MATRIX_FED" == "1" ]] && echo "true" || echo "false")
}
EOF
)

CURL_ARGS=(curl -fsSL --max-time 30 -X POST)
if [[ -n "${API_KEY:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer ${API_KEY}
fi
CURL_ARGS+=(-H "Content-Type: application/json" -d "$REGISTER_BODY")
CURL_ARGS+=("http://${SERVER}/api/v1/register")

info "Contacting ${SERVER}..."

REGISTER_OUTPUT=$("${CURL_ARGS[@]}" 2>&1) || {
    echo ""
    err "Could not reach the VPS provision server."
    err "Server: ${SERVER}"
    echo ""
    warn "Troubleshooting:"
    warn "  1. Is the VPS running? Try: curl http://${SERVER}/health"
    warn "  2. Is the port open in the firewall?"
    warn "  3. Is the API key correct?"
    exit 1
}

STATUS=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "parse_error")
CLIENT_IP=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || echo "")
VPS_PUBKEY=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_public_key',''))" 2>/dev/null || echo "")
VPS_ENDPOINT=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_endpoint',''))" 2>/dev/null || echo "")
VPS_PORT=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_port','51820'))" 2>/dev/null || echo "51820")
SNI_OK=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sni_configured','false'))" 2>/dev/null || echo "false")

if [[ "$STATUS" == "error" ]]; then
    err "Registration failed. Response:"
    echo "$REGISTER_OUTPUT" | python3 -m json.tool 2>/dev/null || echo "$REGISTER_OUTPUT"
    exit 1
fi

if [[ "$STATUS" == "already_registered" ]]; then
    log "This key is already registered - reusing IP ${CLIENT_IP}"
else
    log "Registered! Your tunnel IP: ${BOLD}${CLIENT_IP}${NC}"
fi

log "VPS endpoint: ${BOLD}${VPS_ENDPOINT}:${VPS_PORT}${NC}"
if [[ -n "$DOMAIN" ]]; then
    if [[ "$SNI_OK" == "true" ]]; then
        log "SNI route: ${BOLD}${DOMAIN}${NC} → ${CLIENT_IP}:443"
    else
        warn "SNI route setup failed - the VPS admin may need to add it manually."
    fi
fi

# ── Write WireGuard config ───────────────────────────────────────────────────

step "Step 7 - Configuring WireGuard"

sudo mkdir -p /etc/wireguard

WG_CONFIG="/etc/wireguard/wg0.conf"

sudo tee "$WG_CONFIG" > /dev/null <<EOF
# VeryPowerful - Home Node WireGuard Spoke
# VPS: ${VPS_ENDPOINT}:${VPS_PORT}  |  Your IP: ${CLIENT_IP}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address    = ${CLIENT_IP}/24
MTU        = 1420

[Peer]
PublicKey           = ${VPS_PUBKEY}
Endpoint            = ${VPS_ENDPOINT}:${VPS_PORT}
AllowedIPs          = 10.0.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 "$WG_CONFIG"
log "Config written to /etc/wireguard/wg0.conf"

# ── Start WireGuard ──────────────────────────────────────────────────────────

step "Step 8 - Starting the tunnel"

if wg show wg0 &>/dev/null 2>&1; then
    sudo wg-quick down wg0 2>/dev/null || true
    sleep 1
fi

sudo wg-quick up wg0

sleep 2
if wg show wg0 &>/dev/null 2>&1; then
    log "Tunnel established!"

    VPS_WG_IP=$(echo "$CLIENT_IP" | awk -F. '{print $1"."$2"."$3".1"}')
    if ping -c 2 -W 3 "$VPS_WG_IP" &>/dev/null; then
        log "Connectivity verified - ping ${VPS_WG_IP} OK"
    else
        warn "Tunnel up but ping to ${VPS_WG_IP} failed (ICMP may be blocked)."
    fi
else
    err "Tunnel failed to start."
    err "Check: sudo journalctl -u wg-quick@wg0 --no-pager -n 20"
    exit 1
fi

sudo systemctl enable wg-quick@wg0 2>/dev/null || \
    warn "Could not enable on-boot (non-systemd system?)"

# ── Optional Caddy ────────────────────────────────────────────────────────────

INSTALL_CADDY="${VP_INSTALL_CADDY:-}"

if [[ -z "$INSTALL_CADDY" ]] && [[ -n "$DOMAIN" ]]; then
    echo ""
    step "Optional - Install Caddy for auto-TLS?"
    echo -e "  ${DIM}Caddy will get Let's Encrypt certs for ${DOMAIN}.${NC}"
    echo -e "  ${DIM}It serves HTTPS. Traffic arrives through the WG tunnel.${NC}"
    echo ""
    prompt "Install Caddy? [Y/n]:"
    read -r CADDY_ANSWER
    INSTALL_CADDY=$( "${CADDY_ANSWER,,}" == "n" || "${CADDY_ANSWER,,}" == "no" ]] && echo "no" || echo "yes")
fi

if [[ "${INSTALL_CADDY,,}" == "yes" || "${INSTALL_CADDY,,}" == "y" || "${INSTALL_CADDY:-}" == "1" ]]; then
    install_caddy
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${GREEN}║${NC}           ${BOLD}VeryPowerful - Connected!${NC}            ${BOLD}${GREEN}║${NC}"
echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Your WG IP:     ${BOLD}${CLIENT_IP}${NC}"
if [[ -n "$DOMAIN" ]]; then
echo -e "  Your domain:    ${BOLD}${DOMAIN}${NC}"
fi
echo -e "  VPS endpoint:   ${VPS_ENDPOINT}:${VPS_PORT}"
echo ""
echo -e "  ${DIM}Commands:${NC}"
echo -e "  ${DIM}  sudo wg show wg0          - tunnel status${NC}"
echo -e "  ${DIM}  sudo wg-quick down wg0    - stop${NC}"
echo -e "  ${DIM}  sudo wg-quick up wg0      - start${NC}"
echo ""
if [[ -n "$DOMAIN" ]]; then
echo -e "  ${DIM}Next: point DNS A record for ${DOMAIN} → ${VPS_ENDPOINT}${NC}"
fi
echo -e "  ${BOLD}${GREEN}⚡ Your home lab has a public face. Go build.${NC}"
echo ""

exit 0

# ── Caddy install ─────────────────────────────────────────────────────────────

install_caddy() {
    step "Installing Caddy"

    case "$OS_FAMILY" in
        debian)
            sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
            curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
                sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | \
                sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
            sudo apt-get update -qq
            sudo apt-get install -y -qq caddy ;;
        redhat)
            sudo dnf install -y 'dnf-command(copr)'
            sudo dnf copr enable -y @caddy/caddy
            sudo dnf install -y caddy ;;
        arch)
            sudo pacman -S --noconfirm caddy ;;
        *)
            warn "Cannot auto-install Caddy. Install manually: https://caddyserver.com/docs/install"
            return ;;
    esac

    CLIENT_IP_CLEAN="${CLIENT_IP%/*}"
    CADDY_EMAIL="${VP_CADDY_EMAIL:-}"
    if [[ -z "$CADDY_EMAIL" ]]; then
        prompt "Email for Let's Encrypt notifications:"
        read -r CADDY_EMAIL
    fi

    sudo mkdir -p /etc/caddy
    sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
{
    email ${CADDY_EMAIL:-admin@localhost}
}

:80 {
    bind ${CLIENT_IP_CLEAN}
    redir https://{host}{uri} permanent
}

${DOMAIN:-example.com} {
    bind ${CLIENT_IP_CLEAN}

    handle {
        respond "VeryPowerful node - TLS OK" 200
    }
}
EOF

    sudo systemctl enable caddy
    sudo systemctl restart caddy

    if systemctl is-active --quiet caddy; then
        log "Caddy running. Edit /etc/caddy/Caddyfile to add your services."
    else
        warn "Caddy installed but failed to start. Check: sudo journalctl -u caddy -n 20"
    fi
}
