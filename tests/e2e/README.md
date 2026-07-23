# E2E smoke tests

This tier exists because the `tests/*.bats` suite (hand-written stubs for
`curl`, `systemctl`, etc.) can only validate *"given input X, does the script
produce output Y"* — where X is whatever we assumed the real world looks
like. It structurally cannot catch *"our assumption about the real world was
wrong"*, which in practice is where almost every serious bug in this repo has
come from:

- 3x-ui's `getNewmlkem768` endpoint returning `{seed, client}` instead of the
  `{serverKey, clientKey}` shape the script (and its stub) assumed.
- The NaiveProxy install pulling from `klzgrad/naiveproxy` (a client-only
  `naive` binary) instead of `klzgrad/forwardproxy` (the actual Caddy server
  build) — the stub fixture hardcoded the wrong repo's release shape.
- Caddy's `auto_https` trying to bind `:80` (conflicting with nginx) and
  opening an unwanted HTTP/3 listener — only observable by actually starting
  Caddy.
- `nginx.org`'s apt package not including `sites-enabled` by default —
  `nginx -t` still passes (the `include` glob just matches zero files), so
  no stub-based test would ever notice.
- A Reality inbound's `externalProxy` field silently corrupting 3x-ui's
  persistent `hosts` table, forcing every subscription-generated Reality
  link to `security=tls` regardless of the inbound's actual config — this is
  undocumented 3x-ui-internal behavior nobody could have written a stub for
  in advance.
- The Reality inbound missing the nested `realitySettings.settings.publicKey`
  field 3x-ui's panel/subscription generator actually reads from.

None of these are logic bugs a stub can catch, because the stub encodes the
same wrong assumption as the code being tested. This tier instead runs the
real scripts against real, actually-installed software (real 3x-ui via its
own upstream installer, real nginx from the nginx.org repo, a real Caddy
binary from `klzgrad/forwardproxy`) inside a systemd-booted Docker container,
and asserts on real observed behavior — actual API responses, actual
`nginx -t`/`caddy validate` results, actual TLS handshakes.

## Table of contents

- [What it does NOT replace](#what-it-does-not-replace)
- [What it does NOT cover (yet)](#what-it-does-not-cover-yet)
- [Running locally](#running-locally)
- [Adding a new assertion](#adding-a-new-assertion)
- [Scenarios](#scenarios)
  - [Known local-only caveat: QEMU emulation on arm64 dev hosts](#known-local-only-caveat-qemu-emulation-on-arm64-dev-hosts)

## What it does NOT replace

Pure logic (argument parsing, port-collision math, idempotency checks,
config-file templating) stays covered by `tests/*.bats` — those are fast,
deterministic, and the right tool for that job. This tier is additive.

## What it does NOT cover (yet)

Real DNS + Let's Encrypt/Cloudflare ACME issuance is out of scope — that
needs a real public domain and would make the suite dependent on external,
rate-limited infrastructure. `CERT_DIR` is instead pointed at a locally
generated self-signed cert; everything else (the actual `nginx.org` package,
the actual Caddy binary, the actual 3x-ui installer/API) is real.

## Running locally

This tier is **manual and local-only** -- it is deliberately not part of CI
(see `.github/workflows/tests.yml`). It's slow (real package installs, a
systemd boot, real binary downloads), occasionally network-flaky, and needs
`--privileged` Docker support shared CI runners don't reliably provide.
Run it yourself before merging any change that touches transport/inbound
behavior.

Requires Docker with privileged-container support (systemd needs real
cgroups):

```bash
tests/e2e/run.sh                          # run every scenario
tests/e2e/run.sh 01-xui-reality.sh        # run just one
tests/e2e/run.sh 03-transport-connectivity.sh
```

On an Apple Silicon/arm64 host, this always runs under QEMU amd64 emulation
(see the caveat below) -- expect it to be noticeably slower than on a native
amd64 machine, and treat a failure that reproduces only there as suspect
until confirmed (or not) natively.

## Adding a new assertion

Each time we discover a new class of bug in production, the fix belongs in
two places:

1. The actual script fix (`setup.sh`).
2. A new assertion in the relevant scenario (or a new scenario, if it's a
   new subsystem) asserting on the *real, observed* behavior that was wrong
   — not a re-assertion of our previous (wrong) assumption. If the bug came
   from an external system's shape/behavior, prefer asserting against the
   real system's actual response over a fixture, even if that couples the
   test to network access — that coupling is the point.

## Scenarios

- `01-xui-reality.sh` — real 3x-ui `INSTALL_MODE=no-cdn` flow: Reality keys,
  Host override, subscription output, and proof that no WS/gRPC/XHTTP inbound
  was created.

- `02-nginx-caddy.sh` — real nginx (nginx.org repo): validates the
  `INSTALL_MODE=cdn` listener and VLESS TLS handshake, then renders the
  `no-cdn` flow and proves its Nginx site has no CDN VLESS proxy locations.

- `03-transport-connectivity.sh` — real client-to-upstream connectivity for
  every transport: starts an actual client (the same xray-core binary 3x-ui
  installs, the real `hysteria` client, the real `mieru` client, plain curl
  for NaiveProxy) and asserts on the real response fetched *through* each
  tunnel from `https://example.com`. This is the tier scenarios 1-2
  deliberately don't cover: API payloads, generated config, listeners, and
  TLS handshakes are necessary but not sufficient proof a client can
  actually push a byte through and get a real answer back. Covers VLESS
  WebSocket/gRPC/XHTTP through Nginx, VLESS+Reality direct, Hysteria2 direct
  (including Salamander/`finalmask`), NaiveProxy's HTTPS forward proxy, and
  mieru direct.

Together these scenarios enforce that the two installation flows never create
mixed CDN and direct inbounds, and that every configured transport is
actually reachable by a real, compatible client -- not just well-formed.

### Known local-only caveat: QEMU emulation on arm64 dev hosts

`run.sh` always targets `linux/amd64` (NaiveProxy's real binary is
amd64-only), so on an Apple Silicon/arm64 dev machine every Go binary in
scenario 3 (xray-core, `mita`, `mieru`, `hysteria`) runs under QEMU
user-mode emulation. This caused a SIGSEGV inside grpc-go's HTTP/2 transport
during `mita apply config` on an arm64 dev host, reproducing even with
`GODEBUG=asyncpreemptoff=1` set.

Confirmed as a pure QEMU artifact, not a real bug: the identical
`mita apply config` -> `mita start` -> real `mieru` client -> real SOCKS5
tunnel -> `curl https://example.com` chain, run natively on arm64 (a
systemd/cgroups container built for `linux/arm64`, no emulation involved),
completes with zero crashes and returns the real `Example Domain` response
through the tunnel end-to-end. The failure only manifests when the same Go
binaries run under QEMU's amd64-on-arm64 translation, which is exactly what
`run.sh`'s forced `--platform linux/amd64` does on an arm64 host. GitHub
Actions' `ubuntu-latest` runners are natively amd64, so this scenario is not
expected to hit the same emulator crash there.
