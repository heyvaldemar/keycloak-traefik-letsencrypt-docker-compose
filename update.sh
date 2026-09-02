#!/bin/bash
# Unattended update to the latest RELEASED state of this template.
#
# Design, in one paragraph: releases are the update channel. A tag is cut
# only after CI has built the pinned images, booted the full stack, and
# passed the HTTPS and backup/restore smoke tests — so "update to the
# newest tag" means "update to a combination a machine has already run",
# which is the guarantee a floating `latest` can never give. The script
# refuses to cross a MAJOR template version on its own: majors are
# breaking by definition (a Keycloak platform jump, a changed variable
# contract) and their release notes exist to be read by a person.
#
# Run it from cron or a systemd timer for unattended minor/patch updates:
#   17 5 * * *  /opt/keycloak-traefik-letsencrypt-docker-compose/update.sh >> /var/log/keycloak-update.log 2>&1
#
# Flags:
#   --dry-run      show what would happen, change nothing
#   --allow-major  permit crossing a major version (you read the notes)

set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="keycloak-traefik-letsencrypt-docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-keycloak}"
DRY_RUN=false
ALLOW_MAJOR=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --allow-major) ALLOW_MAJOR=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "local changes present — commit or stash them first, nothing updated" >&2
  exit 1
fi

git fetch --tags --quiet origin

latest="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -z "$latest" ]; then
  echo "no release tags found — nothing to update to" >&2
  exit 1
fi

current="$(git describe --tags --abbrev=0 2>/dev/null || echo 'v0.0.0')"
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$latest^{commit}")" ]; then
  echo "already on $latest"
  exit 0
fi

cur_major="${current#v}"; cur_major="${cur_major%%.*}"
new_major="${latest#v}";  new_major="${new_major%%.*}"
if [ "$new_major" != "$cur_major" ] && [ "$ALLOW_MAJOR" != "true" ]; then
  echo "refusing to cross a major version unattended: $current -> $latest" >&2
  echo "read the release notes, then re-run with --allow-major:" >&2
  echo "  https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/releases/tag/$latest" >&2
  exit 3
fi

echo "updating $current -> $latest"
if [ "$DRY_RUN" = "true" ]; then
  git log --oneline "HEAD..$latest^{commit}" | sed 's/^/  would apply: /'
  echo "dry run — nothing changed"
  exit 0
fi

git checkout -q "$latest"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d --remove-orphans
echo "now on $latest"
