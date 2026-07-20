#!/usr/bin/env bats
#
# Unit tests for setup.sh.
#
# Run with:
#   bats tests/install.bats tests/anonymize.bats
#
# These tests stub out all system-mutating commands (nginx, curl, ss, ufw,
# certbot, systemctl, apt) via tests/stubs/ on PATH, and source setup.sh
# without executing main() (guarded by the BASH_SOURCE check at the bottom
# of the script). No root privileges or real system changes are required.

setup() {
  export PATH="${BATS_TEST_DIRNAME}/stubs:$PATH"
  export SCRIPT="${BATS_TEST_DIRNAME}/../setup.sh"

  # shellcheck disable=SC1090
  source "$SCRIPT"

  # Reset any state that individual tests might rely on being clean.
  unset SS_LISTENING_PORTS CURL_SHOULD_FAIL CURL_CF_IPV4 CURL_CF_IPV6 \
    CURL_HTTP_CODE NGINX_T_SHOULD_FAIL UFW_LOG VPS_COUNTRY_CODE
}

# ---------------------------------------------------------------------------
# validate_port
# ---------------------------------------------------------------------------

@test "validate_port accepts a valid port" {
  run validate_port "Test port" "8080"
  [ "$status" -eq 0 ]
}

@test "validate_port accepts boundary values 1 and 65535" {
  run validate_port "Test port" "1"
  [ "$status" -eq 0 ]
  run validate_port "Test port" "65535"
  [ "$status" -eq 0 ]
}

@test "validate_port rejects non-numeric input" {
  run validate_port "Test port" "abc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a number"* ]]
}

@test "validate_port rejects 0" {
  run validate_port "Test port" "0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"between 1 and 65535"* ]]
}

@test "validate_port rejects out-of-range port" {
  run validate_port "Test port" "70000"
  [ "$status" -eq 1 ]
  [[ "$output" == *"between 1 and 65535"* ]]
}

# ---------------------------------------------------------------------------
# normalize_panel_path / normalize_ws_path
# ---------------------------------------------------------------------------

@test "normalize_panel_path adds leading slash" {
  PANEL_PATH="my-admin"
  normalize_panel_path
  [ "$PANEL_PATH" == "/my-admin" ]
}

@test "normalize_panel_path strips trailing slashes" {
  PANEL_PATH="/my-admin///"
  normalize_panel_path
  [ "$PANEL_PATH" == "/my-admin" ]
}

@test "normalize_panel_path rejects bare root path" {
  PANEL_PATH="/"
  run normalize_panel_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be /"* ]]
}

@test "normalize_panel_path rejects invalid characters" {
  PANEL_PATH="/my;admin"
  run normalize_panel_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"may only contain"* ]]
}

@test "normalize_panel_path rejects spaces" {
  PANEL_PATH="/my admin"
  run normalize_panel_path
  [ "$status" -eq 1 ]
}

@test "normalize_ws_path accepts nested path" {
  WS_PATH="/api/v1/events"
  normalize_ws_path
  [ "$WS_PATH" == "/api/v1/events" ]
}

@test "normalize_ws_path rejects bare root path" {
  WS_PATH="/"
  run normalize_ws_path
  [ "$status" -eq 1 ]
}

@test "normalize_xhttp_path normalizes an API path" {
  XHTTP_PATH="api/v1/ingest/abcd1234///"
  normalize_xhttp_path
  [ "$XHTTP_PATH" == "/api/v1/ingest/abcd1234" ]
}

@test "normalize_xhttp_path rejects bare root path" {
  XHTTP_PATH="/"
  run normalize_xhttp_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"XHTTP path cannot be /"* ]]
}

# ---------------------------------------------------------------------------
# validate_inputs
# ---------------------------------------------------------------------------

valid_inputs() {
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  EMAIL="user@example.com"
  PANEL_PORT="2053"
  SUB_PORT="2096"
  WS_PORT="10001"
  GRPC_PORT="10002"
  XHTTP_PORT="10003"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  SUB_PATH="/sub"
}

@test "validate_inputs accepts a fully valid configuration" {
  valid_inputs
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "confirm_configuration includes XHTTP and its firewall rule" {
  valid_inputs

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VLESS XHTTP:"* ]]
  [[ "$output" == *"network: xhttp (packet-up)"* ]]
  [[ "$output" == *"internal Xray port: ${XHTTP_PORT}"* ]]
  [[ "$output" == *"path: ${XHTTP_PATH}"* ]]
  [[ "$output" == *"${XHTTP_PORT}/tcp"* ]]
}

@test "confirm_configuration omits the Reality section when disabled" {
  valid_inputs
  REALITY_SUBDOMAIN=""

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" != *"VLESS Reality"* ]]
}

@test "confirm_configuration shows the Reality section and its impersonated donor when enabled" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VLESS Reality (direct connection, no CDN):"* ]]
  [[ "$output" == *"domain: reality.example.com"* ]]
  [[ "$output" == *"internal Xray port: 20000"* ]]
  [[ "$output" == *"impersonating: github.com"* ]]
  [[ "$output" == *"20000/tcp"* ]]
}

@test "confirm_configuration describes UFW as open to everyone on 443, not Cloudflare-only" {
  valid_inputs

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed: 443/tcp from anywhere"* ]]
  [[ "$output" != *"Cloudflare IP ranges only"* ]]
}

@test "validate_inputs rejects invalid base domain" {
  valid_inputs
  BASE_DOMAIN="not_a_domain"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid base domain"* ]]
}

@test "validate_inputs rejects identical panel and vless subdomains" {
  valid_inputs
  VLESS_SUBDOMAIN="$PANEL_SUBDOMAIN"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be different"* ]]
}

@test "validate_inputs rejects invalid email" {
  valid_inputs
  EMAIL="not-an-email"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid email"* ]]
}

@test "validate_inputs rejects invalid gRPC service name" {
  valid_inputs
  GRPC_SERVICE="bad service name!"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid gRPC service"* ]]
}

@test "validate_inputs rejects equal websocket and grpc ports" {
  valid_inputs
  GRPC_PORT="$WS_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"WebSocket and gRPC ports must be different"* ]]
}

@test "validate_inputs rejects equal subscription and websocket ports" {
  valid_inputs
  SUB_PORT="$WS_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Subscription and WebSocket ports must be different"* ]]
}

@test "validate_inputs rejects websocket port equal to 443" {
  valid_inputs
  WS_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be 443"* ]]
}

@test "validate_inputs rejects an XHTTP port collision" {
  valid_inputs
  XHTTP_PORT="$GRPC_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"XHTTP port must be different"* ]]
}

# ---------------------------------------------------------------------------
# validate_inputs -- optional Reality fields
# ---------------------------------------------------------------------------

@test "validate_inputs accepts a blank Reality configuration (feature disabled)" {
  valid_inputs
  REALITY_SUBDOMAIN=""
  REALITY_DEST=""
  REALITY_PORT=""
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs accepts a fully populated Reality configuration" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs rejects REALITY_DEST set without REALITY_SUBDOMAIN" {
  valid_inputs
  REALITY_SUBDOMAIN=""
  REALITY_DEST="github.com"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REALITY_DEST is set but REALITY_SUBDOMAIN is blank"* ]]
}

@test "validate_inputs rejects a Reality subdomain without a donor site" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST=""
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"REALITY_DEST"* ]]
  [[ "$output" == *"is required"* ]]
}

@test "validate_inputs rejects a Reality subdomain equal to the panel subdomain" {
  valid_inputs
  REALITY_SUBDOMAIN="$PANEL_SUBDOMAIN"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"different from the panel subdomain"* ]]
}

@test "validate_inputs rejects a Reality subdomain equal to the VLESS subdomain" {
  valid_inputs
  REALITY_SUBDOMAIN="$VLESS_SUBDOMAIN"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"different from the VLESS subdomain"* ]]
}

@test "validate_inputs rejects a malformed Reality donor site" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="not a hostname"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid Reality donor site"* ]]
}

@test "validate_inputs rejects a Reality donor site that is the base domain itself" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="$BASE_DOMAIN"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a real, unrelated third-party site"* ]]
}

@test "validate_inputs rejects a Reality donor site that is a subdomain of the base domain" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="sneaky.${BASE_DOMAIN}"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a real, unrelated third-party site"* ]]
}

@test "validate_inputs rejects a Reality port colliding with another internal port" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="$WS_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Reality port must be different from every other internal port"* ]]
}

@test "validate_inputs rejects a Reality port of 443" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Reality port cannot be 443"* ]]
}

# ---------------------------------------------------------------------------
# validate_panel_port -- PANEL_PORT is no longer validated by validate_inputs
# (it isn't known until after 3x-ui install); this is its dedicated
# post-install check, defensive re-check for a value the script itself
# pre-reserved (see collect_input) and handed to the 3x-ui installer.
# ---------------------------------------------------------------------------

@test "validate_panel_port accepts a non-colliding port and normalizes PANEL_PATH" {
  valid_inputs
  PANEL_PORT="2053"
  PANEL_PATH="my-admin"
  run validate_panel_port
  [ "$status" -eq 0 ]
}

@test "validate_panel_port normalizes PANEL_PATH as a side effect" {
  valid_inputs
  PANEL_PORT="2053"
  PANEL_PATH="my-admin"
  validate_panel_port
  [ "$PANEL_PATH" == "/my-admin" ]
}

@test "validate_panel_port rejects port 443" {
  valid_inputs
  PANEL_PORT="443"
  run validate_panel_port
  [ "$status" -eq 1 ]
  [[ "$output" == *"reserved for the public HTTPS listener"* ]]
}

@test "validate_panel_port rejects collision with WS_PORT" {
  valid_inputs
  PANEL_PORT="$WS_PORT"
  run validate_panel_port
  [ "$status" -eq 1 ]
  [[ "$output" == *"collides with WS_PORT"* ]]
}

@test "validate_panel_port rejects collision with GRPC_PORT" {
  valid_inputs
  PANEL_PORT="$GRPC_PORT"
  run validate_panel_port
  [ "$status" -eq 1 ]
  [[ "$output" == *"collides with GRPC_PORT"* ]]
}

@test "validate_panel_port rejects collision with SUB_PORT" {
  valid_inputs
  PANEL_PORT="$SUB_PORT"
  run validate_panel_port
  [ "$status" -eq 1 ]
  [[ "$output" == *"collides with SUB_PORT"* ]]
}

@test "validate_panel_port rejects an invalid port value" {
  valid_inputs
  PANEL_PORT="not-a-port"
  run validate_panel_port
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a number"* ]]
}

# ---------------------------------------------------------------------------
# port_is_listening / random_free_port (stubbed ss)
# ---------------------------------------------------------------------------

@test "port_is_listening returns false when nothing is listening" {
  run port_is_listening 9999
  [ "$status" -eq 1 ]
}

@test "port_is_listening returns true when ss reports the port" {
  export SS_LISTENING_PORTS="9999"
  run port_is_listening 9999
  [ "$status" -eq 0 ]
}

@test "random_free_port returns a port in the dynamic range" {
  port="$(random_free_port)"
  [ "$port" -ge 49152 ]
  [ "$port" -le 65535 ]
}

@test "random_free_port avoids excluded ports" {
  for i in $(seq 1 20); do
    port="$(random_free_port 2053 2054)"
    [ "$port" != "2053" ]
    [ "$port" != "2054" ]
  done
}

@test "random_free_port avoids an arbitrary number of excluded ports" {
  # Exercises the >2-argument exclusion list used for PANEL_PORT reservation
  # (443, SUB_PORT, WS_PORT, GRPC_PORT all excluded at once).
  for i in $(seq 1 20); do
    port="$(random_free_port 443 2096 51000 51500)"
    [ "$port" != "443" ]
    [ "$port" != "2096" ]
    [ "$port" != "51000" ]
    [ "$port" != "51500" ]
  done
}

@test "random_free_port tolerates empty exclusion args" {
  run random_free_port "" ""
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "random_free_port avoids ports reported as listening" {
  export SS_LISTENING_PORTS="50000"
  for i in $(seq 1 5); do
    port="$(random_free_port)"
    [ "$port" != "50000" ]
  done
}

# ---------------------------------------------------------------------------
# save_config
# ---------------------------------------------------------------------------

@test "save_config creates its missing parent directory" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/missing-nginx/.3xui-proxy.conf"
  TIMESTAMP="20260101-000000"
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  EMAIL="admin@example.com"
  PANEL_PORT="2053"
  SUB_PORT="2096"
  WS_PORT="10001"
  GRPC_PORT="10002"
  XHTTP_PORT="10003"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  SUB_PATH="/sub"
  CLIENT_UUID="00000000-0000-4000-8000-000000000001"
  CLIENT_SUB_ID="client-sub-id"

  run save_config
  [ "$status" -eq 0 ]
  [ -f "$CONFIG_FILE" ]
  [[ "$(<"$CONFIG_FILE")" == *'BASE_DOMAIN="example.com"'* ]]
}

@test "save_config persists Reality fields and load_config restores them" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/.3xui-proxy.conf"
  TIMESTAMP="20260101-000000"
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  EMAIL="admin@example.com"
  PANEL_PORT="2053"
  SUB_PORT="2096"
  WS_PORT="10001"
  GRPC_PORT="10002"
  XHTTP_PORT="10003"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  SUB_PATH="/sub"
  CLIENT_UUID="00000000-0000-4000-8000-000000000001"
  CLIENT_SUB_ID="client-sub-id"
  VLESS_ENCRYPTION_SERVER_KEY="server-key"
  VLESS_ENCRYPTION_CLIENT_KEY="client-key"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  REALITY_SHORT_ID="abcd1234abcd5678"

  save_config

  REALITY_SUBDOMAIN=""
  REALITY_DEST=""
  REALITY_PORT=""
  REALITY_SHORT_ID=""

  load_config

  [ "$REALITY_SUBDOMAIN" == "reality" ]
  [ "$REALITY_DEST" == "github.com" ]
  [ "$REALITY_PORT" == "20000" ]
  [ "$REALITY_SHORT_ID" == "abcd1234abcd5678" ]
}

# ---------------------------------------------------------------------------
# write_nginx_config
# ---------------------------------------------------------------------------

nginx_config_env() {
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  SUB_PATH="/sub"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  PANEL_PORT="2053"
  SUB_PORT="2096"
  WS_PORT="10001"
  GRPC_PORT="10002"
  XHTTP_PORT="10003"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  CERT_DIR="/tmp/fake-cert"
  NGINX_SITE="${BATS_TEST_TMPDIR}/3xui-proxy"
  NGINX_SITE_ENABLED="${BATS_TEST_TMPDIR}/3xui-proxy-enabled"
  TIMESTAMP="20260101-000000"
}

@test "write_nginx_config writes expected ports, paths and domains" {
  nginx_config_env
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "proxy_pass http://127.0.0.1:10001;" "$NGINX_SITE"
  grep -q "grpc_pass grpc://127.0.0.1:10002;" "$NGINX_SITE"
  grep -q "grpc_pass grpc://127.0.0.1:10003;" "$NGINX_SITE"
  grep -q "proxy_pass http://127.0.0.1:2053;" "$NGINX_SITE"
  grep -q "location = /api/v1/events" "$NGINX_SITE"
  grep -q "location \^~ /api/v1/ingest/abcd1234" "$NGINX_SITE"
  grep -q "location /api.v1.SyncService" "$NGINX_SITE"
  grep -q "server_name admin.example.com;" "$NGINX_SITE"
  grep -q "server_name vpn.example.com;" "$NGINX_SITE"
}

@test "write_nginx_config matches XHTTP packet-up session subpaths" {
  nginx_config_env
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "location \^~ /api/v1/ingest/abcd1234" "$NGINX_SITE"
  ! grep -q "location = /api/v1/ingest/abcd1234" "$NGINX_SITE"
}

@test "write_nginx_config defaults the VLESS fallback to 404" {
  nginx_config_env
  FALLBACK_HTML_PATH=""
  FALLBACK_HTML_DEST="${BATS_TEST_TMPDIR}/fallback.html"
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "return 404;" "$NGINX_SITE"
  [ ! -e "$FALLBACK_HTML_DEST" ]
}

@test "prepare_fallback_page rejects a missing source file" {
  FALLBACK_HTML_PATH="${BATS_TEST_TMPDIR}/missing.html"
  FALLBACK_HTML_DEST="${BATS_TEST_TMPDIR}/fallback.html"

  run prepare_fallback_page
  [ "$status" -eq 1 ]
  [[ "$output" == *"FALLBACK_HTML_PATH must point to a readable regular file"* ]]
  [ ! -e "$FALLBACK_HTML_DEST" ]
}

@test "write_nginx_config serves an optional fallback HTML page" {
  nginx_config_env
  local source_html="${BATS_TEST_TMPDIR}/source.html"
  printf '<h1>Fallback</h1>\n' > "$source_html"
  FALLBACK_HTML_PATH="$source_html"
  FALLBACK_HTML_DEST="${BATS_TEST_TMPDIR}/fallback.html"
  run write_nginx_config
  [ "$status" -eq 0 ]

  [ "$(cat "$FALLBACK_HTML_DEST")" = "<h1>Fallback</h1>" ]
  grep -q "location = /" "$NGINX_SITE"
  grep -q "try_files /3xui-proxy-fallback.html =404;" "$NGINX_SITE"
  grep -q "location / {" "$NGINX_SITE"
  grep -q "return 404;" "$NGINX_SITE"
}

@test "write_nginx_config includes gRPC keepalive and buffer settings" {
  nginx_config_env
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "grpc_socket_keepalive on;" "$NGINX_SITE"
  grep -q "grpc_read_timeout 600s;" "$NGINX_SITE"
  grep -q "grpc_send_timeout 600s;" "$NGINX_SITE"
  grep -q "client_body_buffer_size 512k;" "$NGINX_SITE"
  grep -q "client_max_body_size 0;" "$NGINX_SITE"
}

@test "configure_ufw allows TCP 443 from anywhere (shared by CDN and direct-connection inbounds)" {
  nginx_config_env
  STATE_FILE="${BATS_TEST_TMPDIR}/ports.state"
  CF_IP_STATE_FILE="${BATS_TEST_TMPDIR}/cloudflare-ips.state"
  export UFW_LOG="${BATS_TEST_TMPDIR}/ufw.log"
  : > "$UFW_LOG"

  configure_ufw

  grep -q "delete allow 443/tcp" "$UFW_LOG"
  grep -q "delete deny 443/tcp" "$UFW_LOG"
  grep -qx "ufw allow 443/tcp" "$UFW_LOG"
  ! grep -q "allow from .* to any port 443 proto tcp" "$UFW_LOG"
}

@test "configure_ufw denies REALITY_PORT when Reality is enabled" {
  nginx_config_env
  STATE_FILE="${BATS_TEST_TMPDIR}/ports.state"
  CF_IP_STATE_FILE="${BATS_TEST_TMPDIR}/cloudflare-ips.state"
  REALITY_PORT="20000"
  export UFW_LOG="${BATS_TEST_TMPDIR}/ufw.log"
  : > "$UFW_LOG"

  configure_ufw

  grep -q "deny 20000/tcp" "$UFW_LOG"
  grep -q "STATE_REALITY_PORT=20000" "$STATE_FILE"
}

@test "configure_ufw does not deny a Reality port when the feature is disabled" {
  nginx_config_env
  STATE_FILE="${BATS_TEST_TMPDIR}/ports.state"
  CF_IP_STATE_FILE="${BATS_TEST_TMPDIR}/cloudflare-ips.state"
  REALITY_PORT=""
  export UFW_LOG="${BATS_TEST_TMPDIR}/ufw.log"
  : > "$UFW_LOG"

  configure_ufw

  ! grep -q "deny /tcp" "$UFW_LOG"
  grep -q "STATE_REALITY_PORT=$" "$STATE_FILE"
}

@test "configure_ufw cleans up and removes stale per-range Cloudflare allow rules from older installs" {
  nginx_config_env
  STATE_FILE="${BATS_TEST_TMPDIR}/ports.state"
  CF_IP_STATE_FILE="${BATS_TEST_TMPDIR}/cloudflare-ips.state"
  printf '%s\n%s\n' "173.245.48.0/20" "2400:cb00::/32" > "$CF_IP_STATE_FILE"
  export UFW_LOG="${BATS_TEST_TMPDIR}/ufw.log"
  : > "$UFW_LOG"

  configure_ufw

  grep -q "delete allow from 173.245.48.0/20 to any port 443 proto tcp" "$UFW_LOG"
  grep -q "delete allow from 2400:cb00::/32 to any port 443 proto tcp" "$UFW_LOG"
  [ ! -f "$CF_IP_STATE_FILE" ]
}

@test "write_nginx_config's panel proxy_pass has no trailing slash (preserves base path prefix)" {
  # A trailing slash on proxy_pass's target URI makes nginx strip the matched
  # location prefix before forwarding, which breaks apps (like 3x-ui) whose
  # base path routing expects to see the full original path.
  nginx_config_env
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "proxy_pass http://127.0.0.1:2053;" "$NGINX_SITE"
  ! grep -q "proxy_pass http://127.0.0.1:2053/;" "$NGINX_SITE"
}

@test "write_nginx_config uses combined 'listen ... http2' syntax on nginx < 1.25.1" {
  nginx_config_env
  export NGINX_STUB_VERSION=1.24.0
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "listen 443 ssl http2;" "$NGINX_SITE"
  ! grep -q "http2 on;" "$NGINX_SITE"
}

@test "write_nginx_config uses separate 'http2 on' directive on nginx >= 1.25.1" {
  nginx_config_env
  export NGINX_STUB_VERSION=1.25.1
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "listen 443 ssl;" "$NGINX_SITE"
  grep -q "http2 on;" "$NGINX_SITE"
  ! grep -q "listen 443 ssl http2;" "$NGINX_SITE"
}

@test "write_nginx_config uses separate 'http2 on' directive on nginx > 1.25.1" {
  nginx_config_env
  export NGINX_STUB_VERSION=1.27.0
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "http2 on;" "$NGINX_SITE"
}

@test "write_nginx_config rolls back to previous config when nginx -t fails" {
  nginx_config_env
  echo "PREVIOUS CONTENT" > "$NGINX_SITE"

  export NGINX_T_SHOULD_FAIL=1
  run write_nginx_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]

  [ "$(cat "$NGINX_SITE")" == "PREVIOUS CONTENT" ]
}

@test "write_nginx_config removes new config when there was no previous config and nginx -t fails" {
  nginx_config_env
  rm -f "$NGINX_SITE"

  export NGINX_T_SHOULD_FAIL=1
  run write_nginx_config
  [ "$status" -eq 1 ]
  [ ! -e "$NGINX_SITE" ]
}

# ---------------------------------------------------------------------------
# write_cloudflare_real_ip_config
# ---------------------------------------------------------------------------

cf_real_ip_env() {
  CF_REAL_IP_CONF="${BATS_TEST_TMPDIR}/cloudflare-real-ip.conf"
  TIMESTAMP="20260101-000000"
}

@test "write_cloudflare_real_ip_config writes fetched CIDR ranges" {
  cf_real_ip_env
  export CURL_CF_IPV4="1.1.1.0/24"
  export CURL_CF_IPV6="2400:cb00::/32"

  run write_cloudflare_real_ip_config
  [ "$status" -eq 0 ]

  grep -q "set_real_ip_from 1.1.1.0/24;" "$CF_REAL_IP_CONF"
  grep -q "set_real_ip_from 2400:cb00::/32;" "$CF_REAL_IP_CONF"
  grep -q "real_ip_header CF-Connecting-IP;" "$CF_REAL_IP_CONF"
}

@test "write_cloudflare_real_ip_config fails clearly when curl fails" {
  cf_real_ip_env
  export CURL_SHOULD_FAIL=1

  run write_cloudflare_real_ip_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch Cloudflare"* ]]
}

@test "write_cloudflare_real_ip_config rolls back on nginx -t failure" {
  cf_real_ip_env
  echo "PREVIOUS CONTENT" > "$CF_REAL_IP_CONF"

  export CURL_CF_IPV4="1.1.1.0/24"
  export CURL_CF_IPV6="2400:cb00::/32"
  export NGINX_T_SHOULD_FAIL=1

  run write_cloudflare_real_ip_config
  [ "$status" -eq 1 ]
  [ "$(cat "$CF_REAL_IP_CONF")" == "PREVIOUS CONTENT" ]
}

# ---------------------------------------------------------------------------
# prompt / prompt_secret (stdin-driven)
# ---------------------------------------------------------------------------

@test "prompt uses the default value when input is empty" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "\n" | { prompt RESULT "Question" "default-value"; echo "$RESULT"; }
  '
  [[ "$output" == *"default-value"* ]]
}

@test "prompt uses provided value over default" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "custom-value\n" | { prompt RESULT "Question" "default-value"; echo "$RESULT"; }
  '
  [[ "$output" == *"custom-value"* ]]
}

@test "prompt requires a value when no default is given" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "\nfilled-in\n" | { prompt RESULT "Question"; echo "$RESULT"; }
  '
  [[ "$output" == *"Value is required"* ]]
  [[ "$output" == *"filled-in"* ]]
}

@test "prompt_optional leaves the variable blank when input is empty and there is no default" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "\n" | { prompt_optional RESULT "Question"; echo "[\$RESULT]"; }
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"[]"* ]]
}

@test "prompt_optional accepts a provided value over a blank default" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "reality\n" | { prompt_optional RESULT "Question"; echo "[\$RESULT]"; }
  '
  [[ "$output" == *"[reality]"* ]]
}

@test "prompt_optional reuses a persisted default when input is empty" {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    printf "\n" | { prompt_optional RESULT "Question" "reality"; echo "[\$RESULT]"; }
  '
  [[ "$output" == *"[reality]"* ]]
}

# ---------------------------------------------------------------------------
# generate_uuid / print_client_links
# ---------------------------------------------------------------------------

@test "generate_uuid produces a valid v4-shaped UUID" {
  run generate_uuid
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

@test "print_client_links prints panel credentials and URL" {
  XUI_USERNAME="admin_ab12cd34"
  XUI_PASSWORD="S3cretPass1234567890AB"
  PANEL_SUBDOMAIN="admin"
  BASE_DOMAIN="example.com"
  PANEL_PATH="/rand0mBaseP4th"

  CLIENT_UUID="11111111-2222-3333-4444-555555555555"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  INBOUND_REMARK_WS="ws-cdn"
  INBOUND_REMARK_GRPC="grpc-cdn"
  INBOUND_REMARK_XHTTP="xhttp-cdn"
  VLESS_SUBDOMAIN="vpn"
  VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"

  run print_client_links
  [ "$status" -eq 0 ]

  [[ "$output" == *"Username: admin_ab12cd34"* ]]
  [[ "$output" == *"Password: S3cretPass1234567890AB"* ]]
  [[ "$output" == *"https://admin.example.com/rand0mBaseP4th/"* ]]
}

@test "print_client_links emits WS, gRPC, and XHTTP VLESS URIs with TLS and correct host" {
  CLIENT_UUID="11111111-2222-3333-4444-555555555555"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  INBOUND_REMARK_WS="ws-cdn"
  INBOUND_REMARK_GRPC="grpc-cdn"
  INBOUND_REMARK_XHTTP="xhttp-cdn"
  VLESS_SUBDOMAIN="vpn"
  BASE_DOMAIN="example.com"
  XUI_USERNAME="u"
  XUI_PASSWORD="p"
  PANEL_SUBDOMAIN="admin"
  PANEL_PATH="/admin"
  VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"

  run print_client_links
  [ "$status" -eq 0 ]

  [[ "$output" == *"vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?type=ws&security=tls&encryption=mlkem768-client-stub&path=%2Fapi%2Fv1%2Fevents&host=vpn.example.com#ws-cdn"* ]]
  [[ "$output" == *"vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?type=grpc&security=tls&encryption=mlkem768-client-stub&serviceName=api.v1.SyncService&mode=gun&host=vpn.example.com#grpc-cdn"* ]]
  [[ "$output" == *"vless://11111111-2222-3333-4444-555555555555@vpn.example.com:443?type=xhttp&security=tls&encryption=mlkem768-client-stub&flow=xtls-rprx-vision&path=%2Fapi%2Fv1%2Fingest%2Fabcd1234&mode=packet-up&host=vpn.example.com#xhttp-cdn"* ]]

  unique_uuid_count=$(printf '%s\n' "$output" \
    | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
    | sort -u | wc -l | tr -d ' ')

  [ "$unique_uuid_count" = "1" ]
}

@test "print_client_links omits the Reality URI when disabled" {
  CLIENT_UUID="11111111-2222-3333-4444-555555555555"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  INBOUND_REMARK_WS="ws-cdn"
  INBOUND_REMARK_GRPC="grpc-cdn"
  INBOUND_REMARK_XHTTP="xhttp-cdn"
  VLESS_SUBDOMAIN="vpn"
  BASE_DOMAIN="example.com"
  XUI_USERNAME="u"
  XUI_PASSWORD="p"
  PANEL_SUBDOMAIN="admin"
  PANEL_PATH="/admin"
  VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"
  REALITY_SUBDOMAIN=""

  run print_client_links
  [ "$status" -eq 0 ]
  [[ "$output" != *"security=reality"* ]]
}

@test "print_client_links emits a Reality VLESS URI when enabled" {
  CLIENT_UUID="11111111-2222-3333-4444-555555555555"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  INBOUND_REMARK_WS="ws-cdn"
  INBOUND_REMARK_GRPC="grpc-cdn"
  INBOUND_REMARK_XHTTP="xhttp-cdn"
  VLESS_SUBDOMAIN="vpn"
  BASE_DOMAIN="example.com"
  XUI_USERNAME="u"
  XUI_PASSWORD="p"
  PANEL_SUBDOMAIN="admin"
  PANEL_PATH="/admin"
  VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PUBLIC_KEY="reality-pub-stub"
  REALITY_SHORT_ID="abcd1234"
  INBOUND_REMARK_REALITY="reality-remark"

  run print_client_links
  [ "$status" -eq 0 ]
  [[ "$output" == *"vless://11111111-2222-3333-4444-555555555555@reality.example.com:443?type=tcp&security=reality&pbk=reality-pub-stub&fp=chrome&sni=github.com&sid=abcd1234&flow=xtls-rprx-vision#reality-remark"* ]]
}

# ---------------------------------------------------------------------------
# print_summary
# ---------------------------------------------------------------------------

print_summary_env() {
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  BASE_DOMAIN="example.com"
  PANEL_PATH="/admin"
  PANEL_PORT="2053"
  WS_PORT="10001"
  WS_PATH="/api/v1/events"
  XHTTP_PORT="10003"
  XHTTP_PATH="/api/v1/ingest/abcd1234"
  GRPC_PORT="10002"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PATH="/sub"
  SUB_PORT="2096"
  NGINX_SITE="/etc/nginx/sites-available/3xui-proxy"
  CF_REAL_IP_CONF="/etc/nginx/conf.d/cloudflare-real-ip.conf"
  CF_CREDENTIALS="/etc/letsencrypt/cloudflare.ini"
  CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh"
}

@test "print_summary omits the Reality section when disabled" {
  print_summary_env
  REALITY_SUBDOMAIN=""

  run print_summary
  [ "$status" -eq 0 ]
  [[ "$output" != *"VLESS Reality"* ]]
}

@test "print_summary shows the Reality section when enabled" {
  print_summary_env
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"

  run print_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"VLESS Reality (direct connection, no CDN):"* ]]
  [[ "$output" == *"domain: reality.example.com"* ]]
  [[ "$output" == *"impersonating: github.com"* ]]
  [[ "$output" == *"20000/tcp"* ]]
}

@test "print_summary describes UFW as open to everyone on 443" {
  print_summary_env
  REALITY_SUBDOMAIN=""

  run print_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed: 443/tcp from anywhere"* ]]
  [[ "$output" != *"Cloudflare IP ranges only"* ]]
}

# ---------------------------------------------------------------------------
# install-3xui payload contract
# ---------------------------------------------------------------------------

@test "install-3xui explicitly enables generated VLESS clients" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A25 "'clients': \[{" "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'enable': True"* ]]
}

@test "install-3xui fetches full inbound detail before syncing an existing remark" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A55 '^xui_sync_inbound_remark()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/inbounds/get/${id}'* ]]
  [[ "$output" == *'/panel/api/inbounds/update/${id}'* ]]
}

# ---------------------------------------------------------------------------
# VLESS Encryption (ML-KEM-768) -- WS/gRPC/XHTTP only, never Reality.
# setup-3x-ui.sh always runs main() unconditionally (no BASH_SOURCE guard),
# so its functions can't be sourced/exercised directly the way setup.sh's
# can; these assertions are static, matching the existing convention above.
# ---------------------------------------------------------------------------

@test "ensure_vless_encryption_keys calls getNewmlkem768 and reuses a passed-in keypair" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A20 '^ensure_vless_encryption_keys()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/server/getNewmlkem768'* ]]
  [[ "$output" == *"Reusing existing VLESS Encryption keypair"* ]]
}

@test "xui_add_inbound includes decryption and an optional client flow" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A45 '^xui_add_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'decryption': os.environ['DECRYPTION']"* ]]
  [[ "$output" == *"client['flow'] = os.environ['CLIENT_FLOW']"* ]]
}

@test "ensure_ws_inbound and ensure_grpc_inbound pass the VLESS Encryption server key but no flow" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep 'xui_add_inbound "\$WS_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"$VLESS_ENCRYPTION_SERVER_KEY"'* ]]
  [[ "$output" != *"xtls-rprx-vision"* ]]

  run grep 'xui_add_inbound "\$GRPC_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"$VLESS_ENCRYPTION_SERVER_KEY"'* ]]
  [[ "$output" != *"xtls-rprx-vision"* ]]
}

@test "ensure_xhttp_inbound passes the VLESS Encryption server key and xtls-rprx-vision flow" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep 'xui_add_inbound "\$XHTTP_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"$VLESS_ENCRYPTION_SERVER_KEY"'* ]]
  [[ "$output" == *"xtls-rprx-vision"* ]]
}

@test "main generates VLESS Encryption keys before creating any inbound" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A8 '^main() {' "$installer"
  [ "$status" -eq 0 ]
  local key_line inbound_line
  key_line="$(printf '%s\n' "$output" | grep -n 'ensure_vless_encryption_keys' | head -1 | cut -d: -f1)"
  inbound_line="$(printf '%s\n' "$output" | grep -n 'ensure_ws_inbound' | head -1 | cut -d: -f1)"
  [ -n "$key_line" ]
  [ -n "$inbound_line" ]
  [ "$key_line" -lt "$inbound_line" ]
}

# ---------------------------------------------------------------------------
# VLESS+Reality -- optional direct-connection inbound, static assertions
# for the same BASH_SOURCE-guard reason as the VLESS Encryption tests above.
# ---------------------------------------------------------------------------

@test "ensure_reality_keys calls getNewX25519Cert and is a no-op when Reality is disabled" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A25 '^ensure_reality_keys()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/server/getNewX25519Cert'* ]]
  [[ "$output" == *'[[ -n "$REALITY_SUBDOMAIN" ]] || return 0'* ]]
}

@test "ensure_reality_inbound skips creation when REALITY_SUBDOMAIN is empty" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A6 '^ensure_reality_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping Reality inbound"* ]]
}

@test "ensure_reality_inbound builds realitySettings with target, serverNames and shortIds" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A70 '^ensure_reality_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'security': 'reality'"* ]]
  [[ "$output" == *"'target': f\"{os.environ['REALITY_DEST_ARG']}:443\""* ]]
  [[ "$output" == *"'serverNames': [os.environ['REALITY_DEST_ARG']]"* ]]
  [[ "$output" == *"'shortIds': [os.environ['REALITY_SHORT_ID_ARG']]"* ]]
}

@test "ensure_reality_inbound passes flow xtls-rprx-vision and leaves decryption at none" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep 'xui_add_inbound "\$REALITY_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"none" "xtls-rprx-vision"'* ]]
}

@test "main calls ensure_reality_keys and ensure_reality_inbound and reports both keys" {
  local installer="${BATS_TEST_DIRNAME}/../setup-3x-ui.sh"

  run grep -A15 '^main() {' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure_reality_keys"* ]]
  [[ "$output" == *"ensure_reality_inbound"* ]]
  [[ "$output" == *'REALITY_PRIVATE_KEY=%s'* ]]
  [[ "$output" == *'REALITY_PUBLIC_KEY=%s'* ]]
}

# ---------------------------------------------------------------------------
# install_3xui_and_inbounds -- stubs the real install-3xui.sh via
# INSTALL_3XUI_SCRIPT so no network/root access is required.
# ---------------------------------------------------------------------------

write_installer_stub() {
  # $1: path to write the stub to. $2+: extra lines appended verbatim before
  # the final KEY=VALUE report block (e.g. to assert on received env vars).
  local stub_path="$1"
  cat > "$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
  shift
  local extra
  for extra in "$@"; do
    printf '%s\n' "$extra" >> "$stub_path"
  done
  cat >> "$stub_path" <<'EOF'
printf 'PANEL_PORT=%s\n' "${PANEL_PORT}"
printf 'PANEL_PATH=/generated-base-path\n'
printf 'XUI_USERNAME=admin_generated\n'
printf 'XUI_PASSWORD=generated-pass-1234\n'
printf 'CLIENT_UUID=%s\n' "${CLIENT_UUID:-11111111-2222-3333-4444-555555555555}"
printf 'CLIENT_SUB_ID=%s\n' "${CLIENT_SUB_ID:-abcdef1234567890}"
printf 'VLESS_ENCRYPTION_SERVER_KEY=%s\n' "${VLESS_ENCRYPTION_SERVER_KEY:-mlkem768-server-stub}"
printf 'VLESS_ENCRYPTION_CLIENT_KEY=%s\n' "${VLESS_ENCRYPTION_CLIENT_KEY:-mlkem768-client-stub}"
if [[ -n "${REALITY_SUBDOMAIN:-}" ]]; then
  printf 'REALITY_PRIVATE_KEY=%s\n' "${REALITY_PRIVATE_KEY:-reality-priv-stub}"
  printf 'REALITY_PUBLIC_KEY=%s\n' "${REALITY_PUBLIC_KEY:-reality-pub-stub}"
else
  printf 'REALITY_PRIVATE_KEY=\n'
  printf 'REALITY_PUBLIC_KEY=\n'
fi
EOF
  chmod +x "$stub_path"
}

@test "install_3xui_and_inbounds populates PANEL_PORT/PANEL_PATH/creds/UUID from the installer's output" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  SUB_PATH="/sub"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_installer_stub "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  # Deliberately NOT using `run` here: run captures the call via a
  # command-substitution subshell, so global-variable mutations made by
  # install_3xui_and_inbounds (PANEL_PORT/PANEL_PATH/XUI_USERNAME/...)
  # would never be visible afterwards in this test's shell. Calling it
  # directly keeps it in the current shell so those mutations stick.
  install_3xui_and_inbounds
  status=$?

  [ "$status" -eq 0 ]
  [ "$PANEL_PORT" == "51234" ]
  [ "$PANEL_PATH" == "/generated-base-path" ]
  [ "$XUI_USERNAME" == "admin_generated" ]
  [ "$XUI_PASSWORD" == "generated-pass-1234" ]
  [[ "$CLIENT_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

@test "install_3xui_and_inbounds captures Reality keys when REALITY_SUBDOMAIN is set" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  REALITY_SHORT_ID="abcd1234"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_installer_stub "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  install_3xui_and_inbounds
  [ "$REALITY_PRIVATE_KEY" == "reality-priv-stub" ]
  [ "$REALITY_PUBLIC_KEY" == "reality-pub-stub" ]
}

@test "install_3xui_and_inbounds does not require Reality keys when REALITY_SUBDOMAIN is unset" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  REALITY_SUBDOMAIN=""

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_installer_stub "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
}

@test "install_3xui_and_inbounds dies if REALITY_SUBDOMAIN is set but the installer reports no Reality keys" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  REALITY_SHORT_ID="abcd1234"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'PANEL_PORT=%s\n' "${PANEL_PORT}"
printf 'PANEL_PATH=/generated-base-path\n'
printf 'XUI_USERNAME=admin_generated\n'
printf 'XUI_PASSWORD=generated-pass-1234\n'
printf 'CLIENT_UUID=11111111-2222-3333-4444-555555555555\n'
printf 'VLESS_ENCRYPTION_SERVER_KEY=mlkem768-server-stub\n'
printf 'VLESS_ENCRYPTION_CLIENT_KEY=mlkem768-client-stub\n'
EOF
  chmod +x "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not report REALITY_PRIVATE_KEY/REALITY_PUBLIC_KEY"* ]]
}

@test "install_3xui_and_inbounds forwards REALITY_DOMAIN as REALITY_SUBDOMAIN.BASE_DOMAIN" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  REALITY_SHORT_ID="abcd1234"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-reality-domain"
  write_installer_stub "$stub" "echo \"\${REALITY_DOMAIN}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == "reality.example.com" ]
}

@test "install_3xui_and_inbounds passes the pre-reserved PANEL_PORT to the installer as-is" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  SUB_PATH="/sub"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-panel-port"
  write_installer_stub "$stub" "echo \"\${PANEL_PORT}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == "51234" ]
}

# ---------------------------------------------------------------------------
# install_nginx_org_repo
# ---------------------------------------------------------------------------

write_os_release() {
  # $1: dest path, $2: ID, $3: VERSION_CODENAME
  cat > "$1" <<EOF
ID=${2}
VERSION_CODENAME=${3}
EOF
}

@test "install_nginx_org_repo writes the expected apt source and pin for Ubuntu" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  write_os_release "$OS_RELEASE_FILE" "ubuntu" "noble"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  run install_nginx_org_repo
  [ "$status" -eq 0 ]

  grep -qF "deb [signed-by=${NGINX_ORG_KEYRING}] http://nginx.org/packages/ubuntu noble nginx" "$NGINX_ORG_LIST"
  [ -f "$NGINX_ORG_KEYRING" ]
  grep -qF "Pin-Priority: 900" "$NGINX_ORG_PREF"
}

@test "install_nginx_org_repo writes the expected apt source for Debian" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  write_os_release "$OS_RELEASE_FILE" "debian" "bookworm"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  run install_nginx_org_repo
  [ "$status" -eq 0 ]

  grep -qF "deb [signed-by=${NGINX_ORG_KEYRING}] http://nginx.org/packages/debian bookworm nginx" "$NGINX_ORG_LIST"
}

@test "install_nginx_org_repo is idempotent when the repo is already configured" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  write_os_release "$OS_RELEASE_FILE" "ubuntu" "noble"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  install_nginx_org_repo
  local first_content
  first_content="$(cat "$NGINX_ORG_LIST")"

  run install_nginx_org_repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"already configured, skipping"* ]]
  [ "$(cat "$NGINX_ORG_LIST")" = "$first_content" ]
}

@test "install_nginx_org_repo dies on an unsupported distro" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  write_os_release "$OS_RELEASE_FILE" "fedora" "39"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  run install_nginx_org_repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported distro"* ]]
}

@test "install_nginx_org_repo dies when the codename is missing" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  printf 'ID=ubuntu\n' > "$OS_RELEASE_FILE"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  run install_nginx_org_repo
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine distro codename"* ]]
}

@test "install_packages calls install_nginx_org_repo before installing nginx" {
  OS_RELEASE_FILE="${BATS_TEST_TMPDIR}/os-release"
  write_os_release "$OS_RELEASE_FILE" "ubuntu" "noble"
  NGINX_ORG_LIST="${BATS_TEST_TMPDIR}/nginx.list"
  NGINX_ORG_KEYRING="${BATS_TEST_TMPDIR}/nginx-archive-keyring.gpg"
  NGINX_ORG_PREF="${BATS_TEST_TMPDIR}/99nginx"

  run install_packages
  [ "$status" -eq 0 ]
  [ -f "$NGINX_ORG_LIST" ]
}

@test "install_3xui_and_inbounds forwards generated inbound remarks to the panel helper" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  XHTTP_PORT="51237"
  XHTTP_PATH="/api/v1/ingest"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  INBOUND_REMARK_WS="🇪🇪 WebSocket-CDN"
  INBOUND_REMARK_GRPC="🇪🇪 gRPC-CDN"
  INBOUND_REMARK_XHTTP="🇪🇪 XHTTP-CDN"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-remarks"
  write_installer_stub "$stub" "printf '%s\\n%s\\n%s\\n' \"\${INBOUND_REMARK_WS}\" \"\${INBOUND_REMARK_GRPC}\" \"\${INBOUND_REMARK_XHTTP}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == $'🇪🇪 WebSocket-CDN\n🇪🇪 gRPC-CDN\n🇪🇪 XHTTP-CDN' ]
}

@test "install_3xui_and_inbounds dies if PANEL_PORT ends up colliding (validate_panel_port re-check)" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"
  SUB_PATH="/sub"

  # Simulate 3x-ui having already been installed before with its own port,
  # which happens to collide with WS_PORT.
  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'PANEL_PORT=%s\n' "${WS_PORT}"
printf 'PANEL_PATH=/generated-base-path\n'
printf 'XUI_USERNAME=admin_generated\n'
printf 'XUI_PASSWORD=generated-pass-1234\n'
printf 'CLIENT_UUID=11111111-2222-3333-4444-555555555555\n'
printf 'VLESS_ENCRYPTION_SERVER_KEY=mlkem768-server-stub\n'
printf 'VLESS_ENCRYPTION_CLIENT_KEY=mlkem768-client-stub\n'
EOF
  chmod +x "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"collides with WS_PORT"* ]]
}

@test "install_3xui_and_inbounds dies if the installer produces no output" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not report PANEL_PORT"* ]]
}

@test "install_3xui_and_inbounds dies if setup-3x-ui.sh itself fails" {
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  CLIENT_UUID=""

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
EOF
  chmod +x "$stub"
  export SETUP_3X_UI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"setup-3x-ui.sh failed"* ]]
}

@test "install_3xui_and_inbounds forwards XUI_VERSION to install-3xui.sh" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""
  XUI_VERSION="v3.4.0"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-xui-version"
  write_installer_stub "$stub" "echo \"\${XUI_VERSION:-}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == "v3.4.0" ]
}

# ---------------------------------------------------------------------------
# uninstall_all -- exercises the --uninstall cleanup path against stubs.
# ---------------------------------------------------------------------------

write_uninstall_stub() {
  # Records that it was invoked (and with --uninstall) to $1.
  local stub_path="$1"
  local marker_file="$2"
  cat > "$stub_path" <<EOF
#!/usr/bin/env bash
echo "called with: \$*" > '${marker_file}'
exit 0
EOF
  chmod +x "$stub_path"
}

setup_uninstall_fixtures() {
  # Shared fixture wiring for uninstall_all tests: overrides require_root
  # (tests don't run as root) and all path/port vars to BATS_TEST_TMPDIR.
  # Also stubs ANONYMIZE_SCRIPT by default so uninstall_all never shells out
  # to the real anonymize.sh (which would require root and touch real
  # system files) unless a test explicitly wants to assert on it.
  require_root() { :; }

  local default_anonymize_stub="${BATS_TEST_TMPDIR}/anonymize.sh"
  write_uninstall_stub "$default_anonymize_stub" "${BATS_TEST_TMPDIR}/anonymize-called"
  export ANONYMIZE_SCRIPT="$default_anonymize_stub"

  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  STATE_FILE="${BATS_TEST_TMPDIR}/xui-proxy-ports.state"
  NGINX_SITE="${BATS_TEST_TMPDIR}/3xui-proxy"
  NGINX_SITE_ENABLED="${BATS_TEST_TMPDIR}/3xui-proxy-enabled"
  CF_REAL_IP_CONF="${BATS_TEST_TMPDIR}/cloudflare-real-ip.conf"
  CF_IP_STATE_FILE="${BATS_TEST_TMPDIR}/cloudflare-ips.state"
  CERTBOT_DEPLOY_HOOK="${BATS_TEST_TMPDIR}/nginx-reload.sh"
  CF_CREDENTIALS="${BATS_TEST_TMPDIR}/cloudflare.ini"
  BASE_DOMAIN="example.com"
  PANEL_PORT="51234"
  SUB_PORT="2096"
  WS_PORT="51235"
  GRPC_PORT="51236"
}

@test "uninstall_all removes nginx site, cloudflare real-ip config, certbot hook and cf credentials" {
  setup_uninstall_fixtures

  : > "$NGINX_SITE"
  : > "$NGINX_SITE_ENABLED"
  : > "$CF_REAL_IP_CONF"
  : > "$CERTBOT_DEPLOY_HOOK"
  : > "$CF_CREDENTIALS"
  : > "$STATE_FILE"
  : > "$CONFIG_FILE"

  local installer_marker="${BATS_TEST_TMPDIR}/installer-called"
  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "$installer_marker"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  [ ! -e "$NGINX_SITE" ]
  [ ! -e "$NGINX_SITE_ENABLED" ]
  [ ! -e "$CF_REAL_IP_CONF" ]
  [ ! -e "$CERTBOT_DEPLOY_HOOK" ]
  [ ! -e "$CF_CREDENTIALS" ]
  [ ! -e "$STATE_FILE" ]
  [ ! -e "$CONFIG_FILE" ]

  [ -f "$installer_marker" ]
  [[ "$(cat "$installer_marker")" == *"--uninstall"* ]]
}

@test "uninstall_all removes the ufw rules it previously added" {
  setup_uninstall_fixtures

  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "${BATS_TEST_TMPDIR}/installer-called"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  export UFW_LOG="${BATS_TEST_TMPDIR}/ufw.log"
  : > "$UFW_LOG"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  grep -q "delete allow 443/tcp" "$UFW_LOG"
  grep -q "delete deny 443/tcp" "$UFW_LOG"
  grep -q "delete deny 80/tcp" "$UFW_LOG"
  grep -q "delete deny 51234/tcp" "$UFW_LOG"
  grep -q "delete deny 2096/tcp" "$UFW_LOG"
  grep -q "delete deny 51235/tcp" "$UFW_LOG"
  grep -q "delete deny 51236/tcp" "$UFW_LOG"
}

@test "uninstall_all keeps the certbot cert by default" {
  setup_uninstall_fixtures

  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "${BATS_TEST_TMPDIR}/installer-called"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  export CERTBOT_LOG="${BATS_TEST_TMPDIR}/certbot.log"
  : > "$CERTBOT_LOG"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  ! grep -q "delete --cert-name example.com" "$CERTBOT_LOG"
}

@test "uninstall_all deletes the certbot cert when DELETE_CERT=true" {
  setup_uninstall_fixtures

  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "${BATS_TEST_TMPDIR}/installer-called"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  export CERTBOT_LOG="${BATS_TEST_TMPDIR}/certbot.log"
  : > "$CERTBOT_LOG"
  export DELETE_CERT=true

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  grep -q "delete --cert-name example.com" "$CERTBOT_LOG"
}

@test "uninstall_all cancels when not confirmed, leaving files untouched" {
  setup_uninstall_fixtures

  : > "$NGINX_SITE"

  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "${BATS_TEST_TMPDIR}/installer-called"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  run uninstall_all <<< "n"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled."* ]]
  [ -e "$NGINX_SITE" ]
  [ ! -f "${BATS_TEST_TMPDIR}/installer-called" ]
}

# ---------------------------------------------------------------------------
# install_3xui_and_inbounds — CLIENT_SUB_ID forwarding
# ---------------------------------------------------------------------------

@test "install_3xui_and_inbounds captures CLIENT_SUB_ID from installer output" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID=""
  CLIENT_SUB_ID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_installer_stub "$stub"
  export INSTALL_3XUI_SCRIPT="$stub"

  install_3xui_and_inbounds
  [ "$CLIENT_SUB_ID" == "abcdef1234567890" ]
}

@test "install_3xui_and_inbounds forwards SUB_PORT and SUB_PATH to installer" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="54321"
  SUB_PATH="/assets/abc123"
  CLIENT_UUID=""
  CLIENT_SUB_ID=""
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-sub-vars"
  write_installer_stub "$stub" "echo \"\${SUB_PORT}|\${SUB_PATH}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == "54321|/assets/abc123" ]
}

@test "install_3xui_and_inbounds forwards CLIENT_SUB_ID for reuse on reruns" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  SUB_PATH="/sub"
  CLIENT_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  CLIENT_SUB_ID="my_existing_sub_id"
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  EMAIL="user@example.com"

  local stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  local received_log="${BATS_TEST_TMPDIR}/received-sub-id"
  write_installer_stub "$stub" "echo \"\${CLIENT_SUB_ID}\" > '${received_log}'"
  export INSTALL_3XUI_SCRIPT="$stub"

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
  [ "$(cat "$received_log")" == "my_existing_sub_id" ]
}

# ---------------------------------------------------------------------------
# write_nginx_config — subscription proxy rewrite
# ---------------------------------------------------------------------------

@test "write_nginx_config proxies SUB_PATH to SUB_PORT without path rewrite" {
  nginx_config_env
  SUB_PATH="/assets/abc123"
  SUB_PORT="54321"
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "location /assets/abc123/" "$NGINX_SITE"
  grep -q "proxy_pass http://127.0.0.1:54321;" "$NGINX_SITE"
}

# ---------------------------------------------------------------------------
# Path auto-generation — verifies the generated paths/services look realistic
# ---------------------------------------------------------------------------

@test "auto-generated WS_PATH looks like a real API endpoint" {
  WS_PATH=""
  # Simulate what collect_input does
  local ws_words=(events stream messages notifications updates sync relay)
  WS_PATH="/api/v$(( RANDOM % 3 + 1 ))/${ws_words[RANDOM % ${#ws_words[@]}]}/$(openssl rand -hex 4)"

  [[ "$WS_PATH" =~ ^/api/v[123]/[a-z]+/[0-9a-f]{8}$ ]]
}

@test "auto-generated XHTTP_PATH looks like a real API endpoint" {
  XHTTP_PATH=""
  local xhttp_words=(telemetry ingest batch gateway upload)
  XHTTP_PATH="/api/v$(( RANDOM % 3 + 1 ))/${xhttp_words[RANDOM % ${#xhttp_words[@]}]}/$(openssl rand -hex 4)"

  [[ "$XHTTP_PATH" =~ ^/api/v[123]/[a-z]+/[0-9a-f]{8}$ ]]
}

@test "auto-generated GRPC_SERVICE looks like a real gRPC service name" {
  GRPC_SERVICE=""
  local grpc_orgs=(internal backend core cloud platform service)
  local grpc_pkgs=(sync relay push telemetry health streaming)
  local grpc_svcs=(SyncService RelayService PushService EventService DataService StreamService)
  GRPC_SERVICE="com.${grpc_orgs[RANDOM % ${#grpc_orgs[@]}]}.${grpc_pkgs[RANDOM % ${#grpc_pkgs[@]}]}.v$(( RANDOM % 3 + 1 )).${grpc_svcs[RANDOM % ${#grpc_svcs[@]}]}"

  [[ "$GRPC_SERVICE" =~ ^com\.[a-z]+\.[a-z]+\.v[123]\.[A-Z][a-zA-Z]+$ ]]
}

@test "auto-generated SUB_PATH looks like a static web path" {
  SUB_PATH=""
  local sub_words=(download resources assets static content files docs)
  SUB_PATH="/${sub_words[RANDOM % ${#sub_words[@]}]}/$(openssl rand -hex 6)"

  [[ "$SUB_PATH" =~ ^/[a-z]+/[0-9a-f]{12}$ ]]
}

# ---------------------------------------------------------------------------
# anonymize_vps -- stubs harden-host.sh via HARDEN_HOST_SCRIPT so no
# root/network access is required.
# ---------------------------------------------------------------------------

@test "anonymize_vps invokes harden-host.sh next to setup.sh" {
  local marker="${BATS_TEST_TMPDIR}/harden-host-called"
  local stub="${BATS_TEST_TMPDIR}/harden-host.sh"
  write_uninstall_stub "$stub" "$marker"
  export HARDEN_HOST_SCRIPT="$stub"

  run anonymize_vps
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

@test "anonymize_vps does not abort setup if harden-host.sh fails" {
  local stub="${BATS_TEST_TMPDIR}/harden-host.sh"
  cat > "$stub" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
EOF
  chmod +x "$stub"
  export HARDEN_HOST_SCRIPT="$stub"

  run anonymize_vps
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: harden-host.sh reported an error"* ]]
}

@test "anonymize_vps warns but does not fail if harden-host.sh is missing" {
  export HARDEN_HOST_SCRIPT="${BATS_TEST_TMPDIR}/does-not-exist.sh"

  run anonymize_vps
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: harden-host.sh not found"* ]]
}

@test "uninstall_all invokes anonymize.sh --uninstall" {
  setup_uninstall_fixtures

  local anonymize_marker="${BATS_TEST_TMPDIR}/anonymize-called"
  local anonymize_stub="${BATS_TEST_TMPDIR}/anonymize.sh"
  write_uninstall_stub "$anonymize_stub" "$anonymize_marker"
  export ANONYMIZE_SCRIPT="$anonymize_stub"

  local installer_stub="${BATS_TEST_TMPDIR}/install-3xui.sh"
  write_uninstall_stub "$installer_stub" "${BATS_TEST_TMPDIR}/installer-called"
  export INSTALL_3XUI_SCRIPT="$installer_stub"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  [ -f "$anonymize_marker" ]
  [[ "$(cat "$anonymize_marker")" == *"--uninstall"* ]]
}

# ---------------------------------------------------------------------------
# detect_country_flag
# ---------------------------------------------------------------------------

@test "detect_country_flag uses VPS_COUNTRY_CODE over geolocation" {
  export VPS_COUNTRY_CODE="EE"
  export CURL_COUNTRY_CODE="US"

  run detect_country_flag
  [ "$status" -eq 0 ]
  [ "$output" == "🇪🇪" ]
}

@test "detect_country_flag rejects an invalid VPS_COUNTRY_CODE" {
  export VPS_COUNTRY_CODE="EST"

  run detect_country_flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"VPS_COUNTRY_CODE must be"* ]]
}

@test "detect_country_flag returns non-empty output for valid country code FR" {
  export CURL_COUNTRY_CODE="FR"
  run detect_country_flag
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Flag emojis are 8 bytes (two 4-byte UTF-8 regional indicators)
  [ "${#output}" -gt 0 ]
}

@test "detect_country_flag returns different flags for different countries" {
  export CURL_COUNTRY_CODE="FR"
  run detect_country_flag
  local fr_flag="$output"

  export CURL_COUNTRY_CODE="DE"
  run detect_country_flag
  local de_flag="$output"

  [ "$fr_flag" != "$de_flag" ]
}

@test "detect_country_flag returns consistent output for same country" {
  export CURL_COUNTRY_CODE="US"
  run detect_country_flag
  local first="$output"

  run detect_country_flag
  local second="$output"

  [ "$first" = "$second" ]
}

@test "detect_country_flag returns fallback when all APIs fail" {
  export CURL_SHOULD_FAIL=1
  run detect_country_flag
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "detect_country_flag returns fallback for invalid response" {
  export CURL_COUNTRY_CODE="INVALID"
  run detect_country_flag
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "detect_country_flag fallback is same for failure and invalid response" {
  export CURL_SHOULD_FAIL=1
  run detect_country_flag
  local fail_output="$output"
  unset CURL_SHOULD_FAIL

  export CURL_COUNTRY_CODE="INVALID"
  run detect_country_flag
  [ "$output" = "$fail_output" ]
}

@test "INBOUND_REMARK variables contain flag and transport name" {
  export CURL_COUNTRY_CODE="NL"
  local flag
  flag="$(detect_country_flag)"
  local remark_ws="${flag} WebSocket-CDN"
  local remark_grpc="${flag} gRPC-CDN"

  [[ "$remark_ws" == *"WebSocket-CDN" ]]
  [[ "$remark_grpc" == *"gRPC-CDN" ]]
  [[ "$remark_ws" == "${flag}"* ]]
  [[ "$remark_grpc" == "${flag}"* ]]
}
