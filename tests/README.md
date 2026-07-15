# Tests for setup_nginx_proxy.sh

Unit tests using [bats-core](https://github.com/bats-core/bats-core). No root
privileges or real system changes required — every system-mutating command
(`nginx`, `curl`, `ss`, `ufw`, `certbot`, `systemctl`, `apt`) is stubbed out
via `tests/stubs/`, which is prepended to `PATH` before `setup_nginx_proxy.sh` is sourced.

## Running

```bash
brew install bats-core   # or: apt install bats
bats tests/setup_nginx_proxy.bats
```

## What's covered

- `validate_port` — numeric/range validation
- `normalize_panel_path` / `normalize_ws_path` — slash normalization, root-path
  rejection, character whitelist (`^/[A-Za-z0-9/_-]*$`)
- `validate_inputs` — domain/email/service-name regexes, and all the
  port-collision rules (panel/ws/grpc mutually distinct, none equal to 443,
  none equal to 443)
- `port_is_listening` / `random_free_port` — driven by the `ss` stub via the
  `SS_LISTENING_PORTS` env var
- `write_nginx_config` — correct interpolation of ports/paths/domains, the
  non-deprecated `listen 443 ssl; http2 on;` syntax, and rollback behavior
  when `nginx -t` fails (both with and without a pre-existing config)
- `write_cloudflare_real_ip_config` — correct CIDR interpolation from the
  `curl` stub, clear failure on `curl` errors, and rollback on `nginx -t`
  failure
- `prompt` — default-value fallback, custom value, and "value required" retry
  loop
- `validate_panel_port` — the post-3x-ui-install collision re-check
  (443/WS/gRPC/Subscription) and `PANEL_PATH` normalization
- `print_client_links` — panel credentials output and both `vless://` URIs
  (TLS, correct host, shared client UUID)
- `install_3xui_and_inbounds` — stubs `install-3xui.sh` via `INSTALL_3XUI_SCRIPT`
  to verify PANEL_PORT is forwarded unchanged, output is parsed correctly,
  `XUI_VERSION` is forwarded, and failure/collision paths `die` cleanly
- `uninstall_all` (`--uninstall`) — removes the Nginx site, Cloudflare
  real-IP config, Certbot hook/cert, Cloudflare credentials, this script's
  UFW rules, and delegates to `install-3xui.sh --uninstall`; cancels cleanly
  without touching anything if not confirmed

## What's intentionally NOT unit tested

- `install_packages` (`apt`), `issue_certificate` (real `certbot` + Cloudflare
  DNS), `configure_ufw` (real `ufw`), and the real `systemctl reload nginx`
  call. These touch real system state / external services and should be
  smoke-tested manually or in a disposable VM/container against a throwaway
  Cloudflare-managed test domain, not covered by this unit suite.
- `main()` itself — it is guarded by a `BASH_SOURCE` check so that sourcing
  `setup_nginx_proxy.sh` for tests does not trigger a real run.

## Stubs

Each stub in `tests/stubs/` is a minimal fake executable controlled via
environment variables so tests stay hermetic and fast:

| Stub         | Controlled via                                   |
|--------------|---------------------------------------------------|
| `ss`         | `SS_LISTENING_PORTS="8080 9090"`                   |
| `nginx`      | `NGINX_T_SHOULD_FAIL=1` (makes `nginx -t` fail)    |
| `curl`       | `CURL_SHOULD_FAIL=1`, `CURL_CF_IPV4`, `CURL_CF_IPV6`, `CURL_HTTP_CODE` |
| `ufw`        | `UFW_LOG=/path/to/file` (appends invocations)      |
| `systemctl`, `certbot`, `apt` | always succeed, no-op            |
