#!/usr/bin/env bash
# Scenario 2: installs REAL nginx (from the nginx.org apt repo, as
# install_packages does) and a REAL Caddy/forwardproxy binary, then drives
# setup.sh's real config-writing functions and asserts on real runtime
# behavior. Catches the class of bug scenario 1 can't, because it needs
# actual installed system services:
#   - nginx.org packages not including sites-enabled by default (breaks the
#     panel/VLESS server blocks silently -- `nginx -t` still passes because
#     the include just matches zero files)
#   - Caddy's auto_https trying to bind :80 (conflicts with nginx) and
#     opening an unwanted HTTP/3 listener
#   - klzgrad/naiveproxy (client-only `naive` binary) vs
#     klzgrad/forwardproxy (actual Caddy server build) confusion
#   - the nginx stream{} SNI Guard actually routing by SNI to the right
#     upstream at the TCP level (not just "config parses")
#
# Run inside the e2e container (see run.sh). Exits non-zero with a specific
# message on the first failed assertion.
set -euo pipefail

REPO="/opt/repo"
FAIL=0

fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "  ok: $*" >&2; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "${desc}: expected '${expected}', got '${actual}'"
  else
    ok "$desc"
  fi
}

assert_true() {
  local desc="$1"
  shift
  if "$@"; then
    ok "$desc"
  else
    fail "$desc"
  fi
}

cd "$REPO"
chmod +x setup.sh
export VPS_COUNTRY_CODE="EE"
export FALLBACK_HTML_PATH=""

# shellcheck disable=SC1091
source ./setup.sh

# --- Set up the full variable environment write_nginx_config/write_caddyfile
# expect, matching what setup.sh's main() would have collected interactively.
# MUST happen AFTER sourcing: setup.sh unconditionally resets these to their
# defaults ('' for most) at top-level scope, so setting them before sourcing
# would just get clobbered.
BASE_DOMAIN="e2e.test"
PANEL_SUBDOMAIN="admin"
VLESS_SUBDOMAIN="lab"
EMAIL="test@e2e.test"
PANEL_PATH="/panel$(openssl rand -hex 4)"
PANEL_PORT=23456
SUB_PORT=23460; WS_PORT=23457; GRPC_PORT=23458; XHTTP_PORT=23459
WS_PATH="/ws1"; GRPC_SERVICE="grpc1"; XHTTP_PATH="/xhttp1"; SUB_PATH="/sub1"
REALITY_SUBDOMAIN="reality"; REALITY_DEST="github.com"; REALITY_PORT=23461
NAIVE_SUBDOMAIN="naive"; NAIVE_PORT=23462
NAIVE_USERNAME="e2euser"; NAIVE_PASSWORD="e2epass$(openssl rand -hex 4)"
NGINX_CDN_PORT=23463; NGINX_DECOY_PORT=23464

# CERT_DIR is normally a Let's Encrypt live/ dir; stand in with a self-signed
# cert so nginx/Caddy config validation and TLS handshakes work without real
# DNS/ACME. This is the one deliberate divergence from production -- every
# other piece (nginx.org package, real Caddy binary, real config-generation
# code) is exactly what runs on a real VPS.
CERT_DIR="/etc/e2e-selfsigned"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem" \
  -subj "/CN=${BASE_DOMAIN}" \
  -addext "subjectAltName=DNS:${BASE_DOMAIN},DNS:*.${BASE_DOMAIN}" \
  2>/dev/null

echo "--- Installing real nginx from nginx.org repo ---" >&2
install_packages

echo "--- Installing real Caddy/forwardproxy binary ---" >&2
install_naiveproxy

if [[ -x "$NAIVE_BIN" ]]; then
  binary_basename="$(basename "$NAIVE_BIN")"
  assert_eq "installed NaiveProxy binary is named 'caddy' (not the client-only 'naive')" \
    "caddy" "$binary_basename"
else
  fail "NAIVE_BIN (${NAIVE_BIN}) is not executable after install_naiveproxy"
fi

echo "--- Writing and validating Caddyfile ---" >&2
write_caddyfile
assert_true "caddy validate accepts the generated Caddyfile" \
  "$NAIVE_BIN" validate --config "$CADDYFILE"

if grep -q "auto_https off" "$CADDYFILE"; then
  ok "Caddyfile disables auto_https (avoids the port-80 bind conflict)"
else
  fail "Caddyfile is missing 'auto_https off' -- Caddy will try to bind :80"
fi

echo "--- Writing nginx config (panel/VLESS server blocks + stream SNI Guard) ---" >&2
ensure_nginx_stream_context
write_nginx_stream_config
write_nginx_config

assert_true "'nginx -t' accepts the generated config" nginx -t

if grep -rq "sites-enabled" /etc/nginx/nginx.conf; then
  ok "nginx.conf includes sites-enabled (needed by nginx.org packages)"
else
  fail "nginx.conf does not include sites-enabled -- panel/VLESS server blocks would silently never load"
fi

echo "--- Starting real services ---" >&2
write_naive_systemd_unit
assert_true "caddy (NaiveProxy) systemd service is active" \
  systemctl is-active --quiet caddy

if ss -tlnp 2>/dev/null | grep -q ":80 "; then
  fail "something is listening on :80 -- Caddy's auto_https regressed and is binding it again"
else
  ok "nothing listens on :80 (Caddy's auto_https stayed disabled)"
fi

systemctl restart nginx
assert_true "nginx service is active" systemctl is-active --quiet nginx

echo "--- Verifying the stream{} SNI Guard actually routes by SNI ---" >&2
if ss -tlnp 2>/dev/null | grep -q ":443 "; then
  ok "nginx stream{} SNI Guard is listening on :443"
else
  fail "nothing listens on :443 after write_nginx_config -- stream{} SNI Guard did not start"
fi

# An unrecognized SNI should hit the decoy vhost (a real nginx server block
# behind the SNI Guard) and get the real cert back over a full TLS
# handshake -- proving ssl_preread + proxy_pass actually route traffic, not
# just that the config happens to parse.

if timeout 5 openssl s_client -connect 127.0.0.1:443 -servername unknown.invalid </dev/null 2>&1 \
    | grep -q "CN.*=.*${BASE_DOMAIN}"; then
  ok "unrecognized SNI routes to the decoy vhost (serves the real cert)"
else
  fail "unrecognized SNI did not reach the decoy vhost as expected"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo >&2
  echo "One or more assertions failed -- see FAIL lines above." >&2
  exit 1
fi

echo >&2
echo "All assertions passed." >&2
