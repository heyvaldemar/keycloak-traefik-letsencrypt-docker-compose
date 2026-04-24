#!/usr/bin/env bash
#
# End-to-end tests for the Keycloak backup + restore flow.
#
# Requires: docker, docker compose. Assumes the stack is already up with
# short ephemeral backup intervals: INIT_SLEEP=10s, INTERVAL=30s, PRUNE_DAYS=7.
#
# Run from the repository root:
#   ./tests/e2e-backup-restore.sh
#
# CI runs the same script on every push via the backup-restore-e2e job
# in .github/workflows/deployment-verification.yml.

# Tests and helpers are dispatched indirectly via run_test "$name"; shellcheck
# can't trace that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-keycloak}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-keycloak-traefik-letsencrypt-docker-compose.yml}"

# Source .env so KEYCLOAK_DB_USER, KEYCLOAK_DB_NAME,
# KEYCLOAK_POSTGRES_BACKUPS_PATH, and KEYCLOAK_POSTGRES_BACKUP_NAME are in
# this shell's environment for the helpers below.
if [[ -f .env ]]; then
  set -o allexport
  # shellcheck disable=SC1091
  source .env
  set +o allexport
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  echo "       bring the stack up with a populated .env before running tests." >&2
  exit 1
fi

: "${KEYCLOAK_DB_USER:?set in .env}"
: "${KEYCLOAK_DB_NAME:?set in .env}"
: "${KEYCLOAK_POSTGRES_BACKUPS_PATH:?set in .env}"
: "${KEYCLOAK_POSTGRES_BACKUP_NAME:?set in .env}"

BACKUPS_PATH="${KEYCLOAK_POSTGRES_BACKUPS_PATH%/}"
BACKUP_PREFIX="${KEYCLOAK_POSTGRES_BACKUP_NAME}"

BACKUPS_CONTAINER="$(docker ps -aqf "name=${COMPOSE_PROJECT_NAME}-backups" | head -n 1)"
POSTGRES_CONTAINER="$(docker ps -aqf "name=${COMPOSE_PROJECT_NAME}-postgres" | head -n 1)"

if [[ -z "$BACKUPS_CONTAINER" ]]; then
  echo "error: backups container not found (COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME})" >&2
  exit 1
fi
if [[ -z "$POSTGRES_CONTAINER" ]]; then
  echo "error: postgres container not found (COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME})" >&2
  exit 1
fi

# --- Test runner ---

PASSED=0
FAILED=0
FAILURES=()

run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2
    FAILED=$((FAILED + 1))
    FAILURES+=("$name")
  fi
}

fail() {
  echo "  ASSERT: $*" >&2
  return 1
}

# --- Container helpers ---

backups_sh() {
  docker exec "$BACKUPS_CONTAINER" sh -c "$1"
}

psql_query() {
  docker exec "$BACKUPS_CONTAINER" psql \
    -h postgres -p 5432 \
    -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" \
    -tAc "$1"
}

list_backups() {
  backups_sh "ls -1 ${BACKUPS_PATH}/${BACKUP_PREFIX}-*.gz 2>/dev/null" \
    | grep -v '\.failed$' \
    | sort \
    || true
}

wait_for_first_backup() {
  local timeout="${1:-120}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if [[ -n "$(list_backups)" ]]; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

wait_for_postgres_ready() {
  local timeout="${1:-60}"
  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    if docker exec "$POSTGRES_CONTAINER" \
        pg_isready -q -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" \
        > /dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}

# The first backup cycle fires ~INIT_SLEEP (10s in CI) after the backups
# container starts — which on a cold runner is often BEFORE Keycloak
# finishes populating its public schema. Without a guaranteed table in the
# DB, the first backup's SQL body is just headers + SETs, and
# test_backup_sql_valid fails looking for CREATE TABLE. Creating a marker
# table at test-setup time pins a CREATE TABLE statement into every
# backup captured from now on, independent of Keycloak's own startup race.
setup_marker_table() {
  echo "--> creating backup_sql_valid_marker so every backup has CREATE TABLE content"
  if ! docker exec "$BACKUPS_CONTAINER" psql \
      -h postgres -p 5432 \
      -U "$KEYCLOAK_DB_USER" -d "$KEYCLOAK_DB_NAME" \
      -c "CREATE TABLE IF NOT EXISTS backup_sql_valid_marker (id int PRIMARY KEY);" \
      > /dev/null; then
    echo "error: failed to create marker table" >&2
    exit 1
  fi
}

# --- Test cases ---

test_env_required() {
  # Compose file uses ${VAR:?set in .env...} guards. Confirm `docker compose
  # config` fails with a helpful message when .env is absent AND the shell
  # has no matching vars exported. env -i wipes the inherited vars so the
  # guards actually fire (otherwise our sourced .env leaks through).
  if [[ ! -f .env ]]; then
    fail ".env must exist before this test (was sourced above)"
    return 1
  fi
  mv .env .env.bak
  local out
  out=$(env -i PATH="$PATH" HOME="$HOME" \
    docker compose -f "$DOCKER_COMPOSE_FILE" config 2>&1 || true)
  mv .env.bak .env
  if echo "$out" | grep -qiE "set in \.env|required|is not set"; then
    return 0
  fi
  fail "expected a required-variable error from docker compose config, got:"
  echo "$out" >&2
  return 1
}

test_backup_created() {
  echo "  waiting up to 120s for first backup..."
  if ! wait_for_first_backup 120; then
    fail "no backup .gz file appeared within 120s"
    return 1
  fi
  local first
  first=$(list_backups | head -1)
  if [[ -z "$first" ]]; then
    fail "list_backups returned empty after wait"
    return 1
  fi
  local size
  size=$(backups_sh "stat -c %s $first" | tr -d '[:space:]')
  if [[ -z "$size" || "$size" -le 0 ]]; then
    fail "backup $first has size '$size' (expected > 0)"
    return 1
  fi
  echo "  first backup: $first ($size bytes)"
  return 0
}

test_backup_gunzip_ok() {
  local first
  first=$(list_backups | head -1)
  if [[ -z "$first" ]]; then
    fail "no backups available"
    return 1
  fi
  if ! backups_sh "gunzip -t $first"; then
    fail "gunzip -t failed on $first"
    return 1
  fi
  return 0
}

test_backup_sql_valid() {
  local first
  first=$(list_backups | head -1)
  if [[ -z "$first" ]]; then
    fail "no backups available"
    return 1
  fi
  local sample
  sample=$(backups_sh "gunzip -c $first | head -50")
  if ! echo "$sample" | grep -q "PostgreSQL database dump"; then
    fail "expected 'PostgreSQL database dump' header in first 50 lines"
    echo "--- got: ---" >&2
    echo "$sample" >&2
    return 1
  fi
  if ! echo "$sample" | grep -qE "CREATE (TABLE|SCHEMA)"; then
    fail "expected CREATE TABLE or CREATE SCHEMA in first 50 lines"
    echo "--- got: ---" >&2
    echo "$sample" >&2
    return 1
  fi
  return 0
}

test_backup_failure_detected() {
  # Stop postgres so the next backup cycle cannot connect. The backup loop's
  # `set -o pipefail` + failure branch should rename the partial to *.failed
  # and emit a "Backup FAILED" log line. Restart postgres afterward so later
  # tests have a live DB.
  echo "  stopping postgres to force a backup-cycle failure"
  docker stop "$POSTGRES_CONTAINER" > /dev/null

  # INTERVAL=30s; wait one full cycle + buffer so at least one failed
  # backup attempt completes.
  echo "  waiting 45s for failed backup cycle..."
  sleep 45

  local failed_files
  failed_files=$(backups_sh "ls ${BACKUPS_PATH}/*.failed 2>/dev/null" || true)

  echo "  restarting postgres"
  docker start "$POSTGRES_CONTAINER" > /dev/null
  if ! wait_for_postgres_ready 60; then
    fail "postgres did not become ready within 60s after restart"
    return 1
  fi

  if [[ -z "$failed_files" ]]; then
    fail "no *.failed file produced during postgres outage"
    return 1
  fi
  if ! docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -q "Backup FAILED"; then
    fail "expected 'Backup FAILED' in backups container logs"
    return 1
  fi
  echo "  observed failed file: $failed_files"
  return 0
}

test_restore_roundtrip() {
  # End-to-end proof that restore actually replaces DB state (not a no-op):
  #   1. Snapshot the earliest backup (captured before any test mutations).
  #   2. Insert a marker row; verify it is present in the live DB.
  #   3. Drop + recreate + restore from the earliest backup directly via
  #      docker exec (bypassing the interactive DESTROY prompt in
  #      keycloak-restore-database.sh — the prompt is covered by PR #21's
  #      safety guards, not by this test).
  #   4. Verify marker is absent — restore truly replaced the DB state.
  local baseline
  baseline=$(list_backups | head -1)
  if [[ -z "$baseline" ]]; then
    fail "no baseline backup to restore"
    return 1
  fi
  echo "  baseline backup: $baseline"

  echo "  inserting marker row"
  psql_query "CREATE TABLE IF NOT EXISTS restore_test (id int); INSERT INTO restore_test VALUES (1);" > /dev/null

  local before_count
  before_count=$(psql_query "SELECT count(*) FROM restore_test;" | tr -d '[:space:]')
  if [[ "$before_count" != "1" ]]; then
    fail "marker insert failed before restore: count=$before_count"
    return 1
  fi

  echo "  restoring baseline (dropdb + createdb + gunzip | psql)"
  if ! backups_sh "dropdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
      && createdb -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME \
      && gunzip -c $baseline | psql -h postgres -p 5432 -U $KEYCLOAK_DB_USER $KEYCLOAK_DB_NAME > /dev/null"; then
    fail "restore commands failed"
    return 1
  fi

  local after_regclass
  after_regclass=$(psql_query "SELECT to_regclass('public.restore_test');" | tr -d '[:space:]')
  # to_regclass returns empty string when the table does not exist.
  if [[ -n "$after_regclass" && "$after_regclass" != "NULL" ]]; then
    fail "restore_test table still exists after restore (to_regclass='$after_regclass') — restore was a no-op"
    return 1
  fi
  echo "  marker absent after restore — backup is genuinely restorable"
  return 0
}

test_prune_removes_old() {
  local fake_old="${BACKUPS_PATH}/${BACKUP_PREFIX}-fake-0000-00-00_00-00.gz"
  echo "  placing fake old file at $fake_old with mtime 14 days ago"
  # postgres:16 is Debian-based; GNU touch -d handles relative date strings.
  if ! backups_sh "echo fake > $fake_old && touch -d '14 days ago' $fake_old"; then
    fail "could not create fake old file"
    return 1
  fi

  # Prune runs once per backup cycle (INTERVAL=30s). Wait one full cycle
  # plus a generous buffer to account for dump + gzip time on a warm DB.
  echo "  waiting 45s for next prune cycle..."
  sleep 45

  if backups_sh "ls $fake_old 2>/dev/null" > /dev/null 2>&1; then
    fail "fake old file still present after prune cycle"
    return 1
  fi

  # Sanity check: recent backups must still be there (prune must not
  # blanket-delete — see PR #21 prune-scope hardening).
  if [[ -z "$(list_backups)" ]]; then
    fail "prune removed everything, including recent backups"
    return 1
  fi
  return 0
}

# --- Main ---

echo "=== Keycloak backup/restore E2E tests ==="
echo "  COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"
echo "  BACKUPS_CONTAINER=${BACKUPS_CONTAINER}"
echo "  POSTGRES_CONTAINER=${POSTGRES_CONTAINER}"
echo "  BACKUPS_PATH=${BACKUPS_PATH}"
echo "  BACKUP_PREFIX=${BACKUP_PREFIX}"

# Pin a known CREATE TABLE into the DB before the first backup cycle fires
# (explanation in setup_marker_table).
setup_marker_table

run_test test_env_required
run_test test_backup_created
run_test test_backup_gunzip_ok
run_test test_backup_sql_valid
run_test test_backup_failure_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi
if [[ $FAILED -eq 0 ]]; then
  exit 0
fi
exit 1
