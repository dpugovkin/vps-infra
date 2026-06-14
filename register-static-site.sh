#!/usr/bin/env bash
# Register a static site with the shared static container: render the per-site
# nginx server{} block, validate + reload the static container, then render the
# TLS-terminating edge vhost via render_edge_vhost. No DB is created.
# Usage: ./register-static-site.sh <static.env>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env "${SCRIPT_DIR}/.env"

MANIFEST="${1:?Usage: register-static-site.sh <static.env>}"
load_env "${MANIFEST}"

: "${PROJECT_NAME:?manifest missing PROJECT_NAME}"
: "${DOMAIN:?manifest missing DOMAIN}"
: "${STATIC_FALLBACK:?manifest missing STATIC_FALLBACK}"

validate_charset "PROJECT_NAME" "${PROJECT_NAME}" '^[A-Za-z0-9_-]+$'
validate_hostname "DOMAIN" "${DOMAIN}"

if [[ "${STATIC_FALLBACK}" != "spa" && "${STATIC_FALLBACK}" != "static" ]]; then
  log_error "STATIC_FALLBACK must be 'spa' or 'static', got: '${STATIC_FALLBACK}'"
  exit 1
fi

ROOT="/srv/www/${DOMAIN}"
if [[ ! -d "${ROOT}" ]] || [[ -z "$(ls -A "${ROOT}" 2>/dev/null)" ]]; then
  log_warn "Web root ${ROOT} is missing or empty — register will proceed, but the site will serve no files until content is deployed."
fi

# Resolve try_files directive. $uri must remain LITERAL in the output (nginx
# variable). Single-quoting here prevents the shell from expanding $uri.
# shellcheck disable=SC2016
if [[ "${STATIC_FALLBACK}" == "spa" ]]; then
  TRY_FILES='try_files $uri $uri/ /index.html;'
else
  TRY_FILES='try_files $uri $uri/ =404;'
fi

log_step "Rendering static server block for ${DOMAIN}"
SITE_CONF="${SCRIPT_DIR}/nginx-static/conf.d/${PROJECT_NAME}.conf"
mkdir -p "${SCRIPT_DIR}/nginx-static/conf.d"
# __ROOT__ and __TRY_FILES__ both contain '/'; use '#' as sed delimiter.
# TRY_FILES is single-quoted so the shell never expands $uri; sed treats '$'
# in the replacement string as literal, so $uri lands verbatim in the output.
sed \
  -e "s#__DOMAIN__#${DOMAIN}#g" \
  -e "s#__ROOT__#${ROOT}#g" \
  -e "s#__TRY_FILES__#${TRY_FILES}#g" \
  "${SCRIPT_DIR}/nginx-static/site.conf.template" > "${SITE_CONF}"
log_ok "Wrote nginx-static/conf.d/${PROJECT_NAME}.conf"

log_step "Validating and reloading static container"
if docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T static nginx -t 2>/dev/null; then
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" exec -T static nginx -s reload 2>/dev/null \
    || log_warn "static nginx config valid but reload failed — reload manually."
  log_ok "Static container reloaded"
else
  rm -f "${SITE_CONF}"
  log_error "Rendered site block failed 'nginx -t' — removed ${SITE_CONF} to avoid poisoning the static container. Fix the template/inputs and retry."
  exit 1
fi

render_edge_vhost "${PROJECT_NAME}" "${DOMAIN}" "static:8080" "${CSP:-}" "${MANIFEST}"
