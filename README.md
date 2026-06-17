# VeryPowerful (VP)

Host anything from behind NAT with a cheap VPS as a dumb pipe.

A WireGuard hub-and-spoke setup where the VPS reads SNI from incoming
TLS traffic (without decrypting) and forwards raw TCP streams to the
right home node through the tunnel. TLS terminates on the home machine
— the VPS never sees plaintext.

Built for people with a beefy workstation at home/university and a
$4/month VPS who don't want to pay for a real server.

## How it works

```
Internet → VPS (public IP)
             nginx L4 SNI proxy  ← reads domain from TLS, no decryption
             WireGuard hub
               │
               ▼  encrypted tunnel
             Home node (NAT)
               Caddy TLS termination
               your apps (Matrix, Jitsi, whatever)
```

## What's in the box

| File | Purpose |
|------|---------|
| `templates/vps-wireguard-hub.conf.j2` | VPS WireGuard config that accepts spokes |
| `templates/home-wireguard-spoke.conf.j2` | Home node WireGuard config |
| `templates/vps-nginx-stream.conf.j2` | VPS nginx L4 SNI proxy |
| `templates/home-caddyfile.j2` | Home node Caddy TLS + reverse proxy |
| `scripts/vp-usage-aggregator.py` | Aggregates per-domain transfer metrics |

## Deploy

```
# 1. VPS
apt install nginx libnginx-mod-stream wireguard-tools
# render templates/vps-wireguard-hub.conf.j2 → /etc/wireguard/wg0.conf
# render templates/vps-nginx-stream.conf.j2 → /etc/nginx/nginx.conf
wg-quick up wg0
systemctl restart nginx

# 2. Home node
# render templates/home-wireguard-spoke.conf.j2 → /etc/wireguard/wg0.conf
# render templates/home-caddyfile.j2 → /etc/caddy/Caddyfile
wg-quick up wg0
systemctl restart caddy

# 3. DNS
# point your domains to the VPS public IP

# 4. Metrics (optional)
python3 scripts/vp-usage-aggregator.py   # cron every 5 min
python3 vp-usage-server                  # query API on :8090
```

## Adding another home node

```
VPS /etc/wireguard/wg0.conf:
  [Peer]
  PublicKey = <their-key>
  AllowedIPs = 10.0.0.X/32

VPS /etc/nginx/nginx.conf (stream map):
  their.domain.com    10.0.0.X:443;

DNS:
  their.domain.com  A  <VPS-IP>
```

## Requirements

- VPS: any Linux with a public IP, ~1GB RAM, nginx with stream module
- Home: any Linux behind NAT, Caddy for TLS
- Both: WireGuard
