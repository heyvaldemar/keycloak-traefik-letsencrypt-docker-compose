# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `LICENSE` — canonical MIT license text at repo root, `Copyright (c) 2021-2026 Vladimir Mikhalev (heyvaldemar)`.
- `SECURITY.md` — vulnerability disclosure policy, supported versions, supply-chain trust statement, and a callout for the pre-PR-#12 credential rotation advisory.
- `CHANGELOG.md` — this file, Keep-a-Changelog format.

### Changed
- Upstream images pinned by `sha256` digest in addition to tag in `.env.example`
  and the CI ephemeral `.env`. Three images are pinned:
  - `traefik:3.2@sha256:e561a37f…`
  - `postgres:16@sha256:71e27bf6…`
  - `quay.io/keycloak/keycloak:26.2.5@sha256:4883630e…`
  Docker compose now pulls the exact digest; silent upstream repushes cannot
  alter a given deployment. Dependabot's `docker` ecosystem (added in this
  release) auto-opens weekly PRs when upstream digests change.
- Dependabot gained a `docker` ecosystem to track upstream image digest bumps weekly, alongside the existing `github-actions` ecosystem. Both ecosystems now group minor/patch bumps into a single PR per week; major bumps continue to open individual PRs.
- GitHub Actions pinned by commit SHA instead of floating `@vN` tag — currently
  one action (`actions/checkout@de0fac2e…` # v6) in the deployment-verification
  workflow. Dependabot's `github-actions` ecosystem keeps the pin fresh.
- Deployment verification workflow hardened: explicit `permissions: contents: read`,
  `timeout-minutes: 15`, `concurrency` group keyed per-ref, weekly cron
  (`0 6 * * 1`) for upstream image drift detection, and `workflow_dispatch`
  trigger for manual runs. Workflow file renamed `00-deployment-verification.yml`
  → `deployment-verification.yml`.

### Removed
- `.github/FUNDING.yml` — sponsor discovery moves to heyvaldemar.com. Aligns with the same decision applied across other heyvaldemar public repositories.

### Security
- Credentials untracked from `.env` in PR #12 (merged 2026-04-23). `.env.example` now ships `change_me_*` placeholders and the docker-compose `${VAR:?}` syntax fails fast if required variables are unset.

## Project history prior to this changelog

Earlier commits did not follow Keep-a-Changelog. Highlights:

- **2021 (initial commit):** Keycloak + PostgreSQL + Traefik with Let's Encrypt deployment template.
- **2021–2025:** iterative updates to image tags (Traefik 1.x → 3.x, Keycloak 15.x → 26.x, PostgreSQL), healthcheck hardening, backup container with pruning.
- **2026-04:** alignment with the supply-chain hardening track established by [heyvaldemar/aws-kubectl-docker](https://github.com/heyvaldemar/aws-kubectl-docker).

[Unreleased]: https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/commits/main
