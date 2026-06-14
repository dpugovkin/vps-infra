#!/usr/bin/env bash
# Rotate a MariaDB application user password on the shared infra stack.
#
# Usage (run from /opt/infra/):
#   ./rotate-db-password.sh <db_user>            # e.g. the project's DB user
#
# What it does:
#   1. Prompts for the new password (never passed via argv to avoid ps exposure).
#   2. Issues ALTER USER inside the running mariadb container.
#   3. Prints the lines you must update in:
#        /opt/<db_user>/.env           (DB_PASSWORD=)
#        infra/.env                    (<DB_USER>_PASSWORD=)
#      — the script does NOT edit those files; operator updates them manually.
#   4. Reminds you to restart the affected app container and flush its cache.
#
# Note: render-init-sql.sh only runs on a FRESH DB volume and will not rotate an
# existing password. This script is the documented rotation procedure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

DB_USER="${1:-}"
if [[ -z "${DB_USER}" ]]; then
  echo "Usage: $0 <db_user>  (the project's MariaDB user)"
  exit 1
fi
validate_identifier "DB_USER" "${DB_USER}"

MARIADB_CONTAINER="${INFRA_MARIADB_CONTAINER:-infra-mariadb-1}"

if ! docker inspect "${MARIADB_CONTAINER}" &>/dev/null; then
  echo "ERROR: Container ${MARIADB_CONTAINER} not found — is the infra stack running?"
  exit 1
fi

echo "Rotating password for MariaDB user: ${DB_USER}"
echo "New password (input hidden):"
read -r -s NEW_PASSWORD
echo

if [[ -z "${NEW_PASSWORD}" ]]; then
  echo "ERROR: Password cannot be empty."
  exit 1
fi
validate_password_literal "NEW_PASSWORD" "${NEW_PASSWORD}"

# Load infra .env to get the root password (never put it on the command line).
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

if [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]]; then
  echo "ERROR: MARIADB_ROOT_PASSWORD not found in ${SCRIPT_DIR}/.env"
  exit 1
fi

# Alter the user. Pass the root password via MYSQL_PWD env var so it never
# appears on the process list (ps ax) visible to other VPS tenants.
docker exec \
  -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
  "${MARIADB_CONTAINER}" \
  mariadb -u root -e "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${NEW_PASSWORD}'; FLUSH PRIVILEGES;"

echo ""
echo "Password changed in MariaDB. Now update the following files manually:"
echo ""
echo "  /opt/${DB_USER}/.env          → DB_PASSWORD=<new>   (project .env; dir == project name)"
echo "  ${SCRIPT_DIR}/.env            → ${DB_USER^^}_PASSWORD=<new>"
echo "                                  (keeps register-project.sh in sync for future fresh deploys)"
echo ""
echo "Then restart the project's app container so it picks up the new password,"
echo "and flush any app-level cache that holds DB credentials. For example:"
echo "  cd /opt/${DB_USER} && docker compose restart <app-service>"
