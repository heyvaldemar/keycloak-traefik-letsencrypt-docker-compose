# Security Policy

## Supported Versions

| Version                                          | Status             |
|--------------------------------------------------|--------------------|
| Current `main` + tagged semver releases          | :white_check_mark: |
| Older tags / branches without a recent rebuild   | :x:                |

A formal release / maintenance-branch split will be introduced once this repo is tagged for the first semver release.

## Reporting a Vulnerability

Send reports to **v@valdemar.ai**. Encrypted email is preferred — the PGP public key is published at [heyvaldemar.com/security](https://heyvaldemar.com/security).

You can expect an acknowledgment within **7 days**. This project does not operate a bounty program; researchers who submit valid, responsibly disclosed reports receive public credit in the release notes and the changelog.

Please do not open public GitHub issues for security reports.

## Supply Chain Trust

This repository publishes a **deployment template**, not a custom Docker image. It orchestrates well-known upstream images:

- [`traefik`](https://hub.docker.com/_/traefik) — reverse proxy, official image
- [`quay.io/keycloak/keycloak`](https://quay.io/repository/keycloak/keycloak) — Keycloak upstream
- [`postgres`](https://hub.docker.com/_/postgres) — PostgreSQL, official image

Upstream image tags are pinned to specific versions and will migrate to immutable `@sha256:...` digests in an upcoming PR. Dependabot's `docker` ecosystem tracks digest bumps weekly.

## Known historical issue

Prior to PR #12 (merged 2026-04-23), `.env` committed real values for three credentials:

- `KEYCLOAK_DB_PASSWORD`
- `KEYCLOAK_ADMIN_PASSWORD`
- `TRAEFIK_BASIC_AUTH` (BCrypt hash)

Those values remain in git history but are no longer referenced by any live file. Anyone who deployed with the pre-rotation configuration should rotate their live credentials and regenerate the Traefik dashboard BCrypt hash. See PR #12 for details and the `.env.example` for the rotation procedure.
