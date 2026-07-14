# 3x-ui-nginx-proxy

Interactive, idempotent bash script that puts **Nginx** in front of an
existing **3x-ui** panel and **Xray** inbounds, fronted by **Cloudflare**
(DNS + real-IP restoration) and secured with a **Let's Encrypt wildcard
certificate** (DNS-01 via `certbot-dns-cloudflare`). It also locks down the
host with **UFW** so only SSH and 443 are reachable from the internet.

```
setup.sh  ─►  Nginx reverse proxy + TLS + Cloudflare real-IP + UFW
```

3x-ui and Xray themselves are **not installed or configured** by this
script — it assumes you already have them running locally, and its job is
purely to build a secure, correctly-routed front door for them.

---

## Table of contents

- [Architecture](#architecture)
- [Traffic flow](#traffic-flow)
- [What the script configures](#what-the-script-configures)
- [Setup flow (state machine)](#setup-flow-state-machine)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Configuration reference](#configuration-reference)
- [Generated files](#generated-files)
- [Safety features](#safety-features)
- [Re-running the script](#re-running-the-script)
- [Testing](#testing)
- [CI](#ci)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                              Internet
                                 │
                                 ▼
                        ┌─────────────────┐
                        │   Cloudflare    │
                        │  (DNS + proxy)  │
                        └────────┬────────┘
                                 │ HTTPS (443)
                                 ▼
┌───────────────────────────────────────────────────────────────┐
│                            VPS (root)                          │
│                                                                 │
│   UFW firewall:                                                │
│     allow  SSH_PORT/tcp, 443/tcp                                │
│     deny   80/tcp, PANEL_PORT/tcp, WS_PORT/tcp, GRPC_PORT/tcp   │
│                                                                 │
│   ┌───────────────────────────────────────────────────────┐   │
│   │                    Nginx :443 (TLS)                    │   │
│   │                                                         │   │
│   │  server_name: admin.<domain>      server_name: vpn.<domain> │
│   │  ┌───────────────────────┐   ┌───────────────────────┐  │   │
│   │  │  location <PANEL_PATH>/│   │  location = <WS_PATH>  │  │   │
│   │  │  → 127.0.0.1:PANEL_PORT│   │  → 127.0.0.1:WS_PORT   │  │   │
│   │  └───────────────────────┘   ├───────────────────────┤  │   │
│   │                               │  location /<GRPC_SVC>  │  │   │
│   │                               │  → 127.0.0.1:GRPC_PORT │  │   │
│   │                               └───────────────────────┘  │   │
│   └───────────────────────────────────────────────────────┘   │
│              │                       │            │            │
│              ▼                       ▼            ▼            │
│   ┌────────────────┐      ┌────────────────┐  ┌──────────────┐│
│   │  3x-ui panel    │      │  Xray inbound  │  │ Xray inbound  ││
│   │  127.0.0.1:PANEL│      │  WS  :WS_PORT  │  │ gRPC:GRPC_PORT││
│   └────────────────┘      └────────────────┘  └──────────────┘│
│                                                                 │
│   Certbot (DNS-01 via Cloudflare API token)                    │
│     → wildcard cert for <domain> + *.<domain>                  │
│     → deploy hook reloads Nginx on renewal                     │
└───────────────────────────────────────────────────────────────┘
```

Two Nginx `server{}` blocks are generated, both listening on 443 with the
same wildcard certificate, split by `server_name`:

| Domain | Purpose | Backend |
|---|---|---|
| `<PANEL_SUBDOMAIN>.<BASE_DOMAIN>` | 3x-ui web panel | `127.0.0.1:PANEL_PORT` |
| `<VLESS_SUBDOMAIN>.<BASE_DOMAIN>` | VLESS WebSocket + VLESS gRPC | `127.0.0.1:WS_PORT` / `127.0.0.1:GRPC_PORT` |

Everything else on either domain returns `404`.

---

## Traffic flow

A client connecting to the panel:

```
Browser
  │  GET https://admin.example.com/my-admin/
  ▼
Cloudflare (TLS to origin, adds CF-Connecting-IP)
  │
  ▼
Nginx :443  (ssl_certificate = wildcard cert)
  │  server_name admin.example.com
  │  location /my-admin/  → limit_req zone=panel_limit burst=5
  ▼
127.0.0.1:PANEL_PORT   (3x-ui)
```

A VLESS client connecting over WebSocket:

```
Xray client
  │  wss://vpn.example.com/api/v1/events
  ▼
Cloudflare
  │
  ▼
Nginx :443
  │  server_name vpn.example.com
  │  location = /api/v1/events   (exact match, Upgrade/Connection headers)
  ▼
127.0.0.1:WS_PORT   (Xray WS inbound)
```

A VLESS client connecting over gRPC:

```
Xray client
  │  https://vpn.example.com/<serviceName>
  ▼
Cloudflare
  │
  ▼
Nginx :443
  │  server_name vpn.example.com
  │  location /<serviceName>   (grpc_pass)
  ▼
127.0.0.1:GRPC_PORT   (Xray gRPC inbound)
```

`X-Real-IP` / `CF-Connecting-IP` restoration is handled by
`cloudflare-real-ip.conf`, generated from Cloudflare's published IPv4/IPv6
ranges, so Nginx only trusts the `CF-Connecting-IP` header when the request
actually originates from a Cloudflare edge node — not from an attacker
spoofing the header directly against your origin IP.

---

## What the script configures

| Component | Detail |
|---|---|
| **Packages** | `nginx`, `certbot`, `python3-certbot-dns-cloudflare`, `ufw`, `curl`, `ca-certificates` |
| **TLS certificate** | Wildcard (`<domain>` + `*.<domain>`) via Let's Encrypt DNS-01, using a Cloudflare API token — no port 80 required |
| **Certbot renewal** | `systemd` timer + a permanent deploy hook that runs `nginx -t && systemctl reload nginx` after every renewal |
| **Cloudflare real-IP** | `/etc/nginx/conf.d/cloudflare-real-ip.conf`, refreshed from `https://www.cloudflare.com/ips-v{4,6}` on every run |
| **Nginx reverse proxy** | Panel (HTTP) + VLESS WebSocket + VLESS gRPC, all TLS-terminated at 443 |
| **Firewall (UFW)** | Allows only `SSH_PORT/tcp` and `443/tcp`; explicitly denies `80/tcp` and the three internal ports so they're never reachable from outside `127.0.0.1` |
| **Post-run verification** | Optional live check that the internal ports are listening and the public HTTPS endpoints respond correctly |

---

## Setup flow (state machine)

```
 require_root
      │
      ▼
 collect_input ──────► validate_inputs (dies on any invalid value)
      │
      ▼
 confirm_configuration ──[N]──► exit 0
      │ [Y]
      ▼
 [1/8] install_packages
      │
      ▼
 [2/8] write_cloudflare_credentials   (0600, /etc/letsencrypt/cloudflare.ini)
      │
      ▼
 [3/8] issue_certificate              (certbot certonly --dns-cloudflare)
      │
      ▼
 [4/8] install_certbot_hook           (renewal-hooks/deploy/nginx-reload.sh)
      │
      ▼
 [5/8] write_cloudflare_real_ip_config ──[nginx -t fails]──► rollback, exit 1
      │ [ok]
      ▼
 [6/8] write_nginx_config              ──[nginx -t fails]──► rollback, exit 1
      │ [ok]
      ▼
 [7/8] configure_ufw                   (removes stale deny rules from prior runs)
      │
      ▼
 [8/8] print_summary
      │
      ▼
 verify_deployment  (prompts you to configure 3x-ui/Xray, then live-checks)
```

Every `write_*` step follows the same **atomic-write-then-validate** pattern:
write to a temp file → back up the existing config (timestamped) → move the
new file into place → run `nginx -t` → **on failure, restore the backup (or
remove the new file) and exit non-zero**. The live site is never left in a
broken state by a failed run.

---

## Prerequisites

- A fresh (or existing) Debian/Ubuntu VPS, run as **root**.
- A domain managed by **Cloudflare** (orange-clouded or grey-clouded, your
  choice — real-IP restoration works either way).
- A **Cloudflare API token** with `Zone:DNS:Edit` permission scoped to that
  zone (used for the DNS-01 challenge).
- **3x-ui** already installed, with the panel and the WS/gRPC Xray inbounds
  configured to listen on `127.0.0.1` (not `0.0.0.0`) — the script will tell
  you exactly which ports/paths to use.

---

## Usage

```bash
sudo ./setup.sh
```

You'll be prompted for:

```
Base domain, for example example.com
Panel subdomain [admin]
VLESS subdomain [vpn]
Panel path [/my-admin]
Let's Encrypt email
SSH port [22]

3x-ui local port [2053]
WebSocket local port [<random free port>]
gRPC local port [<random free port>]

WebSocket path [/api/v1/events]
gRPC service name [api.v1.SyncService]

Cloudflare API Token (hidden input)
```

A configuration summary is printed for confirmation before anything is
changed on disk.

At the end, `verify_deployment` will ask you to go configure 3x-ui/Xray to
match the printed ports/paths, then (optionally) runs live checks:

```
Checking local listeners...
  [OK]   Panel is listening on 127.0.0.1:2053
  [OK]   WebSocket is listening on 127.0.0.1:51234
  [OK]   gRPC is listening on 127.0.0.1:58921

Checking public HTTPS endpoints...
  [OK]   https://admin.example.com/my-admin/ responded with HTTP 200
  [OK]   TLS handshake to https://vpn.example.com/ succeeded (HTTP 404, 404 is expected here)
```

---

## Configuration reference

| Variable | Default | Notes |
|---|---|---|
| `BASE_DOMAIN` | — | Required, e.g. `example.com` |
| `PANEL_SUBDOMAIN` | `admin` | Must differ from `VLESS_SUBDOMAIN` |
| `VLESS_SUBDOMAIN` | `vpn` | Must differ from `PANEL_SUBDOMAIN` |
| `PANEL_PATH` | `/my-admin` | Normalized (leading `/`, no trailing `/`), whitelisted to `[A-Za-z0-9/_-]` |
| `EMAIL` | — | Let's Encrypt notification address |
| `SSH_PORT` | `22` | Cannot be `443`; internal ports cannot equal this |
| `PANEL_PORT` | `2053` | Internal 3x-ui port |
| `WS_PORT` | random `49152-65535` | Internal Xray WS port |
| `GRPC_PORT` | random `49152-65535`, ≠ `WS_PORT` | Internal Xray gRPC port |
| `WS_PATH` | `/api/v1/events` | Normalized + whitelisted like `PANEL_PATH` |
| `GRPC_SERVICE` | `api.v1.SyncService` | Validated against `^[A-Za-z0-9._-]+$` |
| `CLOUDFLARE_API_TOKEN` | — | Prompted (hidden) unless already exported in the environment |

**Cross-field validation** (all enforced in `validate_inputs`, script dies
with a clear message if violated):

- `PANEL_PORT`, `WS_PORT`, `GRPC_PORT` must all be distinct from each other.
- None of them may be `443` (reserved for the public listener).
- None of them may equal `SSH_PORT`.
- `SSH_PORT` may not be `443`.
- `PANEL_SUBDOMAIN` ≠ `VLESS_SUBDOMAIN`.

---

## Generated files

| Path | Purpose |
|---|---|
| `/etc/letsencrypt/cloudflare.ini` | Cloudflare API token (`chmod 600`) for DNS-01 |
| `/etc/letsencrypt/live/<domain>/` | Wildcard cert + key (managed by certbot) |
| `/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh` | `nginx -t && systemctl reload nginx` on every renewal |
| `/etc/nginx/conf.d/cloudflare-real-ip.conf` | `set_real_ip_from` for all Cloudflare IPv4/IPv6 ranges |
| `/etc/nginx/sites-available/3xui-proxy` | The two `server{}` blocks (panel + VLESS) |
| `/etc/nginx/sites-enabled/3xui-proxy` | Symlink to the above; `sites-enabled/default` is removed |
| `/etc/nginx/.3xui-proxy-ports.state` | Internal bookkeeping so re-runs can clean up stale UFW `deny` rules |

Every config file that already exists is backed up as
`<path>.backup-<YYYYMMDD-HHMMSS>` before being overwritten.

---

## Safety features

- **`set -euo pipefail`** everywhere — the script stops at the first error
  instead of limping forward with a half-applied configuration.
- **Root check** up front (`require_root`).
- **Input validation** for every field, including cross-field port/subdomain
  collision checks (see above) and a character whitelist on user-controlled
  paths, to prevent malformed values from corrupting the generated Nginx
  config.
- **Atomic writes**: every generated file is built in a `mktemp` temp file
  first, then `mv`'d into place — never edited in place.
- **Automatic rollback**: if `nginx -t` fails after writing a new config, the
  previous version is restored (or the new file removed if there was none)
  before the script exits non-zero.
- **Tracked temp files**: all `mktemp` files are registered and cleaned up
  via an `EXIT` trap, even on unexpected failures.
- **UFW deny-by-default for internal ports**: `PANEL_PORT`/`WS_PORT`/`GRPC_PORT`
  are explicitly denied from outside, so a misconfigured Xray/3x-ui bind to
  `0.0.0.0` doesn't expose it directly to the internet.
- **Stale-rule cleanup**: re-running the script with different ports removes
  the old `ufw deny` rules instead of letting them accumulate.
- **Non-destructive Cloudflare token handling**: read via hidden prompt
  (`read -s`) or from an already-exported `CLOUDFLARE_API_TOKEN`, never
  echoed, written with `chmod 600`.

---

## Re-running the script

The script is safe to re-run — it's designed to be idempotent:

- Certbot uses `--keep-until-expiring`, so it won't force a reissue.
- Existing Nginx / real-IP configs are backed up before being replaced.
- UFW rules are reconciled against the previous run's ports (state file),
  removing rules that no longer apply.

Typical reasons to re-run: rotating the Cloudflare token, changing the panel
path, moving to different internal ports, or refreshing Cloudflare's IP
ranges in the real-IP config.

---

## Testing

Unit tests live in [`tests/`](tests/) and use
[bats-core](https://github.com/bats-core/bats-core). All system-mutating
commands (`nginx`, `curl`, `ss`, `ufw`, `certbot`, `systemctl`, `apt`) are
stubbed, so tests run without root and without touching real system state.

```bash
brew install bats-core   # or: apt install bats
chmod +x tests/stubs/*
bats tests/setup.bats
```

See [`tests/README.md`](tests/README.md) for full coverage details and what
is intentionally excluded from the unit suite (real `apt`/`certbot`/`ufw`
calls — those need a disposable VM/container and a real Cloudflare-managed
test domain).

## CI

[`.github/workflows/tests.yml`](.github/workflows/tests.yml) runs on every
push and pull request to `main`:

```
checkout → shellcheck setup.sh → bash -n setup.sh → install bats-core → bats tests/setup.bats
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| `nginx -t` fails after setup | Look for `.backup-<timestamp>` files next to the config that was reverted; inspect them for a diff |
| Panel returns 502 | Confirm 3x-ui is actually listening on `127.0.0.1:PANEL_PORT`: `ss -lntp \| grep PANEL_PORT` |
| VLESS client can't connect | Confirm Xray inbound is bound to `127.0.0.1` (not `0.0.0.0`) on the exact `WS_PORT`/`GRPC_PORT`, and that `WS_PATH`/`GRPC_SERVICE` match exactly |
| Certificate issuance fails | Verify the Cloudflare API token has `Zone:DNS:Edit` on the correct zone; check `/var/log/letsencrypt/letsencrypt.log` |
| Locked out over SSH after running | You likely set `SSH_PORT` to something not matching your actual `sshd_config` — the script only manages UFW rules, it does not touch `sshd_config` |
| Real IPs show as Cloudflare IPs in logs | `cloudflare-real-ip.conf` wasn't generated/loaded — check `nginx -T \| grep real_ip` |

Useful commands (also printed at the end of every run):

```bash
nginx -t
systemctl status nginx
systemctl status certbot.timer
certbot renew --dry-run
ufw status verbose
ss -lntp | egrep ':443|:<PANEL_PORT>|:<WS_PORT>|:<GRPC_PORT>'
```
