#!/usr/bin/env bash
# Generic restore engine. Locates a bundle, snapshots current state via the
# project backup hook, then hands the chosen bundle to the project restore hook.
# DB-agnostic: never calls the DB or the app directly. Run on the VPS.
# Usage: ./infra/backup/restore.sh <project.env> [/path/to/backup-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${INFRA_ROOT}/lib/common.sh"
load_env "${INFRA_ROOT}/.env"

MANIFEST="${1:?Usage: restore.sh <project.env> [backup-dir]}"
load_env "${MANIFEST}"
: "${PROJECT_NAME:?manifest missing PROJECT_NAME}"
APP_DIR="${PROJECT_DIR:?manifest missing PROJECT_DIR}"
export APP_DIR
BACKUP_DIR="${2:-/var/backups/${PROJECT_NAME}}"

# shellcheck disable=SC2012
DB_FILE="$(ls -t "${BACKUP_DIR}"/db-*.sql.gz 2>/dev/null | head -1 || true)"
# shellcheck disable=SC2012
UPLOADS_FILE="$(ls -t "${BACKUP_DIR}"/uploads-*.tar.gz 2>/dev/null | head -1 || true)"
[[ -n "${DB_FILE}" ]] || { log_error "No database backup in ${BACKUP_DIR}"; exit 1; }
export DB_FILE UPLOADS_FILE

log_warn "This will REPLACE ${PROJECT_NAME}'s production data."
log_detail "DB backup:      ${DB_FILE}"
[[ -n "${UPLOADS_FILE}" ]] && log_detail "Uploads backup: ${UPLOADS_FILE}"
printf "[%s] Type 'yes' to continue: " "${PROJECT_NAME}"
read -r confirm
[[ "${confirm}" == "yes" ]] || { log "Restore cancelled."; exit 0; }

# Pre-restore safety snapshot — reuse the project backup hook into a sibling dir
# that cron retention never sweeps.
HISTORY_DIR="${BACKUP_DIR}/restore-history"
mkdir -p "${HISTORY_DIR}"
BACKUP_DIR_SAVE="${BACKUP_DIR}"
log_step "Creating pre-restore snapshot"
BACKUP_DIR="${HISTORY_DIR}" STAMP="pre-restore-$(date +%Y-%m-%d_%H%M)" \
  "${APP_DIR}/deploy/hooks/backup.sh"
BACKUP_DIR="${BACKUP_DIR_SAVE}"

log_step "Applying bundle via project restore hook"
"${APP_DIR}/deploy/hooks/restore.sh"
log_ok "Restore complete for ${PROJECT_NAME}"
