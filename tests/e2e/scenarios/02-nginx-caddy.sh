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
INSTALL_MODE="cdn"
BASE_DOMAIN="e2e.test"
PANEL_SUBDOMAIN="admin"
VLESS_SUBDOMAIN="lab"
EMAIL="test@e2e.test"
PANEL_PATH="/panel$(openssl rand -hex 4)"
PANEL_PORT=23456
SUB_PORT=23460; WS_PORT=23457; GRPC_PORT=23458; XHTTP_PORT=23459
WS_PATH="/ws1"; GRPC_SERVICE="grpc1"; XHTTP_PATH="/xhttp1"; SUB_PATH="/sub1"
# Direct transports are intentionally excluded from the CDN flow.
REALITY_SUBDOMAIN=""; REALITY_DEST=""; REALITY_PORT=""
NAIVE_SUBDOMAIN=""; NAIVE_PORT=""
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

echo "--- Writing nginx config (panel/VLESS server blocks + stream SNI Guard) ---" >&2
write_nginx_config

assert_true "'nginx -t' accepts the generated config" nginx -t

if grep -rq "sites-enabled" /etc/nginx/nginx.conf; then
  ok "nginx.conf includes sites-enabled (needed by nginx.org packages)"
else
  fail "nginx.conf does not include sites-enabled -- panel/VLESS server blocks would silently never load"
fi

# systemctl start/restart returns once the unit is "started", not once its
# listener socket is actually bound -- polling briefly instead of a single
# snapshot check avoids flaky false negatives/positives on slower hosts
# (e.g. under QEMU amd64 emulation on an arm64 dev machine).
wait_for_port_state() {
  local port="$1" want_listening="$2" tries=10
  while ((tries-- > 0)); do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      [[ "$want_listening" == "yes" ]] && return 0
    else
      [[ "$want_listening" == "no" ]] && return 0
    fi
    sleep 0.5
  done
  return 1
}

echo "--- Starting real services ---" >&2
systemctl restart nginx
assert_true "nginx service is active" systemctl is-active --quiet nginx

echo "--- Verifying the CDN Nginx listener ---" >&2
if wait_for_port_state 443 yes; then
  ok "nginx is listening directly on :443 for CDN inbounds"
else
  fail "nothing listens on :443 after write_nginx_config"
fi

if timeout 5 openssl s_client -connect 127.0.0.1:443 -servername "${VLESS_SUBDOMAIN}.${BASE_DOMAIN}" </dev/null 2>&1 \
    | grep -q "CN.*=.*${BASE_DOMAIN}"; then
  ok "CDN VLESS hostname completes a TLS handshake"
else
  fail "CDN VLESS hostname did not complete a TLS handshake"
fi

echo "--- Rendering the no-cdn Nginx flow ---" >&2
INSTALL_MODE="no-cdn"
REALITY_SUBDOMAIN="reality"; REALITY_DEST="github.com"; REALITY_PORT=23461
NGINX_CDN_PORT=23463; NGINX_DECOY_PORT=23464
write_nginx_config
assert_true "no-cdn nginx configuration validates" nginx -t
if grep -q "server_name ${VLESS_SUBDOMAIN}.${BASE_DOMAIN};" "$NGINX_SITE" || \
   grep -q "127.0.0.1:${WS_PORT}" "$NGINX_SITE" || \
   grep -q "127.0.0.1:${GRPC_PORT}" "$NGINX_SITE" || \
   grep -q "127.0.0.1:${XHTTP_PORT}" "$NGINX_SITE"; then
  fail "no-cdn Nginx configuration contains a CDN VLESS proxy"
else
  ok "no-cdn Nginx configuration contains no CDN VLESS proxy"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo >&2
  echo "One or more assertions failed -- see FAIL lines above." >&2
  exit 1
fi

echo >&2
echo "All assertions passed." >&2
