#!/usr/bin/env bash
# Scenario 1: installs a REAL 3x-ui panel (the actual upstream installer, no
# stubs) and drives setup.sh's real 3x-ui functions against it (merged
# directly into setup.sh -- no more subprocess boundary), then asserts on
# the REAL API responses. This is the tier that would have caught every
# 3x-ui-related bug from the 2026-07-20/21 Reality debugging session:
#   - getNewmlkem768 field-name drift (serverKey/clientKey vs seed/client)
#   - Reality inbound missing the nested realitySettings.settings.publicKey
#   - externalProxy polluting 3x-ui's persistent `hosts` table and forcing
#     security=tls in every subscription-generated Reality link
#   - subscription output not reflecting the public domain:port
#   - VPS_COUNTRY_CODE / INBOUND_REMARK_REALITY silently failing to cross
#     the (now-removed) setup.sh -> setup-3x-ui.sh subprocess boundary
#
# Run inside the e2e container (see run.sh). Exits non-zero with a specific
# message on the first failed assertion.
set -euo pipefail

REPO="/opt/repo"
FAIL=0

fail() {
  echo "FAIL: $*" >&2
  FAIL=1
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "${desc}: expected '${expected}', got '${actual}'"
  else
    echo "  ok: ${desc}" >&2
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${desc}: expected to contain '${needle}', got: ${haystack}"
  else
    echo "  ok: ${desc}" >&2
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "${desc}: expected NOT to contain '${needle}', got: ${haystack}"
  else
    echo "  ok: ${desc}" >&2
  fi
}

assert_nonempty() {
  local desc="$1" value="$2"
  if [[ -z "$value" ]]; then
    fail "${desc}: expected non-empty value, got empty"
  else
    echo "  ok: ${desc} (${value})" >&2
  fi
}

cd "$REPO"
chmod +x setup.sh

# shellcheck disable=SC1091
source ./setup.sh

# --- Set the variable environment install_3xui_and_inbounds expects. MUST
# happen AFTER sourcing: setup.sh unconditionally resets these to their
# defaults ('' for most) at top-level scope, so setting them before sourcing
# would just get clobbered.
PANEL_PORT=23456
WS_PORT=23457; GRPC_PORT=23458; XHTTP_PORT=23459; SUB_PORT=23460
WS_PATH="/ws$(openssl rand -hex 4)"
GRPC_SERVICE="grpc-$(openssl rand -hex 4)"
XHTTP_PATH="/xhttp$(openssl rand -hex 4)"
SUB_PATH="/sub$(openssl rand -hex 4)"
CLIENT_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
CLIENT_SUB_ID="$(openssl rand -hex 8)"
BASE_DOMAIN="e2e.test"
PANEL_SUBDOMAIN="panel"
VLESS_SUBDOMAIN="vless"
REALITY_SUBDOMAIN="reality"
REALITY_DEST="github.com"
REALITY_PORT=23461
REALITY_SHORT_ID="deadbeef"
INBOUND_REMARK_WS="e2e WS"; INBOUND_REMARK_GRPC="e2e gRPC"; INBOUND_REMARK_XHTTP="e2e XHTTP"
# Deliberately left unset (not INBOUND_REMARK_REALITY="..."): this forces
# ensure_reality_inbound down the detect_country_flag() fallback path, so
# the assertion below actually exercises VPS_COUNTRY_CODE handling for real.
VPS_COUNTRY_CODE="EE"

echo "--- Installing real 3x-ui via upstream installer ---" >&2
install_3xui_and_inbounds || { fail "install_3xui_and_inbounds exited non-zero"; exit 1; }

assert_nonempty "PANEL_PATH set" "$PANEL_PATH"
assert_nonempty "XUI_USERNAME set" "$XUI_USERNAME"
assert_nonempty "CLIENT_UUID set" "$CLIENT_UUID"
assert_nonempty "VLESS_ENCRYPTION_SERVER_KEY set (catches getNewmlkem768 field-name drift)" \
  "$VLESS_ENCRYPTION_SERVER_KEY"
assert_nonempty "REALITY_PRIVATE_KEY set" "$REALITY_PRIVATE_KEY"
assert_nonempty "REALITY_PUBLIC_KEY set" "$REALITY_PUBLIC_KEY"

# BASE_URL/api_curl are already populated by install_3xui_and_inbounds's
# internal call to setup_api_auth -- no need to re-derive auth here.
echo "--- Checking Reality inbound via real 3x-ui API ---" >&2
inbounds_json="$(api_curl -X GET "${BASE_URL}/panel/api/inbounds/list")"

reality_inbound="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for ib in data.get('obj') or []:
    if ib.get('port') == ${REALITY_PORT}:
        print(json.dumps(ib))
        break
" "$inbounds_json")"

assert_nonempty "Reality inbound found on port ${REALITY_PORT}" "$reality_inbound"

security="$(python3 -c "
import json,sys
ib = json.loads(sys.argv[1])
stream = json.loads(ib['streamSettings']) if isinstance(ib['streamSettings'], str) else ib['streamSettings']
print(stream.get('security',''))
" "$reality_inbound")"
assert_eq "Reality inbound streamSettings.security" "reality" "$security"

# Regression check: VPS_COUNTRY_CODE must be honored by detect_country_flag()
# instead of silently falling back to live IP geolocation (which reports
# whatever the CI runner's/VPS's actual datacenter is, not the requested
# flag). Assert the remark uses the EE regional-indicator emoji.
remark="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('remark',''))" "$reality_inbound")"
assert_contains "Reality inbound remark uses the VPS_COUNTRY_CODE=EE flag (not a geolocated one)" \
  "$remark" "$(python3 -c 'print("\U0001F1EA\U0001F1EA")')"

nested_pbk="$(python3 -c "
import json,sys
ib = json.loads(sys.argv[1])
stream = json.loads(ib['streamSettings']) if isinstance(ib['streamSettings'], str) else ib['streamSettings']
print(stream.get('realitySettings',{}).get('settings',{}).get('publicKey',''))
" "$reality_inbound")"
assert_nonempty "Reality nested realitySettings.settings.publicKey populated (catches missing-pbk regression)" "$nested_pbk"
assert_eq "Nested publicKey matches REALITY_PUBLIC_KEY" "$REALITY_PUBLIC_KEY" "$nested_pbk"

external_proxy="$(python3 -c "
import json,sys
ib = json.loads(sys.argv[1])
stream = json.loads(ib['streamSettings']) if isinstance(ib['streamSettings'], str) else ib['streamSettings']
print('present' if 'externalProxy' in stream else 'absent')
" "$reality_inbound")"
assert_eq "Reality inbound has no externalProxy (catches security=tls corruption bug)" "absent" "$external_proxy"

reality_id="$(python3 -c "
import json,sys
print(json.loads(sys.argv[1])['id'])
" "$reality_inbound")"

echo "--- Checking Reality Host override via real 3x-ui API ---" >&2
hosts_json="$(api_curl -X GET "${BASE_URL}/panel/api/hosts/byInbound/${reality_id}")"
host_count="$(python3 -c "
import json,sys
try:
    print(len(json.loads(sys.argv[1]).get('obj') or []))
except Exception:
    print(0)
" "$hosts_json")"
assert_eq "Reality Host override was created" "1" "$host_count"

host_security="$(python3 -c "
import json,sys
obj = json.loads(sys.argv[1]).get('obj') or []
print(obj[0].get('security','') if obj else '')
" "$hosts_json")"
assert_eq "Reality Host security is 'same' (not 'tls')" "same" "$host_security"

echo "--- Checking subscription output for the Reality link ---" >&2
sub_raw="$(curl -fsS "http://127.0.0.1:${SUB_PORT}${SUB_PATH}/${CLIENT_SUB_ID}")"
sub_decoded="$(python3 -c "
import base64,sys
data = sys.argv[1].strip().encode()
data += b'=' * (-len(data) % 4)
print(base64.b64decode(data).decode())
" "$sub_raw")"

reality_line="$(echo "$sub_decoded" | grep 'security=reality' || true)"
assert_nonempty "subscription contains a security=reality line" "$reality_line"
assert_not_contains "subscription Reality line has no security=tls" "$reality_line" "security=tls"
assert_contains "subscription Reality line has non-empty pbk" "$reality_line" "pbk=${REALITY_PUBLIC_KEY}"
assert_not_contains "subscription Reality line does not use internal loopback address" "$reality_line" "@localhost:"
assert_not_contains "subscription Reality line does not use internal loopback address" "$reality_line" "@127.0.0.1:"
assert_contains "subscription Reality line uses the public Reality domain" "$reality_line" "${REALITY_SUBDOMAIN}.${BASE_DOMAIN}"

echo "--- Checking WS/XHTTP/gRPC inbounds have VLESS Encryption applied ---" >&2
for port in "$WS_PORT" "$XHTTP_PORT" "$GRPC_PORT"; do
  ib="$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for ib in data.get('obj') or []:
    if ib.get('port') == ${port}:
        print(json.dumps(ib))
        break
" "$inbounds_json")"
  assert_nonempty "inbound found on port ${port}" "$ib"
  decryption="$(python3 -c "
import json,sys
ib = json.loads(sys.argv[1])
settings = json.loads(ib['settings']) if isinstance(ib['settings'], str) else ib['settings']
print(settings.get('decryption',''))
" "$ib")"
  assert_nonempty "inbound ${port} has a non-empty VLESS Encryption decryption key" "$decryption"
  assert_not_contains "inbound ${port} decryption is not literal 'none'" "$decryption" "none"
done

if [[ "$FAIL" -ne 0 ]]; then
  echo >&2
  echo "One or more assertions failed -- see FAIL lines above." >&2
  exit 1
fi

echo >&2
echo "All assertions passed." >&2
