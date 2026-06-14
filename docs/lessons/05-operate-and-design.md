# 🛠️ Module 5 — Operate it, and why it's built this way

![module](https://img.shields.io/badge/module-5-blue) ![type](https://img.shields.io/badge/type-operations-orange)

Day-2 operations and the design rationale for the shared infra stack.

**On this page:** [🔧 Part A — operations](#-part-a--operations) · [🧠 Part B — the design](#-part-b--the-design) · [What you can do after this](#what-you-can-do-after-this)

---

## 🔧 Part A — operations

### 💾 Backups

`backup/backup.sh` is the generic engine: it owns timestamps, file naming, encryption, pruning, and output format. It knows nothing about your app. The project's `deploy/hooks/backup.sh` decides *what* to back up. The engine calls the hook, then handles everything else.

The hook must emit `${BACKUP_DIR}/db-${STAMP}.sql.gz` (required). `uploads-${STAMP}.tar.gz` in the same directory is optional. Both env vars (`BACKUP_DIR`, `STAMP`) are set by the engine before invoking the hook.

Backups land in `/var/backups/<PROJECT_NAME>/` and are pruned after `BACKUP_LOCAL_DAYS` days (default: 14).

**Run a plain backup (on the VPS, from `/opt/infra/`):**

```bash
./backup/backup.sh /opt/<project>/deploy/project.env
```


> [!WARNING]
> `.env.example` ships `BACKUP_REQUIRE_ENV_BACKUP=1`. With that set, a plain backup (no `--encrypt-all`) will call the hook successfully, then exit with an error when it tries to encrypt the project `.env` and finds `BACKUP_GPG_PASSPHRASE` unset. The db dump file is written, but the script exits non-zero. Fix: (a) set `BACKUP_GPG_PASSPHRASE` in `infra/.env`, (b) use `--encrypt-all` instead, or (c) set `BACKUP_REQUIRE_ENV_BACKUP=0` if you're doing local-only and don't need `.env` encrypted.

### 💾 Encrypted bundle — `--encrypt-all`

Produces a single `bundle-<stamp>.tar.gz.gpg` (AES-256) containing the db dump, optional uploads tarball, and the project `.env`. The passphrase is read from `BACKUP_GPG_PASSPHRASE` in `infra/.env` and passed to GPG via fd 3 — never on the command line:

```bash
gpg --batch --yes --passphrase-fd 3 --pinentry-mode loopback \
    --symmetric --cipher-algo AES256 -o "${BACKUP_DIR}/bundle-${STAMP}.tar.gz.gpg" \
    3< <(printf '%s' "${BACKUP_GPG_PASSPHRASE}") \
    < "${_bundle_tar}"
```

```bash
./backup/backup.sh --encrypt-all /opt/<project>/deploy/project.env
```

Backups are **local-only by design** — no rclone, no S3. The offsite step is manual (see pull below).

### 💾 Encrypted pull — `pull-backup.sh`

Run from your **laptop**. SSHes to the VPS, runs `backup.sh --encrypt-all` remotely, rsyncs the `.gpg` bundle down. The passphrase never travels over the wire — it is used server-side to build the bundle and is only needed locally when you decrypt.

```bash
./pull-backup.sh deploy@your-vps /opt/<project>/deploy/project.env ~/vps-backups
```

Signature: `pull-backup.sh <ssh-host> <remote-project-manifest> [local-dest-dir]`

`INFRA_DIR` defaults to `/opt/infra` (override with env var if your infra lives elsewhere).

To decrypt locally:

```bash
mkdir restore
gpg -d ~/vps-backups/<project>/bundle-<stamp>.tar.gz.gpg | tar -xzvf - -C restore
# yields: restore/.env   restore/db-<stamp>.sql.gz   restore/uploads-<stamp>.tar.gz
```

### 💾 Restore — `backup/restore.sh`

```bash
./backup/restore.sh /opt/<project>/deploy/project.env
```

What happens:

1. Finds the most recent `db-*.sql.gz` in `/var/backups/<project>/`.
2. Shows what it found, asks you to type `yes`.
3. Takes a pre-restore snapshot via the project backup hook into `restore-history/` (never pruned by normal retention).
4. Calls `${APP_DIR}/deploy/hooks/restore.sh` with `APP_DIR`, `DB_FILE`, and `UPLOADS_FILE` set as env vars.


> [!NOTE]
> The restore hook receives its inputs via environment variables, not positional arguments.

### 🔑 DB password rotation

```bash
cd /opt/infra
./rotate-db-password.sh <db_user>
```

The password exists in **three places**. The script updates one of them:

| Location | Who updates it |
|---|---|
| MariaDB `ALTER USER` (inside the container) | `rotate-db-password.sh` |
| Project `.env` (`DB_PASSWORD=`) at `/opt/<project>/.env` | You, manually |
| `infra/.env` (`<PROJECT_NAME>_PASSWORD=`) | You, manually |

The script prints exactly which lines to edit in which files. After updating both `.env` files, restart the app container:

```bash
cd /opt/<project> && docker compose restart <app-service>
```


> [!NOTE]
> Old docs said "two places, update all three" — that was contradictory. The correct framing: three places, script does the DB, you do the two `.env` files.

### 🔧 Logs and health

```bash
docker compose ps                          # container status
docker compose logs -f <service>           # follow live (nginx / mariadb / redis / certbot)
docker compose logs --tail=100 nginx       # recent without following
```

No healthchecks are defined in `docker-compose.yml`. A container that keeps restarting shows in `docker compose ps` status.

### 🚀 Updates

Manual only — no CI/CD by design:

```bash
# Infra stack
docker compose pull && docker compose up -d
```

---

## 🧠 Part B — the design

### 🧠 The application-agnostic boundary

`lib/common.sh` opens with: `# Intentionally has NO project/app/DB knowledge — infra stays agnostic.`

Infra provides *mechanisms and services*; projects provide *policy and content*. The infra never embeds a project's internals. This is the same separation managed cloud gives you: a managed load balancer or database (e.g. ALB/Cloud LB, RDS/Cloud SQL) has no idea what your schema looks like or what paths your app exposes — that knowledge lives in your code.

**The boundary rule:** infra may execute project-declared intent; it must never embed an app's internals.

A manifest var like `DB_NAME=myapp` is fine — it's a declarative value. A hardcoded `location = /admin-login` in a shared nginx template is a bug — it binds the shared layer to one app's URL structure. The correct approach: the project ships that block in `deploy/nginx-locations.conf`; `register-project.sh` installs it under `nginx/conf.d/locations/<project>/`. When the project is removed, so is the rule.

Projects plug into infra through exactly three interfaces:

- **Manifest** `deploy/project.env` — declarative vars (`PROJECT_NAME`, `DB_NAME`, `DOMAIN`, `UPSTREAM`, `CSP`, …)
- **Hooks** `deploy/hooks/{backup,restore}.sh` — project decides what; engine decides how
- **Optional nginx snippet** `deploy/nginx-locations.conf` — app-specific location blocks, installed by `register-project.sh`

### 🛡️ Security invariants

Each rule exists because a specific failure is possible without it. Framed for a reader familiar with cloud / multi-tenant infrastructure:

| Rule | Failure prevented |
|---|---|
| **Cert-guard in `register-project.sh`** | nginx validates all configs at (re)start; one vhost referencing a missing cert + `restart: unless-stopped` = box-wide crash-loop taking every site down |
| **Secrets never on argv** | On a multi-tenant box, any user can `ps ax`; passwords on the command line are briefly visible to all tenants |
| **`infra/.env` at mode 600** | File holds MariaDB root password + every project's DB password; world-readable = all secrets compromised at once |
| **Input validation before SQL/sed interpolation** | SQL injection via project name or password breaking the `docker exec mariadb -e "…"` string literal |
| **Socket-free nginx reload** | A docker.sock-mounting sidecar is a host-root pivot — code execution in the sidecar yields full host compromise |
| **Backups local-only** | Deliberate scope limit; avoids introducing storage-provider credentials, upload-failure handling, and restore-from-provider testing into the shared engine |

**Cert-guard detail** (`register-project.sh`):

```
1. Check cert exists inside the nginx container (docker compose exec nginx test -f /etc/letsencrypt/live/<domain>/fullchain.pem)
2. Render the vhost from template
3. Run nginx -t inside the container
4. If nginx -t fails → rm the vhost file immediately, exit 1
```

This is why cert acquisition must happen before `register-project.sh`.

**Secrets off argv:**

```bash
# Correct — MYSQL_PWD env var is not visible in ps ax
docker exec -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" "${MARIADB_CONTAINER}" \
  mariadb -u root -e "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${NEW_PASSWORD}'; FLUSH PRIVILEGES;"

# Wrong — password appears in process list
docker exec "${MARIADB_CONTAINER}" mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "ALTER USER ..."
```

GPG passphrase is passed via `--passphrase-fd 3` with `3< <(printf '%s' "${BACKUP_GPG_PASSPHRASE}")` — same principle.

**Input validation** (`lib/common.sh`):

```bash
validate_identifier "DB_NAME" "${DB_NAME}"       # [A-Za-z0-9_] only
validate_hostname   "DOMAIN"  "${DOMAIN}"         # [A-Za-z0-9.-] only
validate_password_literal "DB_PASSWORD" "${pw}"  # rejects ', \, newline
```

Used in both `register-project.sh` and `rotate-db-password.sh`.

**Socket-free nginx reload** (`docker-compose.yml`): the nginx container runs a background shell loop that polls for `/etc/letsencrypt/.reload-pending` every 60 seconds. Certbot's `--deploy-hook` touches that file on successful renewal. The loop issues `nginx -s reload` from inside the container and deletes the trigger file. No sidecar, no docker socket. (A docker.sock-mounting reloader was previously used and was removed as a host-root pivot.)

---

## What you can do after this

- Run `./backup/backup.sh --encrypt-all` on the VPS and `./pull-backup.sh` from your laptop to produce and retrieve a verified encrypted bundle.
- Rotate a DB password with `rotate-db-password.sh`, update the two `.env` files it identifies, and confirm the app reconnects cleanly.
- Read any script in the repo and identify which invariant each guard (cert check, `MYSQL_PWD`, `validate_identifier`, fd 3) is defending against.

---

[← Module 4 · Add an application](04-add-an-application-phase-2.md)  ·  [📚 Course index](../learning-path.md)
