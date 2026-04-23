# Keycloak + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/badge)](https://scorecard.dev/viewer/?uri=github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Contents

- [Why this stack?](#why-this-stack)
- [Getting started](#getting-started)
- [Features](#features)
  - [Typical use cases](#typical-use-cases)
- [Supply chain trust](#supply-chain-trust)
- [Production checklist](#production-checklist)
- [Backups](#backups)
- [Restoring a database backup](#restoring-a-database-backup)
- [Security Notes](#security-notes)
- [About the maintainer](#about-the-maintainer)

This repository deploys **Keycloak** behind **Traefik** with automatic **Let's Encrypt TLS**, backed by **PostgreSQL**, with a scheduled **backup container** and a companion **restore script**. One `docker compose up` away from a production-shaped identity-and-access-management service at `https://your-domain`.

📙 Full narrative installation guide on the blog: [heyvaldemar.com/install-keycloak-using-docker-compose/](https://www.heyvaldemar.com/install-keycloak-using-docker-compose/).

## Why this stack?

| Need | This stack | Manual install | Keycloak Helm (K8s) | Other compose examples |
|------|-----------|----------------|---------------------|------------------------|
| Ready to deploy in <10 min | ✅ | ❌ hours of setup | ✅ if K8s is already running | Often |
| TLS via Let's Encrypt, auto-renewed | ✅ Traefik ACME built-in | Manual certbot | Via cert-manager | Varies |
| Runs on Docker Compose (no Kubernetes required) | ✅ | N/A | ❌ K8s required | ✅ |
| PostgreSQL bundled with healthcheck + start-order dependency | ✅ | Separate install | ✅ | Varies |
| Scheduled DB backups + pruning | ✅ | Manual cron | External (Velero etc.) | Rare |
| One-command restore script | ✅ | Manual `pg_restore` | Manual | Rare |
| Upstream images pinned by `sha256` digest | ✅ | N/A | Depends on chart | Rare |
| Dependabot-tracked weekly updates | ✅ | N/A | Depends | Rare |
| CI-verified deployment on every push | ✅ | N/A | Varies | Rare |
| Credentials via env (never committed) | ✅ | N/A | K8s Secrets | Often committed plaintext |

Four moving parts (Traefik + Keycloak + Postgres + backups). No hidden complexity, no Kubernetes prerequisites, no manual certificate management.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose
cd keycloak-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create keycloak-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: KEYCLOAK_DB_PASSWORD, KEYCLOAK_ADMIN_PASSWORD,
#   TRAEFIK_BASIC_AUTH, TRAEFIK_ACME_EMAIL, TRAEFIK_HOSTNAME,
#   KEYCLOAK_HOSTNAME. See .env.example for generation commands.

# 4. Deploy
docker compose -f keycloak-traefik-letsencrypt-docker-compose.yml -p keycloak up -d
```

Within a minute or two, both `https://${KEYCLOAK_HOSTNAME}` (Keycloak UI) and `https://${TRAEFIK_HOSTNAME}` (Traefik dashboard, basic-auth protected) are live with fresh Let's Encrypt certificates.

Apply `.env` or compose-file changes:

```bash
docker compose -f keycloak-traefik-letsencrypt-docker-compose.yml -p keycloak up -d --force-recreate
```

## Features

- **Keycloak** latest stable (26.2.5) with PostgreSQL 16 backing store.
- **Traefik v3** reverse proxy with automatic HTTP→HTTPS redirect at entry-point level and Let's Encrypt TLS-ALPN challenge for cert issuance.
- **Basic-auth protected Traefik dashboard** on a separate hostname.
- **Prometheus metrics** exposed by Traefik (`--metrics.prometheus`) — wire your own scraper.
- **Healthchecks** on every service (Postgres `pg_isready`, Keycloak `/health/ready`, Traefik `/ping`) with service-dependency ordering (`depends_on: condition: service_healthy`).
- **Scheduled PostgreSQL backups** with configurable interval, retention, and destination path.
- **Automated restore script** (`keycloak-restore-database.sh`) with interactive backup selection.
- **Traefik exposed-by-default disabled** — only services with `traefik.enable=true` labels are routed.
- **Credentials required at deploy time** — compose fails fast if `.env` is incomplete, preventing accidental boots with empty or default credentials.

### Typical use cases

- **Self-hosted SSO for homelabs** — wire up Nextcloud, Grafana, Portainer, GitLab (or anything OIDC-capable) behind Keycloak federation.
- **Small-team identity provider** — consultancies, startups, internal tools that outgrew shared passwords.
- **Developer sandbox** — spin up a realistic Keycloak for integration testing without provisioning a managed IdP.
- **Step toward production Kubernetes** — run the Docker Compose stack first, validate the shape, then migrate to a Helm chart once the config is known-good.

## Supply chain trust

This repository is a **deployment template**, not a custom Docker image. It orchestrates three upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, Docker Hub official image
- [`quay.io/keycloak/keycloak`](https://quay.io/repository/keycloak/keycloak) — Keycloak upstream
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL, Docker Hub official image

All three are pinned to `tag@sha256:<digest>` in `.env.example`. Compose pulls by digest, not by tag. Two users deploying this repo on different days get byte-identical image manifests regardless of upstream repushes.

Dependabot's `docker` ecosystem watches each digest and opens a weekly PR when any of them changes. CI's **Deployment Verification** workflow runs on every push, pull request, and every Monday at 06:00 UTC — it stands up the full compose stack with ephemeral credentials, validates HTTPS routing + Traefik dashboard smoke, and tears down. Drift in upstream images surfaces within a week instead of on the next user deploy.

GitHub Actions are also pinned by commit SHA with `# vX.Y.Z` version comments. Dependabot's `github-actions` ecosystem keeps those fresh.

See [`SECURITY.md`](SECURITY.md) for the disclosure policy.

## Production checklist

Before exposing this to real users, check every box:

- [ ] **Rotate the bootstrap admin.** `KEYCLOAK_ADMIN_USERNAME`/`PASSWORD` create a single admin on first start. After login, create your real admin users (preferably via Keycloak Federation or a second-factor-protected account), then disable or delete the bootstrap admin from the Keycloak UI.
- [ ] **Strong secrets everywhere.** `KEYCLOAK_DB_PASSWORD` and `KEYCLOAK_ADMIN_PASSWORD` must be at least 24 random characters. Generate with `openssl rand -base64 24 | tr -d '/+=' | head -c 32`. Traefik dashboard BCrypt hash must be regenerated per deployment.
- [ ] **Host-mount the backups volume.** By default the `backups` service writes to a named docker volume. For disaster recovery, bind-mount it to a host path that's included in your off-host backup solution: `- /srv/keycloak-postgres/backups:/srv/keycloak-postgres/backups`.
- [ ] **Verify Let's Encrypt cert issuance.** Watch Traefik logs during first start: `docker compose -p keycloak logs traefik -f`. A successful TLS-ALPN challenge logs `Adding certificate for domain(s) ${KEYCLOAK_HOSTNAME}` within ~30 seconds.
- [ ] **Lock down the Traefik dashboard.** The dashboard is basic-auth protected by default, but basic auth is basic. Consider restricting the dashboard's router to specific source IPs via Traefik's `IPAllowList` middleware, or skip exposing it publicly and rely on `docker compose logs`.
- [ ] **Plan your upgrade path.** Keycloak does not guarantee DB-schema compatibility across major versions. Before bumping `KEYCLOAK_IMAGE_TAG` from 26.x to 27.x (when released), read Keycloak's migration guide, test the bump on a staging database restored from a recent backup.
- [ ] **Know the restore procedure.** Run `./keycloak-restore-database.sh` against a test environment before you need it in production. Document the `BACKUP_PATH` and restore steps alongside your other DR runbooks.

## Backups

The `backups` container runs on the same network as Postgres and performs:

1. **Dump** — `pg_dump` of the Keycloak database, gzipped, timestamp-named.
2. **Prune** — deletes backups older than `KEYCLOAK_POSTGRES_BACKUP_PRUNE_DAYS` days.
3. **Sleep** — waits `KEYCLOAK_BACKUP_INTERVAL` before the next dump.

All four variables (`KEYCLOAK_BACKUP_INIT_SLEEP`, `KEYCLOAK_BACKUP_INTERVAL`, `KEYCLOAK_POSTGRES_BACKUP_PRUNE_DAYS`, `KEYCLOAK_POSTGRES_BACKUPS_PATH`) are configured via `.env`; see `.env.example` for defaults (30-minute warm-up, 24-hour interval, 7-day retention).

## Restoring a database backup

`keycloak-restore-database.sh` handles the restore flow end-to-end:

1. Identifies the `keycloak` and `backups` containers by name.
2. Lists all available backups from the backups volume.
3. Prompts you to paste the exact backup filename.
4. Stops Keycloak (to avoid schema writes during restore).
5. Drops the live database, re-creates it, and pipes the gzipped backup into `psql`.
6. Restarts Keycloak.

Make the script executable, then run:

```bash
chmod +x keycloak-restore-database.sh
./keycloak-restore-database.sh
```

The script uses the `PGPASSWORD` inherited from the backups container, so no credentials need to be passed on the command line.

## Security Notes

- Credentials are read from `.env` at deploy time. `.env` is gitignored. The compose file uses `${VAR:?...}` syntax so `docker compose up` fails immediately with a helpful error if any required variable is missing.
- **Pre-rotation advisory.** Commits before [PR #12](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/pull/12) (merged 2026-04-23) committed real credential values. Those values remain in git history but are no longer referenced by any live file. Anyone who deployed with the pre-rotation configuration should rotate their live credentials and regenerate the Traefik dashboard BCrypt hash.
- Traefik dashboard is behind basic auth. Consider adding IP allow-listing for additional isolation.
- Upstream image digests are pinned; Dependabot auto-opens weekly PRs when digests change.
- CI runs on every push and every Monday to catch upstream drift.

See [`SECURITY.md`](SECURITY.md) for the vulnerability disclosure process.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
