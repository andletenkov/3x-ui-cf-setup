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

Requires Docker with privileged-container support (systemd needs real
cgroups):

```bash
tests/e2e/run.sh                    # run every scenario
tests/e2e/run.sh 01-xui-reality.sh  # run just one
```

## Adding a new assertion

Each time we discover a new class of bug in production, the fix belongs in
two places:

1. The actual script fix (`setup.sh` / `setup-3x-ui.sh`).
2. A new assertion in the relevant scenario (or a new scenario, if it's a
   new subsystem) asserting on the *real, observed* behavior that was wrong
   — not a re-assertion of our previous (wrong) assumption. If the bug came
   from an external system's shape/behavior, prefer asserting against the
   real system's actual response over a fixture, even if that couples the
   test to network access — that coupling is the point.

## Scenarios

- `01-xui-reality.sh` — real 3x-ui panel + `setup-3x-ui.sh`: inbound
  creation, VLESS Encryption keys, Reality keys/Host override, subscription
  output.
- `02-nginx-caddy.sh` — real nginx (nginx.org repo) + real Caddy
  (`klzgrad/forwardproxy`) + `setup.sh`'s config-writing functions: config
  validation, service startup, port binding, SNI-based routing.
