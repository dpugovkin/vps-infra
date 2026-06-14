# 🔗 Running a project on the shared infra

![doc](https://img.shields.io/badge/doc-integration_contract-9cf) ![audience](https://img.shields.io/badge/for-tenant_projects-lightgrey)

**On this page:** [How it works](#-how-it-works-the-contract) · [Prerequisites](#-prerequisites) · [Step 1 — Manifest](#-step-1--write-your-manifest-deployprojectenv) · [Step 2 — DB password](#-step-2--add-your-db-password-to-infraenv) · [Step 3 — infra-net](#-step-3--attach-your-app-to-infra-net-and-set-connection-env) · [Step 4 — TLS](#-step-4--get-a-tls-certificate-before-registering) · [Step 5 — Register](#-step-5--register-the-project) · [Opt-in: nginx locations](#-opt-in-custom-nginx-locations--login-rate-limiting) · [Opt-in: scheduled tasks](#-opt-in-scheduled-tasks) · [Backups](#-backups) · [Gotchas / checklist](#-gotchas--checklist)

## 🧭 How it works (the contract)

Infra provides **mechanisms and services**: TLS termination and reverse proxy via nginx, a MariaDB engine, a Redis engine, a generic backup/restore engine, and a generic `auth_limit` rate-limit zone. Your project provides **policy and content** via a manifest file plus optional hook and snippet files. Infra has zero knowledge of what your application is — it never calls your app directly, never installs cron jobs on your behalf, and never touches your code.

The split:

| Infra owns | Your project owns |
|---|---|
| nginx config, TLS, vhost template | `deploy/project.env` manifest |
| MariaDB engine, DB/user creation | Schema, migrations, content |
| Redis engine, auth | Redis key namespacing, TTL policy |
| Backup/restore engine | `deploy/hooks/backup.sh`, `deploy/hooks/restore.sh` |
| `auth_limit` rate-limit zone | `deploy/nginx-locations.conf` (opt-in) |

---

## 📋 Prerequisites

- Your project lives on the VPS at `/opt/<project>` and is already deployed there.
- The infra stack is up (`/opt/infra`, started with `docker compose up -d`) and the `infra-net` external Docker network exists.
- You (or the operator) have shell access to `/opt/infra/.env`.

---

## 🔌 Step 1 — Write your manifest (`deploy/project.env`)

Create `deploy/project.env` at the root of your project's `deploy/` directory. All variables below are required by `register-project.sh` unless noted otherwise.

| Variable | Required by | Charset / format | Description |
|---|---|---|---|
| `PROJECT_NAME` | `register-project.sh`, backup engine | `[A-Za-z0-9_-]` | Names the vhost conf file, the `conf.d/locations/<name>/` dir, the DB-password env-var lookup, and `/var/backups/<name>/`. |
| `DOMAIN` | `register-project.sh` | valid hostname | Domain for the vhost and TLS certificate. |
| `UPSTREAM` | `register-project.sh` | `[A-Za-z0-9_.:-]+` | Your app container and port reachable on `infra-net`, e.g. `myapp:8080`. The host part **must be unique** across the whole box. |
| `DB_NAME` | `register-project.sh` | `[A-Za-z0-9_]` | Database name to create (idempotent). |
| `DB_USER` | `register-project.sh` | `[A-Za-z0-9_]` | Database user to create (grant scoped to `DB_NAME` only). |
| `PROJECT_DIR` | backup engine | absolute path | Absolute path to your project root on the VPS, e.g. `/opt/myapp`. |
| `CSP` | `register-project.sh` | CSP string | **Optional.** Per-project Content-Security-Policy, sent as `Content-Security-Policy-Report-Only`. Omit to use the safe self-only default: `default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'`. |
| `WWW_REDIRECT` | `register-project.sh` | `0` or `1` | **Optional.** Set to `1` to add a `www.<DOMAIN>` → `<DOMAIN>` 301 redirect. Requires the TLS cert to also cover `www.<DOMAIN>`. |

The DB password is **not** in this file — see Step 2.

See the copy-paste template at [`docs/examples/project.env`](examples/project.env).

---

## 🔑 Step 2 — Add your DB password to `infra/.env`

The operator adds one line to `/opt/infra/.env`:

```bash
<PROJECT_NAME>_PASSWORD=<password>
```

`register-project.sh` derives the variable name by uppercasing `PROJECT_NAME` and replacing every `-` with `_`:

```text
PROJECT_NAME=my-app  →  MY_APP_PASSWORD
PROJECT_NAME=myapp   →  MYAPP_PASSWORD
```

Generate a strong password:

```bash
openssl rand -hex 32
```

`/opt/infra/.env` is enforced to mode `600` — keep it that way.

**This must be done before running `register-project.sh`** (the script exits immediately if the variable is missing).

---

## 🌐 Step 3 — Attach your app to `infra-net` and set connection env

Your app container must join the external `infra-net` network. It must **not** publish host ports — nginx proxies to it internally over `infra-net`. The service or network alias name you give the container on `infra-net` is what `UPSTREAM` points at, and it must be unique across the whole box. Naming it the same as `PROJECT_NAME` is the recommended convention.

See the snippet at [`docs/examples/docker-compose.snippet.yml`](examples/docker-compose.snippet.yml).

Set the following environment variables in your app container:

```env
DB_HOST=mariadb
DB_NAME=<your DB_NAME>
DB_USER=<your DB_USER>
DB_PASSWORD=<same value as infra/.env <PROJECT>_PASSWORD>
REDIS_HOST=redis
REDIS_PASSWORD=<same value as infra/.env REDIS_PASSWORD>
REDIS_DB=0
```

| Variable | Value | Notes |
|---|---|---|
| `DB_HOST` | `mariadb` | Fixed service name on `infra-net`. |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | from manifest / `infra/.env` | Password is in `infra/.env` under `<PROJECT>_PASSWORD`. |
| `REDIS_HOST` | `redis` | Fixed service name on `infra-net`. |
| `REDIS_PASSWORD` | from `infra/.env REDIS_PASSWORD` | Shared infra-wide — copy the value, do not generate a new one. |
| `REDIS_DB` | `0`–`15` | **Each tenant should pick a unique integer** to namespace its keys. Redis is shared; without this, projects collide in DB 0. |


> [!NOTE]
> Infra does not generate your project's `.env`. You hand-author it (or template it from your own deploy tooling) using the values above. The `env_file: .env` line in your `docker-compose.yml` loads it into the container at runtime.
>
> `REDIS_DB` is not validated or enforced by infra — it is a convention that protects tenants from key collisions on the shared Redis instance.

---

## 🔒 Step 4 — Get a TLS certificate (BEFORE registering)


> [!CAUTION]
> `register-project.sh` is cert-guarded: it will **not** write the SSL vhost until the certificate exists on disk. A vhost that references a missing certificate causes nginx to fail to start on the next restart, which takes down every site on the box.

Run from `/opt/infra`:

```bash
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d <domain> --agree-tos -m you@example.com --no-eff-email
```

Once the cert is in place, proceed to Step 5. (If you already ran `register-project.sh` before obtaining the cert, just re-run it after — the script is idempotent.)

---

## 🎯 Step 5 — Register the project

Run from `/opt/infra`:

```bash
./register-project.sh /opt/<project>/deploy/project.env
```

What the script does (verified from source):

1. Validates all manifest variables against their allowed charsets.
2. Looks up `<PROJECT_NAME>_PASSWORD` from `infra/.env` (exits if missing).
3. Creates the database and user with `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` and a `GRANT ALL PRIVILEGES ON <DB_NAME>.*` — scoped to your database only, no global privileges.
4. If `deploy/nginx-locations.conf` exists alongside the manifest, copies it into `nginx/conf.d/locations/<PROJECT_NAME>/locations.conf`.
5. Renders the vhost from the template and writes `nginx/conf.d/<PROJECT_NAME>.conf`.
6. Runs `nginx -t` inside the nginx container. If validation fails, removes the vhost file immediately (so it cannot poison nginx) and exits with an error. If validation passes, reloads nginx.

Re-running `register-project.sh` is safe — database creation is idempotent and the vhost is overwritten in place.

---

## 🌐 Opt-in: custom nginx locations / login rate-limiting

Infra exposes a generic `auth_limit` rate-limit zone. To use it — or to add any custom `location` blocks — ship a file at `deploy/nginx-locations.conf` next to your manifest. `register-project.sh` installs it into `conf.d/locations/<PROJECT_NAME>/` and the vhost includes it inside the `443` server block automatically. If no file is present, your project gets a plain reverse proxy with no custom location rules.

See the example at [`docs/examples/nginx-locations.conf`](examples/nginx-locations.conf).

---

## 🎯 Opt-in: scheduled tasks

Infra installs **no cron jobs**. If your application needs scheduled work — cron jobs, queue workers, periodic cleanup, etc. — run it from your own `docker-compose` as a sidecar container. Infra is not involved.

---

## 💾 Backups

Backups are **manual** and driven by two hook scripts your project ships. Both must be executable (`chmod +x`).

### Hooks your project must provide

**`deploy/hooks/backup.sh`**

The infra backup engine exports three variables before calling this hook:

| Variable | Value |
|---|---|
| `STAMP` | Timestamp string, e.g. `2024-06-14_1430` |
| `BACKUP_DIR` | Directory where backup files must be written (e.g. `/var/backups/<project>`) |
| `APP_DIR` | Absolute path to your project root (from `PROJECT_DIR` in the manifest) |

Your hook **must** write `${BACKUP_DIR}/db-${STAMP}.sql.gz`. It may also write `${BACKUP_DIR}/uploads-${STAMP}.tar.gz` (optional). No other filenames are recognised by the engine.

See [`docs/examples/hooks/backup.sh`](examples/hooks/backup.sh).

**`deploy/hooks/restore.sh`**

The infra restore engine exports:

| Variable | Value |
|---|---|
| `APP_DIR` | Absolute path to your project root |
| `DB_FILE` | Path to the chosen `db-*.sql.gz` backup file |
| `UPLOADS_FILE` | Path to the chosen `uploads-*.tar.gz`, or empty string if none exists |

Your hook restores from these files. The engine takes a pre-restore safety snapshot (by calling your `backup.sh` hook into a `restore-history/` sibling directory) before invoking your `restore.sh`.

See [`docs/examples/hooks/restore.sh`](examples/hooks/restore.sh).

### Operator commands

**Run a backup on the VPS** (local-only; prunes copies older than `BACKUP_LOCAL_DAYS` days, default 14):

```bash
./backup/backup.sh /opt/<project>/deploy/project.env
```

**Single encrypted bundle** (db + uploads + `.env`, AES-256 GPG, passphrase from `BACKUP_GPG_PASSPHRASE` in `infra/.env`):

```bash
./backup/backup.sh --encrypt-all /opt/<project>/deploy/project.env
```

Produces `bundle-<stamp>.tar.gz.gpg` in `/var/backups/<project>/`.

**Pull to your laptop in one step** (runs `--encrypt-all` remotely over SSH, then rsyncs the bundle down):

```bash
./pull-backup.sh deploy@your-vps /opt/<project>/deploy/project.env ~/vps-backups
```

**Restore** (prompts for confirmation, takes a pre-restore safety snapshot, then calls your restore hook):

```bash
./backup/restore.sh /opt/<project>/deploy/project.env [backup-dir]
```

`[backup-dir]` defaults to `/var/backups/<project>` if omitted. The script picks the most recent `db-*.sql.gz` and `uploads-*.tar.gz` files automatically.

---

## ⚠️ Gotchas / checklist

- [ ] `UPSTREAM` host part is **unique** on `infra-net` across the whole box (naming it `PROJECT_NAME` is the safe default).
- [ ] `<PROJECT_NAME>_PASSWORD` is added to `infra/.env` **before** running `register-project.sh`.
- [ ] TLS certificate is obtained via certbot **before** running `register-project.sh`.
- [ ] `REDIS_PASSWORD` is shared infra-wide — copy the value from `infra/.env`, do not generate a new one.
- [ ] `REDIS_DB` is set to a unique integer (e.g. `1`, `2`, …) so your project's keys do not collide with other tenants in Redis DB 0.
- [ ] Your app container does **not** publish host ports (`ports:` in docker-compose); nginx is the only public entry point.
- [ ] `DB_USER` is granted privileges on `DB_NAME` only — it cannot access other projects' databases.
- [ ] Both `deploy/hooks/backup.sh` and `deploy/hooks/restore.sh` are executable (`chmod +x`).
- [ ] `PROJECT_DIR` in the manifest matches the actual path on the VPS (`/opt/<project>`).

---

## 🗂️ Static sites (frontend-only, no app container)

Use this path when your project is a built frontend (SPA or plain multi-page static site) with **no server-side runtime**. Files are served directly from disk — there is no app container, no DB, and no Redis connection.

### When to use it

- The output is a directory of static files (HTML, CSS, JS, assets) produced by a build step.
- All routing either happens client-side (SPA) or maps 1:1 to real files (plain static).
- No server-side logic, no database, no session state managed by the app.

### Manifest (`deploy/static.env`)

| Variable | Required | Charset / format | Description |
|---|---|---|---|
| `PROJECT_NAME` | yes | `[A-Za-z0-9_-]` | Names the static server-block conf file (`nginx-static/conf.d/<name>.conf`) and the edge vhost (`nginx/conf.d/<name>.conf`). |
| `DOMAIN` | yes | valid hostname | Domain for the edge vhost and TLS certificate. |
| `STATIC_FALLBACK` | yes | `spa` or `static` | `spa` — unknown paths fall back to `index.html` (client-side routing). `static` — unknown paths return 404. |
| `CSP` | no | CSP string | Per-site Content-Security-Policy, sent `Report-Only` on the edge vhost. Omit for the safe self-only default. |
| `WWW_REDIRECT` | no | `0` or `1` | Set to `1` to add a `www.<DOMAIN>` → `<DOMAIN>` 301 redirect. Requires the TLS cert to also cover `www.<DOMAIN>`. |

> [!CAUTION]
> Do **not** set `UPSTREAM` in the static manifest. The script hard-codes `static:8080` automatically; setting it has no effect and may confuse readers.

See the copy-paste template at [`docs/examples/static.env`](examples/static.env).

### Deploy convention — `/srv/www/<domain>`

Built files are placed in `/srv/www/<domain>/` on the VPS host. The static container mounts `/srv/www` read-only and serves each site from the matching subdirectory by `Host` header.

```bash
# First deploy (or subsequent updates — same command, no re-registration needed)
rsync -a ./dist/ deploy@<VPS_IP>:/srv/www/<domain>/
```

Updating a site is just another `rsync`. No container restart, no re-registration — the static server block and the edge vhost are unchanged.

### Registration

> [!CAUTION]
> The same cert-guard that applies to normal projects applies here: `register-static-site.sh` will not write the SSL edge vhost until the TLS certificate exists on disk. Obtain the cert first (see below).

Run from `/opt/infra`:

```bash
# 1. Create the web root and deploy the build
mkdir -p /srv/www/<domain>
rsync -a ./dist/ /srv/www/<domain>/

# 2. Obtain the TLS cert (required before registering)
docker compose run --rm --entrypoint certbot certbot certonly --webroot -w /var/www/certbot \
  -d <domain> --agree-tos -m you@example.com --no-eff-email

# 3. Register
./register-static-site.sh /opt/<project>/deploy/static.env
```

What the script does:

1. Validates `PROJECT_NAME`, `DOMAIN`, and `STATIC_FALLBACK`.
2. Resolves `STATIC_FALLBACK` → nginx `try_files` directive; renders `nginx-static/site.conf.template` → `nginx-static/conf.d/<PROJECT_NAME>.conf`.
3. Runs `nginx -t` inside the static container; on failure removes the rendered block and exits non-zero.
4. Calls the shared `render_edge_vhost` function (same cert-guard as `register-project.sh`) to write and validate `nginx/conf.d/<PROJECT_NAME>.conf`, then reloads the edge nginx.

No DB is created. No password is required in `infra/.env`.

Re-running `register-static-site.sh` is safe — both config files are overwritten in place.

### Static-site checklist

- [ ] Built files are in `/srv/www/<domain>/` on the VPS before registering.
- [ ] `STATIC_FALLBACK` is set to `spa` (client-side routing) or `static` (real-file 404).
- [ ] `UPSTREAM` is **not** set in the manifest.
- [ ] TLS certificate is obtained via certbot **before** running `register-static-site.sh`.
- [ ] `PROJECT_NAME` is unique on the box (no collision with a `register-project.sh` project).

---

**See also:** [📚 Lessons course](learning-path.md)  ·  [📋 Runbook](deploying-to-a-vps.md)
