#!/usr/bin/env bash
set -euo pipefail

BASE_DOMAIN=""
PANEL_SUBDOMAIN="admin"
VLESS_SUBDOMAIN="vpn"
PANEL_PATH="/my-admin"
EMAIL=""
SSH_PORT="22"

PANEL_PORT="2053"
WS_PORT=""
GRPC_PORT=""

WS_PATH="/api/v1/events"
GRPC_SERVICE="api.v1.SyncService"

CERT_DIR=""
CF_CREDENTIALS="/etc/letsencrypt/cloudflare.ini"

NGINX_SITE="/etc/nginx/sites-available/3xui-proxy"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/3xui-proxy"

CF_REAL_IP_CONF="/etc/nginx/conf.d/cloudflare-real-ip.conf"
CERTBOT_DEPLOY_HOOK="/etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh"

STATE_FILE="/etc/nginx/.3xui-proxy-ports.state"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

TMP_FILES=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup_tmp_files() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f"
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

random_free_port() {
  local excluded_port_1="${1:-}"
  local excluded_port_2="${2:-}"
  local port=""

  while true; do
    port="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    port=$((49152 + port % 16384))

    [[ "$port" != "$excluded_port_1" ]] || continue
    [[ "$port" != "$excluded_port_2" ]] || continue

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

validate_inputs() {
  [[ "$BASE_DOMAIN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] ||
    die "Invalid base domain."

  [[ "$PANEL_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "Invalid panel subdomain."

  [[ "$VLESS_SUBDOMAIN" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "Invalid VLESS subdomain."

  [[ "$PANEL_SUBDOMAIN" != "$VLESS_SUBDOMAIN" ]] ||
    die "Panel and VLESS subdomains must be different."

  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    die "Invalid email address."

  [[ "$GRPC_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "Invalid gRPC service name."

  validate_port "SSH port" "$SSH_PORT"
  validate_port "Panel port" "$PANEL_PORT"
  validate_port "WebSocket port" "$WS_PORT"
  validate_port "gRPC port" "$GRPC_PORT"

  [[ "$SSH_PORT" != "443" ]] ||
    die "SSH port cannot be 443."

  [[ "$PANEL_PORT" != "$WS_PORT" ]] ||
    die "Panel and WebSocket ports must be different."

  [[ "$PANEL_PORT" != "$GRPC_PORT" ]] ||
    die "Panel and gRPC ports must be different."

  [[ "$WS_PORT" != "$GRPC_PORT" ]] ||
    die "WebSocket and gRPC ports must be different."

  local internal_port
  local internal_port_name
  for internal_port_name_port in \
    "Panel port:$PANEL_PORT" \
    "WebSocket port:$WS_PORT" \
    "gRPC port:$GRPC_PORT"
  do
    internal_port_name="${internal_port_name_port%%:*}"
    internal_port="${internal_port_name_port#*:}"

    [[ "$internal_port" != "443" ]] ||
      die "${internal_port_name} cannot be 443 (reserved for the public HTTPS listener)."

    [[ "$internal_port" != "$SSH_PORT" ]] ||
      die "${internal_port_name} cannot be the same as the SSH port."
  done

  normalize_panel_path
  normalize_ws_path
}

collect_input() {
  local default_ws_port=""
  local default_grpc_port=""

  echo
  echo "=== VLESS + Nginx Setup ==="
  echo

  prompt BASE_DOMAIN "Base domain, for example example.com"
  prompt PANEL_SUBDOMAIN "Panel subdomain" "$PANEL_SUBDOMAIN"
  prompt VLESS_SUBDOMAIN "VLESS subdomain" "$VLESS_SUBDOMAIN"
  prompt PANEL_PATH "Panel path" "$PANEL_PATH"
  prompt EMAIL "Let's Encrypt email"
  prompt SSH_PORT "SSH port" "$SSH_PORT"

  echo
  prompt PANEL_PORT "3x-ui local port" "$PANEL_PORT"

  validate_port "Panel port" "$PANEL_PORT"

  default_ws_port="$(random_free_port "$PANEL_PORT")"
  default_grpc_port="$(random_free_port "$PANEL_PORT" "$default_ws_port")"

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

  echo
  prompt WS_PATH "WebSocket path" "$WS_PATH"
  prompt GRPC_SERVICE "gRPC service name" "$GRPC_SERVICE"

  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    echo
    prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API Token"
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
  echo
  echo "Panel:"
  echo "  domain: ${panel_domain}"
  echo "  public/client port: 443"
  echo "  internal 3x-ui port: ${PANEL_PORT}"
  echo "  path: ${PANEL_PATH}/"
  echo
  echo "VLESS WebSocket:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${WS_PORT}"
  echo "  path: ${WS_PATH}"
  echo
  echo "VLESS gRPC:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${GRPC_PORT}"
  echo "  serviceName: ${GRPC_SERVICE}"
  echo
  echo "Firewall:"
  echo "  allowed: ${SSH_PORT}/tcp, 443/tcp"
  echo "  denied: 80/tcp, ${PANEL_PORT}/tcp, ${WS_PORT}/tcp, ${GRPC_PORT}/tcp"
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

install_packages() {
  echo "[1/8] Installing packages..."

  apt update

  apt install -y \
    nginx \
    certbot \
    python3-certbot-dns-cloudflare \
    ufw \
    curl \
    ca-certificates
}

write_cloudflare_credentials() {
  echo "[2/8] Writing Cloudflare credentials..."

  install -d -m 700 /etc/letsencrypt

  local tmp_cf_credentials
  tmp_cf_credentials="$(make_tmp_file)"

  cat > "$tmp_cf_credentials" <<EOF
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
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

write_nginx_config() {
  echo "[6/8] Writing Nginx reverse proxy configuration..."

  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local grpc_location="/${GRPC_SERVICE}"
  local tmp_nginx
  local backup=""
  local default_site_was_enabled=false

  tmp_nginx="$(make_tmp_file)"

  cat > "$tmp_nginx" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

limit_req_zone \$binary_remote_addr zone=panel_limit:10m rate=5r/s;

server {
    listen 443 ssl;
    http2 on;
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

    location ${grpc_location} {
        grpc_pass grpc://127.0.0.1:${GRPC_PORT};

        grpc_set_header Host \$host;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;

        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
    }

    location / {
        return 404;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${panel_domain};

    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    server_tokens off;

    location = ${PANEL_PATH} {
        return 301 ${PANEL_PATH}/;
    }

    location ${PANEL_PATH}/ {
        limit_req zone=panel_limit burst=5 nodelay;

        proxy_pass http://127.0.0.1:${PANEL_PORT}/;

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
EOF

  if [[ -e "$NGINX_SITE" ]]; then
    backup="${NGINX_SITE}.backup-${TIMESTAMP}"
    cp -a "$NGINX_SITE" "$backup"
  fi

  if [[ -e /etc/nginx/sites-enabled/default ]]; then
    default_site_was_enabled=true
  fi

  mv "$tmp_nginx" "$NGINX_SITE"
  chmod 644 "$NGINX_SITE"

  ln -sfn "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  rm -f /etc/nginx/sites-enabled/default

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

    if [[ "$default_site_was_enabled" == true ]]; then
      ln -sfn \
        /etc/nginx/sites-available/default \
        /etc/nginx/sites-enabled/default
    fi

    nginx -t || true
    exit 1
  fi

  systemctl reload nginx || systemctl restart nginx
}

configure_ufw() {
  echo "[7/8] Configuring UFW..."

  local prev_panel_port=""
  local prev_ws_port=""
  local prev_grpc_port=""

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    prev_panel_port="${STATE_PANEL_PORT:-}"
    prev_ws_port="${STATE_WS_PORT:-}"
    prev_grpc_port="${STATE_GRPC_PORT:-}"
  fi

  # Remove stale deny rules left over from a previous run with different ports.
  for stale_port in "$prev_panel_port" "$prev_ws_port" "$prev_grpc_port"; do
    if [[ -n "$stale_port" ]] &&
       [[ "$stale_port" != "$PANEL_PORT" ]] &&
       [[ "$stale_port" != "$WS_PORT" ]] &&
       [[ "$stale_port" != "$GRPC_PORT" ]]; then
      ufw delete deny "${stale_port}/tcp" || true
    fi
  done

  ufw allow "${SSH_PORT}/tcp"
  ufw allow 443/tcp

  ufw deny 80/tcp || true
  ufw deny "${PANEL_PORT}/tcp" || true
  ufw deny "${WS_PORT}/tcp" || true
  ufw deny "${GRPC_PORT}/tcp" || true

  ufw --force enable
  ufw reload

  cat > "$STATE_FILE" <<EOF
STATE_PANEL_PORT=${PANEL_PORT}
STATE_WS_PORT=${WS_PORT}
STATE_GRPC_PORT=${GRPC_PORT}
EOF
  chmod 600 "$STATE_FILE"
}

print_summary() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"

  echo "[8/8] Done."
  echo
  echo "Panel:"
  echo "  URL: https://${panel_domain}${PANEL_PATH}/"
  echo "  public/client port: 443"
  echo "  internal 3x-ui port: ${PANEL_PORT}"
  echo
  echo "VLESS WebSocket:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${WS_PORT}"
  echo "  security: tls"
  echo "  network: ws"
  echo "  path: ${WS_PATH}"
  echo
  echo "VLESS gRPC:"
  echo "  domain: ${vless_domain}"
  echo "  public/client port: 443"
  echo "  internal Xray port: ${GRPC_PORT}"
  echo "  security: tls"
  echo "  network: grpc"
  echo "  serviceName: ${GRPC_SERVICE}"
  echo
  echo "UFW:"
  echo "  allowed: ${SSH_PORT}/tcp, 443/tcp"
  echo "  denied: 80/tcp, ${PANEL_PORT}/tcp, ${WS_PORT}/tcp, ${GRPC_PORT}/tcp"
  echo "  22/tcp was NOT opened unless you selected port 22."
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
  echo "  ss -lntp | egrep ':443|:${PANEL_PORT}|:${WS_PORT}|:${GRPC_PORT}'"
}

verify_deployment() {
  local panel_domain="${PANEL_SUBDOMAIN}.${BASE_DOMAIN}"
  local vless_domain="${VLESS_SUBDOMAIN}.${BASE_DOMAIN}"
  local answer=""
  local all_ok=true

  echo
  echo "=== Post-configuration verification ==="
  echo
  echo "Now go configure 3x-ui / Xray to listen on:"
  echo "  Panel:  127.0.0.1:${PANEL_PORT}${PANEL_PATH}/"
  echo "  WS:     127.0.0.1:${WS_PORT}, path ${WS_PATH}"
  echo "  gRPC:   127.0.0.1:${GRPC_PORT}, serviceName ${GRPC_SERVICE}"
  echo
  read -r -p "Press Enter once 3x-ui/Xray are configured and running (or type 's' to skip verification): " answer

  if [[ "$answer" == "s" || "$answer" == "S" ]]; then
    echo "Skipping verification. Run this script's checks manually later if needed."
    return
  fi

  echo
  echo "Checking local listeners..."

  for check in "Panel:$PANEL_PORT" "WebSocket:$WS_PORT" "gRPC:$GRPC_PORT"; do
    local check_name="${check%%:*}"
    local check_port="${check#*:}"

    if port_is_listening "$check_port"; then
      echo "  [OK]   ${check_name} is listening on 127.0.0.1:${check_port}"
    else
      echo "  [FAIL] ${check_name} is NOT listening on 127.0.0.1:${check_port}"
      all_ok=false
    fi
  done

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
  else
    echo "  [SKIP] curl not available for HTTPS checks."
  fi

  echo

  if [[ "$all_ok" == true ]]; then
    echo "All checks passed."
  else
    echo "Some checks failed. Verify your 3x-ui/Xray configuration matches the ports/paths above,"
    echo "then re-run the checks manually:"
    echo "  ss -lntp | egrep ':${PANEL_PORT}|:${WS_PORT}|:${GRPC_PORT}'"
    echo "  curl -vk https://${panel_domain}${PANEL_PATH}/"
    echo "  curl -vk https://${vless_domain}/"
  fi
}

main() {
  require_root
  collect_input

  CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"

  confirm_configuration
  install_packages
  write_cloudflare_credentials
  issue_certificate
  install_certbot_hook
  write_cloudflare_real_ip_config
  write_nginx_config
  configure_ufw
  print_summary
  verify_deployment
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
