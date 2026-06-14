#!/usr/bin/env bash
# Plug a project into the shared infra: create its DB+user (idempotent), render
# its nginx vhost, reload nginx. Run on the VPS from /opt/infra.
# Usage: ./register-project.sh /opt/<project>/deploy/project.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env "${SCRIPT_DIR}/.env"

MANIFEST="${1:?Usage: register-project.sh <project.env>}"
load_env "${MANIFEST}"
: "${PROJECT_NAME:?manifest missing PROJECT_NAME}"
: "${DOMAIN:?manifest missing DOMAIN}"
: "${UPSTREAM:?manifest missing UPSTREAM}"
: "${DB_NAME:?manifest missing DB_NAME}"
: "${DB_USER:?manifest missing DB_USER}"

# FIX A: validate inputs before use (guards SQL injection and sed/path injection)
validate_identifier "DB_NAME" "${DB_NAME}"
validate_identifier "DB_USER" "${DB_USER}"
validate_hostname "DOMAIN" "${DOMAIN}"
validate_charset "PROJECT_NAME" "${PROJECT_NAME}" '^[A-Za-z0-9_-]+$'
validate_charset "UPSTREAM" "${UPSTREAM}" '^[A-Za-z0-9_.:-]+$'

MARIADB_CONTAINER="${INFRA_MARIADB_CONTAINER:-infra-mariadb-1}"
PROJECT_DB_PASSWORD_VAR="${PROJECT_NAME^^}_PASSWORD"; PROJECT_DB_PASSWORD_VAR="${PROJECT_DB_PASSWORD_VAR//-/_}"
DB_PASSWORD="${!PROJECT_DB_PASSWORD_VAR:-}"
: "${MARIADB_ROOT_PASSWORD:?infra/.env missing MARIADB_ROOT_PASSWORD}"
[[ -n "${DB_PASSWORD}" ]] || { log_error "infra/.env missing ${PROJECT_DB_PASSWORD_VAR}"; exit 1; }

# FIX A: validate password literal (rejects single-quote, backslash, newline)
validate_password_literal "DB_PASSWORD for ${PROJECT_NAME}" "${DB_PASSWORD}"

log_step "Creating DB ${DB_NAME} + user ${DB_USER}"
docker exec -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" "${MARIADB_CONTAINER}" mariadb -u root -e "
  CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
  GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
  FLUSH PRIVILEGES;"
log_ok "Database ready"

# FIX B: cert-guarded vhost + config validation
# FIX C: per-project CSP rendered into vhost
render_edge_vhost "${PROJECT_NAME}" "${DOMAIN}" "${UPSTREAM}" "${CSP:-}" "${MANIFEST}"
