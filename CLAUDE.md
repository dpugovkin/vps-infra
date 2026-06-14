# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-VPS shared infrastructure stack: one Docker Compose stack per box running **nginx + certbot + MariaDB + Redis**. Multiple independent application projects ("tenants") attach to it over the external `infra-net` network. There is no application code here — only the shared services and the bash tooling to provision the host, bring up the stack, and plug projects in.

It is **bash + Docker Compose + nginx/MariaDB config**. There is no build step, no package manager, no test framework, and no application runtime.

## The central design principle: infra is application-agnostic

This is the most important invariant and it is actively enforced — **do not break it**. Infra provides *mechanisms and services*; each project provides *policy and content*. Infra has zero knowledge of what any tenant app is (WordPress, Node, static, …).

The boundary rule: **infra may execute project-declared intent; it must never embed an app's internals.** A manifest var like `DB_NAME=foo` is fine; a hardcoded `/var/www/html/web/wp` or `wp-login.php` in a shared template is a bug. When you touch shared config/scripts, never reintroduce app-specific knowledge. Projects plug in only through:

- **Manifest** `deploy/project.env` (declarative vars — see `docs/integrating-a-project.md`)
- **Backup/restore hooks** `deploy/hooks/{backup,restore}.sh` (project decides *what* to back up; the engine decides *how*)
- **Optional nginx snippet** `deploy/nginx-locations.conf` (custom locations / rate-limiting, installed into `nginx/conf.d/locations/<project>/`)
- **Scheduling** is the project's own job (its own compose sidecar) — infra installs **no** cron.

`lib/common.sh` even states this: it deliberately carries no project/app/DB knowledge.

## Lifecycle / control flow (spans multiple scripts)

1. `provision-host.sh` — run as **root**, once per host. Installs Docker + ufw + fail2ban, creates the `deploy` user (and enforces ownership of its home dir `/home/<user>` on every run — `useradd -m` only chowns the home dir when it *creates* it, so a pre-created root-owned `/home/<user>` would silently break Docker/Composer; this self-heals it), locks the firewall to SSH/80/443, disables any host nginx. Does not clone projects.
2. `bootstrap.sh` — run from `/opt/infra`, once. Enforces `chmod 600 .env`, creates the `infra-net` network, runs `render-init-sql.sh`, renders the global security-headers snippet, `docker compose up -d`.
3. **Obtain a TLS cert** via the certbot service **before** registering a project (see cert-guard below).
4. `register-project.sh <manifest>` — per project. Creates the DB+user (idempotent), installs the optional nginx-locations snippet, renders + validates + reloads the vhost.

Day-2 helpers: `rotate-db-password.sh <db_user>`, `backup/backup.sh`, `backup/restore.sh`, `pull-backup.sh`.

## Critical invariants — preserve these when editing

- **nginx cert-guard (`register-project.sh`):** never write a `443 ssl` vhost whose cert files don't exist. nginx validates *all* configs on container (re)start; a vhost pointing at a missing cert makes nginx fail to boot → `restart: unless-stopped` crash-loop → **every** site on the box goes down. The script checks the cert exists *inside* the nginx container first, renders, runs `nginx -t`, and `rm`s the vhost if validation fails. Keep this guard intact.
- **Secrets never on argv:** DB passwords are passed via `MYSQL_PWD` env to `docker exec`, and GPG passphrases via fd 3 — so other tenants can't see them in `ps`. Don't "simplify" these to `-p<pw>` or `--passphrase <pw>`.
- **`infra/.env` is the crown jewels:** holds the MariaDB root password, the shared Redis password, and *every* project's DB password. It's enforced to mode `600`. All scripts source it via `load_env`.
- **Validate untrusted-ish inputs before interpolating into SQL/sed:** `lib/common.sh` provides `validate_identifier`, `validate_hostname`, `validate_charset`, `validate_password_literal`. `register-project.sh` and `rotate-db-password.sh` use them so a quote/backslash can't break or inject the SQL string literals built by `docker exec ... mariadb -e "..."`.
- **nginx reload has no docker socket:** an in-container poll loop in the nginx service (`docker-compose.yml`) watches `/etc/letsencrypt/.reload-pending`; certbot's `--deploy-hook` touches that file on renewal. There is intentionally **no** reloader sidecar mounting `docker.sock` (that was removed as a host-root pivot). Don't reintroduce one.
- **Per-project DB password var name:** `register-project.sh` derives it as `${PROJECT_NAME^^}_PASSWORD` with `-` → `_` (so `my-app` → `MY_APP_PASSWORD` in `infra/.env`).
- **Backups are local-only:** offsite/rclone upload is deliberately disabled. The backup *engine* (`backup/backup.sh`) is generic — it calls the project's `deploy/hooks/backup.sh`, which must emit `${BACKUP_DIR}/db-${STAMP}.sql.gz` (required) and optionally `uploads-${STAMP}.tar.gz`. `--encrypt-all` produces a single AES-256 `bundle-<stamp>.tar.gz.gpg`. `pull-backup.sh` runs that over SSH and rsyncs the bundle to a local machine.

## Templates and rendering

nginx/SQL configs are templates rendered by `sed` placeholder substitution; the `*.template` files are tracked, the rendered output is runtime state (not meant to be committed — note there is currently **no** `.gitignore`, so be careful not to stage `.env`, `nginx/conf.d/<project>.conf`, `nginx/conf.d/locations/<project>/`, `nginx-static/conf.d/<project>.conf`, or `init/mariadb/01-databases.sql`).

- `nginx/conf.d/vhost.conf.template` → rendered per project by `register-project.sh`. Placeholders: `PROD_DOMAIN`, `__UPSTREAM__`, `__CSP__`, `__PROJECT_NAME__`. CSP is per-project (sent `Report-Only`); the `auth_limit` rate-limit zone (defined in `nginx/nginx.conf`) is opt-in via the project's locations snippet.
- `nginx/nginx.conf` — http-level config: port-80 ACME+redirect default server, a `443 default_server` with `ssl_reject_handshake on` (so unknown-SNI hits don't get a tenant's cert), and the generic `auth_limit` zone.
- `nginx/conf.d/00-security-headers.conf.template` — intentionally project-agnostic (no app allow-lists).
- `backup/cron.txt.template` does not exist — infra installs no cron (removed by design).
- `init/mariadb/01-databases.sql.template` is a `SELECT 1;` no-op; per-project DBs are created by `register-project.sh`, not by init SQL.

## Conventions

- All scripts: `#!/usr/bin/env bash` + `set -euo pipefail`, resolve their own dir via `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`, and `source lib/common.sh` for logging (`log`, `log_step`, `log_ok`, `log_warn`, `log_error`, `log_detail`), `require_root`, `load_env`, and the validators.
- Every Compose service declares `mem_limit` + `cpus` (multi-tenant box) and `security_opt: no-new-privileges`.

## Verifying changes (no test suite exists)

- Shell syntax: `bash -n <script>.sh` (used after every script edit in this repo).
- Lint: scripts carry `# shellcheck` directives — run `shellcheck *.sh lib/*.sh backup/*.sh` if available.
- Compose validity: `docker compose -f docker-compose.yml config`.
- nginx config (requires a running stack): `docker compose exec -T nginx nginx -t`.

## Docs

**Audience & framing.** The lessons are written for engineers who already know **managed cloud** (any vendor — not AWS-specific) but are new to self-managing a bare VPS. Each piece is framed as "the managed service you know → its self-managed equivalent," **brand-agnostic** with light vendor-example parentheticals (e.g. "a managed database (RDS / Cloud SQL / Azure SQL)"). Preserve that framing when editing.

**Tenant- and brand-agnostic — keep it that way.** No specific tenant app and no single cloud vendor is assumed anywhere. Use neutral placeholders (`myapp`, `MYAPP_PASSWORD`, `<project>`, `example.com`, `you@example.com`) and generic cloud terms. Do **not** reintroduce a named tenant/store or a one-vendor framing.

- `docs/learning-path.md` — index for the 5-module lessons course in `docs/lessons/`: `01-foundations` (managed-cloud → VPS shift) · `02-stack-internals` (request path + data) · `03-deploy-phase-1` (deploy the infra) · `04-add-an-application-phase-2` (the project↔infra contract + go-live) · `05-operate-and-design` (day-2 ops + invariants).
- `docs/deploying-to-a-vps.md` — terse end-to-end command runbook (Phase 1 + Phase 2 + day-2); no teaching prose.
- `docs/integrating-a-project.md` — consumer guide for tenant projects (the full manifest + hook + connection contract), with copy-paste templates in `docs/examples/`.
- `README.md` — terse operator/ops reference (host setup incl. deploy-user SSH key + `.ssh` chown, TLS, DB password rotation, backups).
- Lessons/guides use GitHub-flavored markdown: one H1 per file, `> [!NOTE]`/`[!WARNING]`/`[!CAUTION]` alerts, and section icons. Keep that styling consistent when editing.
