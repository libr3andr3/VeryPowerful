#!/usr/bin/env python3
"""
VeryPowerful Provisioning Server
=================================
Runs on the VPS. Accepts peer registrations, manages WireGuard peers
and nginx SNI entries. Zero dependencies (stdlib only).

API:
  POST /api/v1/register   Register a new peer (needs API key)
  DELETE /api/v1/peers/<ip>  Remove a peer
  GET /api/v1/peers        List all peers
  GET /health              Health check (public)

State file: /var/lib/verypowerful/state.json
Nginx SNI map: /etc/nginx/stream-sni-map.conf (included from nginx.conf)
"""

import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from threading import Lock

# ── Configuration ──────────────────────────────────────────────────────────

STATE_DIR = Path(os.environ.get("VP_STATE_DIR", "/var/lib/verypowerful"))
STATE_FILE = STATE_DIR / "state.json"
NGINX_SNI_MAP = Path(os.environ.get("VP_NGINX_SNI_MAP", "/etc/nginx/stream-sni-map.conf"))
NGINX_SNI_MATRIX = Path(os.environ.get("VP_NGINX_SNI_MATRIX", "/etc/nginx/stream-sni-map-8448.conf"))
WG_INTERFACE = os.environ.get("VP_WG_INTERFACE", "wg0")
WG_SUBNET = os.environ.get("VP_WG_SUBNET", "10.0.0.0/24")
LISTEN_HOST = os.environ.get("VP_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("VP_LISTEN_PORT", "9090"))
API_KEY = os.environ.get("VP_API_KEY", "").strip()
FALLBACK_PORT = 9443

# IP allocation: reserve .1 (VPS) and .2 (first home node).
# New peers get .3, .4, .5, ...
# Calculate subnet base and max host from WG_SUBNET.
_subnet_parts = WG_SUBNET.split("/")
_subnet_base = _subnet_parts[0].rsplit(".", 1)[0]  # e.g. "10.0.0"
_cidr = int(_subnet_parts[1])
_max_host = (1 << (32 - _cidr)) - 1
_RESERVED_IPS = {1, 2}  # .1 = VPS, .2 = primary home node

_mutex = Lock()

# Warn if no API key is set with a public-facing listen address
_PUBLIC_LISTEN = not LISTEN_HOST.startswith("127.") and LISTEN_HOST != "localhost"
if not API_KEY and _PUBLIC_LISTEN:
    import sys as _sys
    print("=" * 60, file=_sys.stderr)
    print("⚠️  SECURITY WARNING: No VP_API_KEY set and listening on", file=_sys.stderr)
    print(f"   {LISTEN_HOST}:{LISTEN_PORT} (public-facing)", file=_sys.stderr)
    print("   Anyone who can reach this port can register peers.", file=_sys.stderr)
    print("   Set VP_API_KEY in environment or /etc/verypowerful/env", file=_sys.stderr)
    print("=" * 60, file=_sys.stderr)


# ── State Management ───────────────────────────────────────────────────────

def load_state() -> dict:
    """Load peer state from JSON file."""
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"peers": {}, "next_ip_suffix": 3, "wg_public_key": "", "wg_listen_port": 51820}


def save_state(state: dict) -> None:
    """Atomic write of state file."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    tmp.rename(STATE_FILE)


def allocate_ip(state: dict) -> str | None:
    """Find the next available IP in the WireGuard subnet."""
    used = {int(p["ip"].rsplit(".", 1)[1]) for p in state["peers"].values()}
    used |= _RESERVED_IPS
    suffix = state.get("next_ip_suffix", 3)
    while suffix <= _max_host and suffix in used:
        suffix += 1
    if suffix > _max_host:
        return None
    state["next_ip_suffix"] = suffix + 1
    return f"{_subnet_base}.{suffix}"


# ── WireGuard Management ────────────────────────────────────────────────────

def wg_run(*args: str) -> subprocess.CompletedProcess:
    """Run wg command. Returns CompletedProcess."""
    return subprocess.run(
        ["wg"] + list(args),
        capture_output=True, text=True, timeout=10
    )


def get_wg_public_key() -> str:
    """Get the server's WireGuard public key."""
    result = wg_run("show", WG_INTERFACE, "public-key")
    if result.returncode == 0:
        return result.stdout.strip()
    # Fallback: try to read from interface directly
    result2 = subprocess.run(
        ["wg", "pubkey"],
        input=subprocess.run(
            ["cat", f"/etc/wireguard/{WG_INTERFACE}.conf"],
            capture_output=True, text=True
        ).stdout,
        capture_output=True, text=True
    )
    return ""


def get_wg_listen_port() -> int:
    """Get the server's WireGuard listen port."""
    result = wg_run("show", WG_INTERFACE, "listen-port")
    if result.returncode == 0:
        try:
            return int(result.stdout.strip())
        except ValueError:
            pass
    return 51820


def add_wg_peer(ip: str, public_key: str, endpoint: str = "") -> bool:
    """Add a WireGuard peer. Returns True on success."""
    # First try: wg set (online, no restart needed)
    cmd = ["wg", "set", WG_INTERFACE, "peer", public_key, "allowed-ips", f"{ip}/32"]
    result1 = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result1.returncode == 0:
        # Persist to config file immediately so it survives reboot
        subprocess.run(["wg-quick", "save", WG_INTERFACE],
                       capture_output=True, timeout=10)
        return True

    # Fallback: syncconf (for when wg set fails, e.g., no running interface)
    try:
        current = subprocess.run(
            ["wg-quick", "strip", WG_INTERFACE],
            capture_output=True, text=True, timeout=10
        )
        new_conf = current.stdout.rstrip() + f"\n[Peer]\nPublicKey = {public_key}\nAllowedIPs = {ip}/32\n"
        result2 = subprocess.run(
            ["wg", "syncconf", WG_INTERFACE, "/dev/stdin"],
            input=new_conf, capture_output=True, text=True, timeout=10
        )
        if result2.returncode == 0:
            return True
    except Exception:
        pass

    return False


def remove_wg_peer(public_key: str) -> bool:
    """Remove a WireGuard peer."""
    result = subprocess.run(
        ["wg", "set", WG_INTERFACE, "peer", public_key, "remove"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0:
        subprocess.run(["wg-quick", "save", WG_INTERFACE],
                       capture_output=True, timeout=10)
        return True
    return False


# ── Nginx SNI Map Management ────────────────────────────────────────────────

def _ensure_map_files() -> None:
    """Create nginx SNI map include files if they don't exist."""
    for f in (NGINX_SNI_MAP, NGINX_SNI_MATRIX):
        if not f.exists():
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(f"# VeryPowerful SNI map — managed by provision.py\n"
                         f"default 127.0.0.1:{FALLBACK_PORT};\n")


def _read_sni_map(path: Path) -> dict[str, str]:
    """Read SNI map file, return {domain: backend}."""
    entries = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[0] != "default":
                entries[parts[0]] = " ".join(parts[1:])
    return entries


def _write_sni_map(path: Path, entries: dict[str, str]) -> None:
    """Write SNI map file atomically."""
    lines = ["# VeryPowerful SNI map — managed by provision.py"]
    for domain in sorted(entries.keys()):
        lines.append(f"{domain:<40} {entries[domain]};")
    lines.append(f"{'default':<40} 127.0.0.1:{FALLBACK_PORT};")
    content = "\n".join(lines) + "\n"
    tmp = path.with_suffix(".tmp")
    tmp.write_text(content)
    tmp.rename(path)


def add_sni_route(domain: str, ip: str, port: int = 443, matrix_federation: bool = False) -> bool:
    """
    Add an SNI route: domain → ip:port.
    If matrix_federation, also add to the 8448 map (for Matrix federation port).
    Returns True on success.
    """
    try:
        _ensure_map_files()
        entries = _read_sni_map(NGINX_SNI_MAP)
        entries[domain] = f"{ip}:{port}"
        _write_sni_map(NGINX_SNI_MAP, entries)

        if matrix_federation:
            matrix_entries = _read_sni_map(NGINX_SNI_MATRIX)
            matrix_entries[domain] = f"{ip}:8448"
            _write_sni_map(NGINX_SNI_MATRIX, matrix_entries)

        return reload_nginx()
    except Exception:
        return False


def remove_sni_route(domain: str) -> bool:
    """Remove an SNI route and reload nginx."""
    try:
        for path in (NGINX_SNI_MAP, NGINX_SNI_MATRIX):
            entries = _read_sni_map(path)
            if domain in entries:
                del entries[domain]
                _write_sni_map(path, entries)
        return reload_nginx()
    except Exception:
        return False


def reload_nginx() -> bool:
    """Reload nginx. Returns True on success."""
    result = subprocess.run(
        ["nginx", "-t"], capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        print(f"[ERROR] nginx -t failed:\n{result.stderr}", file=sys.stderr)
        return False
    result2 = subprocess.run(
        ["nginx", "-s", "reload"], capture_output=True, text=True, timeout=10
    )
    return result2.returncode == 0


# ── HTTP Server ─────────────────────────────────────────────────────────────

class ProvisionHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the provisioning API."""

    server_version = "VeryPowerful/1.0"

    def log_message(self, format, *args):
        print(f"[{datetime.now(timezone.utc).isoformat()}] {args[0]}", file=sys.stderr)

    def _check_auth(self) -> bool:
        """Check Bearer token authorization."""
        if not API_KEY:
            return True  # No auth configured — open registration
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            token = auth[7:]
            if token == API_KEY:
                return True
        return False

    def _send_json(self, data: dict, status: int = 200) -> None:
        """Send a JSON response."""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, message: str, status: int = 400) -> None:
        self._send_json({"error": message}, status)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/health":
            self._send_json({"status": "ok", "service": "verypowerful-provision"})
            return

        if self.path == "/api/v1/peers":
            if not self._check_auth():
                self._send_error("unauthorized", 401)
                return
            state = load_state()
            self._send_json({
                "total": len(state["peers"]),
                "peers": [
                    {
                        "ip": p["ip"],
                        "public_key": p["public_key"][:16] + "...",
                        "domain": p.get("domain", ""),
                        "hostname": p.get("hostname", ""),
                        "registered_at": p.get("registered_at", ""),
                    }
                    for p in state["peers"].values()
                ]
            })
            return

        if self.path == "/api/v1/server-info":
            # Public info for clients — they need server pubkey + endpoint
            state = load_state()
            wg_pk = state.get("wg_public_key") or get_wg_public_key()
            wg_lp = state.get("wg_listen_port") or get_wg_listen_port()
            self._send_json({
                "wg_public_key": wg_pk,
                "wg_listen_port": wg_lp,
                "endpoint": os.environ.get("VP_PUBLIC_ENDPOINT", ""),
            })
            return

        self._send_error("not found", 404)

    def do_POST(self):
        """Handle POST requests."""
        if self.path == "/api/v1/register":
            if not self._check_auth():
                self._send_error("unauthorized — provide Bearer token in Authorization header", 401)
                return

            # Read body
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode("utf-8")
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self._send_error("invalid JSON body", 400)
                return

            public_key = data.get("public_key", "").strip()
            if not public_key:
                self._send_error("missing required field: public_key", 400)
                return

            # Validate public key format (base64, 44 chars)
            if not re.match(r'^[A-Za-z0-9+/]{43,44}=?$', public_key):
                self._send_error("invalid WireGuard public key format", 400)
                return

            domain = data.get("domain", "").strip()
            hostname = data.get("hostname", "").strip() or socket.gethostname()
            matrix_federation = data.get("matrix_federation", False)

            # Check for duplicate public key
            with _mutex:
                state = load_state()

                # Check duplicate
                for peer in state["peers"].values():
                    if peer["public_key"] == public_key:
                        self._send_json({
                            "status": "already_registered",
                            "ip": peer["ip"],
                            "domain": peer.get("domain", ""),
                            "message": "This public key is already registered. "
                                       "If you lost your config, re-run with the same key."
                        }, 200)
                        return

                # Allocate IP
                ip = allocate_ip(state)
                if ip is None:
                    self._send_error("no IPs available — subnet full", 503)
                    return

                # Add WireGuard peer
                if not add_wg_peer(ip, public_key):
                    self._send_error("failed to add WireGuard peer", 500)
                    return

                # Add SNI route if domain provided
                sni_ok = True
                if domain:
                    sni_ok = add_sni_route(domain, ip, matrix_federation=matrix_federation)

                # Get server info for client config
                vps_public_key = state.get("wg_public_key") or get_wg_public_key()
                vps_listen_port = state.get("wg_listen_port") or get_wg_listen_port()
                vps_endpoint = os.environ.get("VP_PUBLIC_ENDPOINT", "")
                if not vps_endpoint:
                    # Try to detect public IP
                    vps_endpoint = _detect_public_ip()

                # Save peer to state
                state["peers"][ip] = {
                    "public_key": public_key,
                    "ip": ip,
                    "domain": domain,
                    "hostname": hostname,
                    "matrix_federation": matrix_federation,
                    "registered_at": datetime.now(timezone.utc).isoformat(),
                    "sni_ok": sni_ok,
                }
                state["wg_public_key"] = vps_public_key
                state["wg_listen_port"] = vps_listen_port
                save_state(state)

                # Generate client WireGuard config
                config = _generate_client_config(
                    private_key_placeholder="<YOUR_PRIVATE_KEY>",
                    ip=ip,
                    vps_public_key=vps_public_key,
                    vps_endpoint=vps_endpoint,
                    vps_port=vps_listen_port,
                )

                self._send_json({
                    "status": "registered",
                    "ip": ip,
                    "domain": domain,
                    "sni_configured": sni_ok,
                    "vps_public_key": vps_public_key,
                    "vps_endpoint": vps_endpoint,
                    "vps_port": vps_listen_port,
                    "config": config,
                }, 201)

            return

        self._send_error("not found", 404)

    def do_DELETE(self):
        """Handle DELETE requests — remove a peer."""
        if not self._check_auth():
            self._send_error("unauthorized", 401)
            return

        # Path: /api/v1/peers/<ip>
        match = re.match(r'^/api/v1/peers/(.+)$', self.path)
        if not match:
            self._send_error("not found", 404)
            return

        target_ip = match.group(1)

        with _mutex:
            state = load_state()
            if target_ip not in state["peers"]:
                self._send_error(f"peer {target_ip} not found", 404)
                return

            peer = state["peers"][target_ip]

            # Remove from WireGuard
            remove_wg_peer(peer["public_key"])

            # Remove from nginx SNI
            if peer.get("domain"):
                remove_sni_route(peer["domain"])

            # Remove from state
            del state["peers"][target_ip]
            save_state(state)

            self._send_json({
                "status": "removed",
                "ip": target_ip,
                "domain": peer.get("domain", ""),
            })


def _detect_public_ip() -> str:
    """Try to detect the VPS public IP."""
    try:
        from urllib.request import urlopen
        with urlopen("https://checkip.amazonaws.com", timeout=5) as resp:
            return resp.read().decode().strip()
    except Exception:
        pass
    try:
        from urllib.request import urlopen
        with urlopen("https://ifconfig.me", timeout=5) as resp:
            return resp.read().decode().strip()
    except Exception:
        pass
    return ""


def _generate_client_config(
    private_key_placeholder: str,
    ip: str,
    vps_public_key: str,
    vps_endpoint: str,
    vps_port: int,
) -> str:
    """Generate a WireGuard config for the client."""
    config = f"""# VeryPowerful — Home Node WireGuard Spoke
# Generated: {datetime.now(timezone.utc).isoformat()}
# Your IP: {ip} on {WG_SUBNET}
#
# Replace <YOUR_PRIVATE_KEY> with the private key you generated.
# Keep your private key secret — never share it.
# Your public key has been registered with the VPS hub.

[Interface]
PrivateKey = {private_key_placeholder}
Address    = {ip}/24
MTU        = 1420

[Peer]
# The VPS hub — never sees your plaintext, just forwards TCP
PublicKey           = {vps_public_key}
Endpoint            = {vps_endpoint}:{vps_port}
AllowedIPs          = {_subnet_base}.0/24
PersistentKeepalive = 25
"""
    return config


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    print(f"VeryPowerful Provision Server starting on {LISTEN_HOST}:{LISTEN_PORT}", file=sys.stderr)

    # Ensure state directory exists
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # Ensure SNI map files exist and are included in nginx.conf
    _ensure_map_files()
    _verify_nginx_includes()

    if not API_KEY:
        print("[WARNING] VP_API_KEY not set — registration is OPEN (no auth). "
              "Set VP_API_KEY in environment or /etc/verypowerful/env.",
              file=sys.stderr)

    # Load initial state
    state = load_state()
    if not state.get("wg_public_key"):
        state["wg_public_key"] = get_wg_public_key()
        state["wg_listen_port"] = get_wg_listen_port()
        save_state(state)

    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), ProvisionHandler)

    # Graceful shutdown
    def shutdown(sig, frame):
        print("\n[INFO] Shutting down...", file=sys.stderr)
        server.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    print(f"[INFO] Server ready. API key {'configured' if API_KEY else 'NOT SET (open)'}.", file=sys.stderr)
    print(f"[INFO] Endpoints:", file=sys.stderr)
    print(f"       POST /api/v1/register  — register a peer", file=sys.stderr)
    print(f"       GET  /api/v1/peers      — list peers", file=sys.stderr)
    print(f"       GET  /health            — health check", file=sys.stderr)
    print(f"       GET  /api/v1/server-info — public server info", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass

    print("[INFO] Server stopped.", file=sys.stderr)


def _verify_nginx_includes() -> None:
    """Check that the SNI map files are included from nginx.conf.
    If not, print a warning with instructions."""
    nginx_conf = Path("/etc/nginx/nginx.conf")
    if not nginx_conf.exists():
        print("[WARNING] /etc/nginx/nginx.conf not found — cannot verify includes",
              file=sys.stderr)
        return

    content = nginx_conf.read_text()
    sni_include = str(NGINX_SNI_MAP)
    sni_matrix_include = str(NGINX_SNI_MATRIX)

    warnings = []
    if sni_include not in content:
        warnings.append(
            f"Add to /etc/nginx/nginx.conf inside the stream {{}} block:\n"
            f"    include {sni_include};\n"
        )
    if sni_matrix_include not in content and NGINX_SNI_MATRIX.exists():
        warnings.append(
            f"Add to /etc/nginx/nginx.conf inside the stream {{}} block:\n"
            f"    include {sni_matrix_include};\n"
        )

    if warnings:
        print("[WARNING] Nginx includes not found:", file=sys.stderr)
        for w in warnings:
            print(f"  {w}", file=sys.stderr)


if __name__ == "__main__":
    main()
