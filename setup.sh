#!/usr/bin/env bash
set -euo pipefail

# Required public flow selector. Accepts true/false-compatible values; true
# selects CDN inbounds, false selects direct inbounds. INSTALL_MODE is internal.
CDN_MODE="${CDN_MODE:-}"
INSTALL_MODE=""

BASE_DOMAIN=""
PANEL_SUBDOMAIN="admin"
VLESS_SUBDOMAIN="vpn"
PANEL_PATH=""
EMAIL=""
PANEL_PORT=""
SUB_PORT=""
WS_PORT=""
GRPC_PORT=""
XHTTP_PORT=""

WS_PATH=""
GRPC_SERVICE=""
XHTTP_PATH=""
SUB_PATH=""

# Optional source file for the default public fallback page on the VLESS hostname.
# When unset, non-proxy requests deliberately retain the 404 response.
FALLBACK_HTML_PATH="${FALLBACK_HTML_PATH:-}"

CERT_DIR=""
CF_CREDENTIALS="/etc/letsencrypt/cloudflare.ini"

CLIENT_UUID=""
CLIENT_SUB_ID=""
# VLESS Encryption (ML-KEM-768) keypair, applied only to the WS/gRPC/XHTTP
# CDN inbounds (Reality has no CDN/MITM layer in between to protect against).
VLESS_ENCRYPTION_SERVER_KEY=""
VLESS_ENCRYPTION_CLIENT_KEY=""

# Optional VLESS+Reality direct-connection inbound (no CDN). Blank
# REALITY_SUBDOMAIN disables the feature entirely. REALITY_DEST is the real,
# unrelated donor site Reality impersonates for anyone without valid
# credentials -- never a domain of BASE_DOMAIN itself.
REALITY_SUBDOMAIN=""
REALITY_DEST=""
REALITY_PORT=""
REALITY_SHORT_ID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""

# Optional NaiveProxy deployment (Caddy + forwardproxy, direct connection,
# no CDN). Blank NAIVE_SUBDOMAIN disables the feature entirely. Reuses the
# existing wildcard cert -- Caddy does not manage its own ACME certificate.
NAIVE_SUBDOMAIN=""
NAIVE_PORT=""
NAIVE_USERNAME=""
NAIVE_PASSWORD=""

# Hysteria2 is a direct UDP/QUIC inbound for no-cdn installations. It binds a
# public UDP port (443 by default), so Nginx cannot and must not proxy it.
HYSTERIA_SUBDOMAIN=""
HYSTERIA_PORT=""
HYSTERIA_AUTH=""
HYSTERIA_OBFS_PASSWORD=""

# Optional mieru deployment (mita server, direct connection, no CDN). Blank
# MIERU_SUBDOMAIN disables the feature entirely. Unlike Reality/NaiveProxy,
# mieru does not use TLS/SNI at all -- it authenticates via username/password
# and encrypts with its own AEAD scheme, so it needs no certificate and is
# reached on its own dedicated public port (not shared via the SNI Guard).
MIERU_SUBDOMAIN=""
MIERU_PORT=""
MIERU_PROTOCOL=""
MIERU_USERNAME=""
MIERU_PASSWORD=""

# Internal loopback ports used only when the Nginx stream{} SNI Guard is
# active (i.e. Reality or NaiveProxy is enabled): the CDN server blocks move
# off public 443 onto NGINX_CDN_PORT, and unmatched-SNI probes are routed to
# a decoy vhost on NGINX_DECOY_PORT. Both blank when neither feature is on --
# in that case Nginx keeps binding 443 directly, exactly as before.
NGINX_CDN_PORT=""
NGINX_DECOY_PORT=""

VPS_FLAG=""
# Optional ISO 3166-1 alpha-2 country code for inbound labels. When unset,
# the code is detected from the server's public IP.
VPS_COUNTRY_CODE="${VPS_COUNTRY_CODE:-}"
XUI_USERNAME=""
XUI_PASSWORD=""

# 3x-ui release tag to install (e.g. v3.4.0, or dev-latest). Unset/empty
# installs the latest stable release (installer default).
XUI_VERSION="${XUI_VERSION:-}"
INSTALL_RESULT_FILE="/etc/x-ui/install-result.env"
XUI_SERVICE_UNIT="/etc/systemd/system/x-ui.service"
BASE_URL=""
AUTH_HEADER=""
COOKIE_JAR=""

NGINX_SITE="/etc/nginx/sites-available/3xui-proxy"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/3xui-proxy"
# Preserves the distribution's default site while this script owns port 443.
NGINX_DEFAULT_SITE="/etc/nginx/sites-enabled/default"
NGINX_DEFAULT_SITE_BACKUP="/etc/nginx/.3xui-proxy-default-site.backup"
FALLBACK_HTML_DEST="/etc/nginx/3xui-proxy-fallback.html"

CF_REAL_IP_CONF="/etc/nginx/conf.d/cloudflare-real-ip.conf"
CF_IP_STATE_FILE="/etc/nginx/.3xui-proxy-cloudflare-ips.state"
CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh"

STATE_FILE="/etc/nginx/.3xui-proxy-ports.state"
CONFIG_FILE="/etc/nginx/.3xui-proxy.conf"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

TMP_FILES=()
CF_IP_RANGES=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup_tmp_files() {
  local f
  # NOTE: bare `[[ ... ]] && cmd` here would abort the whole script under
  # `set -e` whenever the condition is false (e.g. TMP_FILES is empty) --
  # an AND-list's exit status is that of its last evaluated command, and
  # this runs as an EXIT trap, so that false exit status becomes the
  # process's exit code. Use an explicit if instead.
  for f in "${TMP_FILES[@]:-}"; do
    if [[ -n "$f" && -e "$f" ]]; then
      rm -f "$f"
    fi
  done
}

trap cleanup_tmp_files EXIT

make_tmp_file() {
  local f
  f="$(mktemp)"
  TMP_FILES+=("$f")
  printf '%s\n' "$f"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

load_config() {
  local requested_cdn_mode="$CDN_MODE"

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading saved configuration from ${CONFIG_FILE}..."
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    # Backward compatibility for config written by the short-lived
    # INSTALL_MODE implementation.
    if [[ -z "$CDN_MODE" && -n "$INSTALL_MODE" ]]; then
      [[ "$INSTALL_MODE" == "cdn" ]] && CDN_MODE=true || CDN_MODE=false
    fi
  fi

  # An explicitly supplied environment value wins over persisted state.
  [[ -z "$requested_cdn_mode" ]] || CDN_MODE="$requested_cdn_mode"
}

save_config() {
  install -d -m 755 "$(dirname -- "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<EOF
# Generated by setup.sh on ${TIMESTAMP}
CDN_MODE="${CDN_MODE}"
BASE_DOMAIN="${BASE_DOMAIN}"
PANEL_SUBDOMAIN="${PANEL_SUBDOMAIN}"
VLESS_SUBDOMAIN="${VLESS_SUBDOMAIN}"
PANEL_PATH="${PANEL_PATH}"
EMAIL="${EMAIL}"
PANEL_PORT="${PANEL_PORT}"
SUB_PORT="${SUB_PORT}"
WS_PORT="${WS_PORT}"
GRPC_PORT="${GRPC_PORT}"
XHTTP_PORT="${XHTTP_PORT}"
WS_PATH="${WS_PATH}"
GRPC_SERVICE="${GRPC_SERVICE}"
XHTTP_PATH="${XHTTP_PATH}"
SUB_PATH="${SUB_PATH}"
CLIENT_UUID="${CLIENT_UUID}"
CLIENT_SUB_ID="${CLIENT_SUB_ID}"
VLESS_ENCRYPTION_SERVER_KEY="${VLESS_ENCRYPTION_SERVER_KEY}"
VLESS_ENCRYPTION_CLIENT_KEY="${VLESS_ENCRYPTION_CLIENT_KEY}"
REALITY_SUBDOMAIN="${REALITY_SUBDOMAIN}"
REALITY_DEST="${REALITY_DEST}"
REALITY_PORT="${REALITY_PORT}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
NAIVE_SUBDOMAIN="${NAIVE_SUBDOMAIN}"
NAIVE_PORT="${NAIVE_PORT}"
NAIVE_USERNAME="${NAIVE_USERNAME}"
NAIVE_PASSWORD="${NAIVE_PASSWORD}"
HYSTERIA_SUBDOMAIN="${HYSTERIA_SUBDOMAIN}"
HYSTERIA_PORT="${HYSTERIA_PORT}"
HYSTERIA_AUTH="${HYSTERIA_AUTH}"
HYSTERIA_OBFS_PASSWORD="${HYSTERIA_OBFS_PASSWORD}"
MIERU_SUBDOMAIN="${MIERU_SUBDOMAIN}"
MIERU_PORT="${MIERU_PORT}"
MIERU_PROTOCOL="${MIERU_PROTOCOL}"
MIERU_USERNAME="${MIERU_USERNAME}"
MIERU_PASSWORD="${MIERU_PASSWORD}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
NGINX_CDN_PORT="${NGINX_CDN_PORT}"
NGINX_DECOY_PORT="${NGINX_DECOY_PORT}"
VPS_COUNTRY_CODE="${VPS_COUNTRY_CODE}"
EOF
  chmod 600 "$CONFIG_FILE"
}

prompt() {
  local variable_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    while true; do
      read -r -p "${prompt_text}: " value

      if [[ -n "$value" ]]; then
        break
      fi

      echo "Value is required."
    done
  fi

  printf -v "$variable_name" '%s' "$value"
}

# Like prompt(), but an empty answer is valid and simply leaves the variable
# blank -- used for genuinely optional features (Reality, NaiveProxy) where
# a blank value means "skip this feature", not "ask again".
prompt_optional() {
  local variable_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local value=""

  if [[ -n "$default_value" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    read -r -p "${prompt_text} [leave blank to skip]: " value
  fi

  printf -v "$variable_name" '%s' "$value"
}

# Converts the public CDN_MODE value to the internal branch selector. Keep the
# latter separate: CDN_MODE retains the user's true/false-compatible input.
normalize_cdn_mode() {
  local value=""
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    true|1|yes|y|on) printf 'cdn' ;;
    false|0|no|n|off) printf 'no-cdn' ;;
    *) return 1 ;;
  esac
}

prompt_install_mode() {
  local value="${CDN_MODE}" normalized=""

  while true; do
    if normalized="$(normalize_cdn_mode "$value")"; then
      CDN_MODE="$value"
      INSTALL_MODE="$normalized"
      return
    fi

    if [[ -n "$value" ]]; then
      echo "Enter a true/false-compatible value (true/false, yes/no, 1/0, on/off)." >&2
    fi
    read -r -p "Use CDN inbounds? [true/false]: " value
  done
}

prompt_secret() {
  local variable_name="$1"
  local prompt_text="$2"
  local value=""

  while true; do
    read -r -s -p "${prompt_text}: " value
    echo

    if [[ -n "$value" ]]; then
      break
    fi

    echo "Value is required."
  done

  printf -v "$variable_name" '%s' "$value"
}

validate_port() {
  local port_name="$1"
  local port="$2"

  [[ "$port" =~ ^[0-9]+$ ]] ||
    die "${port_name} must be a number."

  ((port >= 1 && port <= 65535)) ||
    die "${port_name} must be between 1 and 65535."
}

port_is_listening() {
  local port="$1"

  ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

port_is_udp_listening() {
  local port="$1"

  ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
}

random_free_port() {
  # Accepts any number of ports to exclude (in addition to "already listening").
  # Deliberately iterates "$@" directly rather than building a local array:
  # under `set -u`, expanding an EMPTY array (i.e. called with zero args) as
  # "${arr[@]}" throws "unbound variable" on bash < 4.4 (e.g. macOS's
  # bundled /bin/bash), which random_free_port (no args) relies on.
  local port=""
  local excluded
  local collision

  while true; do
    port="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    port=$((49152 + port % 16384))

    collision=false
    for excluded in "$@"; do
      [[ -n "$excluded" && "$port" == "$excluded" ]] && { collision=true; break; }
    done
    [[ "$collision" == false ]] || continue

    if ! port_is_listening "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
}

normalize_panel_path() {
  PANEL_PATH="/${PANEL_PATH#/}"

  while [[ "$PANEL_PATH" != "/" && "$PANEL_PATH" == */ ]]; do
    PANEL_PATH="${PANEL_PATH%/}"
  done

  [[ "$PANEL_PATH" != "/" ]] ||
    die "Panel path cannot be /."

  [[ "$PANEL_PATH" =~ ^/[A-Za-z0-9/_-]*$ ]] ||
    die "Panel path may only contain letters, numbers, '/', '_' and '-'."
}

normalize_ws_path() {
  WS_PATH="/${WS_PATH#/}"

  while [[ "$WS_PATH" != "/" && "$WS_PATH" == */ ]]; do
    WS_PATH="${WS_PATH%/}"
  done

  [[ "$WS_PATH" != "/" ]] ||
    die "WebSocket path cannot be /."

  [[ "$WS_PATH" =~ ^/[A-Za-z0-9/_-]*$ ]] ||
    die "WebSocket path may only contain letters, numbers, '/', '_' and '-'."
}

normalize_xhttp_path() {
  XHTTP_PATH="/${XHTTP_PATH#/}"

  while [[ "$XHTTP_PATH" != "/" && "$XHTTP_PATH" == */ ]]; do
    XHTTP_PATH="${XHTTP_PATH%/}"
  done

  [[ "$XHTTP_PATH" != "/" ]] ||
    die "XHTTP path cannot be /."

  [[ "$XHTTP_PATH" =~ ^/[A-Za-z0-9/_-]*$ ]] ||
    die "XHTTP path may only contain letters, numbers, '/', '_' and '-'."
}

normalize_sub_path() {
  SUB_PATH="/${SUB_PATH#/}"

  while [[ "$SUB_PATH" != "/" && "$SUB_PATH" == */ ]]; do
    SUB_PATH="${SUB_PATH%/}"
  done

  [[ "$SUB_PATH" != "/" ]] ||
    die "Subscription path cannot be /."

  [[ "$SUB_PATH" =~ ^/[A-Za-z0-9/_-]*$ ]] ||
    die "Subscription path may only contain letters, numbers, '/', '_' and '-'."
}

validate_inputs() {
  [[ "$INSTALL_MODE" == "cdn" || "$INSTALL_MODE" == "no-cdn" ]] ||
    die "CDN_MODE must be a true/false-compatible value."

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    [[ -z "$REALITY_SUBDOMAIN" && -z "$NAIVE_SUBDOMAIN" && -z "$MIERU_SUBDOMAIN" ]] ||
      die "CDN_MODE=true cannot enable direct inbounds (Reality, NaiveProxy, Hysteria2, or mieru)."
  else
    [[ -n "$REALITY_SUBDOMAIN" || -n "$NAIVE_SUBDOMAIN" || -n "$HYSTERIA_SUBDOMAIN" || -n "$MIERU_SUBDOMAIN" ]] ||
      die "CDN_MODE=false requires at least one direct inbound (Reality, NaiveProxy, Hysteria2, or mieru)."
  fi

  [[ "$BASE_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] ||
    die "Invalid base domain."

  [[ "$PANEL_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "Invalid panel subdomain."

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    [[ "$VLESS_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
      die "Invalid VLESS subdomain."

    [[ "$PANEL_SUBDOMAIN" != "$VLESS_SUBDOMAIN" ]] ||
      die "Panel and VLESS subdomains must be different."
  fi

  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    die "Invalid email address."

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    [[ "$GRPC_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "Invalid gRPC service name."
  fi

  validate_port "Subscription port" "$SUB_PORT"

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    validate_port "WebSocket port" "$WS_PORT"
    validate_port "gRPC port" "$GRPC_PORT"
    validate_port "XHTTP port" "$XHTTP_PORT"

    [[ "$SUB_PORT" != "$WS_PORT" ]] ||
    die "Subscription and WebSocket ports must be different."

  [[ "$SUB_PORT" != "$GRPC_PORT" ]] ||
    die "Subscription and gRPC ports must be different."

  [[ "$WS_PORT" != "$GRPC_PORT" ]] ||
    die "WebSocket and gRPC ports must be different."

  local other_port
  for other_port in "$SUB_PORT" "$WS_PORT" "$GRPC_PORT"; do
    [[ "$XHTTP_PORT" != "$other_port" ]] ||
      die "XHTTP port must be different from every other internal port."
  done

  local internal_port
  local internal_port_name
  for internal_port_name_port in \
    "Subscription port:$SUB_PORT" \
    "WebSocket port:$WS_PORT" \
    "gRPC port:$GRPC_PORT" \
    "XHTTP port:$XHTTP_PORT"
  do
    internal_port_name="${internal_port_name_port%%:*}"
    internal_port="${internal_port_name_port#*:}"

    [[ "$internal_port" != "443" ]] ||
      die "${internal_port_name} cannot be 443 (reserved for the public HTTPS listener)."
  done
  fi

  # Reality is entirely optional -- a blank REALITY_SUBDOMAIN disables it,
  # skipping all of the checks below.
  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    [[ "$REALITY_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
      die "Invalid Reality subdomain."

    [[ "$REALITY_SUBDOMAIN" != "$PANEL_SUBDOMAIN" ]] ||
      die "Reality subdomain must be different from the panel subdomain."

    [[ "$REALITY_SUBDOMAIN" != "$VLESS_SUBDOMAIN" ]] ||
      die "Reality subdomain must be different from the VLESS subdomain."

    [[ -n "$REALITY_DEST" ]] ||
      die "REALITY_DEST (donor site to impersonate, e.g. github.com) is required when a Reality subdomain is set."

    [[ "$REALITY_DEST" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] ||
      die "Invalid Reality donor site '${REALITY_DEST}' (expected a plain hostname, e.g. github.com)."

    [[ "$REALITY_DEST" != "$BASE_DOMAIN" && "$REALITY_DEST" != *".${BASE_DOMAIN}" ]] ||
      die "Reality donor site must not be ${BASE_DOMAIN} or a subdomain of it -- it must be a real, unrelated third-party site."

    validate_port "Reality port" "$REALITY_PORT"

    local reality_other_port
    for reality_other_port in "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT"; do
      [[ "$REALITY_PORT" != "$reality_other_port" ]] ||
        die "Reality port must be different from every other internal port."
    done

    [[ "$REALITY_PORT" != "443" ]] ||
      die "Reality port cannot be 443 (reserved for the public HTTPS listener)."
  elif [[ -n "$REALITY_DEST" ]]; then
    die "REALITY_DEST is set but REALITY_SUBDOMAIN is blank -- set both to enable Reality, or clear both to disable it."
  fi

  # Hysteria2 is optional -- a blank HYSTERIA_SUBDOMAIN disables it.
  if [[ -n "$HYSTERIA_SUBDOMAIN" ]]; then
    [[ "$HYSTERIA_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
      die "Invalid Hysteria2 subdomain."
    [[ "$HYSTERIA_SUBDOMAIN" != "$PANEL_SUBDOMAIN" ]] ||
      die "Hysteria2 subdomain must be different from the panel subdomain."
    validate_port "Hysteria2 UDP port" "$HYSTERIA_PORT"
  fi

  # mieru is entirely optional -- a blank MIERU_SUBDOMAIN disables it. Unlike
  # Reality/NaiveProxy it has no TLS/SNI layer, so it gets its own dedicated
  # public port rather than sharing 443 via the SNI Guard.
  if [[ -n "$MIERU_SUBDOMAIN" ]]; then
    [[ "$MIERU_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
      die "Invalid mieru subdomain."

    [[ "$MIERU_SUBDOMAIN" != "$PANEL_SUBDOMAIN" ]] ||
      die "mieru subdomain must be different from the panel subdomain."

    [[ "$MIERU_SUBDOMAIN" != "$VLESS_SUBDOMAIN" ]] ||
      die "mieru subdomain must be different from the VLESS subdomain."

    [[ -z "$REALITY_SUBDOMAIN" || "$MIERU_SUBDOMAIN" != "$REALITY_SUBDOMAIN" ]] ||
      die "mieru subdomain must be different from the Reality subdomain."

    [[ -z "$NAIVE_SUBDOMAIN" || "$MIERU_SUBDOMAIN" != "$NAIVE_SUBDOMAIN" ]] ||
      die "mieru subdomain must be different from the NaiveProxy subdomain."

    [[ -z "$HYSTERIA_SUBDOMAIN" || "$MIERU_SUBDOMAIN" != "$HYSTERIA_SUBDOMAIN" ]] ||
      die "mieru subdomain must be different from the Hysteria2 subdomain."

    [[ "$MIERU_PROTOCOL" == "TCP" || "$MIERU_PROTOCOL" == "UDP" ]] ||
      die "MIERU_PROTOCOL must be TCP or UDP."

    validate_port "mieru port" "$MIERU_PORT"

    local mieru_other_port
    for mieru_other_port in "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}" "${NAIVE_PORT:-}" "${HYSTERIA_PORT:-}"; do
      [[ -z "$mieru_other_port" || "$MIERU_PORT" != "$mieru_other_port" ]] ||
        die "mieru port must be different from every other internal port."
    done

    [[ "$MIERU_PORT" != "443" ]] ||
      die "mieru port cannot be 443 (reserved for the public HTTPS listener)."
  fi

  # NaiveProxy is entirely optional -- a blank NAIVE_SUBDOMAIN disables it.
  if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
    [[ "$NAIVE_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
      die "Invalid NaiveProxy subdomain."

    [[ "$NAIVE_SUBDOMAIN" != "$PANEL_SUBDOMAIN" ]] ||
      die "NaiveProxy subdomain must be different from the panel subdomain."

    [[ "$NAIVE_SUBDOMAIN" != "$VLESS_SUBDOMAIN" ]] ||
      die "NaiveProxy subdomain must be different from the VLESS subdomain."

    [[ -z "$REALITY_SUBDOMAIN" || "$NAIVE_SUBDOMAIN" != "$REALITY_SUBDOMAIN" ]] ||
      die "NaiveProxy subdomain must be different from the Reality subdomain."

    validate_port "NaiveProxy port" "$NAIVE_PORT"

    local naive_other_port
    for naive_other_port in "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}"; do
      [[ -z "$naive_other_port" || "$NAIVE_PORT" != "$naive_other_port" ]] ||
        die "NaiveProxy port must be different from every other internal port."
    done

    [[ "$NAIVE_PORT" != "443" ]] ||
      die "NaiveProxy port cannot be 443 (reserved for the public HTTPS listener)."
  fi

  # The stream{} SNI Guard's two internal ports -- required together exactly
  # when Reality or NaiveProxy is enabled, since that's the only time the
  # guard exists at all.
  if [[ -n "$REALITY_SUBDOMAIN" || -n "$NAIVE_SUBDOMAIN" ]]; then
    validate_port "Nginx CDN internal port" "$NGINX_CDN_PORT"
    validate_port "Nginx decoy internal port" "$NGINX_DECOY_PORT"

    [[ "$NGINX_CDN_PORT" != "$NGINX_DECOY_PORT" ]] ||
      die "Nginx CDN and decoy internal ports must be different."

    local guard_other_port
    for guard_other_port in "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}" "${NAIVE_PORT:-}"; do
      [[ -z "$guard_other_port" || "$NGINX_CDN_PORT" != "$guard_other_port" ]] ||
        die "Nginx CDN internal port must be different from every other internal port."
      [[ -z "$guard_other_port" || "$NGINX_DECOY_PORT" != "$guard_other_port" ]] ||
        die "Nginx decoy internal port must be different from every other internal port."
    done

    [[ "$NGINX_CDN_PORT" != "443" && "$NGINX_DECOY_PORT" != "443" ]] ||
      die "Nginx CDN/decoy internal ports cannot be 443 (reserved for the public HTTPS listener)."
  fi

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    normalize_ws_path
    normalize_xhttp_path
  fi
  normalize_sub_path
}

# Called once PANEL_PATH is known (after 3x-ui install). PANEL_PORT itself is
# pre-reserved by collect_input() BEFORE 3x-ui is installed (see there), and
# explicitly handed to the installer -- so it should always come back
# unchanged. This is a defensive re-check only, in case an already-installed
# 3x-ui (found already configured, so our reservation was ignored) reports
# back a conflicting port.
validate_panel_port() {
  validate_port "Panel port" "$PANEL_PORT"

  [[ "$PANEL_PORT" != "443" ]] ||
    die "3x-ui panel port is 443, reserved for the public HTTPS listener. Change it via 'x-ui setting -port <port>' on the server, then re-run this script."

  [[ "$PANEL_PORT" != "$WS_PORT" ]] ||
    die "3x-ui panel port ${PANEL_PORT} collides with WS_PORT. Change it via 'x-ui setting -port <port>' on the server, then re-run this script."

  [[ "$PANEL_PORT" != "$GRPC_PORT" ]] ||
    die "3x-ui panel port ${PANEL_PORT} collides with GRPC_PORT. Change it via 'x-ui setting -port <port>' on the server, then re-run this script."

  [[ "$PANEL_PORT" != "$XHTTP_PORT" ]] ||
    die "3x-ui panel port ${PANEL_PORT} collides with XHTTP_PORT. Change it via 'x-ui setting -port <port>' on the server, then re-run this script."

  [[ "$PANEL_PORT" != "$SUB_PORT" ]] ||
    die "3x-ui panel port ${PANEL_PORT} collides with SUB_PORT. Change it via 'x-ui setting -port <port>' on the server, then re-run this script."

  normalize_panel_path
}

collect_input() {
  local default_ws_port=""
  local default_grpc_port=""
  local default_xhttp_port=""

  echo
  echo "=== VLESS + Nginx Setup ==="
  echo

  prompt_install_mode
  prompt BASE_DOMAIN "Base domain, for example example.com" "$BASE_DOMAIN"
  prompt PANEL_SUBDOMAIN "Panel subdomain" "$PANEL_SUBDOMAIN"
  # Retained as an unused Nginx hostname in no-cdn mode so the panel-facing
  # reverse-proxy template remains valid; no CDN inbound is created for it.
  prompt VLESS_SUBDOMAIN "VLESS subdomain" "$VLESS_SUBDOMAIN"
  prompt EMAIL "Let's Encrypt email" "$EMAIL"

  echo
  echo "All internal ports and paths are generated automatically (random, unique,"
  echo "collision-free). Panel credentials and web base path are generated by the"
  echo "3x-ui installer itself. Nothing else to configure — just confirm below."

  SUB_PORT="${SUB_PORT:-$(random_free_port "443")}"
  validate_port "Subscription port" "$SUB_PORT"

  default_ws_port="${WS_PORT:-$(random_free_port "$SUB_PORT")}"
  default_grpc_port="${GRPC_PORT:-$(random_free_port "$SUB_PORT" "$default_ws_port")}"
  default_xhttp_port="${XHTTP_PORT:-$(random_free_port "$SUB_PORT" "$default_ws_port" "$default_grpc_port")}"

  prompt WS_PORT "WebSocket local port" "$default_ws_port"
  validate_port "WebSocket port" "$WS_PORT"

  if port_is_listening "$WS_PORT"; then
    echo "WARNING: port ${WS_PORT} is already in use by another process on this host." >&2
  fi

  prompt GRPC_PORT "gRPC local port" "$default_grpc_port"
  validate_port "gRPC port" "$GRPC_PORT"

  if port_is_listening "$GRPC_PORT"; then
    echo "WARNING: port ${GRPC_PORT} is already in use by another process on this host." >&2
  fi

  prompt XHTTP_PORT "XHTTP local port" "$default_xhttp_port"
  validate_port "XHTTP port" "$XHTTP_PORT"

  if port_is_listening "$XHTTP_PORT"; then
    echo "WARNING: port ${XHTTP_PORT} is already in use by another process on this host." >&2
  fi

  # Reserve the panel port here too, BEFORE 3x-ui is installed, so it cannot
  # collide with any port already claimed above. Reused as-is on reruns
  # (loaded from CONFIG_FILE by load_config) so it stays stable.
  PANEL_PORT="${PANEL_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT")}"
  validate_port "Panel port" "$PANEL_PORT"

  if port_is_listening "$PANEL_PORT"; then
    echo "WARNING: port ${PANEL_PORT} is already in use by another process on this host." >&2
  fi

  echo
  # Auto-generate WS_PATH, XHTTP_PATH, GRPC_SERVICE, and SUB_PATH if not already set
  # (loaded from CONFIG_FILE on reruns). These are security-sensitive but
  # must look like plausible real API endpoints to avoid standing out.
  if [[ -z "$WS_PATH" ]]; then
    local ws_words=(events stream messages notifications updates sync relay)
    WS_PATH="/api/v$(( RANDOM % 3 + 1 ))/${ws_words[RANDOM % ${#ws_words[@]}]}/$(openssl rand -hex 4)"
  fi
  if [[ -z "$XHTTP_PATH" ]]; then
    local xhttp_words=(telemetry ingest batch gateway upload)
    XHTTP_PATH="/api/v$(( RANDOM % 3 + 1 ))/${xhttp_words[RANDOM % ${#xhttp_words[@]}]}/$(openssl rand -hex 4)"
  fi
  if [[ -z "$GRPC_SERVICE" ]]; then
    local grpc_orgs=(internal backend core cloud platform service)
    local grpc_pkgs=(sync relay push telemetry health streaming)
    local grpc_svcs=(SyncService RelayService PushService EventService DataService StreamService)
    GRPC_SERVICE="com.${grpc_orgs[RANDOM % ${#grpc_orgs[@]}]}.${grpc_pkgs[RANDOM % ${#grpc_pkgs[@]}]}.v$(( RANDOM % 3 + 1 )).${grpc_svcs[RANDOM % ${#grpc_svcs[@]}]}"
  fi
  if [[ -z "$SUB_PATH" ]]; then
    local sub_words=(download resources assets static content files docs)
    SUB_PATH="/${sub_words[RANDOM % ${#sub_words[@]}]}/$(openssl rand -hex 6)"
  fi

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo
    prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API Token"
  fi

  if [[ "$INSTALL_MODE" == "no-cdn" ]]; then
    echo
    echo "Optional: Hysteria2 is a direct UDP/QUIC connection (DNS-only/grey-cloud)."
    prompt_optional HYSTERIA_SUBDOMAIN "Hysteria2 subdomain (e.g. hy2)" "$HYSTERIA_SUBDOMAIN"
    if [[ -n "$HYSTERIA_SUBDOMAIN" ]]; then
      HYSTERIA_PORT="${HYSTERIA_PORT:-443}"
      HYSTERIA_AUTH="${HYSTERIA_AUTH:-$(openssl rand -hex 16)}"
      HYSTERIA_OBFS_PASSWORD="${HYSTERIA_OBFS_PASSWORD:-$(openssl rand -hex 16)}"
    else
      HYSTERIA_PORT=""
      HYSTERIA_AUTH=""
      HYSTERIA_OBFS_PASSWORD=""
    fi

    echo
    echo "Optional: VLESS+Reality is a direct connection (use a DNS-only/grey-cloud"
    echo "record), sharing port 443 with the panel via SNI-based routing."
    echo
    prompt_optional REALITY_SUBDOMAIN "Reality subdomain (DNS-only, e.g. reality)" "$REALITY_SUBDOMAIN"

  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    prompt REALITY_DEST "Real site for Reality to impersonate (e.g. github.com)" "$REALITY_DEST"

    REALITY_PORT="${REALITY_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT")}"
    validate_port "Reality port" "$REALITY_PORT"

    if port_is_listening "$REALITY_PORT"; then
      echo "WARNING: port ${REALITY_PORT} is already in use by another process on this host." >&2
    fi

    [[ -n "$REALITY_SHORT_ID" ]] || REALITY_SHORT_ID="$(openssl rand -hex 8)"
  else
    REALITY_DEST=""
    REALITY_PORT=""
    REALITY_SHORT_ID=""
  fi

  echo
  echo "Optional: NaiveProxy (Caddy forward proxy) is another direct connection"
  echo "(no CDN -- use a DNS-only/grey-cloud record), sharing port 443 alongside"
  echo "the CDN and Reality inbounds above via SNI-based routing. Leave the"
  echo "subdomain blank to skip it."
  echo
  prompt_optional NAIVE_SUBDOMAIN "NaiveProxy subdomain (DNS-only, e.g. naive)" "$NAIVE_SUBDOMAIN"

  if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
    NAIVE_PORT="${NAIVE_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}")}"
    validate_port "NaiveProxy port" "$NAIVE_PORT"

    if port_is_listening "$NAIVE_PORT"; then
      echo "WARNING: port ${NAIVE_PORT} is already in use by another process on this host." >&2
    fi

    [[ -n "$NAIVE_USERNAME" ]] || NAIVE_USERNAME="user_$(openssl rand -hex 4)"
    [[ -n "$NAIVE_PASSWORD" ]] || NAIVE_PASSWORD="$(openssl rand -hex 16)"
  else
    NAIVE_PORT=""
    NAIVE_USERNAME=""
    NAIVE_PASSWORD=""
  fi

  echo
  echo "Optional: mieru is another direct connection (no CDN -- use a DNS-only/"
  echo "grey-cloud record). Unlike Reality/NaiveProxy it uses no TLS/SNI at all --"
  echo "it authenticates with a username/password and gets its own dedicated"
  echo "public port (TCP or UDP), not shared with 443. Leave the subdomain blank"
  echo "to skip it."
  echo
  prompt_optional MIERU_SUBDOMAIN "mieru subdomain (DNS-only, e.g. mieru)" "$MIERU_SUBDOMAIN"

  if [[ -n "$MIERU_SUBDOMAIN" ]]; then
    MIERU_PORT="${MIERU_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}" "${NAIVE_PORT:-}" "${HYSTERIA_PORT:-}")}"
    validate_port "mieru port" "$MIERU_PORT"

    if port_is_listening "$MIERU_PORT" || port_is_udp_listening "$MIERU_PORT"; then
      echo "WARNING: port ${MIERU_PORT} is already in use by another process on this host." >&2
    fi

    MIERU_PROTOCOL="${MIERU_PROTOCOL:-UDP}"
    [[ -n "$MIERU_USERNAME" ]] || MIERU_USERNAME="user_$(openssl rand -hex 4)"
    [[ -n "$MIERU_PASSWORD" ]] || MIERU_PASSWORD="$(openssl rand -hex 16)"
  else
    MIERU_PORT=""
    MIERU_PROTOCOL=""
    MIERU_USERNAME=""
    MIERU_PASSWORD=""
  fi

  # The stream{} SNI Guard (and its two internal ports) is only needed once
  # a direct-connection feature exists to route to.
  if [[ -n "$REALITY_SUBDOMAIN" || -n "$NAIVE_SUBDOMAIN" ]]; then
    NGINX_CDN_PORT="${NGINX_CDN_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}" "${NAIVE_PORT:-}")}"
    validate_port "Nginx CDN internal port" "$NGINX_CDN_PORT"

    NGINX_DECOY_PORT="${NGINX_DECOY_PORT:-$(random_free_port "443" "$SUB_PORT" "$WS_PORT" "$GRPC_PORT" "$XHTTP_PORT" "$PANEL_PORT" "${REALITY_PORT:-}" "${NAIVE_PORT:-}" "$NGINX_CDN_PORT")}"
    validate_port "Nginx decoy internal port" "$NGINX_DECOY_PORT"
  else
    NGINX_CDN_PORT=""
    NGINX_DECOY_PORT=""
  fi
  else
    # A CDN install must never retain direct-inbound state from an earlier run.
    REALITY_SUBDOMAIN=""
    REALITY_DEST=""
    REALITY_PORT=""
    REALITY_SHORT_ID=""
    NAIVE_SUBDOMAIN=""
    NAIVE_PORT=""
    NAIVE_USERNAME=""
    NAIVE_PASSWORD=""
    HYSTERIA_SUBDOMAIN=""
    HYSTERIA_PORT=""
    HYSTERIA_AUTH=""
    HYSTERIA_OBFS_PASSWORD=""
    MIERU_SUBDOMAIN=""
    MIERU_PORT=""
    MIERU_PROTOCOL=""
    MIERU_USERNAME=""
    MIERU_PASSWORD=""
    NGINX_CDN_PORT=""
    NGINX_DECOY_PORT=""
  fi

  validate_inputs
}

confirm_configuration() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local answer=""

  echo
  echo "Configuration"
  echo
  echo "Base domain: ${BASE_DOMAIN}"
  echo "Installation mode: ${INSTALL_MODE}"
  echo
  echo "Panel:"
  echo "  domain: ${panel_domain}"
  echo "  public/client port: 443"
  echo "  internal 3x-ui port: ${PANEL_PORT:-<auto-generated by 3x-ui installer>}"
  echo "  path: ${PANEL_PATH:-<auto-generated by 3x-ui installer>}"
  echo
  echo "VLESS WebSocket:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${WS_PORT}"
  echo "  path: ${WS_PATH}"
  echo
  echo "VLESS XHTTP:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${XHTTP_PORT}"
  echo "  network: xhttp (packet-up)"
  echo "  path: ${XHTTP_PATH}"
  echo
  echo "VLESS gRPC:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${GRPC_PORT}"
  echo "  serviceName: ${GRPC_SERVICE}"
  echo
  echo "Subscription:"
  echo "  URL: https://${panel_domain}${SUB_PATH}/"
  echo "  internal port: ${SUB_PORT}"
  echo
  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    echo "VLESS Reality (direct connection, no CDN):"
    echo "  domain: ${REALITY_SUBDOMAIN}.${BASE_DOMAIN} (DNS-only/grey-cloud -- do NOT enable the Cloudflare proxy for this record)"
    echo "  public/client port: 443"
    echo "  internal Xray port: ${REALITY_PORT}"
    echo "  impersonating: ${REALITY_DEST}"
    echo
  fi

  if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
    echo "NaiveProxy (direct connection, no CDN):"
    echo "  domain: ${NAIVE_SUBDOMAIN}.${BASE_DOMAIN} (DNS-only/grey-cloud -- do NOT enable the Cloudflare proxy for this record)"
    echo "  public/client port: 443"
    echo "  internal Caddy port: ${NAIVE_PORT}"
    echo "  username: ${NAIVE_USERNAME}"
    echo
  fi

  if [[ -n "$MIERU_SUBDOMAIN" ]]; then
    echo "mieru (direct connection, no CDN):"
    echo "  domain: ${MIERU_SUBDOMAIN}.${BASE_DOMAIN} (DNS-only/grey-cloud -- do NOT enable the Cloudflare proxy for this record)"
    echo "  public/client port: ${MIERU_PORT}/${MIERU_PROTOCOL}"
    echo "  username: ${MIERU_USERNAME}"
    echo
  fi

  echo "Firewall:"
  echo "  allowed: 443/tcp from anywhere; SSH is left untouched by this script"
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    echo "  denied: public 80/tcp, ${PANEL_PORT}/tcp, ${SUB_PORT}/tcp, ${WS_PORT}/tcp, ${GRPC_PORT}/tcp, ${XHTTP_PORT}/tcp"
  else
    echo "  denied: public 80/tcp, ${PANEL_PORT}/tcp, ${SUB_PORT}/tcp${REALITY_PORT:+, ${REALITY_PORT}/tcp}${NAIVE_PORT:+, ${NAIVE_PORT}/tcp}"
  fi
  [[ -z "${MIERU_PORT:-}" ]] || echo "  allowed: ${MIERU_PORT}/${MIERU_PROTOCOL} from anywhere (mieru)"
  echo

  read -r -p "Continue? [y/N]: " answer

  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo "Cancelled."
      exit 0
      ;;
  esac
}

NGINX_ORG_KEYRING="/usr/share/keyrings/nginx-archive-keyring.gpg"
NGINX_ORG_LIST="/etc/apt/sources.list.d/nginx.list"
NGINX_ORG_PREF="/etc/apt/preferences.d/99nginx"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# Installs nginx from nginx.org's official apt repo instead of the distro's
# bundled package. Needed because Debian/Ubuntu's own `nginx` package does
# not reliably ship --with-stream and --with-stream_ssl_preread_module,
# which the SNI Guard (stream {} block routing NaiveProxy/Reality/CDN
# traffic by SNI on shared port 443) depends on.
install_nginx_org_repo() {
  local distro_id distro_codename expected_line

  [[ -f "$OS_RELEASE_FILE" ]] ||
    die "install_nginx_org_repo: ${OS_RELEASE_FILE} not found; cannot determine distro."

  # shellcheck disable=SC1090
  distro_id="$(. "$OS_RELEASE_FILE" && echo "${ID:-}")"
  # shellcheck disable=SC1090
  distro_codename="$(. "$OS_RELEASE_FILE" && echo "${VERSION_CODENAME:-}")"

  [[ "$distro_id" == "ubuntu" || "$distro_id" == "debian" ]] ||
    die "install_nginx_org_repo: unsupported distro '${distro_id:-unknown}' (expected debian or ubuntu)."
  [[ -n "$distro_codename" ]] ||
    die "install_nginx_org_repo: could not determine distro codename from ${OS_RELEASE_FILE}."

  expected_line="deb [signed-by=${NGINX_ORG_KEYRING}] http://nginx.org/packages/${distro_id} ${distro_codename} nginx"

  if [[ -f "$NGINX_ORG_LIST" ]] && grep -qxF "$expected_line" "$NGINX_ORG_LIST"; then
    echo "nginx.org apt repo already configured, skipping." >&2
    return
  fi

  apt install -y curl gnupg2 ca-certificates

  install -d -m 755 "$(dirname -- "$NGINX_ORG_KEYRING")"
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee "$NGINX_ORG_KEYRING" >/dev/null

  echo "$expected_line" > "$NGINX_ORG_LIST"

  install -d -m 755 "$(dirname -- "$NGINX_ORG_PREF")"
  cat > "$NGINX_ORG_PREF" <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

  apt update
}

install_packages() {
  echo "[1/8] Installing packages..."

  if [[ -d /etc/needrestart/conf.d ]]; then
    # shellcheck disable=SC2016
    echo '$nrconf{restart} = '\''a'\'';' > /etc/needrestart/conf.d/50-autorestart.conf
  fi

  apt update

  install_nginx_org_repo

  apt update

  apt install -y \
    nginx \
    certbot \
    python3-certbot-dns-cloudflare \
    ufw \
    curl \
    ca-certificates \
    openssl \
    python3 \
    tar \
    xz-utils
}

NAIVE_BIN="/usr/bin/caddy"
NAIVE_VERSION_FILE="/usr/local/naiveproxy/.installed-version"

# Downloads and installs the latest klzgrad/forwardproxy release's `caddy`
# binary (a Caddy build bundling the naive fork of forwardproxy). Skipped
# entirely when NAIVE_SUBDOMAIN is empty. Idempotent: tracks the installed
# release tag in NAIVE_VERSION_FILE and skips re-downloading when already
# current.
install_naiveproxy() {
  [[ -n "$NAIVE_SUBDOMAIN" ]] || {
    echo "NAIVE_SUBDOMAIN not set, skipping NaiveProxy install." >&2
    return
  }

  echo "Installing NaiveProxy (Caddy + forwardproxy)..." >&2

  local tag download_url

  tag="$(
    curl -sI https://github.com/klzgrad/forwardproxy/releases/latest \
    | awk -F'/tag/' 'tolower($1) ~ /^location:/ {print $2}' \
    | tr -d '\r'
  )" ||
    die "Failed to parse the NaiveProxy (forwardproxy) latest release tag"

  if [[ -f "$NAIVE_VERSION_FILE" ]] && [[ "$(cat "$NAIVE_VERSION_FILE")" == "$tag" ]] && [[ -x "$NAIVE_BIN" ]]; then
    echo "NaiveProxy ${tag} already installed, skipping." >&2
    return
  fi

  download_url="https://github.com/klzgrad/forwardproxy/releases/download/${tag}/caddy-forwardproxy-naive.tar.xz"

  local tmp_dir tmp_archive caddy_binary
  tmp_dir="$(mktemp -d)"
  tmp_archive="${tmp_dir}/caddy-forwardproxy-naive.tar.xz"

  curl -fsSL -o "$tmp_archive" "$download_url" ||
    { rm -rf "$tmp_dir"; die "Failed to download NaiveProxy release archive from ${download_url}."; }

  tar -xJf "$tmp_archive" -C "$tmp_dir" ||
    { rm -rf "$tmp_dir"; die "Failed to extract NaiveProxy release archive."; }

  caddy_binary="$(find "$tmp_dir" -type f -name caddy | head -1)"
  if [[ -z "$caddy_binary" ]]; then
    rm -rf "$tmp_dir"
    die "NaiveProxy archive did not contain a 'caddy' binary."
  fi

  install -m 755 "$caddy_binary" "$NAIVE_BIN"

  install -d -m 755 "$(dirname -- "$NAIVE_VERSION_FILE")"
  printf '%s\n' "$tag" > "$NAIVE_VERSION_FILE"

  # Removes the downloaded archive and extracted files -- only the installed
  # binary at NAIVE_BIN and the version marker are kept.
  rm -rf "$tmp_dir"

  echo "NaiveProxy ${tag} installed to ${NAIVE_BIN}." >&2
}

CADDYFILE="/etc/caddy/Caddyfile"
NAIVE_DOCROOT="/var/www/naiveproxy"
NAIVE_SYSTEMD_UNIT="/etc/systemd/system/caddy.service"

# Populates the decoy file_server root Caddy serves to anyone who reaches it
# without valid forward_proxy credentials. Reuses the same content as the
# CDN inbounds' Nginx fallback page (FALLBACK_HTML_PATH) when set, so there
# is only one "what does an anonymous visitor see" page to maintain.
prepare_naive_docroot() {
  install -d -m 755 "$NAIVE_DOCROOT"

  if [[ -n "$FALLBACK_HTML_PATH" ]]; then
    [[ -f "$FALLBACK_HTML_PATH" && -r "$FALLBACK_HTML_PATH" ]] ||
      die "FALLBACK_HTML_PATH must point to a readable regular file: ${FALLBACK_HTML_PATH}"
    install -m 644 "$FALLBACK_HTML_PATH" "${NAIVE_DOCROOT}/index.html"
  elif [[ ! -f "${NAIVE_DOCROOT}/index.html" ]]; then
    printf '<!DOCTYPE html><html><head><title>It works!</title></head><body><h1>It works!</h1></body></html>\n' \
      > "${NAIVE_DOCROOT}/index.html"
    chmod 644 "${NAIVE_DOCROOT}/index.html"
  fi
}

# Generates the Caddyfile for NaiveProxy. Caddy binds loopback only
# (127.0.0.1:NAIVE_PORT) -- it is reached publicly via Nginx's stream/
# ssl_preread SNI passthrough on port 443, not directly. Reuses the existing
# Let's Encrypt wildcard cert (CERT_DIR) instead of Caddy's own ACME, since
# Caddy never sees a public HTTP-01/TLS-ALPN-01-reachable listener anyway.
write_caddyfile() {
  [[ -n "$NAIVE_SUBDOMAIN" ]] || {
    echo "NAIVE_SUBDOMAIN not set, skipping Caddyfile." >&2
    return
  }

  echo "Writing Caddyfile..." >&2

  prepare_naive_docroot

  install -d -m 755 "$(dirname -- "$CADDYFILE")"

  local tmp_caddyfile
  tmp_caddyfile="$(make_tmp_file)"

  cat > "$tmp_caddyfile" <<EOF
{
    auto_https off
    order forward_proxy before file_server
    servers {
        protocols h1 h2
    }
    log {
        exclude http.log.error
    }
}
:${NAIVE_PORT}, ${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}:${NAIVE_PORT} {
    # Keep both Caddy addresses on the internal listener port; the hostname
    # identifies the proxy without making Caddy bind public port 443.
    bind 127.0.0.1
    tls ${CERT_DIR}/fullchain.pem ${CERT_DIR}/privkey.pem
    encode
    forward_proxy {
        basic_auth ${NAIVE_USERNAME} ${NAIVE_PASSWORD}
        hide_ip
        hide_via
        probe_resistance
    }
    file_server {
        root ${NAIVE_DOCROOT}
    }
}
EOF

  mv "$tmp_caddyfile" "$CADDYFILE"
  chmod 644 "$CADDYFILE"

  if [[ -x "$NAIVE_BIN" ]]; then
    "$NAIVE_BIN" validate --config "$CADDYFILE" ||
      die "Generated Caddyfile failed 'caddy validate'; check ${CADDYFILE}."
  fi
}

# Installs and (re)starts the systemd unit for NaiveProxy. Runs as root
# rather than a dedicated unprivileged user (the pattern klzgrad's own wiki
# recommends): Caddy here reads the same root-owned Let's Encrypt cert files
# Nginx uses, and it never binds a privileged port (loopback high port
# only), so the usual justification for AmbientCapabilities=CAP_NET_BIND_SERVICE
# + a dedicated user doesn't apply, and avoiding ACL/copy-cert complexity for
# a single-purpose VPS keeps this simpler.
write_naive_systemd_unit() {
  [[ -n "$NAIVE_SUBDOMAIN" ]] || {
    echo "NAIVE_SUBDOMAIN not set, skipping NaiveProxy systemd unit." >&2
    return
  }

  echo "Installing NaiveProxy systemd unit..." >&2

  cat > "$NAIVE_SYSTEMD_UNIT" <<EOF
[Unit]
Description=NaiveProxy (Caddy + forwardproxy)
Documentation=https://github.com/klzgrad/naiveproxy
After=network.target network-online.target
Requires=network-online.target

[Service]
User=root
Group=root
ExecStart=${NAIVE_BIN} run --environ --config ${CADDYFILE}
ExecReload=${NAIVE_BIN} reload --config ${CADDYFILE}
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$NAIVE_SYSTEMD_UNIT"

  systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1 || true
  systemctl restart caddy ||
    die "Failed to start the caddy (NaiveProxy) service; check 'systemctl status caddy' and 'journalctl -u caddy'."
}

MITA_VERSION_FILE="/usr/local/mieru/.installed-version"
MITA_CONFIG_DIR="/etc/mieru"
MITA_CONFIG_FILE="/etc/mieru/server_config.json"

# Downloads and installs the latest enfein/mieru release's mita (server)
# Debian package. Skipped entirely when MIERU_SUBDOMAIN is empty. Idempotent:
# tracks the installed release tag in MITA_VERSION_FILE and skips
# re-downloading when already current. See:
# https://github.com/enfein/mieru/blob/main/docs/server-install.md
#
# BBR: mieru's own docs (server-install.md#bbr-congestion-control-algorithm)
# recommend OS-level BBR for the TCP protocol variant -- their UDP variant
# already implements BBR itself internally, so OS-level BBR is a no-op for
# it. This script does not duplicate mieru's own enable_tcp_bbr.py: BBR is
# already enabled system-wide (net.ipv4.tcp_congestion_control=bbr, fq
# qdisc) by harden-host.sh's enable_bbr(), invoked unconditionally via
# anonymize_vps() in main() before this function ever runs -- it benefits
# mieru/TCP the same way it already benefits Xray/WARP.
install_mieru() {
  [[ -n "$MIERU_SUBDOMAIN" ]] || {
    echo "MIERU_SUBDOMAIN not set, skipping mieru install." >&2
    return
  }

  echo "Installing mieru (mita server)..." >&2

  local tag version arch download_url tmp_deb

  tag="$(
    curl -sI https://github.com/enfein/mieru/releases/latest \
    | awk -F'/tag/' 'tolower($1) ~ /^location:/ {print $2}' \
    | tr -d '\r'
  )" ||
    die "Failed to parse the mieru (mita) latest release tag."

  version="${tag#v}"

  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "Unsupported architecture for mieru: $(uname -m)" ;;
  esac

  if [[ -f "$MITA_VERSION_FILE" ]] && [[ "$(cat "$MITA_VERSION_FILE")" == "$tag" ]] && command -v mita >/dev/null 2>&1; then
    echo "mieru ${tag} already installed, skipping." >&2
    return
  fi

  download_url="https://github.com/enfein/mieru/releases/download/${tag}/mita_${version}_${arch}.deb"

  tmp_deb="$(mktemp --suffix=.deb)"
  TMP_FILES+=("$tmp_deb")

  curl -fSsL -o "$tmp_deb" "$download_url" ||
    die "Failed to download mieru (mita) package from ${download_url}."

  dpkg -i "$tmp_deb" || apt-get install -f -y ||
    die "Failed to install mieru (mita) package."

  install -d -m 755 "$(dirname -- "$MITA_VERSION_FILE")"
  printf '%s\n' "$tag" > "$MITA_VERSION_FILE"

  echo "mieru ${tag} installed." >&2
}

# Writes the mita server configuration (port binding, protocol, user
# credentials) and applies it, per
# https://github.com/enfein/mieru/blob/main/docs/server-install.md. mieru
# has no TLS/certificate layer -- its own AEAD encryption is keyed off the
# username/password below, so it needs neither CERT_DIR nor Nginx.
write_mieru_config() {
  [[ -n "$MIERU_SUBDOMAIN" ]] || {
    echo "MIERU_SUBDOMAIN not set, skipping mieru config." >&2
    return
  }

  echo "Writing mieru (mita) server configuration..." >&2

  install -d -m 700 "$MITA_CONFIG_DIR"

  local tmp_config
  tmp_config="$(make_tmp_file)"

  cat > "$tmp_config" <<EOF
{
    "portBindings": [
        {
            "port": ${MIERU_PORT},
            "protocol": "${MIERU_PROTOCOL}"
        }
    ],
    "users": [
        {
            "name": "${MIERU_USERNAME}",
            "password": "${MIERU_PASSWORD}"
        }
    ],
    "loggingLevel": "INFO",
    "mtu": 1400
}
EOF

  mv "$tmp_config" "$MITA_CONFIG_FILE"
  chmod 600 "$MITA_CONFIG_FILE"

  # systemctl only manages the always-on mita control daemon (auto-started/
  # enabled by the deb package itself) -- it does NOT toggle the proxy
  # listener. That is a separate, persistent on/off state controlled by
  # `mita start`/`mita stop`, which `mita apply config` alone does not
  # change. Stop first (harmless if not yet started) so a rerun with new
  # settings takes effect instead of silently keeping the old config live.
  systemctl enable mita >/dev/null 2>&1 || true
  systemctl is-active --quiet mita || systemctl start mita ||
    die "Failed to start the mita control daemon; check 'systemctl status mita' and 'journalctl -u mita'."

  mita apply config "$MITA_CONFIG_FILE" ||
    die "Failed to apply mieru (mita) server configuration; check ${MITA_CONFIG_FILE}."

  mita stop >/dev/null 2>&1 || true
  mita start ||
    die "Failed to start the mieru proxy listener ('mita start'); check 'mita describe config' and 'journalctl -u mita'."

  # `mita start` succeeding only means the command was accepted -- `mita
  # status` reports the actual proxy state (distinct from `systemctl status
  # mita`, which only reflects the always-on control daemon process). Per
  # server-install.md#check-mita-working-status, "RUNNING" is the expected
  # value once the proxy is actually serving requests.
  local mieru_status
  mieru_status="$(mita status 2>&1)" || true
  if [[ "$mieru_status" != *RUNNING* ]]; then
    die "mieru (mita) did not report RUNNING after 'mita start'. Output: ${mieru_status}"
  fi
}

write_cloudflare_credentials() {
  echo "[2/8] Writing Cloudflare credentials..."

  install -d -m 700 /etc/letsencrypt

  local tmp_cf_credentials
  tmp_cf_credentials="$(make_tmp_file)"

  cat > "$tmp_cf_credentials" <<EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN:-}
EOF

  chmod 600 "$tmp_cf_credentials"
  mv "$tmp_cf_credentials" "$CF_CREDENTIALS"
}

issue_certificate() {
  echo "[3/8] Issuing or renewing wildcard certificate..."

  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDENTIALS" \
    --dns-cloudflare-propagation-seconds 30 \
    --cert-name "$BASE_DOMAIN" \
    -d "$BASE_DOMAIN" \
    -d "*.${BASE_DOMAIN}" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring
}

install_certbot_hook() {
  echo "[4/8] Installing permanent Certbot deploy hook..."

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy

  cat > "$CERTBOT_DEPLOY_HOOK" <<'EOF'
#!/usr/bin/env sh
set -eu

nginx -t
systemctl reload nginx
# Harmless no-op if NaiveProxy/Caddy isn't installed or running.
systemctl is-active --quiet caddy 2>/dev/null && systemctl reload caddy || true
EOF

  chmod 755 "$CERTBOT_DEPLOY_HOOK"

  systemctl enable certbot.timer >/dev/null 2>&1 || true
  systemctl start certbot.timer >/dev/null 2>&1 || true
}

write_cloudflare_real_ip_config() {
  echo "[5/8] Writing Cloudflare real IP configuration..."

  local tmp_cf_real_ip
  local backup=""
  local cf_ipv4=""
  local cf_ipv6=""

  tmp_cf_real_ip="$(make_tmp_file)"

  cf_ipv4="$(curl -fsSL https://www.cloudflare.com/ips-v4)" ||
    die "Failed to fetch Cloudflare IPv4 ranges. Check network connectivity and retry."

  [[ -n "$cf_ipv4" ]] ||
    die "Cloudflare IPv4 ranges response was empty."

  cf_ipv6="$(curl -fsSL https://www.cloudflare.com/ips-v6)" ||
    die "Failed to fetch Cloudflare IPv6 ranges. Check network connectivity and retry."

  [[ -n "$cf_ipv6" ]] ||
    die "Cloudflare IPv6 ranges response was empty."

  # Reuse the exact ranges fetched for nginx when locking the origin firewall.
  # Do not use mapfile: Debian supports it, but macOS's Bash 3 does not.
  CF_IP_RANGES=()
  while IFS= read -r cf_range; do
    [[ -n "$cf_range" ]] && CF_IP_RANGES+=("$cf_range")
  done < <(printf '%s\n%s\n' "$cf_ipv4" "$cf_ipv6" | sed '/^[[:space:]]*$/d')
  ((${#CF_IP_RANGES[@]} > 0)) || die "No Cloudflare IP ranges were parsed."

  {
    echo "# Generated by setup-vless-nginx.sh"
    echo "# Trust CF-Connecting-IP only from official Cloudflare networks"

    printf '%s\n' "$cf_ipv4" | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '%s\n' "$cf_ipv6" | sed 's/^/set_real_ip_from /; s/$/;/'

    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
  } > "$tmp_cf_real_ip"

  if [[ -e "$CF_REAL_IP_CONF" ]]; then
    backup="${CF_REAL_IP_CONF}.backup-${TIMESTAMP}"
    cp -a "$CF_REAL_IP_CONF" "$backup"
  fi

  mv "$tmp_cf_real_ip" "$CF_REAL_IP_CONF"
  chmod 644 "$CF_REAL_IP_CONF"

  if ! nginx -t; then
    echo "ERROR: Cloudflare real IP configuration is invalid."
    echo "Restoring previous configuration..."

    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$CF_REAL_IP_CONF"
    else
      rm -f "$CF_REAL_IP_CONF"
    fi

    nginx -t || true
    exit 1
  fi
}

nginx_listen_directive() {
  # $1: listen target, e.g. "443" (default) or "127.0.0.1:20010" -- the
  # latter is used for the CDN server blocks once the stream{} SNI Guard
  # takes over the public 443 listener (see write_nginx_config).
  local listen_target="${1:-443}"
  local version=""
  local major=0
  local minor=0
  local patch=0

  version="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"

  if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  fi

  # `http2 on;` as a separate directive was introduced in nginx 1.25.1.
  # Older versions only understand the combined `listen ... http2;` form.
  if ((major > 1 || (major == 1 && minor > 25) || (major == 1 && minor == 25 && patch >= 1))); then
    printf '%s\n' "listen ${listen_target} ssl;
    http2 on;"
  else
    printf '%s\n' "listen ${listen_target} ssl http2;"
  fi
}

NGINX_STREAM_CONF="/etc/nginx/stream.d/3xui-proxy-sni-guard.conf"
NGINX_STREAM_CONF_DIR="/etc/nginx/stream.d"
NGINX_MAIN_CONF="/etc/nginx/nginx.conf"
NGINX_STREAM_MARKER_BEGIN="# BEGIN 3xui-cf-setup stream"
NGINX_STREAM_MARKER_END="# END 3xui-cf-setup stream"

# Adds a top-level `stream {}` context to nginx.conf that includes
# NGINX_STREAM_CONF_DIR/*.conf, if not already present. Nginx.org's default
# nginx.conf has no stream{} block by default. Idempotent and marker-
# delimited so it can be cleanly reverted on --uninstall.
ensure_nginx_stream_context() {
  install -d -m 755 "$NGINX_STREAM_CONF_DIR"

  [[ -f "$NGINX_MAIN_CONF" ]] ||
    die "${NGINX_MAIN_CONF} not found; is Nginx installed?"

  if grep -qF "$NGINX_STREAM_MARKER_BEGIN" "$NGINX_MAIN_CONF"; then
    return
  fi

  cat >> "$NGINX_MAIN_CONF" <<EOF

${NGINX_STREAM_MARKER_BEGIN}
stream {
    include ${NGINX_STREAM_CONF_DIR}/*.conf;
}
${NGINX_STREAM_MARKER_END}
EOF
}

# Reverts ensure_nginx_stream_context's edit, if present.
unensure_nginx_stream_context() {
  [[ -f "$NGINX_MAIN_CONF" ]] || return 0
  sed -i.bak "/^${NGINX_STREAM_MARKER_BEGIN}\$/,/^${NGINX_STREAM_MARKER_END}\$/d" "$NGINX_MAIN_CONF"
  rm -f "${NGINX_MAIN_CONF}.bak"
}

# Generates the stream{} SNI Guard: routes port 443 traffic by SNI to the
# CDN inbounds (unchanged Nginx http server blocks, now on loopback), the
# NaiveProxy/Reality direct-connection backends, or a decoy vhost for any
# other SNI. Only called when Reality or NaiveProxy is enabled.
write_nginx_stream_config() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local naive_domain="${NAIVE_SUBDOMAIN:+${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}}"

  local tmp_stream
  tmp_stream="$(make_tmp_file)"

  {
    echo "map \$ssl_preread_server_name \$sni_upstream {"
    echo "    ${panel_domain}    cdn;"
    [[ "$INSTALL_MODE" != "cdn" ]] || echo "    ${vless_domain}    cdn;"
    [[ -z "$naive_domain" ]] || echo "    ${naive_domain}    naive;"
    [[ -z "$REALITY_SUBDOMAIN" ]] || echo "    ${REALITY_DEST}    reality;"
    echo "    default    decoy;"
    echo "}"
    echo
    echo "upstream cdn { server 127.0.0.1:${NGINX_CDN_PORT}; }"
    echo "upstream decoy { server 127.0.0.1:${NGINX_DECOY_PORT}; }"
    [[ -z "$naive_domain" ]] || echo "upstream naive { server 127.0.0.1:${NAIVE_PORT}; }"
    [[ -z "$REALITY_SUBDOMAIN" ]] || echo "upstream reality { server 127.0.0.1:${REALITY_PORT}; }"
    echo
    echo "server {"
    echo "    listen 443 reuseport;"
    echo "    listen [::]:443 reuseport;"
    echo "    ssl_preread on;"
    echo "    proxy_pass \$sni_upstream;"
    echo "    proxy_connect_timeout 5s;"
    echo "    proxy_timeout 300s;"
    echo "}"
  } > "$tmp_stream"

  mv "$tmp_stream" "$NGINX_STREAM_CONF"
  chmod 644 "$NGINX_STREAM_CONF"
}

check_port_443() {
  local pid=""
  local proc_name=""
  local answer=""

  if ! port_is_listening 443; then
    return
  fi

  pid="$(ss -H -ltnp 'sport = :443' 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)"
  proc_name="$(ps -p "${pid:-0}" -o comm= 2>/dev/null || echo "unknown")"

  # If it's nginx itself, that's fine — we'll reload it.
  if [[ "$proc_name" == "nginx" ]]; then
    return
  fi

  echo
  echo "WARNING: port 443 is already in use by: ${proc_name} (PID ${pid})"
  echo "Nginx needs to bind to port 443. The conflicting process must be stopped."
  echo
  read -r -p "Stop ${proc_name} (PID ${pid}) now? [y/N]: " answer

  case "$answer" in
    y|Y|yes|YES)
      echo "Stopping ${proc_name} (PID ${pid})..."
      kill "$pid" 2>/dev/null || true
      sleep 2

      if port_is_listening 443; then
        echo "Process did not stop gracefully, sending SIGKILL..."
        kill -9 "$pid" 2>/dev/null || true
        sleep 1
      fi

      if port_is_listening 443; then
        die "Port 443 is still in use. Please stop the process manually and re-run."
      fi

      echo "Port 443 is now free."
      ;;
    *)
      die "Cannot proceed while port 443 is occupied by another process."
      ;;
  esac
}

prepare_fallback_page() {
  if [[ -z "$FALLBACK_HTML_PATH" ]]; then
    rm -f "$FALLBACK_HTML_DEST"
    return
  fi

  [[ -f "$FALLBACK_HTML_PATH" && -r "$FALLBACK_HTML_PATH" ]] ||
    die "FALLBACK_HTML_PATH must point to a readable regular file: ${FALLBACK_HTML_PATH}"

  install -m 644 "$FALLBACK_HTML_PATH" "$FALLBACK_HTML_DEST"
}

nginx_vless_fallback_location() {
  if [[ -n "$FALLBACK_HTML_PATH" ]]; then
    cat <<EOF
    location = / {
        root /etc/nginx;
        try_files /3xui-proxy-fallback.html =404;
    }

    location / {
        return 404;
    }
EOF
  else
    cat <<'EOF'
    location / {
        return 404;
    }
EOF
  fi
}

write_nginx_config() {
  echo "[6/8] Writing Nginx reverse proxy configuration..."

  prepare_fallback_page

  check_port_443

  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local grpc_location="/${GRPC_SERVICE}"
  local vless_fallback_location
  local vless_server_block=""
  local tmp_nginx
  local backup=""
  local stream_backup=""
  local default_site_was_enabled=false
  local listen_directive
  local decoy_server_block=""
  local stream_mode=false

  # The stream{} SNI Guard only exists once there's a direct-connection
  # backend (Reality or NaiveProxy) to route to it. Otherwise Nginx keeps
  # binding 443 directly, exactly as it always has -- zero behavior change
  # for anyone not using those optional features.
  if [[ -n "$REALITY_SUBDOMAIN" || -n "$NAIVE_SUBDOMAIN" ]]; then
    stream_mode=true
  fi

  if [[ "$stream_mode" == true ]]; then
    listen_directive="$(nginx_listen_directive "127.0.0.1:${NGINX_CDN_PORT}")"
    prepare_naive_docroot
    decoy_server_block="$(cat <<DECOYEOF

server {
    listen 127.0.0.1:${NGINX_DECOY_PORT} ssl;
    http2 on;
    server_name _;

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    server_tokens off;

    root ${NAIVE_DOCROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
DECOYEOF
)"
  else
    listen_directive="$(nginx_listen_directive)"
  fi

  vless_fallback_location="$(nginx_vless_fallback_location)"

  # Direct installations must not contain CDN proxy locations at all. The
  # panel/subscription vhost remains, while Reality/Naive are routed by stream.
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    vless_server_block="$(cat <<EOF
server {
    ${listen_directive}
    server_name ${vless_domain};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    server_tokens off;

    location = ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_PORT};

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # packet-up places the session ID and sequence below XHTTP_PATH, so this
    # must be a prefix location rather than an exact-path match.
    location ^~ ${XHTTP_PATH} {
        grpc_pass grpc://127.0.0.1:${XHTTP_PORT};

        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;

        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;

        client_body_buffer_size 512k;
        client_max_body_size 0;
    }

    location ${grpc_location} {
        grpc_pass grpc://127.0.0.1:${GRPC_PORT};

        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;

        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;

        client_body_buffer_size 512k;
        client_max_body_size 0;
    }

${vless_fallback_location}
}
EOF
)"
  fi

  tmp_nginx="$(make_tmp_file)"

  cat > "$tmp_nginx" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

limit_req_zone \$binary_remote_addr zone=panel_limit:10m rate=30r/s;

${vless_server_block}

server {
    ${listen_directive}
    server_name ${panel_domain};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    server_tokens off;

    location = ${PANEL_PATH} {
        return 301 ${PANEL_PATH}/;
    }

    location ${PANEL_PATH}/ {
        limit_req zone=panel_limit burst=60 nodelay;

        proxy_pass http://127.0.0.1:${PANEL_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location ${SUB_PATH}/ {
        proxy_pass http://127.0.0.1:${SUB_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        return 404;
    }
}
${decoy_server_block}
EOF

  install -d -m 755 "$(dirname -- "$NGINX_SITE")" "$(dirname -- "$NGINX_SITE_ENABLED")"

  # Ensure nginx.conf includes sites-enabled (nginx.org packages only ship conf.d)
  if ! grep -q 'sites-enabled' "$NGINX_MAIN_CONF"; then
    sed -i '/include \/etc\/nginx\/conf\.d/a\    include /etc/nginx/sites-enabled/*;' "$NGINX_MAIN_CONF"
  fi

  if [[ -e "$NGINX_SITE" ]]; then
    backup="${NGINX_SITE}.backup-${TIMESTAMP}"
    cp -a "$NGINX_SITE" "$backup"
  fi

  if [[ -e "$NGINX_DEFAULT_SITE" || -L "$NGINX_DEFAULT_SITE" ]]; then
    default_site_was_enabled=true
    # Keep the original target/content across reruns; do not overwrite the
    # backup once this script has claimed the default listener.
    if [[ ! -e "$NGINX_DEFAULT_SITE_BACKUP" && ! -L "$NGINX_DEFAULT_SITE_BACKUP" ]]; then
      cp -a "$NGINX_DEFAULT_SITE" "$NGINX_DEFAULT_SITE_BACKUP"
    fi
  fi

  mv "$tmp_nginx" "$NGINX_SITE"
  chmod 644 "$NGINX_SITE"

  ln -sfn "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  rm -f "$NGINX_DEFAULT_SITE"

  if [[ "$stream_mode" == true ]]; then
    ensure_nginx_stream_context

    if [[ -e "$NGINX_STREAM_CONF" ]]; then
      stream_backup="${NGINX_STREAM_CONF}.backup-${TIMESTAMP}"
      cp -a "$NGINX_STREAM_CONF" "$stream_backup"
    fi

    write_nginx_stream_config
  else
    # Feature(s) disabled on this run -- remove any previously-generated
    # SNI Guard config so a stale stream.d file doesn't linger. The
    # top-level `stream {}` include in nginx.conf is left in place (inert,
    # harmless with an empty stream.d/ directory) rather than reverted here.
    rm -f "$NGINX_STREAM_CONF"
  fi

  if ! nginx -t; then
    echo "ERROR: New Nginx configuration is invalid."
    echo "Restoring previous configuration..."

    if [[ -n "$backup" ]]; then
      cp -a "$backup" "$NGINX_SITE"
      ln -sfn "$NGINX_SITE" "$NGINX_SITE_ENABLED"
    else
      rm -f "$NGINX_SITE"
      rm -f "$NGINX_SITE_ENABLED"
    fi

    if [[ -n "$stream_backup" ]]; then
      cp -a "$stream_backup" "$NGINX_STREAM_CONF"
    elif [[ "$stream_mode" == true ]]; then
      rm -f "$NGINX_STREAM_CONF"
    fi

    if [[ "$default_site_was_enabled" == true ]] &&
       [[ -e "$NGINX_DEFAULT_SITE_BACKUP" || -L "$NGINX_DEFAULT_SITE_BACKUP" ]]; then
      mv "$NGINX_DEFAULT_SITE_BACKUP" "$NGINX_DEFAULT_SITE"
    fi

    nginx -t || true
    exit 1
  fi

  systemctl reload nginx || systemctl restart nginx
}

configure_ufw() {
  echo "[7/8] Configuring UFW..."

  # 443/tcp is intentionally open to the whole internet, not just Cloudflare:
  # direct-connection inbounds (VLESS+Reality, NaiveProxy) share port 443 with
  # the Cloudflare-fronted CDN inbounds via Nginx's SNI-based routing, so
  # restricting 443 to Cloudflare's ranges would block those direct clients.
  # Clean up any per-range Cloudflare-only allow rules left over from a
  # previous run of this script (pre-direct-connection-inbound versions).
  local old_cf_range
  if [[ -f "$CF_IP_STATE_FILE" ]]; then
    while IFS= read -r old_cf_range; do
      [[ -n "$old_cf_range" ]] || continue
      ufw delete allow from "$old_cf_range" to any port 443 proto tcp || true
    done < "$CF_IP_STATE_FILE"
    rm -f "$CF_IP_STATE_FILE"
  fi

  local prev_panel_port=""
  local prev_sub_port=""
  local prev_ws_port=""
  local prev_grpc_port=""
  local prev_xhttp_port=""
  local prev_reality_port=""
  local prev_naive_port=""
  local prev_mieru_port=""
  local prev_nginx_cdn_port=""
  local prev_nginx_decoy_port=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    prev_panel_port="${STATE_PANEL_PORT:-}"
    prev_sub_port="${STATE_SUB_PORT:-}"
    prev_ws_port="${STATE_WS_PORT:-}"
    prev_grpc_port="${STATE_GRPC_PORT:-}"
    prev_xhttp_port="${STATE_XHTTP_PORT:-}"
    prev_reality_port="${STATE_REALITY_PORT:-}"
    prev_naive_port="${STATE_NAIVE_PORT:-}"
    prev_mieru_port="${STATE_MIERU_PORT:-}"
    prev_nginx_cdn_port="${STATE_NGINX_CDN_PORT:-}"
    prev_nginx_decoy_port="${STATE_NGINX_DECOY_PORT:-}"
  fi

  # Remove stale deny/allow rules left over from a previous run with different
  # ports. mieru's own port is allowed (not denied), so clean up both forms.
  if [[ -n "$prev_mieru_port" ]] && [[ "$prev_mieru_port" != "${MIERU_PORT:-}" ]]; then
    ufw delete allow "${prev_mieru_port}/tcp" || true
    ufw delete allow "${prev_mieru_port}/udp" || true
  fi

  # Remove stale deny rules left over from a previous run with different ports.
  for stale_port in "$prev_panel_port" "$prev_sub_port" "$prev_ws_port" "$prev_grpc_port" "$prev_xhttp_port" "$prev_reality_port" "$prev_naive_port" "$prev_nginx_cdn_port" "$prev_nginx_decoy_port"; do
    if [[ -n "$stale_port" ]] &&
       [[ "$stale_port" != "$PANEL_PORT" ]] &&
       [[ "$stale_port" != "$SUB_PORT" ]] &&
       [[ "$stale_port" != "$WS_PORT" ]] &&
       [[ "$stale_port" != "$GRPC_PORT" ]] &&
       [[ "$stale_port" != "$XHTTP_PORT" ]] &&
       [[ "$stale_port" != "${REALITY_PORT:-}" ]] &&
       [[ "$stale_port" != "${NAIVE_PORT:-}" ]] &&
       [[ "$stale_port" != "${NGINX_CDN_PORT:-}" ]] &&
       [[ "$stale_port" != "${NGINX_DECOY_PORT:-}" ]]; then
      ufw delete deny "${stale_port}/tcp" || true
    fi
  done

  # Deliberately does NOT touch SSH (allow/deny) at all -- this script only
  # owns the panel/proxy-related ports. Managing the SSH rule here risked a
  # lockout (enabling UFW without an SSH allow rule already in place, or
  # deleting the wrong one on --uninstall) for something entirely unrelated
  # to this script's job. If SSH isn't already reachable through UFW on this
  # host, allow it yourself, e.g.: ufw allow 22/tcp
  # Remove any stale rules before adding the current one (idempotent reruns).
  ufw delete allow 443/tcp || true
  ufw delete deny 443/tcp || true
  ufw allow 443/tcp
  [[ -z "${HYSTERIA_PORT:-}" ]] || ufw allow "${HYSTERIA_PORT}/udp"
  if [[ -n "${MIERU_PORT:-}" ]]; then
    ufw allow "${MIERU_PORT}/$(printf '%s' "${MIERU_PROTOCOL:-udp}" | tr '[:upper:]' '[:lower:]')"
  fi

  ufw deny 80/tcp || true
  ufw deny "${PANEL_PORT}/tcp" || true
  ufw deny "${SUB_PORT}/tcp" || true
  ufw deny "${WS_PORT}/tcp" || true
  ufw deny "${GRPC_PORT}/tcp" || true
  ufw deny "${XHTTP_PORT}/tcp" || true
  [[ -z "${REALITY_PORT:-}" ]] || ufw deny "${REALITY_PORT}/tcp" || true
  [[ -z "${NAIVE_PORT:-}" ]] || ufw deny "${NAIVE_PORT}/tcp" || true
  [[ -z "${NGINX_CDN_PORT:-}" ]] || ufw deny "${NGINX_CDN_PORT}/tcp" || true
  [[ -z "${NGINX_DECOY_PORT:-}" ]] || ufw deny "${NGINX_DECOY_PORT}/tcp" || true

  ufw --force enable
  ufw reload

  cat > "$STATE_FILE" <<EOF
STATE_PANEL_PORT=${PANEL_PORT}
STATE_SUB_PORT=${SUB_PORT}
STATE_WS_PORT=${WS_PORT}
STATE_GRPC_PORT=${GRPC_PORT}
STATE_XHTTP_PORT=${XHTTP_PORT}
STATE_REALITY_PORT=${REALITY_PORT:-}
STATE_NAIVE_PORT=${NAIVE_PORT:-}
STATE_MIERU_PORT=${MIERU_PORT:-}
STATE_NGINX_CDN_PORT=${NGINX_CDN_PORT:-}
STATE_NGINX_DECOY_PORT=${NGINX_DECOY_PORT:-}
EOF
  chmod 600 "$STATE_FILE"
}

print_summary() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"

  echo "[8/8] Done."
  echo "Installation mode: ${INSTALL_MODE}"
  echo
  echo "Panel:"
  echo "  URL: https://${panel_domain}${PANEL_PATH}/"
  echo "  public/client port: 443"
  echo "  internal 3x-ui port: ${PANEL_PORT}"
  echo
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
  echo "VLESS WebSocket:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${WS_PORT}"
  echo "  security: tls"
  echo "  network: ws"
  echo "  path: ${WS_PATH}"
  echo
  echo "VLESS XHTTP:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${XHTTP_PORT}"
  echo "  security: tls (terminated by Nginx)"
  echo "  network: xhttp"
  echo "  path: ${XHTTP_PATH}"
  echo "  Cloudflare: proxied DNS + gRPC enabled"
  echo
  echo "VLESS gRPC:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${GRPC_PORT}"
  echo "  security: tls"
  echo "  network: grpc"
  echo "  serviceName: ${GRPC_SERVICE}"
  echo
  fi
  echo "Subscription:"
  echo "  URL: https://${panel_domain}${SUB_PATH}/"
  echo "  internal port: ${SUB_PORT}"
  echo
  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    echo "VLESS Reality (direct connection, no CDN):"
    echo "  domain: ${REALITY_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  public/client port: 443"
    echo "  internal Xray port: ${REALITY_PORT}"
    echo "  impersonating: ${REALITY_DEST}"
    echo
  fi

  if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
    echo "NaiveProxy (direct connection, no CDN):"
    echo "  domain: ${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  public/client port: 443"
    echo "  internal Caddy port: ${NAIVE_PORT}"
    echo "  username: ${NAIVE_USERNAME}"
    echo "  password: ${NAIVE_PASSWORD}"
    echo
  fi

  if [[ -n "$MIERU_SUBDOMAIN" ]]; then
    echo "mieru (direct connection, no CDN, no TLS/SNI):"
    echo "  domain: ${MIERU_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  public/client port: ${MIERU_PORT}/${MIERU_PROTOCOL}"
    echo "  username: ${MIERU_USERNAME}"
    echo "  password: ${MIERU_PASSWORD}"
    echo
  fi

  echo "UFW:"
  echo "  allowed: 443/tcp from anywhere (shared by CDN, Reality and NaiveProxy via SNI-based routing); SSH is left untouched by this script"
  echo "  denied: public 80/tcp, ${PANEL_PORT}/tcp, ${SUB_PORT}/tcp, ${WS_PORT}/tcp, ${GRPC_PORT}/tcp, ${XHTTP_PORT}/tcp${REALITY_PORT:+, ${REALITY_PORT}/tcp}${NAIVE_PORT:+, ${NAIVE_PORT}/tcp}"
  [[ -z "${MIERU_PORT:-}" ]] || echo "  allowed: ${MIERU_PORT}/${MIERU_PROTOCOL} from anywhere (mieru)"
  echo
  echo "Files:"
  echo "  Nginx site: ${NGINX_SITE}"
  echo "  Cloudflare real IP config: ${CF_REAL_IP_CONF}"
  echo "  Cloudflare credentials: ${CF_CREDENTIALS}"
  echo "  Certbot deploy hook: ${CERTBOT_DEPLOY_HOOK}"
  echo
  echo "Check:"
  echo "  nginx -t"
  echo "  systemctl status nginx"
  echo "  systemctl status certbot.timer"
  echo "  certbot renew --dry-run"
  echo "  ufw status verbose"
  echo "  ss -lntp | egrep ':443|:${PANEL_PORT}|:${SUB_PORT}|:${WS_PORT}|:${GRPC_PORT}|:${XHTTP_PORT}'"
}

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

detect_country_flag() {
  local country_code=""

  if [[ -n "$VPS_COUNTRY_CODE" ]]; then
    country_code="${VPS_COUNTRY_CODE^^}"
    [[ "$country_code" =~ ^[A-Z]{2}$ ]] ||
      die "VPS_COUNTRY_CODE must be a two-letter ISO country code (for example, FR)."
  else
    country_code="$(curl -fsSL --max-time 5 https://ipapi.co/country/ 2>/dev/null || true)"
  fi

  if [[ "$country_code" =~ ^[A-Z]{2}$ ]]; then
    # Convert 2-letter country code to regional indicator emoji.
    # A=0x1F1E6, B=0x1F1E7, ... Z=0x1F1FF
    local c1 c2
    c1=$(printf '%x' $(( $(printf '%d' "'${country_code:0:1}") - 65 + 0x1F1E6 )))
    c2=$(printf '%x' $(( $(printf '%d' "'${country_code:1:1}") - 65 + 0x1F1E6 )))
    # bash's \U printf escape only emits correct UTF-8 bytes under a UTF-8
    # locale -- under LC_CTYPE=POSIX/C (the default on minimal VPS images,
    # Docker containers, and non-interactive `bash <(curl ...)` invocations,
    # i.e. exactly how this script is normally run) it silently prints the
    # literal escape text instead of the flag. Force a UTF-8 locale just for
    # this printf so it's correct regardless of the ambient shell's locale.
    # shellcheck disable=SC2059
    LC_ALL=C.UTF-8 printf "\\U${c1}\\U${c2}"
  else
    printf '🌐'
  fi
}

# ===========================================================================
# 3x-ui install + inbound configuration (formerly setup-3x-ui.sh).
#
# Merged directly into setup.sh -- these functions used to run as a separate
# subprocess, with values crossing that boundary via explicit env-var
# forwarding on the way in and a printed KEY=VALUE stdout "protocol" on the
# way out. That boundary caused real bugs (VPS_COUNTRY_CODE and
# INBOUND_REMARK_REALITY silently failing to forward; a second, out-of-sync
# copy of detect_country_flag()) and the stdout-parsing protocol was itself
# fragile. Sharing scope directly eliminates that whole class of bug.
#
# 3x-ui's own install.sh (invoked by install_xui below) remains the source
# of truth for panel credentials and web base path: when
# XUI_USERNAME/XUI_PASSWORD/XUI_WEB_BASE_PATH are left unset, it generates
# secure random values and persists them to INSTALL_RESULT_FILE (mode 600).
# This script deliberately does not pass those vars in. The panel PORT is
# the one exception -- reserved up front in collect_input() so it cannot
# collide with the proxy's other internal ports, then passed to the
# installer as XUI_PANEL_PORT.
# ===========================================================================

xui_is_installed() {
  [[ -d /etc/x-ui ]] && command -v x-ui >/dev/null 2>&1
}

install_xui() {
  echo "3x-ui not found, running unattended installer (3x-ui will generate its own secure username/password/path; port ${PANEL_PORT} is pre-reserved by setup.sh)..." >&2
  if [[ -n "$XUI_VERSION" ]]; then
    echo "Requested XUI_VERSION=${XUI_VERSION}." >&2
  fi
  # Deliberately not passing XUI_USERNAME/XUI_PASSWORD/XUI_WEB_BASE_PATH:
  # the upstream installer treats "unset" as "generate a secure random value",
  # which is what we want. XUI_PANEL_PORT is passed because setup.sh reserved
  # it to avoid internal-port collisions. XUI_VERSION, if set, is forwarded as
  # the upstream install.sh positional version argument (e.g. v3.4.0 or
  # dev-latest); unset installs the latest stable release.
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
    echo "WARNING: 3x-ui reports panel port ${XUI_PANEL_PORT}, but setup.sh reserved ${PANEL_PORT}." >&2
    echo "This means 3x-ui was already installed/configured before with a different port; using ${XUI_PANEL_PORT} as reported." >&2
  fi
}

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
  TMP_FILES+=("$COOKIE_JAR")

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
    # Also match by port when the tag was renamed or migrated
    try:
        port = int(tag.split('-')[1])
        if ib.get('port') == port:
            sys.exit(0)
    except (IndexError, ValueError):
        pass
sys.exit(1)
" "$resp" "$tag"
}

# Update only an existing inbound's label. Fetch its full detail first instead
# of reusing /list output, which can be a slim projection on newer 3x-ui
# releases and would risk dropping transport/client fields during an update.
xui_sync_inbound_remark() {
  local tag="$1" remark="$2" list_resp id detail_resp body resp
  list_resp="$(api_curl -X GET "${BASE_URL}/panel/api/inbounds/list")"

  id="$(python3 -c "
import json,sys
tag = sys.argv[2]
try:
    inbounds = json.loads(sys.argv[1]).get('obj') or []
except Exception:
    sys.exit(1)
# Extract port from tag format 'in-<port>-<proto>'
try:
    tag_port = int(tag.split('-')[1])
except (IndexError, ValueError):
    tag_port = None
for inbound in inbounds:
    if inbound.get('tag') == tag or (tag_port and inbound.get('port') == tag_port):
        if inbound.get('remark') == sys.argv[3]:
            sys.exit(2)
        print(inbound['id'])
        sys.exit(0)
sys.exit(1)
" "$list_resp" "$tag" "$remark")" || {
    local status=$?
    [[ "$status" == 2 ]] && return 0
    die "Could not find existing inbound '${tag}' to update its remark."
  }

  detail_resp="$(api_curl -X GET "${BASE_URL}/panel/api/inbounds/get/${id}")"
  body="$(python3 -c "
import json,sys
try:
    inbound = json.loads(sys.argv[1]).get('obj')
    if not isinstance(inbound, dict):
        raise ValueError('missing inbound detail')
    inbound['remark'] = sys.argv[2]
    print(json.dumps(inbound))
except Exception as e:
    print(f'Failed to prepare inbound update: {e}', file=sys.stderr)
    sys.exit(1)
" "$detail_resp" "$remark")" || die "Could not fetch full configuration for inbound '${tag}'."

  resp="$(api_curl -X POST "${BASE_URL}/panel/api/inbounds/update/${id}" \
    -H 'Content-Type: application/json' -d "$body")"
  python3 -c "
import json,sys
try:
    sys.exit(0 if json.loads(sys.argv[1]).get('success') else 1)
except Exception:
    sys.exit(1)
" "$resp" || die "Failed to update remark for inbound '${tag}'. Response: ${resp}"

  echo "Updated inbound '${tag}' remark to '${remark}'." >&2
}

# Generates (or reuses, if already passed in via env) a VLESS Encryption
# (ML-KEM-768) keypair. Applied only to the WS/gRPC/XHTTP inbounds -- Reality
# has no CDN/reverse-proxy TLS-termination layer in between to protect
# against, so it deliberately keeps 'decryption': 'none'.
ensure_vless_encryption_keys() {
  if [[ -n "$VLESS_ENCRYPTION_SERVER_KEY" && -n "$VLESS_ENCRYPTION_CLIENT_KEY" ]]; then
    echo "Reusing existing VLESS Encryption keypair." >&2
    return
  fi

  echo "Generating VLESS Encryption (ML-KEM-768) keypair..." >&2
  local resp
  resp="$(api_curl -X GET "${BASE_URL}/panel/api/server/getNewmlkem768")"

  VLESS_ENCRYPTION_SERVER_KEY="$(python3 -c "
import json,sys
try:
    obj = json.loads(sys.argv[1])['obj']
    # API returns 'serverKey'+'clientKey' or 'seed'+'client'
    print(obj.get('serverKey') or obj['seed'])
except Exception:
    sys.exit(1)
" "$resp")" || die "Failed to generate VLESS Encryption keys (is 3x-ui new enough to support getNewmlkem768?). Response: ${resp}"

  VLESS_ENCRYPTION_CLIENT_KEY="$(python3 -c "
import json,sys
try:
    obj = json.loads(sys.argv[1])['obj']
    # API returns 'serverKey'+'clientKey' or 'seed'+'client'
    print(obj.get('clientKey') or obj['client'])
except Exception:
    sys.exit(1)
" "$resp")" || die "Failed to generate VLESS Encryption keys. Response: ${resp}"

  [[ -n "$VLESS_ENCRYPTION_SERVER_KEY" && -n "$VLESS_ENCRYPTION_CLIENT_KEY" ]] ||
    die "3x-ui returned an empty VLESS Encryption keypair. Response: ${resp}"
}

xui_add_inbound() {
  local port="$1" tag="$2" remark="$3" stream_settings="$4" client_email="$5" decryption="${6:-none}" client_flow="${7:-}"

  # Per the 3x-ui API docs, settings/streamSettings/sniffing should be
  # nested JSON objects (preferred), not JSON-encoded strings.
  local json_body
  # Keep the panel client email separate from the script's Let's Encrypt
  # EMAIL setting; exporting EMAIL here would corrupt saved configuration.
  export REMARK="$remark" PORT="$port" TAG="$tag" UUID="$CLIENT_UUID" CLIENT_EMAIL="$client_email" STREAM="$stream_settings" SUBID="$CLIENT_SUB_ID" DECRYPTION="$decryption" CLIENT_FLOW="$client_flow"
  json_body="$(python3 << 'JSONEOF'
import json,os
client = {
    'id': os.environ['UUID'],
    # 3x-ui treats an omitted per-client enable flag as disabled.
    'enable': True,
    'email': os.environ['CLIENT_EMAIL'],

    'subId': os.environ['SUBID'],
}
if os.environ.get('CLIENT_FLOW'):
    client['flow'] = os.environ['CLIENT_FLOW']
print(json.dumps({
    'up': 0,
    'down': 0,
    'total': 0,
    'remark': os.environ['REMARK'],
    'enable': True,
    'expiryTime': 0,
    'listen': '127.0.0.1',
    'port': int(os.environ['PORT']),
    'protocol': 'vless',
    'tag': os.environ['TAG'],
    'settings': {
        'clients': [client],
        'decryption': os.environ['DECRYPTION'],
        'fallbacks': [],
    },
    'streamSettings': json.loads(os.environ['STREAM']),
    'sniffing': {
        'enabled': True,
        'destOverride': ['http', 'tls'],
    },
}))
JSONEOF
  )"

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
    xui_sync_inbound_remark "$tag" "${INBOUND_REMARK_WS:-$(detect_country_flag) WebSocket-CDN}"
    echo "Inbound '${tag}' already exists, skipping creation." >&2
    return
  fi

  local stream_settings
  export WS_PATH_ARG="$WS_PATH" EXT_DOMAIN="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  stream_settings="$(python3 << 'WSEOF'
import json,os
settings = {
    'network': 'ws',
    'security': 'none',
    'wsSettings': {'acceptProxyProtocol': False, 'path': os.environ['WS_PATH_ARG'], 'host': '', 'headers': {}},
}
if os.environ.get('EXT_DOMAIN'):
    settings['externalProxy'] = [{
        'forceTls': 'tls',
        'dest': os.environ['EXT_DOMAIN'],
        'port': 443,
        'remark': '',
    }]
print(json.dumps(settings))
WSEOF
  )"

  echo "Creating inbound '${tag}' (WS, port ${WS_PORT}, path ${WS_PATH})..." >&2
  local _flag
  _flag="$(detect_country_flag)"
  xui_add_inbound "$WS_PORT" "$tag" "${INBOUND_REMARK_WS:-${_flag} WebSocket-CDN}" "$stream_settings" "client" "$VLESS_ENCRYPTION_SERVER_KEY"
}

ensure_xhttp_inbound() {
  local tag="in-${XHTTP_PORT}-xhttp"

  if xui_inbound_exists "$tag"; then
    xui_sync_inbound_remark "$tag" "${INBOUND_REMARK_XHTTP:-$(detect_country_flag) XHTTP-CDN}"
    echo "Inbound '${tag}' already exists, skipping creation." >&2
    return
  fi

  local stream_settings
  export XHTTP_PATH_ARG="$XHTTP_PATH" EXT_DOMAIN="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  stream_settings="$(python3 << 'XHTTPEOF'
import json,os
settings = {
    'network': 'xhttp',
    'security': 'none',
    # packet-up is the most compatible mode for a CDN/reverse-proxy path.
    'xhttpSettings': {'path': os.environ['XHTTP_PATH_ARG'], 'mode': 'packet-up'},
}
if os.environ.get('EXT_DOMAIN'):
    settings['externalProxy'] = [{
        'forceTls': 'tls',
        'dest': os.environ['EXT_DOMAIN'],
        'port': 443,
        'remark': '',
    }]
print(json.dumps(settings))
XHTTPEOF
  )"

  echo "Creating inbound '${tag}' (XHTTP, port ${XHTTP_PORT}, path ${XHTTP_PATH})..." >&2
  local _flag
  _flag="$(detect_country_flag)"
  # flow: xtls-rprx-vision is only meaningful once VLESS Encryption is
  # enabled -- without it, Vision cannot splice TLS records over XHTTP's own
  # framing (see README/commit history for the full explanation).
  xui_add_inbound "$XHTTP_PORT" "$tag" "${INBOUND_REMARK_XHTTP:-${_flag} XHTTP-CDN}" "$stream_settings" "client" "$VLESS_ENCRYPTION_SERVER_KEY" "xtls-rprx-vision"
}

ensure_grpc_inbound() {
  local tag="in-${GRPC_PORT}-grpc"

  if xui_inbound_exists "$tag"; then
    xui_sync_inbound_remark "$tag" "${INBOUND_REMARK_GRPC:-$(detect_country_flag) gRPC-CDN}"
    echo "Inbound '${tag}' already exists, skipping creation." >&2
    return
  fi

  local stream_settings
  export GRPC_SVC="$GRPC_SERVICE" EXT_DOMAIN="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  stream_settings="$(python3 << 'GRPCEOF'
import json,os
settings = {
    'network': 'grpc',
    'security': 'none',
    'grpcSettings': {'serviceName': os.environ['GRPC_SVC'], 'multiMode': False},
}
if os.environ.get('EXT_DOMAIN'):
    settings['externalProxy'] = [{
        'forceTls': 'tls',
        'dest': os.environ['EXT_DOMAIN'],
        'port': 443,
        'remark': '',
    }]
print(json.dumps(settings))
GRPCEOF
  )"

  echo "Creating inbound '${tag}' (gRPC, port ${GRPC_PORT}, serviceName ${GRPC_SERVICE})..." >&2
  local _flag
  _flag="$(detect_country_flag)"
  xui_add_inbound "$GRPC_PORT" "$tag" "${INBOUND_REMARK_GRPC:-${_flag} gRPC-CDN}" "$stream_settings" "client" "$VLESS_ENCRYPTION_SERVER_KEY"
}

ensure_hysteria_inbound() {
  [[ -n "$HYSTERIA_SUBDOMAIN" ]] || return 0

  local tag="in-${HYSTERIA_PORT}-hysteria" remark=""
  remark="${INBOUND_REMARK_HYSTERIA:-$(detect_country_flag) Hysteria-Gecko}"
  if xui_inbound_exists "$tag"; then
    xui_sync_inbound_remark "$tag" "$remark"
    echo "Inbound '${tag}' already exists, skipping creation." >&2
    return
  fi

  # Hysteria2 is QUIC/UDP. It binds publicly (not through Nginx) and uses the
  # wildcard certificate issued earlier for its own TLS handshake.
  local body resp
  export HYSTERIA_PORT_ARG="$HYSTERIA_PORT" HYSTERIA_AUTH_ARG="$HYSTERIA_AUTH" \
    HYSTERIA_OBFS_ARG="$HYSTERIA_OBFS_PASSWORD" HYSTERIA_DOMAIN_ARG="${HYSTERIA_SUBDOMAIN}.${BASE_DOMAIN}" \
    HYSTERIA_CERT_ARG="${CERT_DIR}/fullchain.pem" HYSTERIA_KEY_ARG="${CERT_DIR}/privkey.pem" \
    HYSTERIA_TAG_ARG="$tag" HYSTERIA_REMARK_ARG="$remark"
  body="$(python3 -c "
import json,os
print(json.dumps({
  'up': 0, 'down': 0, 'total': 0, 'remark': os.environ['HYSTERIA_REMARK_ARG'], 'enable': True,
  'expiryTime': 0, 'listen': '0.0.0.0', 'port': int(os.environ['HYSTERIA_PORT_ARG']),
  'protocol': 'hysteria', 'tag': os.environ['HYSTERIA_TAG_ARG'],
  'settings': {'version': 2, 'users': [{'auth': os.environ['HYSTERIA_AUTH_ARG'], 'level': 0, 'email': 'client'}]},
  'streamSettings': {
    'network': 'hysteria', 'security': 'tls',
    'hysteriaSettings': {'version': 2, 'udpIdleTimeout': 60},
    'tlsSettings': {
      'serverName': os.environ['HYSTERIA_DOMAIN_ARG'], 'minVersion': '1.2', 'maxVersion': '1.3',
      'cipherSuites': '', 'rejectUnknownSni': False, 'disableSystemRoot': False,
      'enableSessionResumption': False,
      'certificates': [{
        'certificateFile': os.environ['HYSTERIA_CERT_ARG'], 'keyFile': os.environ['HYSTERIA_KEY_ARG'],
        'ocspStapling': 0, 'oneTimeLoading': False, 'usage': 'encipherment',
        'buildChain': False, 'useFile': True,
      }],
      'alpn': ['h3'], 'echServerKeys': '',
      'settings': {'fingerprint': 'chrome', 'echConfigList': '',
                   'pinnedPeerCertSha256': [], 'verifyPeerCertByName': ''},
    },
    'finalmask': {'udp': [{'type': 'salamander', 'settings': {'password': os.environ['HYSTERIA_OBFS_ARG'], 'packetSize': '512-1200'}}]},
  },
  'sniffing': {'enabled': True, 'destOverride': ['http', 'tls', 'quic']},
}))
")"
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/inbounds/add" -H 'Content-Type: application/json' -d "$body")"
  python3 -c "import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get('success') else 1)" "$resp" ||
    die "Failed to create Hysteria2 inbound '${tag}'. Response: ${resp}"
}

# Generates (or reuses, if already passed in via env) a Reality X25519
# keypair. Distinct from VLESS Encryption's ML-KEM-768 keypair -- Reality
# uses its own transport-security handshake, unrelated to the VLESS payload
# encryption feature.
ensure_reality_keys() {
  [[ -n "$REALITY_SUBDOMAIN" ]] || return 0

  if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]; then
    echo "Reusing existing Reality keypair." >&2
    return
  fi

  echo "Generating Reality (X25519) keypair..." >&2
  local resp
  resp="$(api_curl -X GET "${BASE_URL}/panel/api/server/getNewX25519Cert")"

  REALITY_PRIVATE_KEY="$(python3 -c "
import json,sys
try:
    print(json.loads(sys.argv[1])['obj']['privateKey'])
except Exception:
    sys.exit(1)
" "$resp")" || die "Failed to generate Reality keys. Response: ${resp}"

  REALITY_PUBLIC_KEY="$(python3 -c "
import json,sys
try:
    print(json.loads(sys.argv[1])['obj']['publicKey'])
except Exception:
    sys.exit(1)
" "$resp")" || die "Failed to generate Reality keys. Response: ${resp}"

  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] ||
    die "3x-ui returned an empty Reality keypair. Response: ${resp}"
}

# Direct-connection inbound (no CDN/Nginx-terminated TLS in front) --
# entirely optional, skipped when REALITY_SUBDOMAIN is empty. Reality
# deliberately keeps 'decryption': 'none' (xui_add_inbound's default): unlike
# the CDN inbounds, there is no MITM-capable reverse proxy in front of this
# one for VLESS Encryption to protect against.
ensure_reality_inbound() {
  [[ -n "$REALITY_SUBDOMAIN" ]] || {
    echo "REALITY_SUBDOMAIN not set, skipping Reality inbound." >&2
    return 0
  }

  local tag="in-${REALITY_PORT}-reality"

  if xui_inbound_exists "$tag"; then
    xui_sync_inbound_remark "$tag" "${INBOUND_REMARK_REALITY:-$(detect_country_flag) Reality}"
    echo "Inbound '${tag}' already exists, skipping creation." >&2
    return
  fi

  # NOTE: externalProxy is deliberately never set here. It tells 3x-ui's
  # subscription/link generator "this inbound sits behind an external
  # TLS-terminating proxy", which makes it emit security=tls instead of
  # security=reality in generated client links -- breaking Reality entirely,
  # since Reality is a direct connection that does its own TLS impersonation
  # and has no CDN/reverse-proxy TLS termination in front of it.
  local stream_settings
  export REALITY_DEST_ARG="$REALITY_DEST" REALITY_SHORT_ID_ARG="$REALITY_SHORT_ID" \
    REALITY_PRIVATE_KEY_ARG="$REALITY_PRIVATE_KEY" REALITY_PUBLIC_KEY_ARG="$REALITY_PUBLIC_KEY"
  stream_settings="$(python3 << 'REALITYEOF'
import json,os
settings = {
    'network': 'tcp',
    'security': 'reality',
    'realitySettings': {
        'show': False,
        'target': f"{os.environ['REALITY_DEST_ARG']}:443",
        'xver': 0,
        'serverNames': [os.environ['REALITY_DEST_ARG']],
        'privateKey': os.environ['REALITY_PRIVATE_KEY_ARG'],
        'shortIds': [os.environ['REALITY_SHORT_ID_ARG']],
        # The 3x-ui panel UI and subscription link generator (applyShareRealityParams)
        # read the public key from this NESTED settings.publicKey field, not from
        # a top-level key -- omitting it leaves the panel showing only the private
        # key and produces subscription links silently missing pbk=.
        'settings': {
            'publicKey': os.environ['REALITY_PUBLIC_KEY_ARG'],
            'fingerprint': 'chrome',
            'spiderX': '/',
        },
    },
}
print(json.dumps(settings))
REALITYEOF
  )"

  echo "Creating inbound '${tag}' (Reality, port ${REALITY_PORT}, impersonating ${REALITY_DEST})..." >&2
  local _flag
  _flag="$(detect_country_flag)"
  xui_add_inbound "$REALITY_PORT" "$tag" "${INBOUND_REMARK_REALITY:-${_flag} Reality}" "$stream_settings" "client" "none" "xtls-rprx-vision"
}

# Looks up an inbound's numeric DB id by tag (falling back to port, same
# convention as xui_inbound_exists), needed for the Hosts API which keys off
# id rather than tag.
xui_get_inbound_id() {
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
try:
    tag_port = int(tag.split('-')[1])
except (IndexError, ValueError):
    tag_port = None
for ib in obj:
    if ib.get('tag') == tag or (tag_port and ib.get('port') == tag_port):
        print(ib['id'])
        sys.exit(0)
sys.exit(1)
" "$resp" "$tag"
}

# Ensures a 3x-ui "Host" override exists for the Reality inbound, advertising
# its public domain:443 in generated subscription/share links instead of the
# internal loopback address:port. Uses security="same" so the link keeps
# advertising Reality (inherits the inbound's own security) -- NEVER "tls",
# which corrupts Reality links by forcing security=tls regardless of the
# inbound's actual config (see github.com/MHSanaei/3x-ui/issues/5143 for the
# analogous externalProxy-driven variant of this failure mode). Idempotent:
# skips creation if a host already exists for this inbound.
ensure_reality_host() {
  [[ -n "$REALITY_SUBDOMAIN" ]] || return 0

  local tag="in-${REALITY_PORT}-reality"
  local inbound_id
  inbound_id="$(xui_get_inbound_id "$tag")" ||
    die "Could not resolve inbound id for '${tag}' while configuring its Host override."

  local existing_resp
  existing_resp="$(api_curl -X GET "${BASE_URL}/panel/api/hosts/byInbound/${inbound_id}")"
  if python3 -c "
import json,sys
try:
    obj = json.loads(sys.argv[1]).get('obj') or []
except Exception:
    obj = []
sys.exit(0 if len(obj) > 0 else 1)
" "$existing_resp"; then
    echo "Host override for '${tag}' already exists, skipping creation." >&2
    return
  fi

  echo "Creating Host override for '${tag}' (advertises ${REALITY_SUBDOMAIN}.${BASE_DOMAIN}:443 in subscription links)..." >&2
  local body resp
  export HOST_INBOUND_ID="$inbound_id" HOST_ADDRESS="${REALITY_SUBDOMAIN}.${BASE_DOMAIN}"
  body="$(python3 << 'HOSTEOF'
import json,os
print(json.dumps({
    'inboundIds': [int(os.environ['HOST_INBOUND_ID'])],
    'remark': 'Reality direct',
    'port': 443,
    'security': 'same',
    'hosts': [os.environ['HOST_ADDRESS']],
}))
HOSTEOF
  )"
  resp="$(api_curl -X POST "${BASE_URL}/panel/api/hosts/add" \
    -H 'Content-Type: application/json' -d "$body")"
  python3 -c "
import json,sys
try:
    sys.exit(0 if json.loads(sys.argv[1]).get('success') else 1)
except Exception:
    sys.exit(1)
" "$resp" || die "Failed to create Host override for '${tag}'. Response: ${resp}"
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
  export CUR_SETTINGS="$current_settings" SUB_PORT_ARG="$SUB_PORT" SUB_PATH_ARG="$SUB_PATH" SUB_DOMAIN_ARG="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  updated_settings="$(python3 << 'SUBEOF'
import json,os,sys

resp = json.loads(os.environ['CUR_SETTINGS'])
if not resp.get('success'):
    print('Failed to fetch current settings:', resp.get('msg',''), file=sys.stderr)
    sys.exit(1)

settings = resp.get('obj') or {}
settings['subEnable'] = True
settings['subPort'] = int(os.environ['SUB_PORT_ARG'])
settings['subPath'] = os.environ['SUB_PATH_ARG'].lstrip('/')
settings['subListen'] = '127.0.0.1'
if os.environ.get('SUB_DOMAIN_ARG'):
    sub_path = os.environ['SUB_PATH_ARG'].strip('/')
    settings['subURI'] = 'https://' + os.environ['SUB_DOMAIN_ARG'] + '/' + sub_path + '/'
    settings['subDomain'] = ''
print(json.dumps(settings))
SUBEOF
  )" ||
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

configure_xray_config() {
  # Configures xray outbounds (direct, warp, blocked) and routing rules.
  # Registers a fresh WARP account (purging any existing one first), builds
  # the wireguard outbound from the registration response, and saves the
  # full xray config via POST /panel/api/xray/update.
  echo "Configuring xray outbounds and routing rules..." >&2

  # Step 1: Purge existing WARP data and register fresh
  echo "Purging existing WARP data..." >&2
  api_curl -X POST "${BASE_URL}/panel/api/xray/warp/del" >/dev/null 2>&1 || true

  if ! command -v wg >/dev/null 2>&1; then
    apt-get install -y wireguard-tools >&2 || die "Failed to install wireguard-tools."
  fi

  local private_key public_key
  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"

  echo "Registering WARP..." >&2
  local reg_resp
  reg_resp="$(api_curl -X POST "${BASE_URL}/panel/api/xray/warp/reg" \
    --data-urlencode "privateKey=${private_key}" \
    --data-urlencode "publicKey=${public_key}")"

  # Step 2: Get current xray config
  local current_xray
  current_xray="$(api_curl -X POST "${BASE_URL}/panel/api/xray/")"

  # Step 3: Build the full xray config with WARP outbound + routing rules
  local build_output
  export REG_RESP="$reg_resp" CURRENT_XRAY="$current_xray"
  build_output="$(python3 << 'PYEOF'
import json,os,sys,base64

# Parse registration response
reg = json.loads(os.environ['REG_RESP'])
if not reg.get('success'):
    print('WARP registration failed:', reg.get('msg',''), file=sys.stderr)
    sys.exit(1)

reg_obj = reg.get('obj', '')
if isinstance(reg_obj, str):
    reg_data = json.loads(reg_obj)
else:
    reg_data = reg_obj

# Extract credentials from the registration response
# Structure: obj.config.config.peers/interface (nested), obj.data.private_key
warp_private_key = reg_data['data']['private_key']
client_id = reg_data['data'].get('client_id', '')
cfg = reg_data['config']['config']
peer_pub = cfg['peers'][0]['public_key']
endpoint = cfg['peers'][0]['endpoint']['host']
addr_v4 = cfg['interface']['addresses']['v4']
addr_v6 = cfg['interface']['addresses']['v6']

reserved = list(base64.b64decode(client_id + '==')[:3]) if client_id else [0, 0, 0]

warp_outbound = {
    'tag': 'warp',
    'protocol': 'wireguard',
    'settings': {
        'mtu': 1420,
        'secretKey': warp_private_key,
        'address': [addr_v4 + '/32', addr_v6 + '/128'],
        'reserved': reserved,
        'domainStrategy': 'ForceIPv4v6',
        'peers': [{
            'publicKey': peer_pub,
            'endpoint': endpoint,
        }],
        'noKernelTun': True,
    },
}

# Parse current xray config
xray_resp = json.loads(os.environ['CURRENT_XRAY'])
if not xray_resp.get('success'):
    print('Failed to fetch xray config:', xray_resp.get('msg',''), file=sys.stderr)
    sys.exit(1)

obj = xray_resp.get('obj', {})
if isinstance(obj, str):
    obj = json.loads(obj)

xray_setting_raw = obj.get('xraySetting', '{}') if isinstance(obj, dict) else '{}'
if isinstance(xray_setting_raw, dict):
    xray_config = xray_setting_raw
elif isinstance(xray_setting_raw, str) and xray_setting_raw:
    xray_config = json.loads(xray_setting_raw)
else:
    xray_config = {}

# Set outbounds (replacing any existing wireguard outbound with fresh one)
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

output = {'xray_config': xray_config, 'warp_outbound': warp_outbound}
print(json.dumps(output))
PYEOF
  )" || die "Failed to build xray config."

  local updated_xray warp_outbound_json
  export BUILD_OUTPUT="$build_output"
  updated_xray="$(python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["BUILD_OUTPUT"])["xray_config"]))')"
  warp_outbound_json="$(python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["BUILD_OUTPUT"])["warp_outbound"]))')"

  # Step 4: Save xray config
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
" "$resp" || die "Failed to save xray config."

  echo "Xray config saved. Testing WARP outbound..." >&2

  # Step 5: Test the WARP outbound
  sleep 2
  local test_resp
  test_resp="$(api_curl -X POST "${BASE_URL}/panel/api/xray/testOutbound" \
    --data-urlencode "outbound=${warp_outbound_json}" \
    --data-urlencode "mode=real")"

  python3 -c "
import json,sys
try:
    data = json.loads(sys.argv[1])
    if data.get('success'):
        obj = data.get('obj', {})
        if isinstance(obj, list):
            obj = obj[0] if obj else {}
        if obj.get('success'):
            print(f\"WARP test passed: {obj.get('delay',0)}ms, egress={obj.get('egress',{}).get('country','?')}\", file=sys.stderr)
        else:
            print(f\"WARNING: WARP test failed: {obj.get('error','unknown')}\", file=sys.stderr)
    else:
        print(f\"WARNING: WARP test request failed: {data.get('msg','unknown')}\", file=sys.stderr)
except Exception as e:
    print(f'WARNING: Could not parse test response: {e}', file=sys.stderr)
" "$test_resp"

  echo "Xray outbounds and routing configured." >&2
}

# Runs the full 3x-ui install + inbound configuration sequence (formerly
# setup-3x-ui.sh's main()). Populates the shared globals every function
# above reads/writes directly -- no serialization across a process boundary.
run_xui_install_and_inbounds() {
  [[ -n "$CLIENT_UUID" ]] || CLIENT_UUID="$(generate_uuid)"
  [[ -n "$CLIENT_SUB_ID" ]] || CLIENT_SUB_ID="$(openssl rand -hex 8)"

  if xui_is_installed; then
    echo "3x-ui is already installed, skipping installer (reusing its existing credentials/port/path)." >&2
  else
    install_xui
    update_geo_files
  fi

  read_install_result
  wait_for_panel
  setup_api_auth
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    ensure_vless_encryption_keys
    ensure_ws_inbound
    ensure_xhttp_inbound
    ensure_grpc_inbound
  else
    ensure_hysteria_inbound
    ensure_reality_keys
    ensure_reality_inbound
    ensure_reality_host
  fi
  configure_subscription
  configure_xray_config

  echo "Inbounds ready." >&2
}

install_3xui_and_inbounds() {
  echo
  echo "=== Installing 3x-ui and configuring inbounds ==="
  echo "(3x-ui is the source of truth for its own username/password/port/path;"
  echo " they are generated by its installer, not dictated by this script.)"

  run_xui_install_and_inbounds

  PANEL_PORT="$XUI_PANEL_PORT"
  PANEL_PATH="/${XUI_WEB_BASE_PATH#/}"

  [[ -n "$PANEL_PORT" && -n "$PANEL_PATH" && -n "$XUI_USERNAME" && -n "$XUI_PASSWORD" && -n "$CLIENT_UUID" ]] ||
    die "3x-ui install/configuration did not produce PANEL_PORT/PANEL_PATH/XUI_USERNAME/XUI_PASSWORD/CLIENT_UUID."

  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    [[ -n "$VLESS_ENCRYPTION_SERVER_KEY" && -n "$VLESS_ENCRYPTION_CLIENT_KEY" ]] ||
      die "CDN installation did not produce VLESS Encryption keys."
  fi

  # Reality is optional -- only require its keys back when the feature is
  # actually enabled (REALITY_SUBDOMAIN set).
  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] ||
      die "REALITY_PRIVATE_KEY/REALITY_PUBLIC_KEY were not produced even though REALITY_SUBDOMAIN is set."
  fi

  validate_panel_port

  save_config
}

anonymize_vps() {
  local script_dir anonymize_script
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

  # HARDEN_HOST_SCRIPT allows tests to stub harden-host.sh without touching
  # the real file. Not meant to be set outside of tests.
  anonymize_script="${HARDEN_HOST_SCRIPT:-${ANONYMIZE_SCRIPT:-${script_dir}/harden-host.sh}}"

  if [[ ! -x "$anonymize_script" ]]; then
    echo "WARNING: harden-host.sh not found next to setup.sh (expected ${anonymize_script}); skipping host hardening." >&2
    return
  fi

  echo
  echo "=== Hardening host (clock sync, DNS, sysctl, ICMP, TTL, banners) ==="
  "$anonymize_script" || echo "WARNING: harden-host.sh reported an error; continuing (this is not fatal to the proxy setup)." >&2
}

print_client_links() {
  echo
  echo "=== 3x-ui panel credentials (generated by the 3x-ui installer) ==="
  echo "  Username: ${XUI_USERNAME}"
  echo "  Password: ${XUI_PASSWORD}"
  echo "  URL:      https://${PANEL_SUBDOMAIN}.${BASE_DOMAIN}${PANEL_PATH}/"
  echo
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    echo "=== Client VLESS URIs (ready to import into your client app) ==="
    echo "vless://${CLIENT_UUID}@${VLESS_SUBDOMAIN}.${BASE_DOMAIN}:443?type=ws&security=tls&encryption=${VLESS_ENCRYPTION_CLIENT_KEY}&path=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')&host=${VLESS_SUBDOMAIN}.${BASE_DOMAIN}#${INBOUND_REMARK_WS}"
    echo "vless://${CLIENT_UUID}@${VLESS_SUBDOMAIN}.${BASE_DOMAIN}:443?type=grpc&security=tls&encryption=${VLESS_ENCRYPTION_CLIENT_KEY}&serviceName=${GRPC_SERVICE}&mode=gun&host=${VLESS_SUBDOMAIN}.${BASE_DOMAIN}#${INBOUND_REMARK_GRPC}"
    echo "vless://${CLIENT_UUID}@${VLESS_SUBDOMAIN}.${BASE_DOMAIN}:443?type=xhttp&security=tls&encryption=${VLESS_ENCRYPTION_CLIENT_KEY}&flow=xtls-rprx-vision&path=$(printf '%s' "$XHTTP_PATH" | sed 's#/#%2F#g')&mode=packet-up&host=${VLESS_SUBDOMAIN}.${BASE_DOMAIN}#${INBOUND_REMARK_XHTTP}"
  fi

  if [[ -n "$HYSTERIA_SUBDOMAIN" ]]; then
    echo
    echo "=== Hysteria2 (direct UDP/QUIC) ==="
    echo "  Server: ${HYSTERIA_SUBDOMAIN}.${BASE_DOMAIN}:${HYSTERIA_PORT}"
    echo "  Auth: ${HYSTERIA_AUTH}"
    echo "  Salamander password: ${HYSTERIA_OBFS_PASSWORD}"
    echo "  SNI: ${HYSTERIA_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  Note: Salamander disables normal HTTP/3 masquerading."
  fi

  if [[ -n "$REALITY_SUBDOMAIN" ]]; then
    echo "vless://${CLIENT_UUID}@${REALITY_SUBDOMAIN}.${BASE_DOMAIN}:443?type=tcp&security=reality&pbk=${REALITY_PUBLIC_KEY}&fp=chrome&sni=${REALITY_DEST}&sid=${REALITY_SHORT_ID}&flow=xtls-rprx-vision&encryption=none#${INBOUND_REMARK_REALITY}"
  fi

  if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
    echo
    echo "=== NaiveProxy (HTTPS forward proxy, not a VLESS client) ==="
    echo "  Server: ${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  Port:   443"
    echo "  Username: ${NAIVE_USERNAME}"
    echo "  Password: ${NAIVE_PASSWORD}"
    echo "  Client config (Caddy/naiveproxy-compatible client):"
    echo "    https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}"
  fi

  if [[ -n "$MIERU_SUBDOMAIN" ]]; then
    echo
    echo "=== mieru (direct connection, username/password, no TLS/SNI) ==="
    echo "  Server: ${MIERU_SUBDOMAIN}.${BASE_DOMAIN}"
    echo "  Port:     ${MIERU_PORT}"
    echo "  Protocol: ${MIERU_PROTOCOL}"
    echo "  Username: ${MIERU_USERNAME}"
    echo "  Password: ${MIERU_PASSWORD}"
    echo "  Client config (mieru client, JSON profile):"
    echo "    {\"profiles\":[{\"profileName\":\"default\",\"servers\":[{\"ipAddress\":\"${MIERU_SUBDOMAIN}.${BASE_DOMAIN}\",\"portBindings\":[{\"port\":${MIERU_PORT},\"protocol\":\"${MIERU_PROTOCOL}\"}]}],\"user\":{\"name\":\"${MIERU_USERNAME}\",\"password\":\"${MIERU_PASSWORD}\"},\"mtu\":1400}],\"activeProfile\":\"default\"}"
  fi
}

verify_deployment() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local all_ok=true

  echo
  echo "=== Post-configuration verification ==="
  echo
  echo "Checking local listeners..."

  local listener_checks=("Panel:$PANEL_PORT" "Subscription:$SUB_PORT")
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    listener_checks+=("WebSocket:$WS_PORT" "gRPC:$GRPC_PORT" "XHTTP:$XHTTP_PORT")
  fi
  [[ -z "$REALITY_SUBDOMAIN" ]] || listener_checks+=("Reality:$REALITY_PORT")
  # Hysteria2 is UDP; its listener is verified separately below.
  [[ -z "$NAIVE_SUBDOMAIN" ]] || listener_checks+=("NaiveProxy:$NAIVE_PORT")
  # mieru may be TCP or UDP; verified separately below since it needs the
  # protocol-appropriate ss check.
  if [[ -n "$MIERU_SUBDOMAIN" && "$MIERU_PROTOCOL" == "TCP" ]]; then
    listener_checks+=("mieru:$MIERU_PORT")
  fi

  for check in "${listener_checks[@]}"; do
    local check_name="${check%%:*}"
    local check_port="${check#*:}"

    if port_is_listening "$check_port"; then
      echo "  [OK]   ${check_name} is listening on 127.0.0.1:${check_port}"
    else
      echo "  [FAIL] ${check_name} is NOT listening on 127.0.0.1:${check_port}"
      all_ok=false
    fi
  done

  if [[ -n "$HYSTERIA_SUBDOMAIN" ]]; then
    if port_is_udp_listening "$HYSTERIA_PORT"; then
      echo "  [OK]   Hysteria2 is listening on UDP :${HYSTERIA_PORT}"
    else
      echo "  [FAIL] Hysteria2 is NOT listening on UDP :${HYSTERIA_PORT}"
      all_ok=false
    fi
  fi

  if [[ -n "$MIERU_SUBDOMAIN" && "$MIERU_PROTOCOL" == "UDP" ]]; then
    if port_is_udp_listening "$MIERU_PORT"; then
      echo "  [OK]   mieru is listening on UDP :${MIERU_PORT}"
    else
      echo "  [FAIL] mieru is NOT listening on UDP :${MIERU_PORT}"
      all_ok=false
    fi
  fi

  echo
  echo "Checking public HTTPS endpoints..."

  if command -v curl >/dev/null 2>&1; then
    local panel_status
    panel_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${panel_domain}${PANEL_PATH}/" || echo "000")"

    if [[ "$panel_status" =~ ^(2|3)[0-9][0-9]$ ]]; then
      echo "  [OK]   https://${panel_domain}${PANEL_PATH}/ responded with HTTP ${panel_status}"
    else
      echo "  [FAIL] https://${panel_domain}${PANEL_PATH}/ responded with HTTP ${panel_status} (or was unreachable)"
      all_ok=false
    fi

    local vless_status
    vless_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${vless_domain}/" || echo "000")"

    if [[ "$vless_status" =~ ^[0-9][0-9][0-9]$ && "$vless_status" != "000" ]]; then
      echo "  [OK]   TLS handshake to https://${vless_domain}/ succeeded (HTTP ${vless_status}, 404 is expected here)"
    else
      echo "  [FAIL] Could not complete a TLS handshake to https://${vless_domain}/"
      all_ok=false
    fi

    if [[ -n "$NAIVE_SUBDOMAIN" ]]; then
      local naive_domain="${NAIVE_SUBDOMAIN}.${BASE_DOMAIN}"
      local naive_status
      naive_status="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${naive_domain}/" || echo "000")"

      if [[ "$naive_status" =~ ^(2|3)[0-9][0-9]$ ]]; then
        echo "  [OK]   https://${naive_domain}/ responded with HTTP ${naive_status} (decoy content, as expected for an unauthenticated request)"
      else
        echo "  [FAIL] https://${naive_domain}/ responded with HTTP ${naive_status} (or was unreachable)"
        all_ok=false
      fi
    fi

    # Reality's own SNI (the donor site) isn't reachable through a plain
    # curl request the way the checks above are -- a real client presenting
    # the correct SNI/Reality handshake is the only meaningful test. Its
    # local listener above is the extent of what's checked automatically
    # here; verify Reality manually with a real client after setup.
  else
    echo "  [SKIP] curl not available for HTTPS checks."
  fi

  echo

  if [[ "$all_ok" == true ]]; then
    echo "All checks passed."
  else
    echo "Some checks failed. Verify your 3x-ui/Xray configuration matches the ports/paths above,"
    echo "then re-run the checks manually:"
    echo "  ss -lntp | egrep ':${PANEL_PORT}|:${SUB_PORT}|:${WS_PORT}|:${GRPC_PORT}|:${XHTTP_PORT}'"
    echo "  curl -vk https://${panel_domain}${PANEL_PATH}/"
    echo "  curl -vk https://${vless_domain}/"
  fi
}

uninstall_all() {
  local script_dir anonymize_script answer
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
  anonymize_script="${HARDEN_HOST_SCRIPT:-${ANONYMIZE_SCRIPT:-${script_dir}/harden-host.sh}}"
  DELETE_CERT="${DELETE_CERT:-false}"

  require_root
  load_config

  echo "=== Uninstalling 3x-ui-cf-setup ==="
  echo "This removes: the Nginx site/Cloudflare-real-IP config, the Certbot"
  echo "deploy hook, the Cloudflare API token file, the UFW rules this script"
  echo "added, 3x-ui itself (service, binary, /etc/x-ui, /usr/local/x-ui), and"
  echo "this script's saved config/state files."
  echo
  echo "The Let's Encrypt certificate for '${BASE_DOMAIN:-<unknown -- none configured>}'"
  echo "is KEPT by default (Let's Encrypt rate-limits reissuance to 5 certs per"
  echo "exact domain set per 7 days -- deleting it needlessly on every"
  echo "uninstall/reinstall cycle burns that quota). Pass --delete-cert to also"
  echo "remove it."
  echo
  read -r -p "Continue? [y/N]: " answer

  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac

  echo
  echo "--- Nginx ---"
  rm -f "$NGINX_SITE_ENABLED" "$NGINX_SITE" "$CF_REAL_IP_CONF" "$FALLBACK_HTML_DEST"
  if [[ -e "$NGINX_DEFAULT_SITE_BACKUP" || -L "$NGINX_DEFAULT_SITE_BACKUP" ]]; then
    if [[ -e "$NGINX_DEFAULT_SITE" || -L "$NGINX_DEFAULT_SITE" ]]; then
      echo "Keeping existing ${NGINX_DEFAULT_SITE}; preserved default site remains at ${NGINX_DEFAULT_SITE_BACKUP}." >&2
    else
      mv "$NGINX_DEFAULT_SITE_BACKUP" "$NGINX_DEFAULT_SITE"
    fi
  fi
  rm -f "${NGINX_STREAM_CONF:-/etc/nginx/stream.d/3xui-proxy-sni-guard.conf}"
  unensure_nginx_stream_context
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx || systemctl restart nginx) || true
  fi

  echo "--- Certbot ---"
  rm -f "$CERTBOT_DEPLOY_HOOK"
  if [[ "$DELETE_CERT" == true ]] && [[ -n "${BASE_DOMAIN:-}" ]] && command -v certbot >/dev/null 2>&1; then
    echo "Deleting certificate for ${BASE_DOMAIN} (--delete-cert was passed)..."
    certbot delete --cert-name "$BASE_DOMAIN" --non-interactive >/dev/null 2>&1 || true
  else
    echo "Keeping existing certificate for ${BASE_DOMAIN:-<unknown>} (pass --delete-cert to remove it)."
  fi
  rm -f "$CF_CREDENTIALS"

  echo "--- UFW ---"
  if command -v ufw >/dev/null 2>&1; then
    # SSH is never touched -- this script never added an SSH rule, so it
    # never removes one either (see configure_ufw).
    # Remove the 443 allow rule this script owns, plus any leftover
    # per-range Cloudflare-only allow rules from installs predating direct-
    # connection inbounds (VLESS+Reality, NaiveProxy).
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
    if [[ -f "$CF_IP_STATE_FILE" ]]; then
      while IFS= read -r cf_range; do
        [[ -n "$cf_range" ]] || continue
        ufw delete allow from "$cf_range" to any port 443 proto tcp >/dev/null 2>&1 || true
      done < "$CF_IP_STATE_FILE"
    fi
    ufw delete deny 443/tcp >/dev/null 2>&1 || true
    ufw delete deny 80/tcp >/dev/null 2>&1 || true
    for p in "${PANEL_PORT:-}" "${SUB_PORT:-}" "${WS_PORT:-}" "${GRPC_PORT:-}" "${XHTTP_PORT:-}" "${REALITY_PORT:-}" "${NAIVE_PORT:-}" "${NGINX_CDN_PORT:-}" "${NGINX_DECOY_PORT:-}"; do
      [[ -n "$p" ]] && ufw delete deny "${p}/tcp" >/dev/null 2>&1 || true
    done
    if [[ -n "${MIERU_PORT:-}" ]]; then
      ufw delete allow "${MIERU_PORT}/tcp" >/dev/null 2>&1 || true
      ufw delete allow "${MIERU_PORT}/udp" >/dev/null 2>&1 || true
    fi
    ufw reload >/dev/null 2>&1 || true
  fi

  echo "--- mieru ---"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop mita >/dev/null 2>&1 || true
    systemctl disable mita >/dev/null 2>&1 || true
  fi
  if command -v dpkg >/dev/null 2>&1 && dpkg -l mita >/dev/null 2>&1; then
    apt-get purge -y mita >/dev/null 2>&1 || true
  fi
  # dpkg purge does not own these runtime-created paths -- mieru's own
  # upstream uninstaller (tools/setup.py Uninstaller.uninstall_mita) removes
  # them explicitly too, for the same reason.
  rm -rf /etc/mita
  rm -rf /var/lib/mita
  rm -f /var/run/mita.sock
  rm -rf /var/run/mita
  rm -f /lib/systemd/system/mita.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  # The deb package creates a dedicated 'mita' system user/group (for socket
  # access, see server-install.md's 'usermod -a -G mita $USER' step).
  userdel mita >/dev/null 2>&1 || true
  groupdel mita >/dev/null 2>&1 || true
  rm -rf "${MITA_CONFIG_DIR:-/etc/mieru}"
  rm -rf "$(dirname -- "${MITA_VERSION_FILE:-/usr/local/mieru/.installed-version}")"

  echo "--- NaiveProxy ---"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true
  fi
  rm -f "${NAIVE_SYSTEMD_UNIT:-/etc/systemd/system/caddy.service}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f "${CADDYFILE:-/etc/caddy/Caddyfile}"
  rm -f "${NAIVE_BIN:-/usr/bin/caddy}"
  rm -rf "$(dirname -- "${NAIVE_VERSION_FILE:-/usr/local/naiveproxy/.installed-version}")"
  rm -rf "${NAIVE_DOCROOT:-/var/www/naiveproxy}"

  echo "--- 3x-ui ---"
  if xui_is_installed || [[ -d /usr/local/x-ui ]] || [[ -f "$XUI_SERVICE_UNIT" ]]; then
    echo "Uninstalling 3x-ui..."

    # Try 3x-ui's own uninstall path first (best-effort, non-interactive:
    # 'y' piped in for any confirmation prompt). Then force-remove everything
    # regardless, so this is idempotent and complete even if that CLI path
    # changes between versions or the install is partially broken.
    if command -v x-ui >/dev/null 2>&1; then
      yes y 2>/dev/null | x-ui uninstall || true
    fi

    systemctl stop x-ui >/dev/null 2>&1 || true
    systemctl disable x-ui >/dev/null 2>&1 || true
    pkill -f 'mtg-linux-[^ ]* run ' >/dev/null 2>&1 || true

    rm -f "$XUI_SERVICE_UNIT"
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -rf /etc/x-ui
    rm -rf /usr/local/x-ui
    rm -f /usr/bin/x-ui

    echo "3x-ui fully removed."
  else
    echo "3x-ui is not installed, nothing to uninstall."
  fi

  echo "--- VPS anonymization ---"
  if [[ -x "$anonymize_script" ]]; then
    "$anonymize_script" --uninstall || echo "WARNING: harden-host.sh --uninstall reported an error; check manually." >&2
  else
    echo "WARNING: harden-host.sh not found next to setup.sh (expected ${anonymize_script}); skipping host-hardening revert." >&2
  fi

  echo "--- Local state ---"
  rm -f "$STATE_FILE" "$CF_IP_STATE_FILE" "$CONFIG_FILE"

  echo
  echo "Done. Uninstall complete."
}

main() {
  if [[ "${1:-}" == "--uninstall" ]]; then
    if [[ "${2:-}" == "--delete-cert" ]]; then
      DELETE_CERT=true
    fi
    uninstall_all
    return
  fi

  require_root
  load_config
  collect_input
  save_config

  CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"

  confirm_configuration

  VPS_FLAG="$(detect_country_flag)"
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    INBOUND_REMARK_WS="${VPS_FLAG} WebSocket-CDN"
    INBOUND_REMARK_GRPC="${VPS_FLAG} gRPC-CDN"
    INBOUND_REMARK_XHTTP="${VPS_FLAG} XHTTP-CDN"
  else
    INBOUND_REMARK_REALITY="${VPS_FLAG} TCP-Reality"
  fi

  install_packages
  install_naiveproxy
  install_mieru
  anonymize_vps
  write_cloudflare_credentials
  issue_certificate
  install_certbot_hook
  install_3xui_and_inbounds
  write_caddyfile
  write_naive_systemd_unit
  write_mieru_config
  if [[ "$INSTALL_MODE" == "cdn" ]]; then
    write_cloudflare_real_ip_config
  else
    rm -f "$CF_REAL_IP_CONF"
  fi
  write_nginx_config
  configure_ufw
  print_summary
  save_config
  print_client_links
  verify_deployment
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
