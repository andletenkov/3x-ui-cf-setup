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
  INSTALL_MODE="cdn"

  # Reset any state that individual tests might rely on being clean.
  unset SS_LISTENING_PORTS CURL_SHOULD_FAIL CURL_CF_IPV4 CURL_CF_IPV6 \
    CURL_HTTP_CODE NGINX_T_SHOULD_FAIL UFW_LOG VPS_COUNTRY_CODE \
    SYSTEMCTL_LOG SYSTEMCTL_SHOULD_FAIL NAIVE_RELEASE_JSON TAR_SHOULD_FAIL
}

# ---------------------------------------------------------------------------
# CDN_MODE normalization
# ---------------------------------------------------------------------------

@test "normalize_cdn_mode accepts true-compatible values" {
  run normalize_cdn_mode "YeS"
  [ "$status" -eq 0 ]
  [ "$output" = "cdn" ]

  run normalize_cdn_mode "1"
  [ "$status" -eq 0 ]
  [ "$output" = "cdn" ]
}

@test "normalize_cdn_mode accepts false-compatible values and rejects invalid input" {
  run normalize_cdn_mode "OFF"
  [ "$status" -eq 0 ]
  [ "$output" = "no-cdn" ]

  run normalize_cdn_mode "maybe"
  [ "$status" -eq 1 ]
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
  INSTALL_MODE="cdn"
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

@test "validate_inputs rejects direct inbounds in cdn mode" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"INSTALL_MODE=cdn cannot enable direct inbounds"* ]]
}

@test "validate_inputs accepts a no-cdn Reality-only configuration" {
  valid_inputs
  INSTALL_MODE="no-cdn"
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs rejects no-cdn mode without a direct inbound" {
  valid_inputs
  INSTALL_MODE="no-cdn"
  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN=""
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires at least one direct inbound"* ]]
}

@test "validate_inputs accepts a no-cdn Hysteria2-only configuration" {
  valid_inputs
  INSTALL_MODE="no-cdn"
  HYSTERIA_SUBDOMAIN="hy2"
  HYSTERIA_PORT="443"
  HYSTERIA_AUTH="test-auth"
  HYSTERIA_OBFS_PASSWORD="test-obfs"
  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN=""
  run validate_inputs
  [ "$status" -eq 0 ]
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
  # Run in a real bash -c subshell (not a direct unwrapped call in this test
  # process) -- calling save_config/load_config directly here has been
  # observed to silently drop this test's result under this bats version.
  CONFIG_FILE="${BATS_TEST_TMPDIR}/.3xui-proxy.conf"

  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    CONFIG_FILE="'"$CONFIG_FILE"'"
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

    printf "SUBDOMAIN=%s DEST=%s PORT=%s SHORTID=%s\n" "$REALITY_SUBDOMAIN" "$REALITY_DEST" "$REALITY_PORT" "$REALITY_SHORT_ID"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"SUBDOMAIN=reality DEST=github.com PORT=20000 SHORTID=abcd1234abcd5678"* ]]
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
  NGINX_DEFAULT_SITE="${BATS_TEST_TMPDIR}/default"
  NGINX_DEFAULT_SITE_BACKUP="${BATS_TEST_TMPDIR}/default.backup"
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

@test "write_nginx_config omits CDN VLESS proxy locations in no-cdn mode" {
  nginx_config_env
  INSTALL_MODE="no-cdn"

  run write_nginx_config
  [ "$status" -eq 0 ]

  ! grep -q "server_name vpn.example.com;" "$NGINX_SITE"
  ! grep -q "127.0.0.1:10001" "$NGINX_SITE"
  ! grep -q "127.0.0.1:10002" "$NGINX_SITE"
  ! grep -q "127.0.0.1:10003" "$NGINX_SITE"
  grep -q "server_name admin.example.com;" "$NGINX_SITE"
}

@test "write_nginx_config preserves the default site for uninstall" {
  nginx_config_env
  ln -s /etc/nginx/sites-available/default "$NGINX_DEFAULT_SITE"

  run write_nginx_config
  [ "$status" -eq 0 ]

  [ ! -e "$NGINX_DEFAULT_SITE" ]
  [ -L "$NGINX_DEFAULT_SITE_BACKUP" ]
  [ "$(readlink "$NGINX_DEFAULT_SITE_BACKUP")" = "/etc/nginx/sites-available/default" ]
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

@test "print_client_links prints NaiveProxy connection info when enabled" {
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
  NAIVE_SUBDOMAIN="naive"
  NAIVE_USERNAME="user_abcd1234"
  NAIVE_PASSWORD="supersecretpassword"

  run print_client_links
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== NaiveProxy (HTTPS forward proxy, not a VLESS client) ==="* ]]
  [[ "$output" == *"Server: naive.example.com"* ]]
  [[ "$output" == *"Username: user_abcd1234"* ]]
  [[ "$output" == *"Password: supersecretpassword"* ]]
  [[ "$output" == *"https://user_abcd1234:supersecretpassword@naive.example.com"* ]]
}

@test "print_client_links omits the NaiveProxy section when disabled" {
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
  NAIVE_SUBDOMAIN=""

  run print_client_links
  [ "$status" -eq 0 ]
  [[ "$output" != *"NaiveProxy"* ]]
}

# ---------------------------------------------------------------------------
# verify_deployment
# ---------------------------------------------------------------------------

verify_deployment_env() {
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  BASE_DOMAIN="example.com"
  PANEL_PATH="/admin"
  PANEL_PORT="2053"
  SUB_PORT="2096"
  WS_PORT="10001"
  GRPC_PORT="10002"
  XHTTP_PORT="10003"
  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN=""
}

@test "verify_deployment checks the Reality and NaiveProxy local listeners when enabled" {
  verify_deployment_env
  REALITY_SUBDOMAIN="reality"
  REALITY_PORT="20000"
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  export SS_LISTENING_PORTS="2053 2096 10001 10002 10003 20000 21000"
  export CURL_HTTP_CODE="200"

  run verify_deployment
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]   Reality is listening on 127.0.0.1:20000"* ]]
  [[ "$output" == *"[OK]   NaiveProxy is listening on 127.0.0.1:21000"* ]]
  [[ "$output" == *"All checks passed."* ]]
}

@test "verify_deployment reports a failing Reality listener" {
  verify_deployment_env
  REALITY_SUBDOMAIN="reality"
  REALITY_PORT="20000"
  export SS_LISTENING_PORTS="2053 2096 10001 10002 10003"
  export CURL_HTTP_CODE="200"

  run verify_deployment
  [ "$status" -eq 0 ]
  [[ "$output" == *"[FAIL] Reality is NOT listening on 127.0.0.1:20000"* ]]
  [[ "$output" != *"All checks passed."* ]]
}

@test "verify_deployment omits Reality/NaiveProxy listener checks when both disabled" {
  verify_deployment_env
  export SS_LISTENING_PORTS="2053 2096 10001 10002 10003"
  export CURL_HTTP_CODE="200"

  run verify_deployment
  [ "$status" -eq 0 ]
  [[ "$output" != *"Reality is"* ]]
  [[ "$output" != *"NaiveProxy is"* ]]
}

@test "verify_deployment checks the NaiveProxy public HTTPS endpoint when enabled" {
  verify_deployment_env
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  export SS_LISTENING_PORTS="2053 2096 10001 10002 10003 21000"
  export CURL_HTTP_CODE="200"

  run verify_deployment
  [ "$status" -eq 0 ]
  [[ "$output" == *"[OK]   https://naive.example.com/ responded with HTTP 200"* ]]
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
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A25 "'clients': \[{" "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'enable': True"* ]]
}

@test "install-3xui fetches full inbound detail before syncing an existing remark" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A55 '^xui_sync_inbound_remark()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/inbounds/get/${id}'* ]]
  [[ "$output" == *'/panel/api/inbounds/update/${id}'* ]]
}

# ---------------------------------------------------------------------------
# VLESS Encryption (ML-KEM-768) -- WS/gRPC/XHTTP only, never Reality. These
# functions ARE sourceable/callable now (merged into setup.sh, which has a
# BASH_SOURCE guard) -- kept as static source-text assertions here for
# minimal diff; see the "real 3x-ui" e2e tier (tests/e2e) for functional
# coverage against an actual running panel.
# ---------------------------------------------------------------------------

@test "ensure_vless_encryption_keys calls getNewmlkem768 and reuses a passed-in keypair" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A20 '^ensure_vless_encryption_keys()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/server/getNewmlkem768'* ]]
  [[ "$output" == *"Reusing existing VLESS Encryption keypair"* ]]
}

@test "xui_add_inbound includes decryption and an optional client flow" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A45 '^xui_add_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLIENT_EMAIL=\"\$client_email\""* ]]
  [[ "$output" == *"'email': os.environ['CLIENT_EMAIL']"* ]]
  [[ "$output" != *" EMAIL=\"\$client_email\""* ]]
  [[ "$output" == *"'decryption': os.environ['DECRYPTION']"* ]]
  [[ "$output" == *"client['flow'] = os.environ['CLIENT_FLOW']"* ]]
}

@test "ensure_ws_inbound and ensure_grpc_inbound pass the VLESS Encryption server key but no flow" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

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
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep 'xui_add_inbound "\$XHTTP_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"$VLESS_ENCRYPTION_SERVER_KEY"'* ]]
  [[ "$output" == *"xtls-rprx-vision"* ]]
}

@test "run_xui_install_and_inbounds generates VLESS Encryption keys before creating any inbound" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A10 '^run_xui_install_and_inbounds()' "$installer"
  [ "$status" -eq 0 ]
  local key_line inbound_line
  key_line="$(printf '%s\n' "$output" | grep -n 'ensure_vless_encryption_keys' | head -1 | cut -d: -f1)"
  inbound_line="$(printf '%s\n' "$output" | grep -n 'ensure_ws_inbound' | head -1 | cut -d: -f1)"
  [ -n "$key_line" ]
  [ -n "$inbound_line" ]
  [ "$key_line" -lt "$inbound_line" ]
}

# ---------------------------------------------------------------------------
# Hysteria2 -- direct UDP/QUIC inbound, static payload contract
# ---------------------------------------------------------------------------

@test "ensure_hysteria_inbound uses public UDP, TLS, Salamander, and the required remark" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A55 '^ensure_hysteria_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'listen': '0.0.0.0'"* ]]
  [[ "$output" == *"'protocol': 'hysteria'"* ]]
  [[ "$output" == *"'type': 'salamander'"* ]]
  [[ "$output" == *"Hysteria-Gecko"* ]]
  [[ "$output" == *"'echServerKeys': ''"* ]]
}

# ---------------------------------------------------------------------------
# VLESS+Reality -- optional direct-connection inbound, static source-text
# assertions (same rationale as the VLESS Encryption block above).
# ---------------------------------------------------------------------------

@test "ensure_reality_keys calls getNewX25519Cert and is a no-op when Reality is disabled" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A25 '^ensure_reality_keys()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'/panel/api/server/getNewX25519Cert'* ]]
  [[ "$output" == *'[[ -n "$REALITY_SUBDOMAIN" ]] || return 0'* ]]
}

@test "ensure_reality_inbound skips creation when REALITY_SUBDOMAIN is empty" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A6 '^ensure_reality_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping Reality inbound"* ]]
}

@test "ensure_reality_inbound builds realitySettings with target, serverNames and shortIds" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A70 '^ensure_reality_inbound()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'security': 'reality'"* ]]
  [[ "$output" == *"'target': f\"{os.environ['REALITY_DEST_ARG']}:443\""* ]]
  [[ "$output" == *"'serverNames': [os.environ['REALITY_DEST_ARG']]"* ]]
  [[ "$output" == *"'shortIds': [os.environ['REALITY_SHORT_ID_ARG']]"* ]]
}

@test "ensure_reality_inbound passes flow xtls-rprx-vision and leaves decryption at none" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep 'xui_add_inbound "\$REALITY_PORT"' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"none" "xtls-rprx-vision"'* ]]
}

@test "run_xui_install_and_inbounds calls ensure_reality_keys, ensure_reality_inbound and ensure_reality_host" {
  local installer="${BATS_TEST_DIRNAME}/../setup.sh"

  run grep -A16 '^run_xui_install_and_inbounds()' "$installer"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure_reality_keys"* ]]
  [[ "$output" == *"ensure_reality_inbound"* ]]
  [[ "$output" == *"ensure_reality_host"* ]]
}

# ---------------------------------------------------------------------------
# install_3xui_and_inbounds -- exercises the real orchestration logic
# (deriving PANEL_PORT/PANEL_PATH, validating required outputs, re-checking
# PANEL_PORT, calling save_config) by stubbing out run_xui_install_and_
# inbounds, which is what actually talks to a real 3x-ui panel/network (that
# part is covered by the "real 3x-ui" e2e tier instead, see tests/e2e).
#
# There is no longer a subprocess boundary between setup.sh and 3x-ui setup
# (both merged into one script/one shared variable scope), so tests that
# used to check "does env var X survive being forwarded to the installer
# subprocess" no longer apply -- there's no serialization step left to drop
# a variable. Only install_3xui_and_inbounds's own orchestration logic
# (validation, PANEL_PORT/PANEL_PATH derivation, save_config, error
# propagation) is still meaningful to test here.
# ---------------------------------------------------------------------------

# Stubs run_xui_install_and_inbounds (the real chain that talks to a real
# 3x-ui panel) with a fake that sets the same globals the real chain would.
# $1, if given, is extra bash code eval'd at the start of the fake (e.g. to
# simulate a failure via `die ...` or `return 1`, or to record received
# globals for assertions).
stub_run_xui_install_and_inbounds() {
  XUI_STUB_HOOK="${1:-:}"
  run_xui_install_and_inbounds() {
    eval "$XUI_STUB_HOOK"
    XUI_PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
    XUI_WEB_BASE_PATH="${XUI_WEB_BASE_PATH:-generated-base-path}"
    XUI_USERNAME="${XUI_USERNAME:-admin_generated}"
    XUI_PASSWORD="${XUI_PASSWORD:-generated-pass-1234}"
    [[ -n "$CLIENT_UUID" ]] || CLIENT_UUID="11111111-2222-3333-4444-555555555555"
    [[ -n "$CLIENT_SUB_ID" ]] || CLIENT_SUB_ID="abcdef1234567890"
    VLESS_ENCRYPTION_SERVER_KEY="${VLESS_ENCRYPTION_SERVER_KEY:-mlkem768-server-stub}"
    VLESS_ENCRYPTION_CLIENT_KEY="${VLESS_ENCRYPTION_CLIENT_KEY:-mlkem768-client-stub}"
    if [[ -n "$REALITY_SUBDOMAIN" ]]; then
      REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-reality-priv-stub}"
      REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-reality-pub-stub}"
    fi
  }
}

@test "install_3xui_and_inbounds populates PANEL_PORT/PANEL_PATH/creds/UUID from the install chain" {
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

  stub_run_xui_install_and_inbounds

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

  stub_run_xui_install_and_inbounds

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

  stub_run_xui_install_and_inbounds

  run install_3xui_and_inbounds
  [ "$status" -eq 0 ]
}

@test "install_3xui_and_inbounds dies if REALITY_SUBDOMAIN is set but the install chain reports no Reality keys" {
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

  # Stub deliberately leaves REALITY_PRIVATE_KEY/PUBLIC_KEY unset even
  # though REALITY_SUBDOMAIN is set, simulating the install chain failing
  # to produce them. Returns immediately after, so the fake's own
  # default-filling logic (which would otherwise backfill them) never runs.
  stub_run_xui_install_and_inbounds '
    XUI_PANEL_PORT="$PANEL_PORT"
    XUI_WEB_BASE_PATH="generated-base-path"
    XUI_USERNAME="admin_generated"
    XUI_PASSWORD="generated-pass-1234"
    CLIENT_UUID="11111111-2222-3333-4444-555555555555"
    VLESS_ENCRYPTION_SERVER_KEY="mlkem768-server-stub"
    VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""
    return 0
  '

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"REALITY_PRIVATE_KEY/REALITY_PUBLIC_KEY were not produced"* ]]
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

# ---------------------------------------------------------------------------
# validate_inputs / save_config / confirm_configuration / print_summary --
# optional NaiveProxy fields
# ---------------------------------------------------------------------------

@test "validate_inputs accepts a blank NaiveProxy configuration (feature disabled)" {
  valid_inputs
  NAIVE_SUBDOMAIN=""
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs accepts a fully populated NaiveProxy configuration" {
  valid_inputs
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs rejects a NaiveProxy subdomain equal to the panel subdomain" {
  valid_inputs
  NAIVE_SUBDOMAIN="$PANEL_SUBDOMAIN"
  NAIVE_PORT="21000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"different from the panel subdomain"* ]]
}

@test "validate_inputs rejects a NaiveProxy subdomain equal to the Reality subdomain" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  NAIVE_SUBDOMAIN="reality"
  NAIVE_PORT="21000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"different from the Reality subdomain"* ]]
}

@test "validate_inputs rejects a NaiveProxy port colliding with the Reality port" {
  valid_inputs
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="20000"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"NaiveProxy port must be different from every other internal port"* ]]
}

@test "validate_inputs rejects a NaiveProxy port of 443" {
  valid_inputs
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"NaiveProxy port cannot be 443"* ]]
}

@test "save_config persists NaiveProxy fields and load_config restores them" {
  # See the equivalent Reality test above for why this runs in a real
  # bash -c subshell instead of calling save_config/load_config directly.
  CONFIG_FILE="${BATS_TEST_TMPDIR}/.3xui-proxy.conf"

  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
    CONFIG_FILE="'"$CONFIG_FILE"'"
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
    NAIVE_SUBDOMAIN="naive"
    NAIVE_PORT="21000"
    NAIVE_USERNAME="user_abcd1234"
    NAIVE_PASSWORD="supersecretpassword"

    save_config

    NAIVE_SUBDOMAIN=""
    NAIVE_PORT=""
    NAIVE_USERNAME=""
    NAIVE_PASSWORD=""

    load_config

    printf "SUBDOMAIN=%s PORT=%s USERNAME=%s PASSWORD=%s\n" "$NAIVE_SUBDOMAIN" "$NAIVE_PORT" "$NAIVE_USERNAME" "$NAIVE_PASSWORD"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"SUBDOMAIN=naive PORT=21000 USERNAME=user_abcd1234 PASSWORD=supersecretpassword"* ]]
}

@test "confirm_configuration shows the NaiveProxy section when enabled" {
  valid_inputs
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  NAIVE_USERNAME="user_abcd1234"

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NaiveProxy (direct connection, no CDN):"* ]]
  [[ "$output" == *"domain: naive.example.com"* ]]
  [[ "$output" == *"internal Caddy port: 21000"* ]]
  [[ "$output" == *"username: user_abcd1234"* ]]
  [[ "$output" == *"21000/tcp"* ]]
}

@test "confirm_configuration omits the NaiveProxy section when disabled" {
  valid_inputs
  NAIVE_SUBDOMAIN=""

  run confirm_configuration <<< "y"
  [ "$status" -eq 0 ]
  [[ "$output" != *"NaiveProxy"* ]]
}

@test "print_summary shows the NaiveProxy section including the password when enabled" {
  print_summary_env
  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  NAIVE_USERNAME="user_abcd1234"
  NAIVE_PASSWORD="supersecretpassword"

  run print_summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"NaiveProxy (direct connection, no CDN):"* ]]
  [[ "$output" == *"domain: naive.example.com"* ]]
  [[ "$output" == *"username: user_abcd1234"* ]]
  [[ "$output" == *"password: supersecretpassword"* ]]
  [[ "$output" == *"21000/tcp"* ]]
}

# ---------------------------------------------------------------------------
# naive_map_arch / install_naiveproxy
# ---------------------------------------------------------------------------

@test "naive_map_arch maps common uname -m values to naiveproxy release arches" {
  [ "$(naive_map_arch x86_64)" == "x64" ]
  [ "$(naive_map_arch amd64)" == "x64" ]
  [ "$(naive_map_arch aarch64)" == "arm64" ]
  [ "$(naive_map_arch arm64)" == "arm64" ]
  [ "$(naive_map_arch armv7l)" == "arm" ]
  [ "$(naive_map_arch i686)" == "x86" ]
}

@test "naive_map_arch dies on an unrecognized architecture" {
  run naive_map_arch "made-up-arch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported architecture for NaiveProxy"* ]]
}

naive_env() {
  NAIVE_SUBDOMAIN="naive"
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy"
  NAIVE_VERSION_FILE="${BATS_TEST_TMPDIR}/naiveproxy/.installed-version"
}

@test "install_naiveproxy skips entirely when NAIVE_SUBDOMAIN is unset" {
  NAIVE_SUBDOMAIN=""
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy"
  NAIVE_VERSION_FILE="${BATS_TEST_TMPDIR}/naiveproxy/.installed-version"

  run install_naiveproxy
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAIVE_SUBDOMAIN not set, skipping"* ]]
  [ ! -e "$NAIVE_BIN" ]
}

@test "install_naiveproxy downloads, extracts and installs the caddy binary" {
  naive_env

  run install_naiveproxy
  [ "$status" -eq 0 ]
  [ -x "$NAIVE_BIN" ]
  [ "$(cat "$NAIVE_VERSION_FILE")" == "v150.0.0.0-1" ]
  [[ "$output" == *"NaiveProxy v150.0.0.0-1 installed"* ]]
}

@test "install_naiveproxy is idempotent when the installed version already matches" {
  naive_env

  install_naiveproxy
  local first_mtime
  first_mtime="$(cat "$NAIVE_BIN")"

  run install_naiveproxy
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed, skipping"* ]]
  [ "$(cat "$NAIVE_BIN")" == "$first_mtime" ]
}

@test "install_naiveproxy re-downloads when the release tag changes" {
  naive_env

  install_naiveproxy
  [ "$(cat "$NAIVE_VERSION_FILE")" == "v150.0.0.0-1" ]

  export NAIVE_RELEASE_JSON='{"tag_name":"v151.0.0.0-1","assets":[{"name":"naiveproxy-v151.0.0.0-1-linux-x64.tar.xz","browser_download_url":"https://example.test/naiveproxy-v151.0.0.0-1-linux-x64.tar.xz"}]}'

  run install_naiveproxy
  [ "$status" -eq 0 ]
  [ "$(cat "$NAIVE_VERSION_FILE")" == "v151.0.0.0-1" ]
}

@test "install_naiveproxy fails clearly when the release metadata fetch fails" {
  naive_env
  export CURL_SHOULD_FAIL=1

  run install_naiveproxy
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to fetch the latest NaiveProxy release metadata"* ]]
}

@test "install_naiveproxy fails clearly when no asset matches this architecture" {
  naive_env
  export NAIVE_RELEASE_JSON='{"tag_name":"v150.0.0.0-1","assets":[{"name":"naiveproxy-v150.0.0.0-1-linux-riscv64.tar.xz","browser_download_url":"https://example.test/naiveproxy-v150.0.0.0-1-linux-riscv64.tar.xz"}]}'

  run install_naiveproxy
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not find NaiveProxy release asset"* ]]
}

@test "install_naiveproxy fails clearly when extraction fails" {
  naive_env
  export TAR_SHOULD_FAIL=1

  run install_naiveproxy
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to extract NaiveProxy release archive"* ]]
  [ ! -e "$NAIVE_BIN" ]
}

# ---------------------------------------------------------------------------
# prepare_naive_docroot / write_caddyfile / write_naive_systemd_unit
# ---------------------------------------------------------------------------

caddy_env() {
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  NAIVE_USERNAME="user_abcd1234"
  NAIVE_PASSWORD="supersecretpassword"
  BASE_DOMAIN="example.com"
  CERT_DIR="/tmp/fake-cert"
  CADDYFILE="${BATS_TEST_TMPDIR}/Caddyfile"
  NAIVE_DOCROOT="${BATS_TEST_TMPDIR}/naive-docroot"
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy-not-installed"
  NAIVE_SYSTEMD_UNIT="${BATS_TEST_TMPDIR}/caddy.service"
  FALLBACK_HTML_PATH=""
}

@test "prepare_naive_docroot reuses FALLBACK_HTML_PATH content when set" {
  caddy_env
  local source_html="${BATS_TEST_TMPDIR}/source.html"
  printf '<h1>Fallback</h1>\n' > "$source_html"
  FALLBACK_HTML_PATH="$source_html"

  run prepare_naive_docroot
  [ "$status" -eq 0 ]
  [ "$(cat "${NAIVE_DOCROOT}/index.html")" = "<h1>Fallback</h1>" ]
}

@test "prepare_naive_docroot writes a generic default page when FALLBACK_HTML_PATH is unset" {
  caddy_env

  run prepare_naive_docroot
  [ "$status" -eq 0 ]
  grep -q "It works!" "${NAIVE_DOCROOT}/index.html"
}

@test "prepare_naive_docroot rejects a missing FALLBACK_HTML_PATH" {
  caddy_env
  FALLBACK_HTML_PATH="${BATS_TEST_TMPDIR}/missing.html"

  run prepare_naive_docroot
  [ "$status" -eq 1 ]
  [[ "$output" == *"FALLBACK_HTML_PATH must point to a readable regular file"* ]]
}

@test "write_caddyfile skips entirely when NAIVE_SUBDOMAIN is unset" {
  caddy_env
  NAIVE_SUBDOMAIN=""

  run write_caddyfile
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAIVE_SUBDOMAIN not set, skipping Caddyfile"* ]]
  [ ! -e "$CADDYFILE" ]
}

@test "write_caddyfile generates the expected site block" {
  caddy_env

  run write_caddyfile
  [ "$status" -eq 0 ]

  grep -q "order forward_proxy before file_server" "$CADDYFILE"
  grep -q ":21000, naive.example.com:21000 {" "$CADDYFILE"
  grep -q "bind 127.0.0.1" "$CADDYFILE"
  grep -q "tls /tmp/fake-cert/fullchain.pem /tmp/fake-cert/privkey.pem" "$CADDYFILE"
  grep -q "basic_auth user_abcd1234 supersecretpassword" "$CADDYFILE"
  grep -q "hide_ip" "$CADDYFILE"
  grep -q "hide_via" "$CADDYFILE"
  grep -q "probe_resistance" "$CADDYFILE"
  grep -q "root ${NAIVE_DOCROOT}" "$CADDYFILE"
}

@test "write_caddyfile does not reference the public domain in the site address (loopback only)" {
  caddy_env

  run write_caddyfile
  [ "$status" -eq 0 ]
  ! grep -q "naive.example.com" "$CADDYFILE"
}

@test "write_caddyfile validates the generated config when the caddy binary is present" {
  caddy_env
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy"
  cat > "$NAIVE_BIN" <<'EOF'
#!/usr/bin/env bash
echo "validate called: $*" >&2
exit 0
EOF
  chmod +x "$NAIVE_BIN"

  run write_caddyfile
  [ "$status" -eq 0 ]
  [[ "$output" == *"validate called: validate --config"* ]]
}

@test "write_caddyfile fails clearly when caddy validate rejects the config" {
  caddy_env
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy"
  cat > "$NAIVE_BIN" <<'EOF'
#!/usr/bin/env bash
echo "bad config" >&2
exit 1
EOF
  chmod +x "$NAIVE_BIN"

  run write_caddyfile
  [ "$status" -eq 1 ]
  [[ "$output" == *"Generated Caddyfile failed 'caddy validate'"* ]]
}

@test "write_naive_systemd_unit skips entirely when NAIVE_SUBDOMAIN is unset" {
  caddy_env
  NAIVE_SUBDOMAIN=""

  run write_naive_systemd_unit
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping NaiveProxy systemd unit"* ]]
  [ ! -e "$NAIVE_SYSTEMD_UNIT" ]
}

@test "write_naive_systemd_unit generates a unit running as root with no bind capability" {
  caddy_env
  export SYSTEMCTL_LOG="${BATS_TEST_TMPDIR}/systemctl.log"
  : > "$SYSTEMCTL_LOG"

  run write_naive_systemd_unit
  [ "$status" -eq 0 ]

  grep -q "User=root" "$NAIVE_SYSTEMD_UNIT"
  grep -q "ExecStart=${NAIVE_BIN} run --environ --config ${CADDYFILE}" "$NAIVE_SYSTEMD_UNIT"
  ! grep -q "AmbientCapabilities" "$NAIVE_SYSTEMD_UNIT"
  grep -q "systemctl enable caddy" "$SYSTEMCTL_LOG"
  grep -q "systemctl restart caddy" "$SYSTEMCTL_LOG"
}

@test "write_naive_systemd_unit fails clearly when the service fails to start" {
  caddy_env
  export SYSTEMCTL_SHOULD_FAIL=1

  run write_naive_systemd_unit
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to start the caddy (NaiveProxy) service"* ]]
}

@test "install_certbot_hook's deploy hook also reloads caddy when active" {
  CERTBOT_DEPLOY_HOOK="${BATS_TEST_TMPDIR}/nginx-reload.sh"

  run install_certbot_hook
  [ "$status" -eq 0 ]
  grep -q "systemctl is-active --quiet caddy" "$CERTBOT_DEPLOY_HOOK"
  grep -q "systemctl reload caddy" "$CERTBOT_DEPLOY_HOOK"
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
  stub_run_xui_install_and_inbounds '
    XUI_PANEL_PORT="$WS_PORT"
    XUI_WEB_BASE_PATH="generated-base-path"
    XUI_USERNAME="admin_generated"
    XUI_PASSWORD="generated-pass-1234"
    CLIENT_UUID="11111111-2222-3333-4444-555555555555"
    VLESS_ENCRYPTION_SERVER_KEY="mlkem768-server-stub"
    VLESS_ENCRYPTION_CLIENT_KEY="mlkem768-client-stub"
  '

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"collides with WS_PORT"* ]]
}

@test "install_3xui_and_inbounds dies if the install chain doesn't produce the required outputs" {
  CONFIG_FILE="${BATS_TEST_TMPDIR}/xui-proxy.conf"
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  SUB_PORT="2096"
  CLIENT_UUID=""

  stub_run_xui_install_and_inbounds 'return 0'

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not produce PANEL_PORT"* ]]
}

@test "install_3xui_and_inbounds dies if the install chain itself fails" {
  PANEL_PORT="51234"
  WS_PORT="51235"
  WS_PATH="/api/v1/events"
  GRPC_PORT="51236"
  GRPC_SERVICE="api.v1.SyncService"
  CLIENT_UUID=""

  stub_run_xui_install_and_inbounds 'echo "boom" >&2; return 1'

  run install_3xui_and_inbounds
  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
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

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  [ ! -e "$NGINX_SITE" ]
  [ ! -e "$NGINX_SITE_ENABLED" ]
  [ ! -e "$CF_REAL_IP_CONF" ]
  [ ! -e "$CERTBOT_DEPLOY_HOOK" ]
  [ ! -e "$CF_CREDENTIALS" ]
  [ ! -e "$STATE_FILE" ]
  [ ! -e "$CONFIG_FILE" ]

  # 3x-ui removal is now inlined (no separate subprocess) -- with neither
  # /etc/x-ui nor /usr/local/x-ui present in this fixture, it correctly
  # reports there's nothing to uninstall rather than erroring.
  [[ "$output" == *"3x-ui is not installed, nothing to uninstall"* ]]
}

@test "uninstall_all removes the ufw rules it previously added" {
  setup_uninstall_fixtures

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

@test "uninstall_all stops caddy and removes NaiveProxy files" {
  setup_uninstall_fixtures

  NAIVE_SYSTEMD_UNIT="${BATS_TEST_TMPDIR}/caddy.service"
  CADDYFILE="${BATS_TEST_TMPDIR}/Caddyfile"
  NAIVE_BIN="${BATS_TEST_TMPDIR}/caddy-bin"
  NAIVE_VERSION_FILE="${BATS_TEST_TMPDIR}/naiveproxy-state/.installed-version"
  NAIVE_DOCROOT="${BATS_TEST_TMPDIR}/naive-docroot"
  : > "$NAIVE_SYSTEMD_UNIT"
  : > "$CADDYFILE"
  : > "$NAIVE_BIN"
  install -d "$(dirname -- "$NAIVE_VERSION_FILE")"
  : > "$NAIVE_VERSION_FILE"
  install -d "$NAIVE_DOCROOT"

  export SYSTEMCTL_LOG="${BATS_TEST_TMPDIR}/systemctl.log"
  : > "$SYSTEMCTL_LOG"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  grep -q "systemctl stop caddy" "$SYSTEMCTL_LOG"
  grep -q "systemctl disable caddy" "$SYSTEMCTL_LOG"
  [ ! -e "$NAIVE_SYSTEMD_UNIT" ]
  [ ! -e "$CADDYFILE" ]
  [ ! -e "$NAIVE_BIN" ]
  [ ! -e "$NAIVE_VERSION_FILE" ]
  [ ! -d "$NAIVE_DOCROOT" ]
}

@test "uninstall_all keeps the certbot cert by default" {
  setup_uninstall_fixtures

  export CERTBOT_LOG="${BATS_TEST_TMPDIR}/certbot.log"
  : > "$CERTBOT_LOG"

  run uninstall_all <<< "y"
  [ "$status" -eq 0 ]

  ! grep -q "delete --cert-name example.com" "$CERTBOT_LOG"
}

@test "uninstall_all deletes the certbot cert when DELETE_CERT=true" {
  setup_uninstall_fixtures

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

  run uninstall_all <<< "n"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled."* ]]
  [ -e "$NGINX_SITE" ]
  [ ! -f "${BATS_TEST_TMPDIR}/installer-called" ]
}

# ---------------------------------------------------------------------------
# install_3xui_and_inbounds — CLIENT_SUB_ID generation/reuse
# ---------------------------------------------------------------------------

@test "install_3xui_and_inbounds captures a generated CLIENT_SUB_ID when unset" {
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

  stub_run_xui_install_and_inbounds

  install_3xui_and_inbounds
  [ "$CLIENT_SUB_ID" == "abcdef1234567890" ]
}

@test "install_3xui_and_inbounds reuses an existing CLIENT_SUB_ID instead of regenerating it" {
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

  stub_run_xui_install_and_inbounds

  # Not using `run`: its subshell would hide the CLIENT_SUB_ID mutation
  # (or lack thereof) from this test's shell afterwards.
  install_3xui_and_inbounds
  [ "$CLIENT_SUB_ID" == "my_existing_sub_id" ]
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
# write_nginx_config / write_nginx_stream_config / ensure_nginx_stream_context
# -- the stream{} SNI Guard, active only when Reality or NaiveProxy is on.
# ---------------------------------------------------------------------------

nginx_stream_env() {
  nginx_config_env
  REALITY_SUBDOMAIN="reality"
  REALITY_DEST="github.com"
  REALITY_PORT="20000"
  NAIVE_SUBDOMAIN="naive"
  NAIVE_PORT="21000"
  NGINX_CDN_PORT="22000"
  NGINX_DECOY_PORT="22001"
  NAIVE_DOCROOT="${BATS_TEST_TMPDIR}/naive-docroot"
  FALLBACK_HTML_PATH=""
  NGINX_STREAM_CONF="${BATS_TEST_TMPDIR}/stream-sni-guard.conf"
  NGINX_STREAM_CONF_DIR="${BATS_TEST_TMPDIR}/stream.d"
  NGINX_MAIN_CONF="${BATS_TEST_TMPDIR}/nginx.conf"
  printf 'http {\n    include /etc/nginx/conf.d/*.conf;\n}\n' > "$NGINX_MAIN_CONF"
}

# Some individual tests calling write_nginx_config through bats' `run` in
# stream mode have been observed to silently drop their result under this
# bats version (same class of issue as the save_config round-trip tests
# above). This helper routes the call through a real bash -c subshell
# instead, which reliably avoids it.
run_stream_write_nginx_config() {
  run bash -c '
    source "'"$SCRIPT"'" >/dev/null 2>&1 || true
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
    NGINX_SITE="'"$NGINX_SITE"'"
    NGINX_SITE_ENABLED="'"$NGINX_SITE_ENABLED"'"
    NGINX_DEFAULT_SITE="'"$NGINX_DEFAULT_SITE"'"
    NGINX_DEFAULT_SITE_BACKUP="'"$NGINX_DEFAULT_SITE_BACKUP"'"
    TIMESTAMP="20260101-000000"
    REALITY_SUBDOMAIN="reality"
    REALITY_DEST="github.com"
    REALITY_PORT="20000"
    NAIVE_SUBDOMAIN="naive"
    NAIVE_PORT="21000"
    NGINX_CDN_PORT="22000"
    NGINX_DECOY_PORT="22001"
    NAIVE_DOCROOT="'"$NAIVE_DOCROOT"'"
    FALLBACK_HTML_PATH=""
    NGINX_STREAM_CONF="'"$NGINX_STREAM_CONF"'"
    NGINX_STREAM_CONF_DIR="'"$NGINX_STREAM_CONF_DIR"'"
    NGINX_MAIN_CONF="'"$NGINX_MAIN_CONF"'"
    printf "http {\n    include /etc/nginx/conf.d/*.conf;\n}\n" > "$NGINX_MAIN_CONF"
    write_nginx_config
  '
}

@test "write_nginx_config moves the CDN server blocks to loopback when stream mode is active" {
  nginx_stream_env
  run_stream_write_nginx_config

  [ "$status" -eq 0 ]
  grep -q "listen 127.0.0.1:22000 ssl;" "$NGINX_SITE"
  ! grep -q "listen 443 ssl;" "$NGINX_SITE"
}

@test "write_nginx_config keeps CDN server blocks on public 443 when neither Reality nor NaiveProxy is enabled" {
  nginx_config_env
  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN=""
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "listen 443 ssl;" "$NGINX_SITE"
  ! grep -q "127.0.0.1:22000" "$NGINX_SITE"
}

@test "write_nginx_config adds a decoy vhost on the decoy port serving the shared docroot" {
  nginx_stream_env
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "listen 127.0.0.1:22001 ssl;" "$NGINX_SITE"
  grep -q "server_name _;" "$NGINX_SITE"
  grep -q "root ${NAIVE_DOCROOT};" "$NGINX_SITE"
  [ -f "${NAIVE_DOCROOT}/index.html" ]
}

@test "write_nginx_config generates a stream SNI map routing CDN, naive and reality domains, defaulting to decoy" {
  nginx_stream_env
  run_stream_write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "map \\$ssl_preread_server_name \$sni_upstream" "$NGINX_STREAM_CONF"
  grep -q "admin.example.com    cdn;" "$NGINX_STREAM_CONF"
  grep -q "vpn.example.com    cdn;" "$NGINX_STREAM_CONF"
  grep -q "naive.example.com    naive;" "$NGINX_STREAM_CONF"
  grep -q "github.com    reality;" "$NGINX_STREAM_CONF"
  grep -q "default    decoy;" "$NGINX_STREAM_CONF"
  grep -q "upstream cdn { server 127.0.0.1:22000; }" "$NGINX_STREAM_CONF"
  grep -q "upstream decoy { server 127.0.0.1:22001; }" "$NGINX_STREAM_CONF"
  grep -q "upstream naive { server 127.0.0.1:21000; }" "$NGINX_STREAM_CONF"
  grep -q "upstream reality { server 127.0.0.1:20000; }" "$NGINX_STREAM_CONF"
  grep -q "listen 443 reuseport;" "$NGINX_STREAM_CONF"
  grep -q "ssl_preread on;" "$NGINX_STREAM_CONF"
}

@test "write_nginx_config's stream map omits naive/reality branches when only one is enabled" {
  nginx_stream_env
  NAIVE_SUBDOMAIN=""
  NAIVE_PORT=""
  run write_nginx_config
  [ "$status" -eq 0 ]

  grep -q "github.com    reality;" "$NGINX_STREAM_CONF"
  ! grep -q "naive;" "$NGINX_STREAM_CONF"
  ! grep -q "upstream naive" "$NGINX_STREAM_CONF"
}

@test "write_nginx_config removes a stale stream config when the feature is later disabled" {
  nginx_stream_env
  run write_nginx_config
  [ "$status" -eq 0 ]
  [ -f "$NGINX_STREAM_CONF" ]

  REALITY_SUBDOMAIN=""
  NAIVE_SUBDOMAIN=""
  run write_nginx_config
  [ "$status" -eq 0 ]
  [ ! -f "$NGINX_STREAM_CONF" ]
}

@test "write_nginx_config rolls back the stream config too when nginx -t fails" {
  nginx_stream_env
  run write_nginx_config
  [ "$status" -eq 0 ]
  local original_stream
  original_stream="$(cat "$NGINX_STREAM_CONF")"

  export NGINX_T_SHOULD_FAIL=1
  run write_nginx_config
  [ "$status" -eq 1 ]
  [ "$(cat "$NGINX_STREAM_CONF")" == "$original_stream" ]
}

@test "ensure_nginx_stream_context adds a marker-delimited stream block to nginx.conf" {
  nginx_stream_env

  run ensure_nginx_stream_context
  [ "$status" -eq 0 ]

  grep -q "# BEGIN 3xui-cf-setup stream" "$NGINX_MAIN_CONF"
  grep -q "include ${NGINX_STREAM_CONF_DIR}/\*.conf;" "$NGINX_MAIN_CONF"
  grep -q "# END 3xui-cf-setup stream" "$NGINX_MAIN_CONF"
}

@test "ensure_nginx_stream_context is idempotent" {
  nginx_stream_env

  run ensure_nginx_stream_context
  [ "$status" -eq 0 ]
  local first_content
  first_content="$(cat "$NGINX_MAIN_CONF")"

  run ensure_nginx_stream_context
  [ "$status" -eq 0 ]
  [ "$(cat "$NGINX_MAIN_CONF")" == "$first_content" ]
}

@test "unensure_nginx_stream_context cleanly removes the marker-delimited block" {
  nginx_stream_env

  run ensure_nginx_stream_context
  [ "$status" -eq 0 ]
  grep -q "BEGIN 3xui-cf-setup stream" "$NGINX_MAIN_CONF"

  run unensure_nginx_stream_context
  [ "$status" -eq 0 ]
  ! grep -q "3xui-cf-setup stream" "$NGINX_MAIN_CONF"
  ! grep -q "stream {" "$NGINX_MAIN_CONF"
  grep -q "http {" "$NGINX_MAIN_CONF"
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
