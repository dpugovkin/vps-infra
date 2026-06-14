#!/usr/bin/env bash
# Generic backup engine. Knows HOW to bundle/encrypt/retain; the project
# hook decides WHAT to back up.
# Usage: ./infra/backup/backup.sh [--encrypt-all] /opt/<project>/deploy/project.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${INFRA_ROOT}/lib/common.sh"
load_env "${INFRA_ROOT}/.env"

ENCRYPT_ALL=0
_args=()
for _a in "$@"; do
  case "${_a}" in
    --encrypt-all) ENCRYPT_ALL=1 ;;
    *) _args+=("${_a}") ;;
  esac
done
set -- "${_args[@]:-}"

MANIFEST="${1:?Usage: backup.sh [--encrypt-all] <project.env>}"
load_env "${MANIFEST}"
: "${PROJECT_NAME:?manifest missing PROJECT_NAME}"
APP_DIR="${PROJECT_DIR:?manifest missing PROJECT_DIR}"

STAMP="$(date +%Y-%m-%d_%H%M)"
export STAMP APP_DIR
BACKUP_DIR="${BACKUP_DIR:-/var/backups/${PROJECT_NAME}}"
export BACKUP_DIR
BACKUP_LOCAL_DAYS="${BACKUP_LOCAL_DAYS:-14}"
mkdir -p "${BACKUP_DIR}"

log_step "Backup ${PROJECT_NAME} ${STAMP}"

# 1) Project data via hook (db + uploads).
HOOK="${APP_DIR}/deploy/hooks/backup.sh"
if [[ -x "${HOOK}" ]]; then
  log "Running project backup hook"
  "${HOOK}"
else
  log_error "Project backup hook not found/executable: ${HOOK}"
  exit 1
fi

# 2) Encrypted project .env (passphrase via fd 3, never on argv).
if [[ "${ENCRYPT_ALL}" == "1" ]]; then
  : "${BACKUP_GPG_PASSPHRASE:?--encrypt-all requires BACKUP_GPG_PASSPHRASE (set it in infra/.env)}"
  [[ -f "${BACKUP_DIR}/db-${STAMP}.sql.gz" ]] || { log_error "--encrypt-all: expected ${BACKUP_DIR}/db-${STAMP}.sql.gz from the hook, not found"; exit 1; }
  log "Building single encrypted bundle (db + uploads + .env)"
  _stage="$(mktemp -d)"
  cp "${BACKUP_DIR}/db-${STAMP}.sql.gz" "${_stage}/"
  [[ -f "${BACKUP_DIR}/uploads-${STAMP}.tar.gz" ]] && cp "${BACKUP_DIR}/uploads-${STAMP}.tar.gz" "${_stage}/"
  [[ -f "${APP_DIR}/.env" ]] && cp "${APP_DIR}/.env" "${_stage}/.env"
  _bundle_tar="$(mktemp)"
  tar -czf "${_bundle_tar}" -C "${_stage}" .
  gpg --batch --yes --passphrase-fd 3 --pinentry-mode loopback \
      --symmetric --cipher-algo AES256 -o "${BACKUP_DIR}/bundle-${STAMP}.tar.gz.gpg" \
      3< <(printf '%s' "${BACKUP_GPG_PASSPHRASE}") \
      < "${_bundle_tar}"
  rm -rf "${_stage}" "${_bundle_tar}"
  log_ok "Wrote ${BACKUP_DIR}/bundle-${STAMP}.tar.gz.gpg"
else
  if [[ -f "${APP_DIR}/.env" ]]; then
    if [[ -n "${BACKUP_GPG_PASSPHRASE:-}" ]]; then
      log "Encrypting .env"
      env_tar="$(mktemp)"
      tar -czf "${env_tar}" -C "${APP_DIR}" .env
      gpg --batch --yes --passphrase-fd 3 --pinentry-mode loopback \
          --symmetric --cipher-algo AES256 -o "${BACKUP_DIR}/env-${STAMP}.tar.gz.gpg" \
          3< <(printf '%s' "${BACKUP_GPG_PASSPHRASE}") \
          < "${env_tar}"
      rm -f "${env_tar}"
    elif [[ "${BACKUP_REQUIRE_ENV_BACKUP:-0}" == "1" ]]; then
      log_error "BACKUP_GPG_PASSPHRASE unset and BACKUP_REQUIRE_ENV_BACKUP=1 — refusing"
      exit 1
    else
      log_warn "BACKUP_GPG_PASSPHRASE not set — .env not included"
    fi
  fi
fi

# Offsite upload is intentionally DISABLED — backups are local-only on this VPS for now.
# To re-enable encrypted offsite backups later, GPG-encrypt the db/uploads bundles like the
# .env step above, then rclone-copy only the *.gpg artifacts to RCLONE_REMOTE.

find "${BACKUP_DIR}" -maxdepth 1 -type f \
  \( -name 'db-*.sql.gz' -o -name 'uploads-*.tar.gz' -o -name 'env-*.tar.gz.gpg' -o -name 'bundle-*.tar.gz.gpg' \) \
  -mtime +"${BACKUP_LOCAL_DAYS}" -delete

log_ok "Backup complete: ${PROJECT_NAME} ${STAMP}"

if [[ "${ENCRYPT_ALL}" == "1" ]]; then
  printf 'BUNDLE_PATH=%s\n' "${BACKUP_DIR}/bundle-${STAMP}.tar.gz.gpg"
fi
