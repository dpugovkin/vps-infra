📋 Deploying this infra — command runbook

![doc](https://img.shields.io/badge/doc-runbook-9cf) ![scope](https://img.shields.io/badge/scope-phase_1_and_2-lightgrey)

Step-by-step explanations live in `docs/lessons/` (Modules 1–5). This is the terse runbook.

**On this page:** [🚀 Phase 1 — infra](#-phase-1--infra) · [📦 Phase 2 — add a project](#-phase-2--add-a-project) · [🔧 Day-2 operations](#-day-2-operations)

---

## 🚀 Phase 1 — infra

**1. Copy repo to VPS** (run on your laptop):

```bash
rsync -av --exclude='.git' ~/projects/personal/vps-infra/ root@<VPS_IP>:/opt/infra/
```

**2. Run provision script** (SSH in as root first):

```bash
ssh root@<VPS_IP>
cd /opt/infra && ./provision-host.sh
```

Success: script exits with `Host ready. Next: ./bootstrap.sh …`

**3. Add SSH key for the `deploy` user** (still as root on VPS):

```bash
mkdir -p /home/deploy/.ssh
nano /home/deploy/.ssh/authorized_keys     # paste your PUBLIC key (~/.ssh/id_ed25519.pub)
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
```


> [!CAUTION]
> sshd reads `authorized_keys` as the `deploy` user — if `.ssh` stays root-owned, key login silently falls back to a password prompt. Verify: `ssh deploy@<VPS_IP>` logs in with no password.

**4. Create `.env`**:

```bash
cd /opt/infra
cp .env.example .env
openssl rand -hex 32    # run twice — one value each for MARIADB_ROOT_PASSWORD and REDIS_PASSWORD
nano .env               # fill MARIADB_ROOT_PASSWORD, REDIS_PASSWORD
```


> [!NOTE]
> Per-project `<PROJECT>_PASSWORD` vars are not in `.env.example` — they are project-specific, so add them to `.env` in Phase 2 before running `register-project.sh`. `BACKUP_REQUIRE_ENV_BACKUP=1` ships in `.env.example`: backups will refuse unless `BACKUP_GPG_PASSPHRASE` is set (or set it to `0` to skip).

**5. Bootstrap the stack**:

```bash
./bootstrap.sh
```

Success: `docker compose ps` shows four services `Up` (nginx, certbot, mariadb, redis).

**6. Verify nginx is up**:

```bash
curl -I http://<VPS_IP>
```

Expected: `HTTP/1.1 301 Moved Permanently` — nginx is redirecting HTTP to HTTPS.

---

## 📦 Phase 2 — add a project

**1. DNS A record** → VPS IP. Must propagate before getting the cert.

**2. Deploy the project** to `/opt/<project>`, create its `.env` (reuse `REDIS_PASSWORD` from `infra/.env`; add `<PROJECT_NAME_UPPER>_PASSWORD` to `infra/.env` as well), then start its prod stack.

**3. Get the TLS cert BEFORE registering** (run from `/opt/infra`):

```bash
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d <domain> --agree-tos -m <you@example.com> --no-eff-email
```


> [!CAUTION]
> `register-project.sh` includes a cert-guard: if the cert is missing it will skip writing the vhost entirely. A vhost referencing a missing cert causes nginx to fail on the next container restart, taking down every site on the box.

**4. Register the project**:

```bash
./register-project.sh /opt/<project>/deploy/project.env
```

Creates the DB + user (idempotent), installs any nginx-locations snippet, renders and validates the vhost, reloads nginx.

**5. Verify**:

```bash
curl -I https://<domain>
```

Expected: `HTTP/1.1 200 OK` (or your app's expected status).

---

## 🗂️ Phase 2b — add a static site

**1. DNS A record** → VPS IP. Must propagate before getting the cert.

**2. Create the web root and deploy the build** (run on VPS or push from laptop):

```bash
mkdir -p /srv/www/<domain>
rsync -a ./dist/ deploy@<VPS_IP>:/srv/www/<domain>/
```

**3. Get the TLS cert BEFORE registering** (run from `/opt/infra`):

```bash
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d <domain> --agree-tos -m <you@example.com> --no-eff-email
```

> [!CAUTION]
> `register-static-site.sh` includes the same cert-guard as `register-project.sh`: if the cert is missing it will skip writing the edge vhost entirely. A vhost referencing a missing cert causes nginx to fail on the next container restart, taking down every site on the box.

**4. Register the static site**:

```bash
./register-static-site.sh /opt/<project>/deploy/static.env
```

Renders the static server block (`nginx-static/conf.d/<PROJECT_NAME>.conf`), validates the static container config, then renders and validates the edge vhost. No DB is created.

**5. Verify**:

```bash
curl -I https://<domain>
```

Expected: `HTTP/1.1 200 OK`.

**Updating a static site** (no re-registration needed — rsync new files and you're done):

```bash
rsync -a ./dist/ deploy@<VPS_IP>:/srv/www/<domain>/
```

---

## 🔧 Day-2 operations

See Module 5 for full detail. One-liners:

**Backup** (run on VPS from `/opt/infra`):

```bash
./backup/backup.sh --encrypt-all /opt/<project>/deploy/project.env
```

**Pull backup to laptop** (run on laptop):

```bash
./pull-backup.sh deploy@<VPS_IP> /opt/<project>/deploy/project.env ~/vps-backups
```

**Rotate a DB password**:

```bash
./rotate-db-password.sh <db_user>
```

Prompts for the new password interactively (never passed via argv).

**Restore** (run on VPS from `/opt/infra`):

```bash
./backup/restore.sh /opt/<project>/deploy/project.env [/path/to/backup-dir]
```

Prompts for confirmation; takes a pre-restore safety snapshot automatically.

---

**See also:** [📚 Lessons course](learning-path.md)  ·  [🔗 Integrate a project](integrating-a-project.md)
