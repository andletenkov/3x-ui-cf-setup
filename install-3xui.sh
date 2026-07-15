#!/usr/bin/env bash
# Installs 3x-ui unattended (if not already installed) and creates the
# VLESS/WS + VLESS/gRPC inbounds via the 3x-ui panel API. Invoked by setup_nginx_proxy.sh.
#
# 3x-ui's own installer (install.sh) is the SOURCE OF TRUTH for panel
# credentials and web base path: when XUI_USERNAME/XUI_PASSWORD/
# XUI_WEB_BASE_PATH are left unset, install.sh generates secure random
# values itself and persists them to /etc/x-ui/install-result.env
# (mode 600). This script deliberately does NOT pass those vars in.
#
# The panel PORT is the one exception: setup_nginx_proxy.sh reserves it up front (before
# installing 3x-ui) so it cannot collide with the WS/gRPC/Subscription/SSH
# ports it also owns, and hands it here as PANEL_PORT -- which is forwarded
# to the installer as XUI_PANEL_PORT. This script also forces
# XUI_SSL_MODE=none, because TLS is terminated by Nginx, not Xray/3x-ui.
#
# It then reads the resulting values back out of install-result.env (the
# panel port there should simply confirm what we asked for) and reports them
# to setup_nginx_proxy.sh.
#
# Required env vars (owned by setup_nginx_proxy.sh -- 3x-ui has no say in these):
#   PANEL_PORT                   - pre-reserved panel port (see above)
#   WS_PORT, WS_PATH             - VLESS/WS inbound
#   GRPC_PORT, GRPC_SERVICE      - VLESS/gRPC inbound
# Optional:
#   CLIENT_UUID                  - reuse an existing client UUID (persisted
#                                  across setup_nginx_proxy.sh reruns); generated if empty
#   XUI_VERSION                  - 3x-ui release tag to install (e.g. v3.4.0,
#                                  or dev-latest). Unset/empty installs the
#                                  latest stable release (installer default).
#
# On success, prints these lines (in this order) to stdout, one per line:
#   PANEL_PORT=<port>
#   PANEL_PATH=<path>
#   XUI_USERNAME=<username>
#   XUI_PASSWORD=<password>
#   CLIENT_UUID=<uuid>
# setup_nginx_proxy.sh parses these key=value lines; nothing else should be relied upon.
# Human-readable progress goes to stderr.
#
# CLI:
#   --uninstall   Completely remove 3x-ui (service, binary, /etc/x-ui,
#                 /usr/local/x-ui) and exit. Does not touch Nginx/UFW/certs --
#                 that's setup_nginx_proxy.sh --uninstall's job. Safe to run
#                 even if 3x-ui isn't installed (no-op).

set -euo pipefail

INSTALL_RESULT_FILE="/etc/x-ui/install-result.env"
XUI_SERVICE_UNIT="/etc/systemd/system/x-ui.service"

die() {
  echo "install-3xui.sh ERROR: $*" >&2
  exit 1
}

xui_is_installed() {
  [[ -d /etc/x-ui ]] && command -v x-ui >/dev/null 2>&1
}

uninstall_xui() {
  if ! xui_is_installed && [[ ! -d /usr/local/x-ui ]] && [[ ! -f "$XUI_SERVICE_UNIT" ]]; then
    echo "3x-ui is not installed, nothing to uninstall." >&2
    return 0
  fi

  echo "Uninstalling 3x-ui..." >&2

  # Try 3x-ui's own uninstall path first (best-effort, non-interactive: 'y'
  # piped in for any confirmation prompt). Then force-remove everything
  # regardless, so this is idempotent and complete even if that CLI path
  # changes between versions or the install is partially broken.
  if command -v x-ui >/dev/null 2>&1; then
    yes y 2>/dev/null | x-ui uninstall >&2 || true
  fi

  systemctl stop x-ui >/dev/null 2>&1 || true
  systemctl disable x-ui >/dev/null 2>&1 || true
  pkill -f 'mtg-linux-[^ ]* run ' >/dev/null 2>&1 || true

  rm -f "$XUI_SERVICE_UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true

  rm -rf /etc/x-ui
  rm -rf /usr/local/x-ui
  rm -f /usr/bin/x-ui

  echo "3x-ui fully removed." >&2
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall_xui
  exit 0
fi

: "${PANEL_PORT:?PANEL_PORT is required}"
: "${WS_PORT:?WS_PORT is required}"
: "${WS_PATH:?WS_PATH is required}"
: "${GRPC_PORT:?GRPC_PORT is required}"
: "${GRPC_SERVICE:?GRPC_SERVICE is required}"
: "${SUB_PORT:?SUB_PORT is required}"
: "${SUB_PATH:?SUB_PATH is required}"

CLIENT_UUID="${CLIENT_UUID:-}"
CLIENT_SUB_ID="${CLIENT_SUB_ID:-}"
XUI_VERSION="${XUI_VERSION:-}"

generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    die "No UUID generator available (need /proc/sys/kernel/random/uuid, uuidgen, or python3)."
  fi
}

[[ -n "$CLIENT_UUID" ]] || CLIENT_UUID="$(generate_uuid)"
[[ -n "$CLIENT_SUB_ID" ]] || CLIENT_SUB_ID="$(openssl rand -hex 8)"

install_xui() {
  echo "3x-ui not found, running unattended installer (3x-ui will generate its own secure username/password/path; port ${PANEL_PORT} is pre-reserved by setup_nginx_proxy.sh)..." >&2
  if [[ -n "$XUI_VERSION" ]]; then
    echo "Requested XUI_VERSION=${XUI_VERSION}." >&2
  fi
  # Deliberately not passing XUI_USERNAME/XUI_PASSWORD/XUI_WEB_BASE_PATH:
  # install.sh treats "unset" as "generate a secure random value", which is
  # what we want. XUI_PANEL_PORT IS passed, since setup_nginx_proxy.sh already reserved
  # it to avoid colliding with WS/gRPC/Subscription/SSH ports. XUI_VERSION, if
  # set, is forwarded as install.sh's positional version argument (e.g.
  # v3.4.0 or dev-latest); unset installs the latest stable release.
  XUI_NONINTERACTIVE=1 \
  XUI_PANEL_PORT="$PANEL_PORT" \
  XUI_SSL_MODE="none" \
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) ${XUI_VERSION:+"$XUI_VERSION"} \
    || die "3x-ui unattended install failed."
}

read_install_result() {
  [[ -f "$INSTALL_RESULT_FILE" ]] ||
    die "Expected ${INSTALL_RESULT_FILE} after install but it does not exist. Inspect the 3x-ui install log above, or if 3x-ui was already installed/customized before, ensure ${INSTALL_RESULT_FILE} exists (re-run 'x-ui' and set/save credentials, or delete /etc/x-ui and let this script reinstall)."

  # shellcheck disable=SC1090
  source "$INSTALL_RESULT_FILE"

  : "${XUI_USERNAME:?${INSTALL_RESULT_FILE} did not contain XUI_USERNAME}"
  : "${XUI_PASSWORD:?${INSTALL_RESULT_FILE} did not contain XUI_PASSWORD}"
  : "${XUI_PANEL_PORT:?${INSTALL_RESULT_FILE} did not contain XUI_PANEL_PORT}"
  : "${XUI_WEB_BASE_PATH:?${INSTALL_RESULT_FILE} did not contain XUI_WEB_BASE_PATH}"

  if [[ "$XUI_PANEL_PORT" != "$PANEL_PORT" ]]; then
    echo "WARNING: 3x-ui reports panel port ${XUI_PANEL_PORT}, but setup_nginx_proxy.sh reserved ${PANEL_PORT}." >&2
    echo "This means 3x-ui was already installed/configured before with a different port; using ${XUI_PANEL_PORT} as reported." >&2
  fi
}

BASE_URL=""
AUTH_HEADER=""
COOKIE_JAR=""

setup_api_auth() {
  BASE_URL="http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}"

  # Prefer Bearer token (works on all /panel/api/* routes); fall back to
  # cookie-session login if no token was generated by the installer.
  if [[ -n "${XUI_API_TOKEN:-}" ]]; then
    AUTH_HEADER="Authorization: Bearer ${XUI_API_TOKEN}"
    echo "Using API token for authentication." >&2
    return
  fi

  echo "No API token found, falling back to cookie login..." >&2
  COOKIE_JAR="$(mktemp)"
  trap 'rm -f "$COOKIE_JAR"' EXIT

  local resp http_code
  resp="$(curl -s -c "$COOKIE_JAR" -w '\n%{http_code}' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${XUI_USERNAME}" \
    --data-urlencode "password=${XUI_PASSWORD}" \
    "${BASE_URL}/login")"

  http_code="$(printf '%s' "$resp" | tail -n1)"
  resp="$(printf '%s' "$resp" | sed '$ d')"

  python3 -c "
import json,sys
try:
    ok = json.loads(sys.argv[1]).get('success')
except Exception:
    ok = False
sys.exit(0 if ok else 1)
" "$resp" || die "3x-ui panel login failed (HTTP ${http_code}). URL: ${BASE_URL}/login"

  echo "Cookie login succeeded." >&2
}

api_curl() {
  if [[ -n "$AUTH_HEADER" ]]; then
    curl -s -H "$AUTH_HEADER" "$@"
  else
    curl -s -b "$COOKIE_JAR" "$@"
  fi
}

wait_for_panel() {
  local i
  for ((i = 0; i < 30; i++)); do
    if curl -s -o /dev/null "http://127.0.0.1:${XUI_PANEL_PORT}/${XUI_WEB_BASE_PATH#/}/login"; then
      return 0
    fi
    sleep 2
  done
  die "3x-ui panel did not become reachable on 127.0.0.1:${XUI_PANEL_PORT}."
}

# Returns 0 (found) or 1 (not found) for a given inbound tag.
xui_inbound_exists() {
  local tag="$1"
  local resp
  resp="$(api_curl -X GET "${BASE_URL}/panel/api/inbounds/list")"

  python3 -c "
import json,sys
tag = sys.argv[2]
try:
    data = json.loads(sys.argv[1])
    obj = data.get('obj') or []
except Exception:
    obj = []
for ib in obj:
    if ib.get('tag') == tag:
        sys.exit(0)
sys.exit(1)
" "$resp" "$tag"
}

xui_add_inbound() {
  local port="$1" tag="$2" remark="$3" stream_settings="$4" client_email="$5"

  # Per the 3x-ui API docs, settings/streamSettings/sniffing should be
  # nested JSON objects (preferred), not JSON-encoded strings.
  local json_body
  json_body="$(python3 -c "
import json,sys
print(json.dumps({
    'up': 0,
    'down': 0,
    'total': 0,
    'remark': sys.argv[1],
    'enable': True,
    'expiryTime': 0,
    'listen': '127.0.0.1',
    'port': int(sys.argv[2]),
    'protocol': 'vless',
    'tag': sys.argv[3],
    'settings': {
        'clients': [{
            'id': sys.argv[4],
            'email': sys.argv[5],
            'subId': sys.argv[7],
        }],
        'decryption': 'none',
        'fallbacks': [],
    },
    'streamSettings': json.loads(sys.argv[6]),
    'sniffing': {
        'enabled': True,
        'destOverride': ['http', 'tls'],
    },
}))
" "$remark" "$port" "$tag" "$CLIENT_UUID" "$client_email" "$stream_settings" "$CLIENT_SUB_ID")"

  local resp
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/inbounds/add" \
    -H 'Content-Type: application/json' \
    -d "$json_body")"

  python3 -c "
import json,sys
try:
    data = json.loads(sys.argv[1])
    ok = data.get('success')
    if not ok:
        print('API error:', data.get('msg', 'unknown'), file=sys.stderr)
except Exception as e:
    print('Failed to parse response:', e, file=sys.stderr)
    ok = False
sys.exit(0 if ok else 1)
" "$resp" || die "Failed to create inbound '${tag}'. Response: ${resp}"
}

ensure_ws_inbound() {
  local tag="in-${WS_PORT}-ws"

  if xui_inbound_exists "$tag"; then
    echo "Inbound '${tag}' already exists, skipping." >&2
    return
  fi

  local stream_settings
  stream_settings="$(python3 -c "
import json,sys
print(json.dumps({
    'network': 'ws',
    'security': 'none',
    'wsSettings': {'acceptProxyProtocol': False, 'path': sys.argv[1], 'host': '', 'headers': {}},
}))
" "$WS_PATH")"

  echo "Creating inbound '${tag}' (WS, port ${WS_PORT}, path ${WS_PATH})..." >&2
  xui_add_inbound "$WS_PORT" "$tag" "ws-cdn" "$stream_settings" "client"
}

ensure_grpc_inbound() {
  local tag="in-${GRPC_PORT}-grpc"

  if xui_inbound_exists "$tag"; then
    echo "Inbound '${tag}' already exists, skipping." >&2
    return
  fi

  local stream_settings
  stream_settings="$(python3 -c "
import json,sys
print(json.dumps({
    'network': 'grpc',
    'security': 'none',
    'grpcSettings': {'serviceName': sys.argv[1], 'multiMode': False},
}))
" "$GRPC_SERVICE")"

  echo "Creating inbound '${tag}' (gRPC, port ${GRPC_PORT}, serviceName ${GRPC_SERVICE})..." >&2
  xui_add_inbound "$GRPC_PORT" "$tag" "grpc-cdn" "$stream_settings" "client"
}

update_geo_files() {
  local geo_dir="/usr/local/x-ui/bin"
  local geoip_url="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
  local geosite_url="https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat"

  echo "Updating geo files (geoip.dat, geosite.dat) from runetfreedom/russia-v2ray-rules-dat..." >&2

  curl -fsSL -o "${geo_dir}/geoip.dat" "$geoip_url" ||
    echo "WARNING: Failed to download geoip.dat; routing rules using geoip: may not work." >&2

  curl -fsSL -o "${geo_dir}/geosite.dat" "$geosite_url" ||
    echo "WARNING: Failed to download geosite.dat; routing rules using geosite: may not work." >&2

  echo "Geo files updated." >&2
}

configure_subscription() {
  echo "Configuring subscription (port ${SUB_PORT}, path ${SUB_PATH})..." >&2

  # Fetch current settings, patch subscription fields, push back.
  local current_settings
  current_settings="$(api_curl -X POST "${BASE_URL}/panel/api/setting/all")"

  local updated_settings
  updated_settings="$(python3 -c "
import json,sys

resp = json.loads(sys.argv[1])
if not resp.get('success'):
    print('Failed to fetch current settings:', resp.get('msg',''), file=sys.stderr)
    sys.exit(1)

settings = resp.get('obj') or {}
settings['subEnable'] = True
settings['subPort'] = int(sys.argv[2])
settings['subPath'] = sys.argv[3].lstrip('/')
settings['subListen'] = '127.0.0.1'
print(json.dumps(settings))
" "$current_settings" "$SUB_PORT" "$SUB_PATH")" ||
    die "Failed to prepare subscription settings."

  local resp
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/setting/update" \
    -H 'Content-Type: application/json' \
    -d "$updated_settings")"

  python3 -c "
import json,sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('success'):
        print('API error:', data.get('msg','unknown'), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('Failed to parse response:', e, file=sys.stderr)
    sys.exit(1)
" "$resp" || die "Failed to update subscription settings via API."

  echo "Subscription configured, restarting x-ui to apply..." >&2
  systemctl restart x-ui >&2 || true

  # Wait for the subscription port to come up after restart
  local i
  for ((i = 0; i < 15; i++)); do
    if ss -H -ltn "sport = :${SUB_PORT}" 2>/dev/null | grep -q .; then
      echo "Subscription service is listening on port ${SUB_PORT}." >&2
      return
    fi
    sleep 2
  done
  echo "WARNING: Subscription service did not start listening on port ${SUB_PORT} within 30s." >&2
}

register_warp() {
  # Uses 3x-ui's built-in WARP registration endpoint.
  # Generates a keypair and POSTs to /panel/api/xray/warp/reg.
  echo "Registering WARP via 3x-ui panel API..." >&2

  if ! command -v wg >/dev/null 2>&1; then
    apt-get install -y wireguard-tools >&2 || die "Failed to install wireguard-tools (needed for wg genkey)."
  fi

  local private_key public_key
  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"

  local resp
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/xray/warp/reg" \
    --data-urlencode "privateKey=${private_key}" \
    --data-urlencode "publicKey=${public_key}")"

  python3 -c "
import json,sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('success'):
        print('WARP reg error:', data.get('msg','unknown'), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('Failed to parse WARP response:', e, file=sys.stderr)
    print('Response:', sys.argv[1][:500], file=sys.stderr)
    sys.exit(1)
" "$resp" || die "WARP registration via panel API failed."

  echo "WARP registered successfully." >&2
}

configure_xray_config() {
  # Configures xray outbounds (direct, warp, blocked) and routing rules
  # via POST /panel/api/xray/update with the xraySetting form field.
  echo "Configuring xray outbounds and routing (WARP + blocking rules)..." >&2

  # Step 1: Register WARP (stores credentials in panel DB)
  register_warp

  # Step 2: Fetch the WARP wireguard outbound config the panel built
  local warp_config_resp
  warp_config_resp="$(api_curl -X POST "${BASE_URL}/panel/api/xray/warp/config")"

  # Step 3: Get the current xray config template
  local current_xray
  current_xray="$(api_curl -X POST "${BASE_URL}/panel/api/xray/")"

  # Step 4: Patch in WARP outbound + routing rules
  local updated_xray
  updated_xray="$(CURRENT_XRAY="$current_xray" WARP_CONFIG="$warp_config_resp" python3 << 'PYEOF'
import json,os,sys

resp = json.loads(os.environ['CURRENT_XRAY'])
if not resp.get('success'):
    print('Failed to fetch xray config:', resp.get('msg',''), file=sys.stderr)
    sys.exit(1)

obj = resp.get('obj', {})
if isinstance(obj, str):
    obj = json.loads(obj)

xray_setting_raw = obj.get('xraySetting', '{}') if isinstance(obj, dict) else '{}'
if isinstance(xray_setting_raw, dict):
    xray_config = xray_setting_raw
elif isinstance(xray_setting_raw, str) and xray_setting_raw:
    xray_config = json.loads(xray_setting_raw)
else:
    xray_config = {}

# Parse the WARP config from the panel
warp_resp = json.loads(os.environ['WARP_CONFIG'])
warp_obj = warp_resp.get('obj', '')
if isinstance(warp_obj, str) and warp_obj:
    warp_outbound = json.loads(warp_obj)
elif isinstance(warp_obj, dict):
    warp_outbound = warp_obj
else:
    warp_outbound = None

if not warp_outbound:
    print('ERROR: WARP config endpoint returned empty/null. Cannot build warp outbound.', file=sys.stderr)
    sys.exit(1)

# Ensure the warp outbound has the right tag
if 'tag' not in warp_outbound:
    warp_outbound['tag'] = 'warp'

xray_config['outbounds'] = [
    {
        'tag': 'direct',
        'protocol': 'freedom',
        'settings': {
            'domainStrategy': 'AsIs',
            'finalRules': [{'action': 'allow'}],
        },
    },
    warp_outbound,
    {
        'tag': 'blocked',
        'protocol': 'blackhole',
        'settings': {},
    },
]

# Set routing rules
xray_config.setdefault('routing', {})['rules'] = [
    {
        'type': 'field',
        'inboundTag': ['api'],
        'outboundTag': 'api',
    },
    {
        'type': 'field',
        'ip': ['geoip:ru'],
        'outboundTag': 'warp',
    },
    {
        'type': 'field',
        'domain': [
            'geosite:category-ru',
            'regexp:.*\\.ru$',
            'geosite:openai',
        ],
        'outboundTag': 'warp',
    },
    {
        'type': 'field',
        'ip': ['geoip:private'],
        'outboundTag': 'blocked',
    },
    {
        'type': 'field',
        'protocol': ['bittorrent'],
        'outboundTag': 'blocked',
    },
]

print(json.dumps(xray_config))
PYEOF
  )" || die "Failed to prepare xray config."

  # Step 5: Save via the correct endpoint (form field, not JSON body)
  local resp
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/xray/update" \
    --data-urlencode "xraySetting=${updated_xray}")"

  python3 -c "
import json,sys
try:
    data = json.loads(sys.argv[1])
    if not data.get('success'):
        print('API error:', data.get('msg','unknown'), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('Failed to parse response:', e, file=sys.stderr)
    sys.exit(1)
" "$resp" || die "Failed to save xray config via /panel/api/xray/update."

  echo "Xray outbounds and routing configured and applied." >&2
}

main() {
  if xui_is_installed; then
    echo "3x-ui is already installed, skipping installer (reusing its existing credentials/port/path)." >&2
  else
    install_xui
    update_geo_files
  fi

  read_install_result
  wait_for_panel
  setup_api_auth
  ensure_ws_inbound
  ensure_grpc_inbound
  configure_subscription
  configure_xray_config

  echo "Inbounds ready." >&2

  printf 'PANEL_PORT=%s\n' "$XUI_PANEL_PORT"
  printf 'PANEL_PATH=/%s\n' "${XUI_WEB_BASE_PATH#/}"
  printf 'XUI_USERNAME=%s\n' "$XUI_USERNAME"
  printf 'XUI_PASSWORD=%s\n' "$XUI_PASSWORD"
  printf 'CLIENT_UUID=%s\n' "$CLIENT_UUID"
  printf 'CLIENT_SUB_ID=%s\n' "$CLIENT_SUB_ID"
}

main "$@"
