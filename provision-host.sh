#!/usr/bin/env bash
# One-time VPS setup: Ubuntu 24.04 + Docker + firewall.
# Containerized nginx/MariaDB live under /opt/infra/ — no host nginx.
# Run as root. Does not clone projects — see deploy/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DEPLOY_USER="${DEPLOY_USER:-deploy}"

require_root
export DEBIAN_FRONTEND=noninteractive

log_step "Installing Docker and firewall tools"

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg ufw fail2ban

if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

if ! id -u "${DEPLOY_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${DEPLOY_USER}"
  usermod -aG docker "${DEPLOY_USER}"
  log_warn "Add SSH key to /home/${DEPLOY_USER}/.ssh/authorized_keys"
else
  usermod -aG docker "${DEPLOY_USER}" 2>/dev/null || true
fi

``# `useradd -m` only sets home ownership when it CREATES the directory. If /home/<user> already
# exists (e.g. pre-created by root during image provisioning), useradd leaves it root-owned — and
# the deploy user then can't write to its own home, which silently breaks Docker and Composer
# (~/.docker and ~/.cache can't be created). Enforce correct ownership on every run so this also
# self-heals hosts that were already provisioned with the bug.
mkdir -p "/home/${DEPLOY_USER}"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}"
log_ok "/home/${DEPLOY_USER} owned by ${DEPLOY_USER}"

log_step "Creating static web-root parent /srv/www"
mkdir -p /srv/www
chown "${DEPLOY_USER}:${DEPLOY_USER}" /srv/www
log_ok "/srv/www ready (owned by ${DEPLOY_USER})"

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

systemctl enable docker
systemctl start docker

log_step "Enabling fail2ban (SSH brute-force protection)"
if [[ ! -f /etc/fail2ban/jail.local ]]; then
  cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
fi
systemctl enable --now fail2ban
log_ok "fail2ban enabled"

# Host nginx conflicts with containerized nginx at /opt/infra/ (both bind :80/:443).
if systemctl is-active nginx &>/dev/null; then
  log_warn "Stopping host nginx — edge TLS is handled by the infra nginx container"
  systemctl stop nginx
fi
if systemctl is-enabled nginx &>/dev/null; then
  systemctl disable nginx
fi

log_ok "Host ready. Next: ./bootstrap.sh, then ./register-project.sh <project.env>"
