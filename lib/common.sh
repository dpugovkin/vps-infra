#!/usr/bin/env bash
# Self-contained helpers for infra engines (logging + env loading).
# Intentionally has NO project/app/DB knowledge — infra stays agnostic.

infra_use_color() {
  [[ -t 2 && -z "${NO_COLOR:-}" ]] || [[ -n "${FORCE_COLOR:-}" ]]
}
_c() { if infra_use_color; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

log()        { printf '%s %s\n' "$(_c 36 '•')" "$*"; }
log_step()   { printf '\n%s %s\n' "$(_c '1;36' '▶')" "$*"; }
log_ok()     { printf '%s %s\n' "$(_c 32 '✓')" "$*"; }
log_detail() { printf '   %s\n' "$*"; }
log_warn()   { printf '%s %s\n' "$(_c 33 '!')" "$*" >&2; }
log_error()  { printf '%s %s\n' "$(_c 31 '✗')" "$*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "Run as root."
    exit 1
  fi
}

# Reject anything that is not a plain SQL identifier (db/user name).
validate_identifier() { # $1=name $2=value
  [[ "$2" =~ ^[A-Za-z0-9_]+$ ]] || { log_error "$1 must contain only [A-Za-z0-9_]: '$2'"; exit 1; }
}
# Reject anything that is not a hostname.
validate_hostname() { # $1=name $2=value
  [[ "$2" =~ ^[A-Za-z0-9.-]+$ ]] || { log_error "$1 is not a valid hostname: '$2'"; exit 1; }
}
# Generic charset guard; $3 is an ERE matched with =~ (pass unquoted regex string).
validate_charset() { # $1=name $2=value $3=regex
  [[ "$2" =~ $3 ]] || { log_error "$1 has invalid characters: '$2'"; exit 1; }
}
# Reject characters that would break/inject a single-quoted SQL string literal.
validate_password_literal() { # $1=name $2=value
  case "$2" in
    *\'*|*\\*|*$'\n'*) log_error "$1 contains a forbidden character (single-quote, backslash, or newline)"; exit 1 ;;
  esac
}

# Render, validate, and reload the edge nginx vhost for a project.
# Preserves the cert-guard invariant: never writes a 443-ssl vhost whose cert
# files do not already exist inside the nginx container.
# Usage: render_edge_vhost <project_name> <domain> <upstream> <csp> <manifest_path>
render_edge_vhost() {
  local PROJECT_NAME="$1"
  local DOMAIN="$2"
  local UPSTREAM="$3"
  local CSP="$4"
  local MANIFEST_PATH="$5"
  local MANIFEST_DIR; MANIFEST_DIR="$(dirname "${MANIFEST_PATH}")"

  log_step "Rendering nginx vhost for ${DOMAIN}"
  local CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
  if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T nginx test -f "${CERT_PATH}" 2>/dev/null; then
    local VHOST_OUT="${SCRIPT_DIR}/nginx/conf.d/${PROJECT_NAME}.conf"
    local CSP_VALUE="${CSP:-default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'}"
    # Per-project opt-in nginx location policy (e.g. rate-limited login). The project may
    # ship deploy/nginx-locations.conf next to its manifest; infra installs it blindly.
    local LOC_DIR="${SCRIPT_DIR}/nginx/conf.d/locations/${PROJECT_NAME}"
    mkdir -p "${LOC_DIR}"
    local PROJECT_LOCATIONS="${MANIFEST_DIR}/nginx-locations.conf"
    if [[ -f "${PROJECT_LOCATIONS}" ]]; then
      cp "${PROJECT_LOCATIONS}" "${LOC_DIR}/locations.conf"
      log_detail "Installed project nginx locations from ${PROJECT_LOCATIONS}"
    fi
    sed -e "s/PROD_DOMAIN/${DOMAIN}/g" -e "s#__UPSTREAM__#${UPSTREAM}#g" -e "s#__CSP__#${CSP_VALUE}#g" \
      -e "s#__PROJECT_NAME__#${PROJECT_NAME}#g" \
      "${SCRIPT_DIR}/nginx/conf.d/vhost.conf.template" > "${VHOST_OUT}"
    # Optional www -> apex 301 redirect (opt-in via WWW_REDIRECT=1 in the manifest).
    # The cert referenced above MUST also cover www.<domain>; expand it first with an extra
    # `-d www.<domain> --expand`. nginx still boots if www is absent from the cert (the file
    # exists), so this stays within the cert-guard invariant — www would just present a
    # name-mismatched cert until the cert is expanded. DOMAIN is already validated upstream.
    if [[ "${WWW_REDIRECT:-}" == "1" || "${WWW_REDIRECT:-}" == "true" ]]; then
      cat >> "${VHOST_OUT}" <<EOF

server {
    listen 443 ssl http2;
    server_name www.${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    return 301 https://${DOMAIN}\$request_uri;
}
EOF
      log_detail "Added www.${DOMAIN} -> ${DOMAIN} 301 redirect (ensure the TLS cert covers www.${DOMAIN})"
    fi
    if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T nginx nginx -t 2>/dev/null; then
      docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T nginx nginx -s reload 2>/dev/null \
        || log_warn "nginx config valid but reload failed — reload manually."
      log_ok "Wrote and activated nginx/conf.d/${PROJECT_NAME}.conf"
    else
      rm -f "${VHOST_OUT}"
      log_error "Rendered vhost failed 'nginx -t' — removed ${VHOST_OUT} to avoid poisoning nginx. Fix the template/inputs and retry."
      exit 1
    fi
  else
    log_warn "No TLS cert for ${DOMAIN} yet — NOT writing the SSL vhost (a vhost referencing a missing cert makes nginx fail to start on the next restart, taking down all sites)."
    log_detail "Get the cert first, then re-run this script:"
    log_detail "  docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN} --agree-tos -m you@example.com --no-eff-email"
    log_detail "  ${0} ${MANIFEST_PATH}"
  fi
}

# Export KEY=VALUE pairs from a .env file.
load_env() {
  local f="$1"
  if [[ -f "$f" ]]; then set -a; # shellcheck disable=SC1090
    source "$f"; set +a; fi
}
