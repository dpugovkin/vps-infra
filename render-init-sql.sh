#!/usr/bin/env bash
# Render MariaDB init SQL from .env templates (run once before first infra up).
#
# The rendered SQL uses "GRANT ALL PRIVILEGES ON <db>.* TO <user>@'%'" — this is a
# DB-scoped grant, not a global superuser grant. The user can only access the named
# database; it cannot CREATE/DROP other databases or access information_schema beyond
# what MariaDB exposes to normal users. It does NOT carry SUPER, GRANT OPTION, or FILE.
#
# To rotate an existing password after first boot, use rotate-db-password.sh instead —
# this script is a no-op once the DB volume already exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing ${SCRIPT_DIR}/.env — copy .env.example and fill passwords."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

render_template() {
  local template="$1"
  local output="$2"
  cp "${template}" "${output}"
  chmod 600 "${output}"
}

render_template \
  init/mariadb/01-databases.sql.template \
  init/mariadb/01-databases.sql

echo "Rendered init/mariadb/01-databases.sql"
