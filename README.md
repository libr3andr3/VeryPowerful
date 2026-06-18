# VeryPowerful

**Host anything from behind NAT. The VPS never sees your plaintext.**

Cloudflare tunnels read your data. Tailscale funnels you through their relays.
VeryPowerful is different — TLS terminates on YOUR machine. The VPS is just a
dumb L4 pipe that reads domain names from SNI and forwards raw TCP. It never
decrypts, never sees plaintext, never has your keys.

```
Internet → VPS (nginx SNI proxy) → WireGuard tunnel → Your machine (Caddy TLS)
               ↑ never decrypts                            ↑ you own the keys
```

## One command. Two terminals. Done.

**Terminal 1 (VPS):**
```bash
curl -fsSL https://yaya.sh/vp-server-setup.sh | sudo bash
```
Shows your VPS public key. Paste the peer's public key + domain. Done.

**Terminal 2 (your machine):**
```bash
curl -fsSL https://yaya.sh/install.sh | bash
```
Shows your public key. Paste the VPS key + endpoint. Tunnel up. Done.

No accounts. No API keys. No cloud services. Just WireGuard keys and copy-paste.

## Why this matters

| Service | Where TLS terminates | Who sees your data |
|---------|---------------------|--------------------|
| Cloudflare Tunnel | Cloudflare's edge | Cloudflare |
| Tailscale Funnel | Tailscale relays | Tailscale |
| ngrok | ngrok servers | ngrok |
| **VeryPowerful** | **Your machine** | **Nobody** |

## What you get

- WireGuard hub-and-spoke VPN through a $4/month VPS
- nginx L4 SNI stream proxy — routes by domain without decrypting
- Caddy auto-TLS with Let's Encrypt on your machine
- Multi-port: HTTPS (443), HTTP (80 for ACME), Matrix federation (8448)
- Per-domain transfer metrics (optional)

## How it works

```
User visits yourdomain.com
  │
  ▼
VPS (public IP)
  nginx reads SNI "yourdomain.com" from TLS ClientHello
  forwards raw TCP to your machine through WireGuard
  NEVER decrypts, NEVER sees plaintext
  │
  ▼ WireGuard encrypted tunnel
Your machine (behind NAT)
  Caddy terminates TLS with Let's Encrypt cert
  serves your apps, your data, your rules
```

## Contributing

MIT licensed. Zero dependencies beyond WireGuard, nginx, and curl.
The entire stack is bash scripts — easy to read, easy to fork.

- [Report issues](https://github.com/libr3andr3/VeryPowerful/issues)
- [Read the code](https://github.com/libr3andr3/VeryPowerful) — it's two bash scripts
- Share with friends who homelab

## Requirements

**VPS:** any Linux with public IP, ~512MB RAM, root access
**Your machine:** any Linux behind NAT, root/sudo access
