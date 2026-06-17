#!/usr/bin/env bash
# VeryPowerful — One-Command Install
# ===================================
# Sets up a persistent WireGuard VPN tunnel to a VeryPowerful VPS,
# giving your home lab a public ingress point. The VPS never sees
# your plaintext — TLS terminates on your machine.
#
# Usage:
#   curl -fsSL https://yaya.sh/install.sh | bash
#
# Or with explicit server info:
#   VP_SERVER=103.89.12.145:9090 VP_API_KEY=*** VP_DOMAIN=my.lab.com bash install.sh
#
# What this does:
#   1. Detects your OS and installs wireguard-tools
#   2. Generates a WireGuard keypair
#   3. Registers your public key with the VeryPowerful VPS
#   4. Configures WireGuard spoke
#   5. Optionally installs/configures Caddy for TLS termination
#   6. Starts the VPN tunnel
#
# Environment variables (all optional — script prompts interactively):
#   VP_SERVER          VPS provision server host:port
#   VP_API_KEY         API key for authentication
#   VP_DOMAIN          Your domain name (for SNI routing)
#   VP_HOSTNAME        Friendly name for your node
#   VP_MATRIX          Set to "1" to enable Matrix federation
#   VP_INSTALL_CADDY   Set to "1" to auto-install Caddy
#   VP_NON_INTERACTIVE Set to "1" to skip prompts (needs VP_DOMAIN)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
bold() { echo -e "${BOLD}$*${NC}"; }

# ── Banner ─────────────────────────────────────────────────────────────────

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║            VeryPowerful Installer            ║"
echo "  ║    VPN ingress for your home lab, no hassle  ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# ── Detect OS ──────────────────────────────────────────────────────────────

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
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
        OS_ID="macos"
        OS_FAMILY="macos"
    else
        OS_ID="unknown"
        OS_FAMILY="unknown"
    fi
}

detect_os

info "Detected OS: ${OS_ID} (${OS_FAMILY:-unknown})"

if [[ "$OS_FAMILY" == "macos" ]]; then
    err "macOS is not currently supported for VeryPowerful home nodes."
    err "macOS WireGuard works but runs in userland and lacks systemd."
    err "Use a Linux server/VM instead, or install WireGuard manually."
    exit 1
fi

if [[ "$OS_FAMILY" == "unknown" ]]; then
    warn "Unrecognized OS. Will try generic Linux approach."
fi

# ── Install WireGuard ──────────────────────────────────────────────────────

install_wireguard() {
    info "Installing WireGuard..."

    case "$OS_FAMILY" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq wireguard-tools resolvconf curl
            ;;
        redhat)
            sudo dnf install -y wireguard-tools curl
            ;;
        arch)
            sudo pacman -S --noconfirm wireguard-tools curl
            ;;
        alpine)
            sudo apk add wireguard-tools curl
            ;;
        suse)
            sudo zypper install -y wireguard-tools curl
            ;;
        *)
            warn "Could not auto-install WireGuard for your OS."
            warn "Please install wireguard-tools and curl manually, then re-run."
            warn "https://www.wireguard.com/install/"
            exit 1
            ;;
    esac

    # Verify installation
    if ! command -v wg &>/dev/null; then
        err "WireGuard (wg) command not found after installation."
        exit 1
    fi
    if ! command -v wg-quick &>/dev/null; then
        err "wg-quick not found after installation."
        exit 1
    fi

    log "WireGuard installed: $(wg --version 2>/dev/null || echo 'ok')"
}

if command -v wg &>/dev/null && command -v wg-quick &>/dev/null; then
    log "WireGuard already installed: $(wg --version 2>/dev/null || echo 'ok')"
else
    install_wireguard
fi

# ── Check existing WireGuard interfaces ─────────────────────────────────────

EXISTING_CONFIG=""
for iface in wg0 vp0; do
    if wg show "$iface" &>/dev/null 2>&1; then
        warn "WireGuard interface '$iface' already running."
        warn "VeryPowerful uses wg0 by default. If you already have a wg0,"
        warn "this script will NOT overwrite it. Use a different interface"
        warn "or remove the existing one first: sudo wg-quick down $iface"
        EXISTING_CONFIG="$iface"
    fi
done

if [[ -n "$EXISTING_CONFIG" ]] && [[ -z "${VP_FORCE:-}" ]]; then
    err "Existing WireGuard interface found. Set VP_FORCE=1 to overwrite,"
    err "or manually clean up first: sudo wg-quick down $EXISTING_CONFIG"
    exit 1
fi

# ── Generate WireGuard keys ────────────────────────────────────────────────

WG_DIR="${HOME}/.wireguard"
mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

PRIVATE_KEY_FILE="${WG_DIR}/verypowerful.private"
PUBLIC_KEY_FILE="${WG_DIR}/verypowerful.public"

# Only generate if we don't already have keys
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
    umask 077
    wg genkey > "$PRIVATE_KEY_FILE"
    wg pubkey < "$PRIVATE_KEY_FILE" > "$PUBLIC_KEY_FILE"
    log "Generated new WireGuard keypair"
else
    log "Using existing WireGuard keypair"
fi

CLIENT_PRIVATE_KEY=$(cat "$PRIVATE_KEY_FILE")
CLIENT_PUBLIC_KEY=$(cat "$PUBLIC_KEY_FILE")

info "Your public key: ${CLIENT_PUBLIC_KEY:0:16}..."

# ── Gather configuration ───────────────────────────────────────────────────

# Server endpoint
if [[ -n "${VP_SERVER:-}" ]]; then
    VP_SERVER="${VP_SERVER}"
else
    echo ""
    info "Where is the VeryPowerful VPS provisioning server?"
    info "Example: vps.example.com:9090"
    read -r -p "  Server (host:port): " VP_SERVER
fi

# API Key (optional — server may allow open registration)
if [[ -n "${VP_API_KEY:-}" ]]; then
    API_KEY="${VP_API_KEY}"
else
    echo ""
    info "API key (leave blank if the server allows open registration):"
    read -r -s -p "  API Key: " API_KEY
    echo ""
fi

# Domain
if [[ -n "${VP_DOMAIN:-}" ]]; then
    DOMAIN="${VP_DOMAIN}"
else
    echo ""
    info "Your domain name (e.g., myhomelab.example.com)."
    info "This is used for SNI routing — HTTPS traffic for this domain"
    info "will be forwarded through the VPS to your machine."
    info "Leave blank if you just want the VPN tunnel (no SNI routing)."
    read -r -p "  Domain: " DOMAIN
fi

# Hostname
if [[ -n "${VP_HOSTNAME:-}" ]]; then
    HOSTNAME_NAME="${VP_HOSTNAME}"
else
    HOSTNAME_NAME=$(hostname 2>/dev/null || echo "unknown")
fi

# Matrix federation
MATRIX_FED="${VP_MATRIX:-0}"

# Non-interactive check
if [[ "${VP_NON_INTERACTIVE:-0}" == "1" ]] && [[ -z "$DOMAIN" ]]; then
    err "VP_NON_INTERACTIVE=1 requires VP_DOMAIN to be set."
    exit 1
fi

echo ""

# ── Register with VPS ──────────────────────────────────────────────────────

info "Registering with VeryPowerful VPS at ${VP_SERVER}..."

REGISTER_BODY=$(cat <<EOF
{
    "public_key": "${CLIENT_PUBLIC_KEY}",
    "domain": "${DOMAIN:-}",
    "hostname": "${HOSTNAME_NAME}",
    "matrix_federation": $([[ "$MATRIX_FED" == "1" ]] && echo "true" || echo "false")
}
EOF
)

# Build curl command
CURL_CMD=(curl -fsSL --max-time 30 -X POST)
if [[ -n "$API_KEY" ]]; then
    CURL_CMD+=(-H "Authorization: Bearer ${API_KEY}")
fi
CURL_CMD+=(-H "Content-Type: application/json" -d "$REGISTER_BODY")
CURL_CMD+=("http://${VP_SERVER}/api/v1/register")

# Attempt registration
REGISTER_OUTPUT=$("${CURL_CMD[@]}" 2>&1) || {
    CURL_EXIT=$?
    echo ""
    err "Registration failed (curl exit code: ${CURL_EXIT})"
    err "Server: ${VP_SERVER}"
    err "Response: ${REGISTER_OUTPUT}"
    echo ""
    warn "Troubleshooting:"
    warn "  1. Is the VPS provision server running?"
    warn "  2. Is the port accessible from your network?"
    warn "  3. Is the API key correct?"
    warn "  4. Try: curl http://${VP_SERVER}/health"
    exit 1
}

# Parse response
RESPONSE=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d, indent=2))" 2>/dev/null || echo "$REGISTER_OUTPUT")

STATUS=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null || echo "parse_error")
CLIENT_IP=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || echo "")
VPS_PUBKEY=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_public_key',''))" 2>/dev/null || echo "")
VPS_ENDPOINT=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_endpoint',''))" 2>/dev/null || echo "")
VPS_PORT=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vps_port','51820'))" 2>/dev/null || echo "51820")
SNI_OK=$(echo "$REGISTER_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sni_configured','false'))" 2>/dev/null || echo "false")

echo ""
echo "$RESPONSE"
echo ""

if [[ "$STATUS" == "error" ]]; then
    err "Registration failed."
    exit 1
fi

if [[ "$STATUS" == "already_registered" ]]; then
    log "This key is already registered with IP: ${CLIENT_IP}"
fi

if [[ "$STATUS" == "registered" ]] || [[ "$STATUS" == "already_registered" ]]; then
    log "Registration successful!"
    log "  Your WG IP   : ${CLIENT_IP}"
    log "  VPS Endpoint : ${VPS_ENDPOINT}:${VPS_PORT}"
    if [[ -n "$DOMAIN" ]]; then
        if [[ "$SNI_OK" == "true" ]]; then
            log "  SNI Route    : ${DOMAIN} → ${CLIENT_IP}:443"
        else
            warn "  SNI Route    : Failed to configure"
            warn "  The VPS admin may need to add your domain manually."
        fi
    fi
fi

# ── Write WireGuard config ─────────────────────────────────────────────────

info "Writing WireGuard spoke config..."

sudo mkdir -p /etc/wireguard

WG_CONFIG="/etc/wireguard/wg0.conf"

cat | sudo tee "$WG_CONFIG" > /dev/null <<EOF
# VeryPowerful — Home Node WireGuard Spoke
# Connects to ${VPS_ENDPOINT}:${VPS_PORT}
# Your tunnel IP: ${CLIENT_IP}
#
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#
# To stop:  sudo wg-quick down wg0
# To start: sudo wg-quick up wg0
# Status:   sudo wg show wg0

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address    = ${CLIENT_IP}/24
MTU        = 1420

[Peer]
# The VPS hub — never sees your plaintext, just forwards TCP
PublicKey           = ${VPS_PUBKEY}
Endpoint            = ${VPS_ENDPOINT}:${VPS_PORT}
AllowedIPs          = 10.0.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 "$WG_CONFIG"
log "Config written: ${WG_CONFIG}"

# ── Start WireGuard ────────────────────────────────────────────────────────

info "Starting WireGuard tunnel..."

# Check if wg0 already exists
if wg show wg0 &>/dev/null 2>&1; then
    warn "wg0 already running. Bringing down first..."
    sudo wg-quick down wg0 2>/dev/null || true
    sleep 1
fi

sudo wg-quick up wg0

# Verify
sleep 2
if wg show wg0 &>/dev/null 2>&1; then
    log "WireGuard tunnel established!"
    wg show wg0 | grep -E "interface|peer|transfer|endpoint" || true

    # Test connectivity to VPS
    VPS_TUNNEL_IP=$(echo "$VPS_ENDPOINT" | cut -d: -f1)
    VPS_WG_IP=$(echo "$CLIENT_IP" | awk -F. '{print $1"."$2"."$3".1"}')
    if ping -c 2 -W 3 "$VPS_WG_IP" &>/dev/null; then
        log "Tunnel connectivity verified (ping ${VPS_WG_IP} OK)"
    else
        warn "Tunnel up but ping to ${VPS_WG_IP} failed."
        warn "This is normal if the VPS blocks ICMP. Check with:"
        warn "  curl -v http://${VPS_WG_IP}:80"
    fi
else
    err "WireGuard tunnel failed to start."
    err "Check: sudo journalctl -u wg-quick@wg0 --no-pager -n 30"
    exit 1
fi

# Enable on boot
sudo systemctl enable wg-quick@wg0 2>/dev/null || \
    warn "Could not enable wg-quick@wg0 on boot (non-systemd system?)"

# ── Optional: Caddy TLS Termination ────────────────────────────────────────

INSTALL_CADDY="${VP_INSTALL_CADDY:-}"

if [[ -z "$INSTALL_CADDY" ]] && [[ -n "$DOMAIN" ]]; then
    echo ""
    info "Would you like to install Caddy for automatic TLS termination?"
    info "Caddy will obtain Let's Encrypt certificates for your domain"
    info "and serve HTTPS. Traffic arrives through the WireGuard tunnel."
    info "Install Caddy? [Y/n]"
    read -r INSTALL_CADDY_ANSWER
    INSTALL_CADDY=$("${INSTALL_CADDY_ANSWER,,}" == "n" || "${INSTALL_CADDY_ANSWER,,}" == "no" ]] && echo "no" || echo "yes")
fi

if [[ "${INSTALL_CADDY,,}" == "yes" || "${INSTALL_CADDY,,}" == "y" || "${INSTALL_CADDY:-}" == "1" ]]; then
    install_caddy
fi

# ── Final summary ──────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  VeryPowerful — Connected!"
echo "══════════════════════════════════════════════════════════════════"
echo ""
echo "  Your WG IP:     ${CLIENT_IP}"
if [[ -n "$DOMAIN" ]]; then
echo "  Your domain:    ${DOMAIN}"
fi
echo "  VPS endpoint:   ${VPS_ENDPOINT}:${VPS_PORT}"
echo ""
echo "  Useful commands:"
echo "    sudo wg show wg0              — tunnel status"
echo "    sudo wg-quick down wg0        — stop tunnel"
echo "    sudo wg-quick up wg0          — start tunnel"
echo "    ping ${CLIENT_IP%/*}.1        — ping VPS through tunnel"
echo ""
if [[ -n "$DOMAIN" ]]; then
echo "  Next steps:"
echo "    1. Point DNS A record for ${DOMAIN} → ${VPS_ENDPOINT}"
echo "    2. Run your services, binding to ${CLIENT_IP%/*} (your WG IP)"
echo "    3. (Caddy) TLS will automatically provision via Let's Encrypt"
fi
echo ""
echo "  ⚡ Your home lab has a public ingress point. Go build!"
echo "══════════════════════════════════════════════════════════════════"
echo ""

exit 0

# ── Caddy installation function ────────────────────────────────────────────

install_caddy() {
    info "Installing Caddy web server with automatic TLS..."

    case "$OS_FAMILY" in
        debian)
            sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
            curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
                sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | \
                sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
            sudo apt-get update -qq
            sudo apt-get install -y -qq caddy
            ;;
        redhat)
            sudo dnf install -y 'dnf-command(copr)'
            sudo dnf copr enable -y @caddy/caddy
            sudo dnf install -y caddy
            ;;
        arch)
            sudo pacman -S --noconfirm caddy
            ;;
        *)
            warn "Auto Caddy install not supported for this OS."
            warn "Install manually: https://caddyserver.com/docs/install"
            return
            ;;
    esac

    CLIENT_IP_CLEAN="${CLIENT_IP%/*}"

    # Write Caddyfile
    sudo mkdir -p /etc/caddy

    # Get email for Let's Encrypt
    CADDY_EMAIL="${VP_CADDY_EMAIL:-}"
    if [[ -z "$CADDY_EMAIL" ]]; then
        echo ""
        read -r -p "  Email for Let's Encrypt notifications: " CADDY_EMAIL
    fi

    if [[ -z "$DOMAIN" ]]; then
        warn "No domain set — Caddy will only serve on the WG IP."
    fi

    cat | sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
# VeryPowerful — Caddy TLS Termination
# Binds to WireGuard tunnel IP only. TLS terminates here.
# The VPS never sees your plaintext.
{
    email ${CADDY_EMAIL:-admin@localhost}
}

:80 {
    bind ${CLIENT_IP_CLEAN}
    redir https://{host}{uri} permanent
}

${DOMAIN:-home.example.com} {
    bind ${CLIENT_IP_CLEAN}

    tls {
        # Remove 'issuer internal' for production Let's Encrypt certs
        # issuer internal
    }

    handle {
        respond "VeryPowerful node — TLS OK" 200
    }

    # ── Add your services here ──────────────────────────────────────
    # Example: reverse proxy to a local Docker container
    #
    # @app {
    #     host app.${DOMAIN:-home.example.com}
    # }
    # handle @app {
    #     reverse_proxy localhost:3000
    # }
    #
    # See: https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
}

# Matrix federation port (if needed)
${DOMAIN:-home.example.com}:8448 {
    bind ${CLIENT_IP_CLEAN}
    handle {
        respond "Matrix federation — TLS OK" 200
    }
}
EOF

    # Start Caddy
    sudo systemctl enable caddy
    sudo systemctl restart caddy

    if systemctl is-active --quiet caddy; then
        log "Caddy installed and running."
        log "Caddyfile: /etc/caddy/Caddyfile"
        log "Edit Caddyfile to add your services, then: sudo systemctl reload caddy"
    else
        warn "Caddy installed but failed to start."
        warn "Check: sudo journalctl -u caddy --no-pager -n 20"
        warn "Caddyfile written to /etc/caddy/Caddyfile — fix it, then:"
        warn "  sudo systemctl restart caddy"
    fi
}
