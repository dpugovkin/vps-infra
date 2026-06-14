# 🎓 Learning path — self-managing a VPS (for engineers coming from managed cloud)

![course](https://img.shields.io/badge/course-5_modules-blue) ![audience](https://img.shields.io/badge/for-cloud_engineers-lightgrey)

A 5-module course built around this repo — **`vps-infra`** (the shared stack: nginx, certbot, MariaDB, Redis, and the provisioning scripts) — and a generic tenant application that plugs into it (any web app). The course maps every concept to the actual code you'll run.

- *[concept]* modules are reading + architecture; no server required.
- *[do]* modules produce a real, running outcome on your VPS.
- Track progress with the checkboxes below.
- Companion runbook: [deploying-to-a-vps.md](deploying-to-a-vps.md) — terse end-to-end commands used in the *[do]* modules.
- Full tenant contract reference: [integrating-a-project.md](integrating-a-project.md).

**What you'll build:**

<img src="diagrams/architecture.svg" alt="Shared VPS stack: Internet to nginx + certbot, fronting tenant apps and a static-file server with MariaDB and Redis on the private infra-net" width="480">

---

## 🛡️ Ground rules

- The only sensitive operation is the *[do]* modules running on the VPS. Worst case: rebuild the box.
- Never paste `.env` contents into a chat or commit them to version control.

---

## 🧭 Part A — Foundations & internals

- [ ] **[🧱 Module 1 — Foundations: the managed-cloud → VPS shift](lessons/01-foundations.md)** *[concept]*
  Maps the managed services you already know — load balancer + cert manager, managed database, managed cache, cloud firewall rules, workload identity, container orchestration (ALB+ACM, RDS, ElastiCache, security groups, IAM, ECS — or your cloud's equivalents) — to their self-managed equivalents (nginx+certbot, MariaDB, Redis, ufw, OS users, compose+rsync). Covers the access model, host security posture, and docker-compose as the
  orchestration layer.
  *Outcome: you can reason about what each infra component replaces and why.*

- [ ] **[🌐 Module 2 — Inside the stack: request path & data](lessons/02-stack-internals.md)** *[concept]*
  Traces DNS→nginx→app; explains TLS termination and the ACME challenge flow on :80; walks the
  per-project vhost template, CSP header strategy, and rate-limit zone. Covers MariaDB per-tenant
  DB+GRANT isolation and Redis shared-password + key namespacing.
  *Outcome: you can follow a request from browser to app and explain where each service sits.*

---

## 🚀 Part B — Deploy & integrate

- [ ] **[🚀 Module 3 — Phase 1: deploy the infra](lessons/03-deploy-phase-1.md)** *[do]*
  provision-host.sh → SSH key + chown → `.env` → bootstrap.sh → verify stack is up.
  *Outcome: secured host running the shared nginx + MariaDB + Redis stack.*

- [ ] **[📦 Module 4 — Phase 2: add an application](lessons/04-add-an-application-phase-2.md)** *[concept + do]*
  The project↔infra contract (manifest vars, hooks, nginx snippet), then: DNS → obtain cert (before
  register) → register-project.sh → verify. Also covers the static-site path
  (`register-static-site.sh`) for frontend-only tenants that need no app container and no database.
  *Outcome: a tenant application live on HTTPS; frontend-only sites deployable via the static-site path.*

---

## 🔧 Part C — Operate

- [ ] **[🛠️ Module 5 — Operate it, and why it's built this way](lessons/05-operate-and-design.md)** *[concept + do]*
  Backups, restore, DB password rotation, reading logs, applying updates. Then the design rationale:
  the application-agnostic boundary, security invariants (cert-guard, secrets off argv, input
  validation), and what each constraint is protecting against.
  *Outcome: you can keep the stack running, recover from failures, and extend it without breaking the invariants.*

---

**Start here →** [🧱 Module 1 — Foundations: the managed-cloud → VPS shift](lessons/01-foundations.md)
