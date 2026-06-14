#!/usr/bin/env bash
# Project backup hook — called by infra's backup/backup.sh.
# Contract: infra exports STAMP, BACKUP_DIR, APP_DIR. You MUST write:
#   ${BACKUP_DIR}/db-${STAMP}.sql.gz        (required)
#   ${BACKUP_DIR}/uploads-${STAMP}.tar.gz   (optional)
# Adapt the dump command and uploads path to your app.
set -euo pipefail
: "${STAMP:?}"; : "${BACKUP_DIR:?}"; : "${APP_DIR:?}"

# Load this project's own DB credentials.
# shellcheck disable=SC1091
source "${APP_DIR}/.env"

INFRA_MARIADB="${INFRA_MARIADB_CONTAINER:-infra-mariadb-1}"

# Dump the database with the project's own (DB-scoped) user. MYSQL_PWD keeps the
# password off the process list.
docker exec -e MYSQL_PWD="${DB_PASSWORD}" "${INFRA_MARIADB}" \
  mariadb-dump -u "${DB_USER}" --single-transaction --quick --no-tablespaces "${DB_NAME}" \
  | gzip > "${BACKUP_DIR}/db-${STAMP}.sql.gz"

# Archive uploads/media (adjust the path to your app's data dir).
if [[ -d "${APP_DIR}/data/uploads" ]]; then
  tar -czf "${BACKUP_DIR}/uploads-${STAMP}.tar.gz" -C "${APP_DIR}/data" uploads
fi
