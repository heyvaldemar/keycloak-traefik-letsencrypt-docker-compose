#!/usr/bin/env bash
# tests/dr-drill.sh before|after
#
# The host is gone. What is left is what an operator keeps off it: the backup
# files and the .env. Can the current release be brought back from those, on a
# machine that has never run this stack, and how long does it take?
#
#   before  on the host that is about to die: start the PREVIOUS release,
#           write a marker row and a marker file, wait for a backup taken
#           after them, and export only the backup files and the .env.
#   after   on a clean machine: start the CURRENT release empty, put the
#           backup files back, run the shipped restore scripts, and require
#           the application to answer and both markers to be back. The time
#           from the first command to that answer is the measured result.
#
# Every value comes from the workflow's environment:
#   DOCKER_COMPOSE_FILE COMPOSE_PROJECT_NAME APP_URL APP_OK (curl codes, regex)
#   DB_ENGINE (postgres|mariadb|mysql) DB_HOST DB_NAME_ENV DB_USER_ENV
#   DB_PASS_ENV (mariadb/mysql only: the variable holding the password in the
#               backups container; postgres reads PGPASSWORD there)
#   DB_DIR_ENV     the backups container variable naming the dump directory
#   DATA_DIR_ENV   the same for the application data archives (optional)
#   DATA_PATH_ENV  the variable naming the live data directory (optional)
#   DB_RESTORE     the shipped command, with "$F" for the dump's file name
#   DATA_RESTORE   the same for the data archive (optional)
#   DR_FROM        the release the backup is taken on (before only)
set -Eeuo pipefail

OUT="${DR_OUT:-dr-out}"
# The workflow names the hostname by variable; env values there are not expanded.
APP_URL="${APP_URL//\$APP_HOSTNAME/${APP_HOSTNAME:-}}"
PROJECT="$COMPOSE_PROJECT_NAME"
MARK="dr-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

cid() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -n 1; }
bk() { docker exec "$(cid backups)" sh -c "$1"; }
env_of() { docker exec "$(cid backups)" printenv "$1"; }
say() { echo "[dr $(date -u +%H:%M:%S)] $*"; }

sql() {  # one statement against the application's database, from the backups container
  local q="$1"
  case "$DB_ENGINE" in
    postgres) bk "psql -q -h '$DB_HOST' -U \"\$$DB_USER_ENV\" -d \"\$$DB_NAME_ENV\" -tAc \"$q\"" ;;
    mariadb|mysql) bk "MYSQL_PWD=\"\$$DB_PASS_ENV\" $DB_ENGINE -h '$DB_HOST' -u \"\$$DB_USER_ENV\" -N -s -e \"$q\" \"\$$DB_NAME_ENV\"" ;;
    *) echo "unknown DB_ENGINE $DB_ENGINE" >&2; return 2 ;;
  esac
}

wait_app() {
  local limit="$1" waited=0 code=""
  while [ "$waited" -lt "$limit" ]; do
    code="$(curl -skL -o /dev/null -w '%{http_code}' "$APP_URL" || true)"
    if printf '%s' "$code" | grep -qE "^($APP_OK)$"; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  echo "the application did not answer $APP_URL within ${limit}s (last: $code)" >&2
  return 1
}

wait_healthy() {  # every container running and healthy, or a one-shot that exited 0
  local file="$1" bad=""
  for _ in $(seq 1 90); do
    bad="$(docker compose -f "$file" -p "$PROJECT" ps -a --format json \
      | jq -rs '[.[] | select((.State == "running" and (.Health == "" or .Health == "healthy")) or (.State == "exited" and .ExitCode == 0) | not)] | map("\(.Service):\(.State)/\(.Health)") | join(" ")')"
    [ -z "$bad" ] && return 0
    sleep 10
  done
  echo "not healthy after 15 minutes: $bad" >&2
  return 1
}

newest_after() {  # directory, glob suffix, stamp file: the newest complete file written after the stamp
  bk "find '$1' -maxdepth 1 -type f -name '*$2' -newer '$3' | sort | tail -n 1"
}

wait_backup_after_stamp() {  # directory variable, suffix, log word
  local dir stamp f waited=0
  dir="$(env_of "$1")"; stamp="$dir/.dr-stamp"
  while [ "$waited" -lt 600 ]; do
    f="$(newest_after "$dir" "$2" "$stamp")"
    if [ -n "$f" ] && docker logs "$(cid backups)" 2>&1 | grep -qF "backup OK: $f"; then
      say "backup after the markers: $f"; return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo "no $3 backup after the markers within 600s in $dir" >&2
  return 1
}

before() {
  local from_file=".dr-from.yml"
  git show "$DR_FROM:$DOCKER_COMPOSE_FILE" > "$from_file"
  say "starting $DR_FROM, the release this host was running"
  docker compose -f "$from_file" -p "$PROJECT" up -d
  wait_healthy "$from_file"
  wait_app 600
  say "writing the markers"
  sql "CREATE TABLE IF NOT EXISTS dr_marker (v varchar(80)); DELETE FROM dr_marker; INSERT INTO dr_marker VALUES ('$MARK');" > /dev/null
  if [ -n "${DATA_PATH_ENV:-}" ]; then
    bk "printf '%s' '$MARK' > \"\$$DATA_PATH_ENV/.dr-marker\""
  fi
  bk "touch \"\$$DB_DIR_ENV/.dr-stamp\"${DATA_DIR_ENV:+ \"\$$DATA_DIR_ENV/.dr-stamp\"}"
  wait_backup_after_stamp "$DB_DIR_ENV" ".gz" "database"
  if [ -n "${DATA_DIR_ENV:-}" ]; then
    wait_backup_after_stamp "$DATA_DIR_ENV" ".tar.gz" "data"
  fi
  say "exporting what an operator keeps off the host: the backup files and .env"
  mkdir -p "$OUT"
  cp .env "$OUT/env"
  local v dir
  for v in "$DB_DIR_ENV" ${DATA_DIR_ENV:+"$DATA_DIR_ENV"}; do
    dir="$(env_of "$v")"
    mkdir -p "$OUT/$v"
    docker cp "$(cid backups):$dir/." "$OUT/$v/"
    rm -f "$OUT/$v/.dr-stamp"
  done
  printf '%s\n' "$MARK" > "$OUT/marker"
  printf '%s\n' "$DR_FROM" > "$OUT/from"
  du -sh "$OUT"
}

after() {
  local t0 t1 tr to dbf dataf v dir
  t0="$(date +%s)"
  # The release main carries: the newest tag whose stack is main's, or "main"
  # when the stack has moved on since the last release.
  to="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  if [ -z "$to" ] || ! git diff --quiet "$to" HEAD -- "$DOCKER_COMPOSE_FILE"; then to="main"; fi
  MARK="$(cat "$OUT/marker")"
  cp "$OUT/env" .env
  say "a clean machine: starting $to empty"
  docker compose -f "$DOCKER_COMPOSE_FILE" -p "$PROJECT" up -d
  wait_healthy "$DOCKER_COMPOSE_FILE"
  for v in "$DB_DIR_ENV" ${DATA_DIR_ENV:+"$DATA_DIR_ENV"}; do
    dir="$(env_of "$v")"
    docker cp "$OUT/$v/." "$(cid backups):$dir/"
  done
  tr="$(date +%s)"
  dbf="$(bk "ls -1t \"\$$DB_DIR_ENV\" | grep -E '\\.gz\$' | grep -vE '\\.tar\\.gz\$' | head -n 1")"
  say "restoring the database from $dbf"
  F="$dbf" bash -c "$DB_RESTORE"
  if [ -n "${DATA_DIR_ENV:-}" ]; then
    dataf="$(bk "ls -1t \"\$$DATA_DIR_ENV\" | grep -E '\\.tar\\.gz\$' | head -n 1")"
    say "restoring the data from $dataf"
    F="$dataf" bash -c "$DATA_RESTORE"
  fi
  wait_healthy "$DOCKER_COMPOSE_FILE"
  wait_app 900
  t1="$(date +%s)"

  local got_row got_file="(no data directory)" ok=true
  got_row="$(sql "SELECT v FROM dr_marker;" | tr -d '[:space:]')"
  [ "$got_row" = "$MARK" ] || { echo "the marker row came back as '$got_row', expected '$MARK'" >&2; ok=false; }
  if [ -n "${DATA_PATH_ENV:-}" ]; then
    got_file="$(bk "cat \"\$$DATA_PATH_ENV/.dr-marker\" 2>/dev/null" || true)"
    [ "$got_file" = "$MARK" ] || { echo "the marker file came back as '$got_file', expected '$MARK'" >&2; ok=false; }
  fi

  local from total restore
  from="$(cat "$OUT/from")"; total=$((t1 - t0)); restore=$((t1 - tr))
  jq -n --arg repo "${GITHUB_REPOSITORY:-local}" --arg from "$from" --arg to "$to" --argjson total "$total" \
        --argjson restore "$restore" --argjson ok "$ok" --arg run "${GITHUB_RUN_ID:-}" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{repository: $repo, from: $from, to: $to, seconds_total: $total, seconds_restore: $restore, markers_back: $ok, run: $run, finished_at: $at}' \
        > dr-result.json
  cat dr-result.json
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Clean-machine restore: $from → $to"
      echo
      echo "| | |"; echo "|:--|:--|"
      echo "| From the first command on an empty machine to the application answering | **$((total / 60)) min $((total % 60)) s** |"
      echo "| Of that, putting the backups back and restoring | $((restore / 60)) min $((restore % 60)) s |"
      echo "| Marker row written on $from, read back on $to | $got_row |"
      echo "| Marker file | $got_file |"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  $ok || exit 1
  say "restored $from onto $to on a clean machine in ${total}s"
}

case "${1:-}" in
  before) before ;;
  after) after ;;
  *) echo "usage: $0 before|after" >&2; exit 2 ;;
esac
