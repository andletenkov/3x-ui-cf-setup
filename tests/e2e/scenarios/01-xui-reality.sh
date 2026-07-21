#!/usr/bin/env bash
# Scenario 1: installs a REAL 3x-ui panel (the actual upstream installer, no
# stubs) and drives setup-3x-ui.sh's real functions against it, then asserts
# on the REAL API responses. This is the tier that would have caught every
# 3x-ui-related bug from the 2026-07-20/21 Reality debugging session:
#   - getNewmlkem768 field-name drift (serverKey/clientKey vs seed/client)
#   - Reality inbound missing the nested realitySettings.settings.publicKey
#   - externalProxy polluting 3x-ui's persistent `hosts` table and forcing
#     security=tls in every subscription-generated Reality link
#   - subscription output not reflecting the public domain:port
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

echo "--- Installing real 3x-ui via upstream installer ---" >&2
export PANEL_PORT=23456
export WS_PORT=23457 GRPC_PORT=23458 XHTTP_PORT=23459 SUB_PORT=23460
export WS_PATH="/ws$(openssl rand -hex 4)"
export GRPC_SERVICE="grpc-$(openssl rand -hex 4)"
export XHTTP_PATH="/xhttp$(openssl rand -hex 4)"
export SUB_PATH="/sub$(openssl rand -hex 4)"
export CLIENT_UUID
CLIENT_UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
export CLIENT_SUB_ID
CLIENT_SUB_ID="$(openssl rand -hex 8)"
export SUB_DOMAIN="panel.e2e.test"
export VLESS_DOMAIN="vless.e2e.test"
export REALITY_SUBDOMAIN="reality"
export REALITY_DEST="github.com"
export REALITY_PORT=23461
export REALITY_SHORT_ID="deadbeef"
export REALITY_DOMAIN="reality.e2e.test"
export BASE_DOMAIN="e2e.test"
export INBOUND_REMARK_WS="e2e WS" INBOUND_REMARK_GRPC="e2e gRPC" INBOUND_REMARK_XHTTP="e2e XHTTP"
# Deliberately left unset (not INBOUND_REMARK_REALITY="..."): this forces
# ensure_reality_inbound down the detect_country_flag() fallback path, so
# the assertion below actually exercises VPS_COUNTRY_CODE forwarding across
# the setup.sh -> setup-3x-ui.sh subprocess boundary, instead of trivially
# passing because a remark was hardcoded end-to-end.
export VPS_COUNTRY_CODE="EE"

cd "$REPO"
chmod +x setup-3x-ui.sh

installer_out="$(./setup-3x-ui.sh)" || { fail "setup-3x-ui.sh exited non-zero"; exit 1; }

declare -A OUT
while IFS='=' read -r k v; do
  [[ -n "$k" ]] || continue
  OUT["$k"]="$v"
done <<< "$installer_out"

assert_nonempty "PANEL_PATH reported" "${OUT[PANEL_PATH]:-}"
assert_nonempty "XUI_USERNAME reported" "${OUT[XUI_USERNAME]:-}"
assert_nonempty "CLIENT_UUID reported" "${OUT[CLIENT_UUID]:-}"
assert_nonempty "VLESS_ENCRYPTION_SERVER_KEY reported (catches getNewmlkem768 field-name drift)" \
  "${OUT[VLESS_ENCRYPTION_SERVER_KEY]:-}"
assert_nonempty "REALITY_PRIVATE_KEY reported" "${OUT[REALITY_PRIVATE_KEY]:-}"
assert_nonempty "REALITY_PUBLIC_KEY reported" "${OUT[REALITY_PUBLIC_KEY]:-}"

PANEL_PATH="${OUT[PANEL_PATH]}"
BASE_URL="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"

# Re-derive auth the same way setup-3x-ui.sh's setup_api_auth does, by
# reading the install-result file it sourced -- avoids re-implementing auth
# here. Prefers the Bearer token; falls back to cookie login if the
# installer didn't generate one.
# shellcheck disable=SC1091
source /etc/x-ui/install-result.env

COOKIE_JAR="$(mktemp)"
if [[ -z "${XUI_API_TOKEN:-}" ]]; then
  curl -fsS -c "$COOKIE_JAR" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${XUI_USERNAME}" \
    --data-urlencode "password=${XUI_PASSWORD}" \
    "${BASE_URL}/login" >/dev/null
fi

api() {
  if [[ -n "${XUI_API_TOKEN:-}" ]]; then
    curl -fsS -H "Authorization: Bearer ${XUI_API_TOKEN}" "$@"
  else
    curl -fsS -b "$COOKIE_JAR" "$@"
  fi
}

echo "--- Checking Reality inbound via real 3x-ui API ---" >&2
inbounds_json="$(api -X GET "${BASE_URL}/panel/api/inbounds/list")"

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

# Regression check: setup-3x-ui.sh runs as a separate subprocess from
# setup.sh and used to carry its own out-of-sync detect_country_flag() that
# ignored VPS_COUNTRY_CODE entirely, always live-geolocating the VPS's
# actual IP instead (frequently reporting the wrong country for the
# configured/desired flag). Assert the remark uses the EE regional-indicator
# emoji (\U0001F1EA\U0001F1EA) requested via VPS_COUNTRY_CODE, not whatever
# a live geolocation lookup would return for this CI runner's IP.
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
assert_eq "Nested publicKey matches reported REALITY_PUBLIC_KEY" "${OUT[REALITY_PUBLIC_KEY]}" "$nested_pbk"

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
hosts_json="$(api -X GET "${BASE_URL}/panel/api/hosts/byInbound/${reality_id}")"
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
assert_contains "subscription Reality line has non-empty pbk" "$reality_line" "pbk=${OUT[REALITY_PUBLIC_KEY]}"
assert_not_contains "subscription Reality line does not use internal loopback address" "$reality_line" "@localhost:"
assert_not_contains "subscription Reality line does not use internal loopback address" "$reality_line" "@127.0.0.1:"
assert_contains "subscription Reality line uses the public Reality domain" "$reality_line" "${REALITY_DOMAIN}"

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
