# Tests for install.sh, install-3xui.sh and anonymize.sh

Unit tests using [bats-core](https://github.com/bats-core/bats-core). No root
privileges or real system changes required — every system-mutating command
(`nginx`, `curl`, `ss`, `ufw`, `certbot`, `systemctl`, `apt`, `apt-get`,
`sysctl`, `iptables`, `timedatectl`, `netfilter-persistent`) is stubbed out
via `tests/stubs/`, which is prepended to `PATH` before the scripts are
sourced. Two test files: `tests/install.bats` (covers `install.sh`, and
`install-3xui.sh` integration points via stubs) and `tests/anonymize.bats`
(covers `anonymize.sh` directly).

## Running

```bash
brew install bats-core   # or: apt install bats
chmod +x tests/stubs/*
bats tests/install.bats tests/anonymize.bats
```

## What's covered (`tests/install.bats`)

- `validate_port` — numeric/range validation
- `normalize_panel_path` / `normalize_ws_path` — slash normalization, root-path
  rejection, character whitelist (`^/[A-Za-z0-9/_-]*$`)
- `validate_inputs` — domain/email/service-name regexes, and all the
  port-collision rules (panel/ws/grpc mutually distinct, none equal to 443)
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
  UFW rules, and delegates to `install-3xui.sh --uninstall` AND
  `anonymize.sh --uninstall`; cancels cleanly without touching anything if
  not confirmed
- `anonymize_vps` — stubs `anonymize.sh` via `ANONYMIZE_SCRIPT` to verify
  it's invoked, and that a failure/missing script warns without aborting
  the install

## What's covered (`tests/anonymize.bats`)

Each `harden_*`/`unharden_*` function pair, applied and reverted directly
against stubbed `sysctl`/`iptables`/`systemctl`/`timedatectl`/`apt-get`:

- `harden_ntp` / `unharden_ntp` — chrony-preferred-over-timedatectl branch
  selection
- `harden_dns` / `unharden_dns` — DoT config written only when
  `systemd-resolved` is present; clean skip otherwise
- `harden_sysctl` / `unharden_sysctl` — all expected directives present,
  including `icmp_echo_ignore_all` and the normalized default TTL
- `harden_ping_block` / `unharden_ping_block` — two-way ICMP echo-request
  DROP rules (`INPUT` + `OUTPUT`), idempotent re-application, graceful skip
  when `iptables` is absent
- `harden_ttl` / `unharden_ttl` — POSTROUTING TTL-set mangle rule,
  idempotent re-application
- `harden_banners` / `unharden_banners` — SSH `Banner none` config
- `enable_bbr` / `disable_bbr` — fq/bbr sysctl written, active
  congestion-control readback check, graceful skip when the `tcp_bbr`
  module can't be loaded, revert to cubic/pfifo_fast on disable
- `uninstall_all` — full revert of everything a complete run would have
  applied (including BBR); requires root
- `main --uninstall` dispatch
- `print_limitations` — documents the IP/ASN reputation, reverse-DNS and
  WebRTC caveats

## What's intentionally NOT unit tested

- `install_packages` (`apt`), `issue_certificate` (real `certbot` + Cloudflare
  DNS), `configure_ufw` (real `ufw`), and the real `systemctl reload nginx`
  call. These touch real system state / external services and should be
  smoke-tested manually or in a disposable VM/container against a throwaway
  Cloudflare-managed test domain, not covered by this unit suite.
- `main()` itself — it is guarded by a `BASH_SOURCE` check so that sourcing
  `install.sh` for tests does not trigger a real run.

## Stubs

Each stub in `tests/stubs/` is a minimal fake executable controlled via
environment variables so tests stay hermetic and fast:

| Stub         | Controlled via                                   |
|--------------|---------------------------------------------------|
| `ss`         | `SS_LISTENING_PORTS="8080 9090"`                   |
| `nginx`      | `NGINX_T_SHOULD_FAIL=1` (makes `nginx -t` fail)    |
| `curl`       | `CURL_SHOULD_FAIL=1`, `CURL_CF_IPV4`, `CURL_CF_IPV6`, `CURL_HTTP_CODE` |
| `ufw`        | `UFW_LOG=/path/to/file` (appends invocations)      |
| `iptables`   | `IPTABLES_STATE_FILE=/path/to/file` — stateful fake: tracks added rules so `-C`/`-A`/`-D` behave consistently across calls |
| `sysctl`     | `-p <file>` fails if the file doesn't exist, mirroring real behavior |
| `timedatectl`| `status` prints lines containing `sync`/`ntp` for the log-grep in `harden_ntp` |
| `sysctl -n net.ipv4.tcp_congestion_control` | `SYSCTL_STUB_CONGESTION_CONTROL` (default `bbr`) — simulates the post-`enable_bbr` readback |
| `modprobe`   | `MODPROBE_SHOULD_FAIL=1` — simulates a kernel without BBR support |
| `systemctl`, `certbot`, `apt`, `apt-get`, `netfilter-persistent` | always succeed, no-op |
