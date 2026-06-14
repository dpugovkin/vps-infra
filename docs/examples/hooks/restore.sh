#!/usr/bin/env bash
# Project restore hook — called by infra's backup/restore.sh.
# Contract: infra exports APP_DIR, DB_FILE (chosen db-*.sql.gz), and UPLOADS_FILE
# (may be empty). Restore them into this project. Adapt to your app.
set -euo pipefail
: "${APP_DIR:?}"; : "${DB_FILE:?}"

# shellcheck disable=SC1091
source "${APP_DIR}/.env"
INFRA_MARIADB="${INFRA_MARIADB_CONTAINER:-infra-mariadb-1}"

# Restore the database.
gunzip -c "${DB_FILE}" \
  | docker exec -i -e MYSQL_PWD="${DB_PASSWORD}" "${INFRA_MARIADB}" \
      mariadb -u "${DB_USER}" "${DB_NAME}"

# Restore uploads if a bundle was provided.
if [[ -n "${UPLOADS_FILE:-}" && -f "${UPLOADS_FILE}" ]]; then
  tar -xzf "${UPLOADS_FILE}" -C "${APP_DIR}/data"
fi
