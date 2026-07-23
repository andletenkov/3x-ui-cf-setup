# Tests

Two independent test tiers, kept deliberately separate:

| Tier | What it runs against | Speed | CI |
|---|---|---|---|
| [Bats unit tests](#bats-unit-tests) (`tests/*.bats`) | Hand-written stubs for `curl`, `systemctl`, `nginx`, etc. | Fast, deterministic | Runs on every push/PR |
| [E2E smoke tests](e2e/README.md) (`tests/e2e/`) | Real installed software (3x-ui, nginx.org packages, Caddy, xray-core, hysteria, mieru) in a real Docker container | Slow, real network/installs | **Manual/local only** -- not run in CI |

Run both before merging any change that touches `setup.sh` or `harden-host.sh`.

## Table of contents

- [Bats unit tests](#bats-unit-tests)
  - [Run locally](#run-locally)
  - [Coverage](#coverage)
  - [Stubs](#stubs)
- [E2E smoke tests](#e2e-smoke-tests)
- [CI](#ci)

## Bats unit tests

Covers `setup.sh` and `harden-host.sh` logic: argument parsing, port/path
validation, config-file templating, idempotency. System-mutating commands
are replaced by executables in `tests/stubs/`; no root access or real
Cloudflare zone is needed.

### Run locally

```bash
brew install bats-core   # or: apt install bats
chmod +x tests/stubs/*
bats tests/install.bats tests/anonymize.bats
```

### Coverage

`tests/install.bats` covers:

- required `CDN_MODE` validation and mutually exclusive CDN/direct inbound flows;
- port/path validation, including XHTTP API-style paths and collision checks;
- generated Nginx WS, gRPC, XHTTP, fallback, and panel proxy locations;
- XHTTP packet-up prefix routing for session/sequence subpaths;
- fallback-page installation and 404 behavior;
- Cloudflare real-IP generation and UFW rules;
- panel port validation, generated client links, and explicit enabled-client
  payloads;
- NaiveProxy, Hysteria2, and mieru install/config/UFW/uninstall behavior
  (including mieru's boring-port-set selection and collision skipping);
- 3x-ui install/inbound configuration, subscription forwarding, uninstall
  cleanup, and idempotent reruns.

`tests/anonymize.bats` covers DNS, NTP, sysctl, ICMP, TTL, banner, BBR, and
uninstall behavior in `harden-host.sh`.

### Stubs

| Stub | Purpose |
|---|---|
| `nginx` | Simulates config validation failures with `NGINX_T_SHOULD_FAIL=1` |
| `curl` | Supplies configurable Cloudflare IP ranges and HTTP responses |
| `ufw` | Records commands to `UFW_LOG` |
| `ss` | Simulates listeners via `SS_LISTENING_PORTS` |
| `iptables`, `sysctl`, `timedatectl`, `systemctl` | Isolate host-hardening behavior |
| `certbot`, `apt`, `apt-get`, `netfilter-persistent` | No-op external/system operations |

## E2E smoke tests

Real 3x-ui, real nginx.org packages, real Caddy/forwardproxy, real
xray-core/hysteria/mieru clients, running inside a real systemd-booted
Docker container -- no stubs. Exists because the bats tier can only catch
"given input X, does the script produce output Y", never "was our
assumption about the real world (API shapes, release asset names, runtime
service behavior) actually correct." See [`tests/e2e/README.md`](e2e/README.md)
for the full rationale, scenario list, and a documented QEMU-on-arm64 caveat.

**This tier is not run in CI** -- it's slow, real-network-dependent, and
needs `--privileged` Docker support. Run it yourself locally:

```bash
tests/e2e/run.sh                                   # every scenario
tests/e2e/run.sh 03-transport-connectivity.sh      # just one
```

## CI

`.github/workflows/tests.yml` runs ShellCheck + `bash -n` + the full Bats
suite on every push/PR to `main`. The E2E tier is intentionally excluded from
CI (see above) -- it's a manual pre-merge check for anyone changing
transport/inbound behavior, not an automated gate.
