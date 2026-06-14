# 🚀 Module 3 — Phase 1: deploy the infra

![module](https://img.shields.io/badge/module-3-blue) ![type](https://img.shields.io/badge/type-hands--on-brightgreen)

Turn a bare Ubuntu 24.04 VPS into the running shared stack (nginx + certbot + MariaDB + Redis). No application is deployed here — that is [Module 4 — Phase 2: add an application](04-add-an-application-phase-2.md).

**On this page:** [Before you start](#-before-you-start) · [Step 1 — Copy the repo to the VPS](#-step-1--copy-the-repo-to-the-vps) · [Step 2 — Run `provision-host.sh`](#-step-2--run-provision-hostsh) · [Step 3 — SSH key and ownership for the `deploy` user](#-step-3--ssh-key-and-ownership-for-the-deploy-user) · [Step 4 — Create `.env`](#-step-4--create-env) · [Step 5 — Run `bootstrap.sh`](#-step-5--run-bootstrapsh) · [Step 6 — Verify](#-step-6--verify) · [What you have now](#-what-you-have-now)

---

## 📋 Before you start

- Ubuntu 24.04 VPS with a known IP address and root password
- Your SSH public key (`~/.ssh/id_ed25519.pub` on your laptop; run `ssh-keygen` once if absent)
- This repo checked out locally

---

## 🚀 Step 1 — Copy the repo to the VPS

Run on **your laptop**:

```bash
rsync -av --exclude='.git' /path/to/vps-infra/ root@<VPS_IP>:/opt/infra/
```

The trailing `/` on the source path is required — it copies the contents into `/opt/infra/`, not a nested subdirectory. Accept the host fingerprint on first connect, then enter the root password.

**Success:** a file list scrolls by and the command exits cleanly.

---

## 🚀 Step 2 — Run `provision-host.sh`

SSH in as root, then:

```bash
ssh root@<VPS_IP>
cd /opt/infra
./provision-host.sh
```

What the script does:

- Installs Docker (CE + Compose plugin) from the official Docker apt repo
- Installs `ufw` and opens only ports 22, 80, 443; blocks everything else
- Installs `fail2ban` with SSH brute-force protection (5 retries → 1 h ban)
- Creates the `deploy` OS user and adds it to the `docker` group
- Stops and disables any host nginx (it would conflict on ports 80/443)

**Success:** the script ends with:

```
Host ready. Next: ./bootstrap.sh, then ./register-project.sh <project.env>
```

---

## 🔑 Step 3 — SSH key and ownership for the `deploy` user

> [!CAUTION]
> This is the most common silent failure. `sshd` opens `authorized_keys` as the target user, not as root. If `/home/deploy/.ssh` is still owned by root, the kernel's permission check fails — key auth silently falls through to password auth. The `chown` below is mandatory.

> [!NOTE]
> The `chown` below is only for `.ssh`. The deploy user's *home directory itself* (`/home/deploy`) is handled automatically by `provision-host.sh`, which enforces `chown -R deploy:deploy /home/deploy` on every run. That guards a separate silent failure: if `/home/deploy` was pre-created root-owned, the deploy user can't create `~/.docker` or `~/.cache`, and Docker and Composer break with no obvious error.

Still on the VPS as root:

```bash
mkdir -p /home/deploy/.ssh
nano /home/deploy/.ssh/authorized_keys      # paste your PUBLIC key; Ctrl-O Enter Ctrl-X to save
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh && chmod 600 /home/deploy/.ssh/authorized_keys
```

Also hand ownership of `/opt/infra` to the deploy user so it can manage the stack day-to-day:

```bash
chown -R deploy:deploy /opt/infra
```

**Success:** from a new terminal on your laptop, `ssh deploy@<VPS_IP>` logs in with no password prompt.

If it still prompts for a password, re-check ownership and modes:

```bash
ls -lan /home/deploy/.ssh
```

Expected: directory owned by the numeric UID of `deploy`, mode `700`; `authorized_keys` mode `600`.

---

## 📋 Step 4 — Create `.env`

```bash
cd /opt/infra
cp .env.example .env
openssl rand -hex 32   # run twice — one output per required password
nano .env
```

Required Phase-1 variables:

| Variable | Purpose |
|---|---|
| `MARIADB_ROOT_PASSWORD` | MariaDB server master admin — never typed by hand |
| `REDIS_PASSWORD` | Shared infra-wide cache password — **every tenant reuses this exact value** in its own config |

Use a separate `openssl rand -hex 32` output for each. Do not reuse values.

> [!NOTE]
> Per-project secrets like `<PROJECT>_PASSWORD` are **not** in `.env.example` — they are project-specific, so you add them to `.env` in Phase 2 (before running `register-project.sh`), not now.

> [!NOTE]
> `.env.example` ships with `BACKUP_REQUIRE_ENV_BACKUP=1`. With this set, the backup script will refuse to run unless `BACKUP_GPG_PASSPHRASE` is also set. Either set a strong passphrase now (another `openssl rand -hex 32` output works), or leave it for [Module 5 — Operate it, and why it's built this way](05-operate-and-design.md). If you skip it now, backups will error until you return to it.

`bootstrap.sh` enforces `chmod 600 .env` automatically, but setting it yourself is harmless:

```bash
chmod 600 .env
```

---

## 🚀 Step 5 — Run `bootstrap.sh`

```bash
./bootstrap.sh
```

What it does, in order:

1. Exits if `.env` is missing
2. Enforces `chmod 600 .env`
3. Creates the `infra-net` Docker bridge network (containers communicate over it by service name)
4. Calls `render-init-sql.sh` — renders the MariaDB init SQL from its template
5. Copies `nginx/conf.d/00-security-headers.conf.template` → `nginx/conf.d/00-security-headers.conf`
6. Runs `docker compose up -d` — pulls images and starts all four containers

**Success:** the script exits without errors.

```bash
docker compose ps
```

All four services (`nginx`, `certbot`, `mariadb`, `redis`) should show status `Up`.

> [!NOTE]
> `docker-compose.yml` defines no healthchecks. The status column will show `Up`, not `Up (healthy)`. That is correct.

---

## ✅ Step 6 — Verify

```bash
docker compose ps          # all four services Up
curl -I http://<VPS_IP>    # nginx is answering
```

`curl` should return `HTTP/1.1 301 Moved Permanently`. That is nginx redirecting plain HTTP to HTTPS — correct behavior when no site is configured.

There is no website yet, and that is intentional. Unknown-SNI HTTPS connections are rejected at the `443 default_server` (`ssl_reject_handshake on` in `nginx/nginx.conf`).

If `curl` returns `Connection refused`, nginx did not start. Check:

```bash
docker compose logs nginx
```

---

## 🎯 What you have now

- A locked-down host (ufw + fail2ban) with the four shared services running on `infra-net`
- Next: [Module 4 — Phase 2: add an application](04-add-an-application-phase-2.md) — obtain a TLS cert and register the first tenant

---

[← Module 2 · Inside the stack](02-stack-internals.md)  ·  [📚 Course index](../learning-path.md)  ·  [Module 4 · Add an application →](04-add-an-application-phase-2.md)
