# VeryPowerful

**One command to give your home lab a public face.**

```
curl -fsSL https://campusgenie.ai/install.sh | bash
```

VeryPowerful creates a persistent WireGuard VPN tunnel from your home machine
(behind NAT, no public IP) to a cheap VPS that acts as a **dumb L4 pipe**.
The VPS reads the domain name from incoming TLS (SNI) and forwards the raw
TCP stream to your machine. TLS terminates on YOUR hardware — the VPS never
sees your plaintext.

## How it works

```
User's browser
    │
    ▼
campusgenie.ai  ──►  VPS (public IP, $4/mo)
                      │  nginx L4 SNI proxy ← reads domain, no decryption
                      │  WireGuard hub (10.0.0.1)
                      │    │
                      │    ▼  encrypted tunnel
                      │  Your home machine (10.0.0.3)
                      │    Caddy auto-TLS (Let's Encrypt)
                      │    your apps, your data, your rules
```

## One-command install (home lab owner)

From any Linux machine behind NAT:

```bash
curl -fsSL https://campusgenie.ai/install.sh | bash
```

The script will:
1. Install WireGuard
2. Generate a keypair
3. Register with the VeryPowerful VPS
4. Configure and start the VPN tunnel
5. Optionally install Caddy for auto-TLS

**That's it.** Your machine now has a public ingress point. Point a DNS
A record at the VPS IP and you're serving traffic from your basement.

### Options

```bash
# Non-interactive (CI/CD, automation):
VP_SERVER=vps.example.com:9090 \
VP_API_KEY=*** \
VP_DOMAIN=myhomelab.com \
VP_INSTALL_CADDY=1 \
curl -fsSL https://campusgenie.ai/install.sh | bash
```

## Server setup (VPS admin)

Run this once on your VPS:

```bash
curl -fsSL https://campusgenie.ai/vp-server-setup.sh | sudo bash
```

This installs and configures:
- WireGuard hub (accepts peer connections)
- nginx L4 SNI stream proxy (routes traffic by domain)
- Provisioning daemon (API for peer registration, systemd-managed)

After setup, the VPS is ready to accept peer registrations.

### Provisioning API

The server exposes a REST API on port 9090 (internal):

```bash
# Register a peer (requires API key)
curl -X POST http://127.0.0.1:9090/api/v1/register \
  -H "Authorization: Bearer *** \
  -H "Content-Type: application/json" \
  -d '{"public_key": "...", "domain": "myhomelab.com"}'

# List peers
curl http://127.0.0.1:9090/api/v1/peers \
  -H "Authorization: Bearer $VP_API_KEY"

# Remove a peer
curl -X DELETE http://127.0.0.1:9090/api/v1/peers/10.0.0.3 \
  -H "Authorization: Bearer $VP_API_KEY"

# Health check (public)
curl http://127.0.0.1:9090/health
```

## Architecture

| Component | Where | What it does |
|-----------|-------|--------------|
| `server/provision.py` | VPS | Provisioning daemon — registers peers, manages WG + nginx |
| `server/vp-server-setup.sh` | VPS | One-time setup script for the VPS |
| `client/install.sh` | Home node | One-command client install |
| `templates/*.j2` | Repo | Jinja2 templates for static config generation |
| `scripts/vp-usage-aggregator.py` | VPS | Per-domain transfer metrics (cron) |

## What's included in the tunnel

- **HTTPS (443)** — SNI-routed to the right home node
- **HTTP (80)** — forwarded for Let's Encrypt HTTP-01 challenges
- **Matrix federation (8448)** — optional, for Matrix homeservers

## Security properties

- VPS is a **dumb pipe** — no TLS private keys, no plaintext access
- Home node **self-terminates TLS** — Caddy auto-obtains Let's Encrypt certs
- All traffic between VPS and home is **WireGuard-encrypted**
- nginx reads only the **SNI hostname** (unencrypted part of TLS ClientHello)
- Adding a node requires no VPS shell access — just the API

## Requirements

### VPS
- Any Linux with a public IP and root access
- ~512 MB RAM (the stack uses ~20 MB)
- Open ports: 51820/udp (WireGuard), 80/tcp, 443/tcp, 8448/tcp (optional)

### Home node
- Any Linux (Debian/Ubuntu/Fedora/Arch/Alpine)
- Behind NAT is fine (that's the whole point)
- Root or sudo access

## Usage metrics (optional)

The VPS tracks per-domain transfer via nginx stream access logs. A cron
aggregator accumulates byte counts. Query via HTTP API on port 8090:

```bash
curl http://vps:8090/usage/myhomelab.com
```

See `scripts/vp-usage-aggregator.py` and the WireGuard ingress reference
for details.

## Prior art

VeryPowerful was extracted from [LibreSynergy](https://github.com/libr3andr3/LibreSynergy),
a federated learning community suite. The ingress architecture proved so useful
on its own that it became a standalone project.

## License

MIT
