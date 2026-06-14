#!/usr/bin/env bash
# One-time shared infra bootstrap on the VPS.
# Run from /opt/infra/ after copying infra/ contents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

if [[ ! -f .env ]]; then
  echo "Copy .env.example to .env and set passwords first."
  exit 1
fi

# infra/.env holds root DB + Redis + all project passwords. On a multi-tenant box a
# group/other-readable .env leaks every secret. Enforce 0600 (owner-only).
current_perms="$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null || echo '')"
if [[ "${current_perms}" != "600" ]]; then
  echo "Tightening .env permissions to 600 (was ${current_perms:-unknown})."
  chmod 600 .env
fi

if ! docker network inspect infra-net >/dev/null 2>&1; then
  echo "Creating docker network infra-net"
  docker network create infra-net
fi

"${SCRIPT_DIR}/render-init-sql.sh"

# Render infra-global nginx security-headers template (per-project vhosts come from register-project.sh).
cp nginx/conf.d/00-security-headers.conf.template nginx/conf.d/00-security-headers.conf

echo "Register a project vhost with: ./register-project.sh /opt/<project>/deploy/project.env"

# Create the runtime conf.d dir for rendered per-site static nginx blocks so the
# bind mount exists before the container starts (nginx requires the dir to be
# present; the include directive is harmless when the dir is empty).
echo "Ensuring nginx-static/conf.d exists"
mkdir -p "${SCRIPT_DIR}/nginx-static/conf.d"

echo "Starting infra stack"
docker compose up -d

echo ""
echo "First HTTPS certificate (replace domains):"
echo "  docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \\"
echo "    -d <domain> -d www.<domain> --agree-tos -m you@example.com"
echo ""
echo "Then reload nginx: docker compose exec nginx nginx -s reload"
