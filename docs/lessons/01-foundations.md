# 🧱 Module 1 — Foundations: the managed-cloud → VPS shift

![module](https://img.shields.io/badge/module-1-blue) ![type](https://img.shields.io/badge/type-concept-lightgrey)

You already know managed databases, load balancers + cert managers, caches, cloud firewall rules, workload identity, and container orchestration (RDS/Cloud SQL, ALB+ACM, ElastiCache, security groups, IAM, ECS — or the equivalents on your cloud). This module maps that mental model onto a single VPS running a shared Docker stack. The primitives are the same; the operational boundary moves to you.

**The stack at a glance:**

<img src="../diagrams/architecture.svg" alt="Shared VPS stack: Internet to nginx + certbot, fronting tenant apps and a static-file server with MariaDB and Redis on the private infra-net" width="480">

**On this page:** [🔌 The service map](#-the-service-map) · [🔑 Access model](#-access-model) · [🚀 What `provision-host.sh` sets up](#-what-provision-hostsh-sets-up) · [🐳 docker compose as your orchestration layer](#-docker-compose-as-your-orchestration-layer) · [🎯 What you can do after this](#-what-you-can-do-after-this)

---

## 🔌 The service map

| Managed cloud service | VPS equivalent |
|---|---|
| Managed LB + cert manager (ALB+ACM, Cloud Load Balancing + Certificate Manager, App Gateway + Key Vault) | nginx container (reverse proxy + TLS) |
| Managed cert auto-renewal | certbot container (Let's Encrypt, ~90-day auto-renew) |
| Managed relational database (RDS / Cloud SQL / Azure SQL) | MariaDB 11.4 container |
| Managed cache (ElastiCache / Memorystore / Azure Cache) | Redis 7.4 container |
| Cloud firewall rules (security groups / VPC firewall / NSGs) | ufw (default-deny, allow 22/80/443) |
| Cloud workload identity (IAM roles / service accounts / managed identities) | Linux users + `docker` group membership |
| Managed container orchestration (ECS·Fargate / Cloud Run / AKS) | docker compose |
| Infrastructure-as-code (CloudFormation, Terraform, Bicep) | bash scripts + rsync |
| Managed session service (SSM Session Manager / IAP / Bastion) | none — SSH is the only entry point |

**The shape of the stack:** one `docker-compose.yml` defines four services (`nginx`, `certbot`, `mariadb`, `redis`) on a shared user-defined network (`infra-net`). Independent application projects — "tenants" — attach to that same `infra-net` and connect to MariaDB/Redis by service name. Infra is application-agnostic; apps plug in only through a manifest, hooks, and an optional nginx locations snippet.

---

## 🔑 Access model

SSH is your only remote access path — no managed session service, no web console. Your laptop holds the repo; the VPS runs it. The deploy loop:

1. Edit files locally.
2. `rsync` the repo to the VPS (uses SSH as its transport):
   ```bash
   rsync -av --exclude='.git' ~/projects/personal/vps-infra/ root@<VPS_IP>:/opt/infra/
   ```
3. SSH into the VPS and run scripts there.

`rsync` handles bulk file transfer; it does not open an interactive shell. SSH (`ssh user@host`) is the separate step for running commands. `/opt/infra/` on the VPS is the working directory for all script invocations.

> [!NOTE]
> The initial `rsync` and provisioning run as `root`. Subsequent day-to-day operations run as the `deploy` user (see below).

---

## 🚀 What `provision-host.sh` sets up

`provision-host.sh` runs as root, once per host. Key actions verified against the script:

### Non-root `deploy` user + docker group

```bash
useradd -m -s /bin/bash "${DEPLOY_USER}"   # DEPLOY_USER defaults to "deploy"
usermod -aG docker "${DEPLOY_USER}"
```

This is your least-privilege equivalent to a managed compute instance role: `deploy` can manage the Docker stack but cannot modify the underlying OS. The `docker` group grants access to the Docker socket without root.

After `provision-host.sh` completes, the script only **warns** you to add the deploy SSH key — it prints `log_warn "Add SSH key to /home/${DEPLOY_USER}/.ssh/authorized_keys"` and moves on. The actual key installation and ownership fix (`chown -R deploy:deploy /home/deploy/.ssh`) are part of the one-time setup you do manually before using the `deploy` account. See [Module 3 — Phase 1: deploy the infra](03-deploy-phase-1.md) for the exact sequence.

> [!NOTE]
> The script *does* fix one ownership case for you: it runs `mkdir -p /home/deploy` then `chown -R deploy:deploy /home/deploy` on every run. `useradd -m` only sets home-dir ownership when it *creates* the directory — if `/home/deploy` was pre-created by root (common in cloud images), the deploy user would be unable to write its own `~/.docker` or `~/.cache`, silently breaking Docker and Composer. Running it unconditionally also self-heals hosts provisioned before this fix.

### ufw firewall (default-deny)

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH   # port 22
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Equivalent to cloud firewall rules (security groups / VPC firewall / NSGs) with only 22/80/443 inbound. Port 3306 (MariaDB) and 6379 (Redis) are never opened — those services are reachable only from within `infra-net`, not from the internet.

### fail2ban on SSH

Config written to `/etc/fail2ban/jail.local`: 5 failed attempts within 10 minutes → 1-hour IP ban. On a public IP, automated SSH probes are constant; this is the minimum viable mitigation.

### `.env` at mode 600

`bootstrap.sh` enforces `chmod 600 .env` before proceeding. `/opt/infra/.env` holds the MariaDB root password, the Redis password, and every project's DB password. Group- or world-readable means every tenant can read every other tenant's credentials.

### Host nginx (conditional stop)

`provision-host.sh` stops and disables a host-level nginx only if one is currently running (`systemctl is-active nginx`). On a fresh Ubuntu 24.04 VPS there typically isn't one; the guard is defensive.

---

## 🐳 docker compose as your orchestration layer

### Images, containers, and named volumes

Containers are ephemeral — destroy and recreate a container and its internal filesystem is gone. Persistent state lives in **named volumes** declared in `docker-compose.yml`:

```yaml
volumes:
  mariadb_data:    # MariaDB data files → /var/lib/mysql inside the container
  redis_data:      # Redis AOF/RDB persistence
  letsencrypt:     # TLS certificates (shared between nginx and certbot)
  certbot-webroot: # ACME HTTP-01 challenge files
```

`docker compose down` removes containers; named volumes survive. `docker compose down -v` removes volumes — almost never what you want.

### `infra-net`: service discovery by name

```yaml
networks:
  infra-net:
    external: true   # created once by bootstrap.sh; not torn down with compose down
    name: infra-net
```

`external: true` is the key difference from a default compose network. The network outlives the infra stack's lifecycle, which lets tenant app containers (started independently) stay on `infra-net` across infra restarts. Within the network, containers reach each other by service name: `mariadb:3306`, `redis:6379`.

### Per-service resource caps

You size each service, not an instance type. From `docker-compose.yml`:

| Service | `mem_limit` | `cpus` |
|---|---|---|
| nginx | 128m | 0.5 |
| certbot | 64m | 0.25 |
| mariadb | 768m | 1.0 |
| redis | 320m | 0.25 |

On a shared box, these caps prevent one service (or one tenant's traffic spike) from starving the rest — the role that separate instance types and auto-scaling play on managed cloud.

### Restart and privilege policy

Every service carries:

```yaml
restart: unless-stopped       # survives crashes and host reboots
security_opt:
  - no-new-privileges:true    # process cannot escalate privileges inside the container
```

`unless-stopped` is the VPS equivalent of a managed orchestrator keeping desired-count = 1. `no-new-privileges` blocks `sudo` / setuid escalation paths inside the container.

### certbot reload without the docker socket

Certbot's `--deploy-hook` writes a sentinel file (`/etc/letsencrypt/.reload-pending`) on successful renewal. The nginx container runs a background poll loop that watches for that file and issues `nginx -s reload` directly — no sidecar, no docker socket mount. A prior version used a reloader sidecar with a read-write docker socket; that was removed because a compromise of the sidecar yielded host root.

---

## 🎯 What you can do after this

- Read `docker-compose.yml` and recognize every field: which services exist, what volumes they mount, why `infra-net` is external.
- Explain the security posture: what ufw allows, why DB ports are not exposed, why `.env` is 600, what fail2ban does.
- Follow the deploy loop: edit locally → rsync → run on VPS — and know which step runs as root vs `deploy`.

---

[📚 Course index](../learning-path.md)  ·  [Module 2 · Inside the stack →](02-stack-internals.md)
