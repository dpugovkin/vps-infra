#!/usr/bin/env bash
# Pull an encrypted, self-contained backup bundle from the VPS to this machine.
# Runs the remote backup engine with --encrypt-all, then rsyncs the single .gpg
# bundle down. Intended for low-frequency (manual) offsite copies to your laptop.
#
# Usage: ./pull-backup.sh <ssh-host> <remote-project-manifest> [local-dest-dir]
#   ./pull-backup.sh deploy@vps.example.com /opt/myproject/deploy/project.env ~/vps-backups
#
# The GPG passphrase lives only in the VPS infra/.env (used server-side to build the
# bundle) and is never sent over the wire. You are prompted for it locally only when
# you later decrypt the bundle.
set -euo pipefail

SSH_HOST="${1:?Usage: pull-backup.sh <ssh-host> <remote-project-manifest> [local-dest-dir]}"
MANIFEST="${2:?Usage: pull-backup.sh <ssh-host> <remote-project-manifest> [local-dest-dir]}"
DEST_ROOT="${3:-${HOME}/vps-backups}"
INFRA_DIR="${INFRA_DIR:-/opt/infra}"

echo "-> Running remote backup (--encrypt-all) on ${SSH_HOST} ..."
REMOTE_OUT="$(ssh "${SSH_HOST}" "cd '${INFRA_DIR}' && ./backup/backup.sh --encrypt-all '${MANIFEST}'")"
printf '%s\n' "${REMOTE_OUT}"

BUNDLE="$(printf '%s\n' "${REMOTE_OUT}" | sed -n 's/^BUNDLE_PATH=//p' | tail -1)"
[[ -n "${BUNDLE}" ]] || { echo "ERROR: could not determine bundle path from remote output." >&2; exit 1; }

PROJECT="$(basename "$(dirname "${BUNDLE}")")"
DEST_DIR="${DEST_ROOT}/${PROJECT}"
mkdir -p "${DEST_DIR}"

echo "-> Downloading $(basename "${BUNDLE}") to ${DEST_DIR}/ ..."
rsync -avz --progress "${SSH_HOST}:${BUNDLE}" "${DEST_DIR}/"

echo ""
echo "Pulled: ${DEST_DIR}/$(basename "${BUNDLE}")"
echo ""
echo "To open it (prompts for BACKUP_GPG_PASSPHRASE):"
echo "  mkdir restore && gpg -d '${DEST_DIR}/$(basename "${BUNDLE}")' | tar -xzvf - -C restore"
echo "  # yields .env, db-*.sql.gz, uploads-*.tar.gz"
