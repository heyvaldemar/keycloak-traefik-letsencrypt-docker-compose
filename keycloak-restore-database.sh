#!/bin/bash
#
# keycloak-restore-database.sh — restore the Keycloak PostgreSQL database
# from a scheduled backup.
#
# Safety guards:
#   1. Sources `.env` so DB name/user/backup path match the deployed stack
#      (no hardcoded values — works even if you customised the defaults).
#   2. Verifies the selected backup passes `gunzip -t` before touching the
#      live database. A corrupt archive is caught here, not mid-restore.
#   3. Requires you to type DESTROY (exactly, all caps) to confirm the
#      destructive operation. Any other input aborts without changes.
#   4. Captures a pre-restore snapshot of the CURRENT database state to
#      `/tmp/pre-restore-<timestamp>.gz` inside the backups container
#      before dropping the live DB. If the restore produces a broken DB,
#      the snapshot is your rollback.
#   5. After restore, waits for the Keycloak healthcheck to report `healthy`
#      and runs a sanity query confirming the public schema has tables.
#      If either check fails, prints the command to recover from the
#      pre-restore snapshot and exits non-zero.
#
# Interactive by design. Safe to Ctrl-C at any prompt before DESTROY is
# typed — no changes are made until after confirmation.
#
# Make the script executable and run from the repository root (where `.env`
# lives):
#
#   chmod +x keycloak-restore-database.sh
#   ./keycloak-restore-database.sh

set -euo pipefail

# --- Resolve paths and source .env ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at $ENV_FILE" >&2
  echo "       Run this script from the repository root, after copying .env.example to .env." >&2
  exit 1
fi

set -o allexport
# shellcheck disable=SC1090
source "$ENV_FILE"
set +o allexport

# Defaults match `.env.example` — overridden by the user's `.env` via the source above.
: "${KEYCLOAK_DB_NAME:=keycloakdb}"
: "${KEYCLOAK_DB_USER:=keycloakdbuser}"
: "${KEYCLOAK_POSTGRES_BACKUPS_PATH:=/srv/keycloak-postgres/backups}"
: "${COMPOSE_PROJECT_NAME:=keycloak}"

# Ensure trailing slash for path concatenation.
BACKUP_PATH="${KEYCLOAK_POSTGRES_BACKUPS_PATH%/}/"

# --- Resolve container IDs via COMPOSE_PROJECT_NAME ---

KEYCLOAK_CONTAINER="$(docker ps -aqf "name=${COMPOSE_PROJECT_NAME}-keycloak" | head -n 1)"
KEYCLOAK_BACKUPS_CONTAINER="$(docker ps -aqf "name=${COMPOSE_PROJECT_NAME}-backups" | head -n 1)"

if [[ -z "$KEYCLOAK_CONTAINER" ]]; then
  echo "Error: could not find Keycloak container matching '${COMPOSE_PROJECT_NAME}-keycloak'." >&2
  echo "       Is the stack running? Try: docker compose -p ${COMPOSE_PROJECT_NAME} ps" >&2
  exit 1
fi

if [[ -z "$KEYCLOAK_BACKUPS_CONTAINER" ]]; then
  echo "Error: could not find backups container matching '${COMPOSE_PROJECT_NAME}-backups'." >&2
  echo "       Is the backups service running? Try: docker compose -p ${COMPOSE_PROJECT_NAME} ps backups" >&2
  exit 1
fi

# --- List backups ---

echo "--> Available database backups in ${BACKUP_PATH} (inside the backups container):"

mapfile -t BACKUPS < <(docker container exec "$KEYCLOAK_BACKUPS_CONTAINER" sh -c "ls $BACKUP_PATH 2>/dev/null" || true)

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
  echo "Error: no backup files found in ${BACKUP_PATH} inside the backups container." >&2
  echo "       Scheduled backups may not have started yet (default KEYCLOAK_BACKUP_INIT_SLEEP is 30m)." >&2
  exit 1
fi

for entry in "${BACKUPS[@]}"; do
  echo "    $entry"
done

# --- Prompt for selection ---

echo
echo "--> Copy and paste the backup name from the list above, then press [ENTER]."
echo "    Example: keycloak-postgres-backup-YYYY-MM-DD_hh-mm-ss.gz"
echo -n "--> "
read -r SELECTED_BACKUP

if [[ -z "$SELECTED_BACKUP" ]]; then
  echo "Error: no backup selected. Aborting." >&2
  exit 1
fi

# Validate the selection is actually in the list (no typos, no path traversal).
FOUND=0
for entry in "${BACKUPS[@]}"; do
  if [[ "$entry" == "$SELECTED_BACKUP" ]]; then
    FOUND=1
    break
  fi
done

if [[ $FOUND -eq 0 ]]; then
  echo "Error: '$SELECTED_BACKUP' does not match any entry in the backup list." >&2
  exit 1
fi

echo "--> Selected: $SELECTED_BACKUP"

# --- Integrity check ---

echo "--> Verifying backup integrity (gunzip -t)..."
if ! docker exec "$KEYCLOAK_BACKUPS_CONTAINER" gunzip -t "${BACKUP_PATH}${SELECTED_BACKUP}"; then
  echo "Error: backup archive is corrupt — gunzip integrity check failed. Aborting restore." >&2
  exit 1
fi
echo "    OK — archive is a valid gzip stream."

# --- Confirmation ---

echo
echo "WARNING: this will DROP the current '$KEYCLOAK_DB_NAME' database and REPLACE its"
echo "         contents with $SELECTED_BACKUP."
echo
echo "         A pre-restore snapshot of the CURRENT database state will be saved to"
echo "         /tmp/pre-restore-<timestamp>.gz inside the backups container ($KEYCLOAK_BACKUPS_CONTAINER)"
echo "         BEFORE the drop. If the restore produces a broken database, that snapshot"
echo "         is your rollback — the script will print the exact recovery command if needed."
echo
echo "         To proceed, type DESTROY (exactly, all caps) and press [ENTER]."
echo "         Any other input (including empty) will abort without changes."
echo -n "--> "
read -r CONFIRMATION

if [[ "$CONFIRMATION" != "DESTROY" ]]; then
  echo "Confirmation not received. Aborting — no changes made." >&2
  exit 1
fi

# --- Pre-restore snapshot ---

SNAPSHOT_NAME="pre-restore-$(date +%Y-%m-%d_%H-%M-%S).gz"
SNAPSHOT_PATH="/tmp/${SNAPSHOT_NAME}"

echo "--> Creating pre-restore snapshot: ${SNAPSHOT_PATH} (inside $KEYCLOAK_BACKUPS_CONTAINER)"
if ! docker exec "$KEYCLOAK_BACKUPS_CONTAINER" sh -c \
    "set -o pipefail; pg_dump -h postgres -p 5432 -d $KEYCLOAK_DB_NAME -U $KEYCLOAK_DB_USER | gzip > $SNAPSHOT_PATH"; then
  echo "Error: failed to create pre-restore snapshot. Aborting — no changes made." >&2
  exit 1
fi
echo "    Snapshot created."

# --- Perform the restore ---

echo "--> Stopping Keycloak..."
docker stop "$KEYCLOAK_CONTAINER" > /dev/null

echo "--> Restoring database from ${SELECTED_BACKUP}..."
docker exec "$KEYCLOAK_BACKUPS_CONTAINER" sh -c \
  "dropdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
  && createdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
  && gunzip -c ${BACKUP_PATH}${SELECTED_BACKUP} | psql -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME"

echo "    Restore completed."

# --- Start Keycloak and verify ---

echo "--> Starting Keycloak..."
docker start "$KEYCLOAK_CONTAINER" > /dev/null

echo "--> Waiting for Keycloak to report healthy (up to 2 minutes)..."
HEALTH="unknown"
for _ in $(seq 1 24); do
  HEALTH="$(docker inspect --format='{{.State.Health.Status}}' "$KEYCLOAK_CONTAINER" 2>/dev/null || echo "unknown")"
  if [[ "$HEALTH" == "healthy" ]]; then
    echo "    Keycloak is healthy."
    break
  fi
  sleep 5
done

rollback_hint() {
  echo
  echo "ROLLBACK available: the pre-restore snapshot is still in ${SNAPSHOT_PATH}" >&2
  echo "inside container ${KEYCLOAK_BACKUPS_CONTAINER}. To recover the pre-restore state:" >&2
  echo >&2
  echo "    docker stop $KEYCLOAK_CONTAINER" >&2
  echo "    docker exec $KEYCLOAK_BACKUPS_CONTAINER sh -c \\" >&2
  echo "      'dropdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \\" >&2
  echo "       && createdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \\" >&2
  echo "       && gunzip -c $SNAPSHOT_PATH | psql -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME'" >&2
  echo "    docker start $KEYCLOAK_CONTAINER" >&2
}

if [[ "$HEALTH" != "healthy" ]]; then
  echo "Warning: Keycloak did not reach healthy state within 2 minutes (last status: $HEALTH)." >&2
  echo "         Inspect logs: docker logs $KEYCLOAK_CONTAINER" >&2
  rollback_hint
  exit 1
fi

# Sanity query — the restored DB should have tables in the public schema.
TABLE_COUNT="$(docker exec "$KEYCLOAK_BACKUPS_CONTAINER" \
  psql -h postgres -p 5432 -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null \
  | tr -d '[:space:]')"

if [[ -z "$TABLE_COUNT" ]] || [[ "$TABLE_COUNT" -eq 0 ]]; then
  echo "Warning: restored database has 0 tables in the public schema." >&2
  echo "         This likely indicates a partial or corrupt restore." >&2
  rollback_hint
  exit 1
fi

echo "    Sanity check OK — public schema has $TABLE_COUNT tables."
echo
echo "--> Restore completed successfully."
echo "    Pre-restore snapshot preserved at ${SNAPSHOT_PATH} inside ${KEYCLOAK_BACKUPS_CONTAINER}."
echo "    Delete it manually when you're satisfied with the restored state:"
echo "        docker exec ${KEYCLOAK_BACKUPS_CONTAINER} rm ${SNAPSHOT_PATH}"
