# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `.github/workflows/scorecard.yml` — OpenSSF Scorecard analysis workflow.
  Runs weekly on Tuesdays at 06:00 UTC (one day after the Monday deployment
  verification run), on every push to `main`, and on branch-protection-rule
  changes. Publishes results to the public OpenSSF API (scorecard.dev
  viewer) and uploads SARIF to the GitHub Security tab. All action pins
  are commit-SHA based, including the dereferenced commit SHA for the
  annotated-tag `ossf/scorecard-action@v2.4.3` (plain `@v2.4.3` tag-object
  SHA is rejected by Scorecard's imposter-commit verification).
- README badge for OpenSSF Scorecard, placed between the Deployment
  Verification and License badges.
- `LICENSE` — canonical MIT license text at repo root, `Copyright (c) 2021-2026 Vladimir Mikhalev (heyvaldemar)`.
- `SECURITY.md` — vulnerability disclosure policy, supported versions, supply-chain trust statement, and a callout for the pre-PR-#12 credential rotation advisory.
- `CHANGELOG.md` — this file, Keep-a-Changelog format.

### Changed
- **Backup/restore safety hardening.** Closes four HIGH-severity gaps in the
  backup + restore flow identified during the post-runbook-v1.2 audit. No
  functional regression — existing backups remain restorable by the new
  script.
  - `keycloak-restore-database.sh` now sources `.env` so the DB name, user,
    and backup path match whatever is deployed (previously hardcoded to the
    defaults, which broke on customisation).
  - Script runs under `set -euo pipefail`; any failure mid-flow aborts with
    non-zero exit instead of silently continuing.
  - `gunzip -t` integrity check runs against the selected backup BEFORE the
    live database is touched. A corrupt archive is caught here, not mid-
    restore with a half-loaded DB.
  - Requires typing `DESTROY` to confirm the destructive operation. Any
    other input (including empty / accidental Enter) aborts without
    changes.
  - Takes a pre-restore snapshot of the CURRENT database state to
    `/tmp/pre-restore-<timestamp>.gz` inside the backups container BEFORE
    dropping the live DB. The snapshot path is printed; if the restore
    produces a broken DB, the script exits non-zero and prints the exact
    command to recover from the snapshot.
  - Post-restore verification: waits up to 2 minutes for Keycloak's
    healthcheck to report `healthy`, then runs a sanity query asserting
    the `public` schema has >0 tables. Either check failing prints the
    rollback-from-snapshot command and exits non-zero.
  - Selection input validated against the listed backup filenames —
    rejects typos and path-traversal ( `../` etc.).
- **Backup loop hardened in the `backups` compose service.**
  `pg_dump | gzip > file` now runs under `set -o pipefail`, so a `pg_dump`
  error fails the pipe instead of silently producing an empty gzip.
  Failed backups are renamed `*.failed` for post-hoc diagnosis instead of
  overwriting the next cycle. Each cycle emits one timestamped log line
  (`[TIMESTAMP] Backup OK: <path> (<bytes>)` or `... Backup FAILED`).
  The prune scope is restricted to `${KEYCLOAK_POSTGRES_BACKUP_NAME}-*.gz`
  (cannot delete unrelated files) and `PRUNE_DAYS=0` disables pruning
  entirely instead of deleting everything. `find -delete` replaces
  `find | xargs rm -f` for idiomatic correctness on empty input.
- README Backups + Restore sections expanded with observability command
  (`docker compose logs backups | tail -20` + expected output shape),
  off-host-replication override example, and an RTO/RPO table with
  tightening knobs.
- Deployment-verification workflow gained two new jobs:
  - **`lint`** — runs `shellcheck` (via `koalaman/shellcheck-alpine:stable`) on
    every `*.sh` in the repo root, and `actionlint` (via
    `rhysd/actionlint:1.7.12`) on every workflow YAML. Blocks `deploy-and-test`
    via `needs: lint` so CI fails fast on typos and footguns before burning
    the 15-minute compose-up slot.
  - **`scan-trivy`** — matrix job scanning each pinned upstream image
    (`postgres:16@sha256:…`, `traefik:3.2@sha256:…`,
    `quay.io/keycloak/keycloak:26.2.5@sha256:…`) for CRITICAL/HIGH fixable
    CVEs via `aquasecurity/trivy-action@v0.35.0`, uploading per-image SARIF
    to the GitHub Security tab under categories `trivy-postgres`,
    `trivy-traefik`, `trivy-keycloak`. Runs parallel to `deploy-and-test`
    with `continue-on-error: true` — findings don't block deployment but
    surface for triage via Dependabot digest bumps.
- Resolved pre-existing shellcheck warnings (SC2034, SC2086, SC2162) in
  `keycloak-restore-database.sh`; fixed the README `server.cfg` leftover
  phrasing. Both shipped in PR #18.
- README rewritten for evaluator-first audience. Replaces the prior affiliate-and-socials-heavy footer with a focused technical structure: badges, table of contents, "Why this stack?" comparison table vs manual install / Helm / other compose examples, Getting started quickstart, Features + Typical use cases, Supply chain trust, Production checklist (7-item deployment-readiness check), preserved Backups and Restore sections, Security Notes, compact maintainer footer (YouTube · Blog · LinkedIn). Removes: first-person bio, "My Courses", "My Services", Patreon tiers, affiliate kit.co links, crypto wallet addresses, Discord invite, octocat gif, footer SVG.
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
- `SECURITY.md` Supply Chain Trust section synced with
  [self-host-repo-hardening-runbook v1.2](https://github.com/heyvaldemar/self-host-repo-hardening-runbook/releases/tag/v1.2.0)
  template. Replaces the stale "will migrate to immutable `@sha256:...` digests
  in an upcoming PR" language (that migration shipped in PR #14) with the
  current-state description: digests pinned in `.env.example`, Dependabot
  weekly bumps, CI weekly drift detection. Adds the GitHub-Actions-pinned-by-
  commit-SHA statement that the template now includes.

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
