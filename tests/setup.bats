#!/usr/bin/env bats
#
# Unit tests for setup.sh.
#
# Run with:
#   bats tests/setup.bats
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
    CURL_HTTP_CODE NGINX_T_SHOULD_FAIL UFW_LOG
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

# ---------------------------------------------------------------------------
# validate_inputs
# ---------------------------------------------------------------------------

valid_inputs() {
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  EMAIL="user@example.com"
  SSH_PORT="22"
  PANEL_PORT="2053"
  WS_PORT="10001"
  GRPC_PORT="10002"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
}

@test "validate_inputs accepts a fully valid configuration" {
  valid_inputs
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

@test "validate_inputs rejects SSH port 443" {
  valid_inputs
  SSH_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSH port cannot be 443"* ]]
}

@test "validate_inputs rejects equal panel and websocket ports" {
  valid_inputs
  WS_PORT="$PANEL_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Panel and WebSocket ports must be different"* ]]
}

@test "validate_inputs rejects equal panel and grpc ports" {
  valid_inputs
  GRPC_PORT="$PANEL_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Panel and gRPC ports must be different"* ]]
}

@test "validate_inputs rejects equal websocket and grpc ports" {
  valid_inputs
  GRPC_PORT="$WS_PORT"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"WebSocket and gRPC ports must be different"* ]]
}

@test "validate_inputs rejects internal port equal to 443" {
  valid_inputs
  PANEL_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be 443"* ]]
}

@test "validate_inputs rejects websocket port equal to 443" {
  valid_inputs
  WS_PORT="443"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be 443"* ]]
}

@test "validate_inputs rejects internal port equal to SSH port" {
  valid_inputs
  SSH_PORT="2222"
  PANEL_PORT="2222"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"same as the SSH port"* ]]
}

@test "validate_inputs rejects grpc port equal to SSH port" {
  valid_inputs
  SSH_PORT="2222"
  GRPC_PORT="2222"
  run validate_inputs
  [ "$status" -eq 1 ]
  [[ "$output" == *"same as the SSH port"* ]]
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

@test "random_free_port avoids ports reported as listening" {
  export SS_LISTENING_PORTS="50000"
  for i in $(seq 1 5); do
    port="$(random_free_port)"
    [ "$port" != "50000" ]
  done
}

# ---------------------------------------------------------------------------
# write_nginx_config
# ---------------------------------------------------------------------------

nginx_config_env() {
  BASE_DOMAIN="example.com"
  PANEL_SUBDOMAIN="admin"
  VLESS_SUBDOMAIN="vpn"
  PANEL_PATH="/my-admin"
  WS_PATH="/api/v1/events"
  GRPC_SERVICE="api.v1.SyncService"
  PANEL_PORT="2053"
  WS_PORT="10001"
  GRPC_PORT="10002"
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
  grep -q "proxy_pass http://127.0.0.1:2053;" "$NGINX_SITE"
  grep -q "location = /api/v1/events" "$NGINX_SITE"
  grep -q "location /api.v1.SyncService" "$NGINX_SITE"
  grep -q "server_name admin.example.com;" "$NGINX_SITE"
  grep -q "server_name vpn.example.com;" "$NGINX_SITE"
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
