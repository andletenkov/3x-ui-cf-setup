# 3x-ui-nginx-proxy

![Tests](https://github.com/andletenkov/3x-ui-nginx-proxy/actions/workflows/tests.yml/badge.svg)
![License](https://img.shields.io/github/license/andletenkov/3x-ui-nginx-proxy)

Interactive setup that installs **3x-ui** (unattended) and puts **Nginx** in
front of its panel and VLESS/WS + VLESS/gRPC **Xray** inbounds, behind
**Cloudflare**, with a **Let's Encrypt wildcard certificate** (DNS-01) and a
locked-down **UFW** firewall.

Two scripts:

| Script | Responsibility |
|---|---|
| `install-3xui.sh` | Installs 3x-ui unattended (or reuses an existing install), creates the WS/gRPC inbounds via the panel API. Invoked automatically by `setup_nginx_proxy.sh` — not normally run by hand. |
| `setup_nginx_proxy.sh` | Everything else: Nginx reverse proxy, TLS, UFW, Cloudflare real-IP restoration. Calls `install-3xui.sh` as part of its flow. |

3x-ui itself is the source of truth for its username/password/web-base-path
(generated securely by its own installer); `setup_nginx_proxy.sh` only
pre-reserves the panel **port** up front so it can't collide with the
WS/gRPC/Subscription/SSH ports it also owns.

## Architecture

```mermaid
flowchart TD
    Internet["Internet"] --> CF["Cloudflare (DNS + proxy)"]
    CF -->|"HTTPS :443"| Nginx["Nginx :443 (TLS)"]

    subgraph VPS["VPS"]
        UFW["UFW: allow SSH_PORT, 443 · deny 80, PANEL_PORT, WS_PORT, GRPC_PORT"]
        Nginx
        Panel["3x-ui panel — 127.0.0.1:PANEL_PORT"]
        WS["Xray WS inbound — 127.0.0.1:WS_PORT"]
        GRPC["Xray gRPC inbound — 127.0.0.1:GRPC_PORT"]
    end

    Nginx -->|"admin.domain, path PANEL_PATH"| Panel
    Nginx -->|"vpn.domain, path WS_PATH"| WS
    Nginx -->|"vpn.domain, service GRPC_SERVICE"| GRPC
```

Two `server{}` blocks are generated, both on port 443 with the same wildcard
cert, split by `server_name`:

| Domain | Purpose | Backend |
|---|---|---|
| `<PANEL_SUBDOMAIN>.<BASE_DOMAIN>` | 3x-ui panel | `127.0.0.1:PANEL_PORT` |
| `<VLESS_SUBDOMAIN>.<BASE_DOMAIN>` | VLESS WebSocket + gRPC | `127.0.0.1:WS_PORT` / `127.0.0.1:GRPC_PORT` |

Everything else on either domain returns `404`.

## Prerequisites

- Debian/Ubuntu VPS, run as root.
- Domain managed by Cloudflare.
- Cloudflare API token with `Zone:DNS:Edit` on that zone.
- Nothing else — 3x-ui is installed for you (unattended) if not already
  present.

## Usage

```bash
git clone https://github.com/andletenkov/3x-ui-nginx-proxy.git && cd 3x-ui-nginx-proxy
chmod +x setup_nginx_proxy.sh install-3xui.sh
sudo ./setup_nginx_proxy.sh
```

(`install-3xui.sh` must sit next to `setup_nginx_proxy.sh` — it's invoked
automatically, not downloaded separately.)

You'll be prompted for the base domain, subdomains, email, SSH port,
internal ports (WS/gRPC/panel default to random free ports), WS path, gRPC
service name, and your Cloudflare API token. A summary is shown before
anything is changed on disk.

During the run, 3x-ui is installed unattended (or reused if already
installed) and the WS/gRPC inbounds are created automatically via its panel
API — no manual copy-pasting of inbound JSON. The generated panel
username/password are printed at the end, along with ready-to-import
`vless://` client links. The script then optionally runs a live check
(internal ports listening + public HTTPS reachability).

### Pinning the 3x-ui version

```bash
sudo XUI_VERSION=v3.4.0 ./setup_nginx_proxy.sh
```

Unset (default) installs the latest stable 3x-ui release. `dev-latest` is
also accepted (rolling pre-release build). Only used on a fresh 3x-ui
install — ignored if 3x-ui is already installed on the host.

### Uninstalling

```bash
sudo ./setup_nginx_proxy.sh --uninstall
```

Removes everything both scripts set up: the Nginx site and Cloudflare
real-IP config, the Certbot deploy hook and certificate for `BASE_DOMAIN`,
the Cloudflare API token file, the UFW rules this script added, 3x-ui itself
(service, binary, `/etc/x-ui`, `/usr/local/x-ui`), and the saved
config/state files. Asks for confirmation first. Safe to run even if some
pieces were never installed.

`install-3xui.sh --uninstall` can also be run directly to remove just 3x-ui
(service, binary, `/etc/x-ui`, `/usr/local/x-ui`) without touching
Nginx/UFW/certs.

## Configuration reference

| Variable | Default | Notes |
|---|---|---|
| `BASE_DOMAIN` | — | Required |
| `PANEL_SUBDOMAIN` | `admin` | Must differ from `VLESS_SUBDOMAIN` |
| `VLESS_SUBDOMAIN` | `vpn` | Must differ from `PANEL_SUBDOMAIN` |
| `PANEL_PATH` | `/my-admin` | Letters/numbers/`/`/`_`/`-` only |
| `EMAIL` | — | Let's Encrypt contact |
| `SSH_PORT` | `22` | Can't be `443`; internal ports can't equal this |
| `PANEL_PORT` | `2053` | Internal 3x-ui port |
| `WS_PORT` | random | Internal Xray WS port |
| `GRPC_PORT` | random | Internal Xray gRPC port |
| `WS_PATH` | `/api/v1/events` | Same character rules as `PANEL_PATH` |
| `GRPC_SERVICE` | `api.v1.SyncService` | `[A-Za-z0-9._-]+` |
| `CLOUDFLARE_API_TOKEN` | — | Prompted (hidden) unless already exported |

`PANEL_PORT`/`WS_PORT`/`GRPC_PORT` must all differ from each other, from
`443`, and from `SSH_PORT`.

## Generated files

| Path | Purpose |
|---|---|
| `/etc/letsencrypt/cloudflare.ini` | Cloudflare API token (`chmod 600`) |
| `/etc/letsencrypt/live/<domain>/` | Wildcard cert + key |
| `/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh` | Reloads Nginx on renewal |
| `/etc/nginx/conf.d/cloudflare-real-ip.conf` | Trusted Cloudflare IP ranges |
| `/etc/nginx/sites-available/3xui-proxy` | Panel + VLESS server blocks |
| `/etc/nginx/sites-enabled/3xui-proxy` | Symlink (default site removed) |

Existing files are backed up as `<path>.backup-<timestamp>` before being
overwritten.

## Safety

- Every config write is atomic (temp file → `mv`), with automatic rollback
  if `nginx -t` fails.
- All internal ports are explicitly denied in UFW, so a service accidentally
  bound to `0.0.0.0` is still not reachable from the internet.
- Re-running the script is safe: certs aren't force-reissued, configs are
  backed up, and stale UFW rules from previous runs are cleaned up.

## Testing

```bash
brew install bats-core   # or: apt install bats
chmod +x tests/stubs/*
bats tests/setup_nginx_proxy.bats
```

See [`tests/README.md`](tests/README.md) for coverage details. CI
([`.github/workflows/tests.yml`](.github/workflows/tests.yml)) runs
shellcheck + these tests on every push/PR to `main`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `nginx -t` fails after setup | Look for a `.backup-<timestamp>` file next to the reverted config |
| Panel returns 502 | `ss -lntp \| grep PANEL_PORT` — is 3x-ui actually listening there? |
| VLESS client can't connect | Confirm Xray is bound to `127.0.0.1` on the exact `WS_PORT`/`GRPC_PORT`, with matching `WS_PATH`/`GRPC_SERVICE` |
| Certificate issuance fails | Check the Cloudflare token's permissions and `/var/log/letsencrypt/letsencrypt.log` |
| Locked out over SSH | The script only manages UFW rules — it doesn't touch `sshd_config` |

Useful commands (also printed at the end of every run):

```bash
nginx -t
ufw status verbose
certbot renew --dry-run
ss -lntp | egrep ':443|:<PANEL_PORT>|:<WS_PORT>|:<GRPC_PORT>'
```
