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
#   DOCKER_COMPOSE_FILE the compose file, or several separated by spaces, in
#                    the order they are started (Outline: traefik, keycloak,
#                    outline); COMPOSE_PROJECT_NAME
#   BACKUPS_SVC      the backups service that holds the database and data
#                    variables (default: backups)
#   EXTRA_DB_SVC     a second stack's backups service whose dump is carried
#                    and restored first (Outline's Keycloak), with
#                    EXTRA_DB_DIR_ENV, EXTRA_DB_FILE_MATCH and EXTRA_DB_RESTORE
#   APP_URL          what must answer over HTTPS; empty for a stack with no
#                    HTTP face, which is then judged healthy by its containers
#   APP_OK           the codes that count as an answer (a regex)
#   DB_ENGINE        postgres | mariadb | mysql | mongo | mssql | "" (no
#                    database the drill can write a row into: SQLite, or none)
#   DB_HOST          the database service
#   DB_NAME_ENV      the backups container variable naming the database, or
#                    "=name" for a literal
#   DB_USER_ENV      the same for the user
#   DB_PASS_ENV      the same for the password; "" when the container carries
#                    PGPASSWORD; "/path" for a file the container mounts
#   DB_DIR_ENV       the variable naming the dump directory
#   DB_FILE_MATCH    a regex the dump's file name matches; $VAR inside it is
#                    expanded in the backups container (default: [0-9]\.gz$)
#   DATA_DIR_ENV     the same for the data archives (optional)
#   DATA_FILE_MATCH  (default: \.tar\.gz$)
#   DATA_PATH_ENV    the variable naming the live data directory, or "=/path"
#   DATA_MARK_SUBDIR where under it the marker file goes (default: the
#                    directory itself; Outline's Garage tree is two mounts
#                    under a path that is not one, so its marker goes in /data)
#   DB_RESTORE       the shipped command, with "$F" for the dump's file name
#                    and "$S" for the cycle stamp in it
#   DATA_RESTORE     the same for the data archive (optional)
#   DR_APP_WAIT      seconds to wait for the application on the dying host
#                    (default 600; Mailu's own CI gives its admin twelve minutes)
#   DR_IGNORE_SERVICES  services whose state does not count (a Beszel agent
#                    with no key restarts by design; CI ignores it too)
#   DR_KEEP          paths an operator keeps off the host besides .env, such
#                    as Authelia's secret files, carried to the clean machine
#   DR_FROM          the release the backup is taken on (before only)
#   DR_DIAG          optional: a command whose output explains a failed answer
set -Eeuo pipefail

OUT="${DR_OUT:-dr-out}"
# The workflow names the hostname by variable; env values there are not expanded.
APP_URL="${APP_URL//\$APP_HOSTNAME/${APP_HOSTNAME:-}}"
PROJECT="$COMPOSE_PROJECT_NAME"
MARK="dr-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
DB_FILE_MATCH="${DB_FILE_MATCH:-[0-9]\\.gz\$}"
DATA_FILE_MATCH="${DATA_FILE_MATCH:-\\.tar\\.gz\$}"

BACKUPS_SVC="${BACKUPS_SVC:-backups}"
cid() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$1" | head -n 1; }
bk() { docker exec "$(cid "$BACKUPS_SVC")" sh -c "$1"; }
env_of() { docker exec "$(cid "$BACKUPS_SVC")" printenv "$1"; }
bk_in() { docker exec "$(cid "$1")" sh -c "$2"; }                                # the same, in a named backups service
env_in() { docker exec "$(cid "$1")" printenv "$2"; }
cf() { CF=(); local f; for f in $1; do CF+=(-f "$f"); done; }                    # CF=(-f a -f b): the compose files, in order
val() { case "$1" in =*) printf '%s' "${1#=}" ;; *) env_of "$1" ;; esac; }   # a variable, or "=literal"
expand() { bk "printf '%s' \"$1\""; }                                          # $VAR in a pattern, as the container sees it
say() { echo "[dr $(date -u +%H:%M:%S)] $*"; }

pass_expr() {  # how the password reaches the client, inside the backups container's shell
  case "${DB_PASS_ENV:-}" in
    "") printf '' ;;
    /*) printf '$(cat %s)' "$DB_PASS_ENV" ;;
    *) printf '"$%s"' "$DB_PASS_ENV" ;;
  esac
}

sql() {  # one statement against the application's database, from the backups container
  local q="$1" db user
  db="$(val "$DB_NAME_ENV")"; user="$(val "${DB_USER_ENV:-=}")"
  case "$DB_ENGINE" in
    postgres) bk "${DB_PASS_ENV:+PGPASSWORD=$(pass_expr) }psql -q -h '$DB_HOST' -U '$user' -d '$db' -tAc \"$q\"" ;;
    mariadb|mysql) bk "MYSQL_PWD=$(pass_expr) $DB_ENGINE -h '$DB_HOST' -u '$user' -N -s -e \"$q\" '$db'" ;;
    mongo) bk "mongosh --quiet --host '$DB_HOST' '$db' --eval \"$q\"" ;;
    mssql) bk "/opt/mssql-tools18/bin/sqlcmd -S '$DB_HOST' -U sa -P $(pass_expr) -C -b -h -1 -W -d '$db' -Q \"SET NOCOUNT ON; $q\"" ;;
    *) echo "unknown DB_ENGINE $DB_ENGINE" >&2; return 2 ;;
  esac
}

mark_write() {
  case "$DB_ENGINE" in
    mongo) sql "db.dr_marker.deleteMany({}); db.dr_marker.insertOne({v: '$MARK'});" > /dev/null ;;
    mssql) # the drill's own database, made from master: a connection to a database that is not there yet cannot create it
           bk "/opt/mssql-tools18/bin/sqlcmd -S '$DB_HOST' -U sa -P $(pass_expr) -C -b -d master -Q \"IF DB_ID(N'$(val "$DB_NAME_ENV")') IS NULL CREATE DATABASE [$(val "$DB_NAME_ENV")];\"" > /dev/null
           sql "IF OBJECT_ID('dr_marker') IS NULL CREATE TABLE dr_marker (v varchar(80)); DELETE FROM dr_marker; INSERT INTO dr_marker VALUES ('$MARK');" > /dev/null ;;
    *) sql "CREATE TABLE IF NOT EXISTS dr_marker (v varchar(80)); DELETE FROM dr_marker; INSERT INTO dr_marker VALUES ('$MARK');" > /dev/null ;;
  esac
}

mark_read() {
  case "$DB_ENGINE" in
    mongo) sql "print(db.dr_marker.findOne().v)" ;;
    *) sql "SELECT v FROM dr_marker;" ;;
  esac
}

mark_path() {  # where the marker file goes: under the data directory, in DATA_MARK_SUBDIR when that exists there
  local p; p="$(val "$DATA_PATH_ENV")"
  if [ -n "${DATA_MARK_SUBDIR:-}" ] && bk "[ -d '$p${DATA_MARK_SUBDIR}' ]"; then p="$p${DATA_MARK_SUBDIR}"; fi
  printf '%s' "$p/.dr-marker"
}
mark_file_write() {
  # THE PATH IS RECORDED, NOT RECOMPUTED. The previous release may keep its
  # data under another directory than the current one (Outline moved from
  # /data to /var/lib/garage between two releases), and a backup taken from /
  # restores the file where it was. The clean machine reads the path the dead
  # host wrote to, whatever the current release would have chosen. A write
  # that fails is a failed drill, not a quiet one: the first attempt at
  # Outline wrote into a directory that was not there and said nothing.
  [ -n "${DATA_PATH_ENV:-}" ] || return 0
  local p; p="$(mark_path)"
  bk "printf '%s' '$MARK' > '$p'" || { echo "could not write the marker file $p in the backups container" >&2; return 1; }
  printf '%s\n' "$p" > "$OUT/marker_path"
  say "marker file written to $p"
}
mark_file_read() {
  local p; p="$(cat "$OUT/marker_path" 2>/dev/null || mark_path)"
  bk "cat '$p' 2>/dev/null" || true
}

wait_app() {
  local limit="$1" waited=0 code=""
  [ -n "$APP_URL" ] || return 0
  while [ "$waited" -lt "$limit" ]; do
    code="$(curl -skL -o /dev/null -w '%{http_code}' "$APP_URL" || true)"
    if printf '%s' "$code" | grep -qE "^($APP_OK)$"; then return 0; fi
    sleep 5; waited=$((waited + 5))
  done
  echo "the application did not answer $APP_URL within ${limit}s (last: $code)" >&2
  return 1
}

wait_healthy() {  # every container running and healthy, or a one-shot that exited 0
  local files="$1" bad=""
  for _ in $(seq 1 90); do
    cf "$files"
    bad="$(docker compose "${CF[@]}" -p "$PROJECT" ps -a --format json \
      | jq -rs --arg ignore " ${DR_IGNORE_SERVICES:-} " '[.[] | . as $c | select(($ignore | contains(" " + $c.Service + " ")) | not) | select((.State == "running" and (.Health == "" or .Health == "healthy")) or (.State == "exited" and .ExitCode == 0) | not)] | map("\(.Service):\(.State)/\(.Health)") | join(" ")')"
    [ -z "$bad" ] && return 0
    sleep 10
  done
  echo "not healthy after 15 minutes: $bad" >&2
  return 1
}

cycle_of() {  # the cycle start written into a backup's name: YYYY-MM-DD_HH-MM
  sed -n 's/.*\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]_[0-9][0-9]-[0-9][0-9]\).*/\1/p'
}

wait_backup_started_after() {  # directory variable, file regex, marker minute, log word, [backups service]
  # A BACKUP THAT FINISHED AFTER THE MARKERS IS NOT ONE THAT CONTAINS THEM.
  # Nextcloud's data archive takes minutes: a cycle that started before the
  # marker file was written finished after it, was newer than the stamp, and
  # held no marker. The cycle's start is in the file name, so the backup must
  # be one whose cycle began in a later minute than the markers.
  local dir pat f waited=0 svc="${5:-$BACKUPS_SVC}"
  dir="$(env_in "$svc" "$1")"; pat="$(bk_in "$svc" "printf '%s' \"$2\"")"
  while [ "$waited" -lt 900 ]; do
    for f in $(bk_in "$svc" "ls -1 '$dir'" | grep -E -e "$pat" | sort -r); do
      [ "$(printf '%s' "$f" | cycle_of)" \> "$3" ] || continue
      if docker logs "$(cid "$svc")" 2>&1 | grep -qiF "backup OK: $dir/$f"; then
        say "backup started after the markers: $f"; return 0
      fi
    done
    sleep 5; waited=$((waited + 5))
  done
  echo "no $4 backup started after $3 within 900s in $dir (matching $pat)" >&2
  return 1
}

newest() {  # the newest exported file matching a pattern, by name: the names carry the time
  local pat; pat="$(expand "$2")"
  find "$OUT/$1" -maxdepth 1 -type f -printf '%f\n' | grep -E -e "$pat" | sort | tail -n 1
}

explain() {  # what a failed restore looks like from the inside
  if [ -n "$APP_URL" ]; then
    echo "--- what $APP_URL answers:" >&2
    curl -skL "$APP_URL" | head -c 2000 >&2 || true
    echo >&2
  fi
  if [ -n "${DR_DIAG:-}" ]; then echo "--- $DR_DIAG" >&2; bash -c "$DR_DIAG" >&2 || true; fi
}

dirs() {  # the backup directories to carry off the host, each once
  printf '%s\n' ${DB_DIR_ENV:+"$DB_DIR_ENV"} ${DATA_DIR_ENV:+"$DATA_DIR_ENV"} | awk 'NF && !seen[$0]++'
}

before() {
  local from_files="" f i=0
  # The dying host backs up every minute, whatever the copied .env says:
  # Keycloak's deploy job carries the production 30m/24h, and a drill that
  # waits a day for its first backup is not a drill.
  sed -i -E 's/^([A-Z_]*BACKUP_INIT_SLEEP)=.*/\1=15s/; s/^([A-Z_]*BACKUP_INTERVAL)=.*/\1=60s/' .env
  # An .env that never names the interval leaves the compose default of a day;
  # every prefix the compose file gives the two variables is set here.
  local p
  for p in $(grep -oE '\$\{[A-Z_]*BACKUP_INIT_SLEEP' "$DOCKER_COMPOSE_FILE" | sed 's/^\${//; s/BACKUP_INIT_SLEEP$//' | sort -u); do
    grep -q "^${p}BACKUP_INIT_SLEEP=" .env || echo "${p}BACKUP_INIT_SLEEP=15s" >> .env
    grep -q "^${p}BACKUP_INTERVAL=" .env || echo "${p}BACKUP_INTERVAL=60s" >> .env
  done
  for f in $DOCKER_COMPOSE_FILE; do
    i=$((i + 1)); git show "$DR_FROM:$f" > ".dr-from-$i.yml"; from_files="$from_files .dr-from-$i.yml"
  done
  say "starting $DR_FROM, the release this host was running"
  cf "$from_files"; docker compose "${CF[@]}" -p "$PROJECT" up -d
  wait_healthy "$from_files"
  # THE DYING HOST'S FRONT DOOR IS NOT THE MEASUREMENT. The markers go in
  # through the backups container and come out on the clean machine; whether
  # the previous release answered over HTTPS is noted, not required. Mailu's
  # v1.7.7 answered on two starts in three (two Traefik routers, one rule),
  # and a drill that gives up on the host that is about to die anyway would
  # measure that old fault instead of the restore.
  wait_app "${DR_APP_WAIT:-600}" || say "the previous release did not answer over HTTPS; the markers and the backup do not depend on it"
  mkdir -p "$OUT"
  say "writing the markers"
  [ -z "$DB_ENGINE" ] || mark_write
  mark_file_write
  local marked
  marked="$(bk 'date +%Y-%m-%d_%H-%M')"   # the backups container's clock names the files
  say "markers written at $marked; waiting for backups whose cycle starts later"
  [ -z "${DB_DIR_ENV:-}" ] || wait_backup_started_after "$DB_DIR_ENV" "$DB_FILE_MATCH" "$marked" "database"
  [ -z "${EXTRA_DB_SVC:-}" ] || wait_backup_started_after "$EXTRA_DB_DIR_ENV" "${EXTRA_DB_FILE_MATCH:-[0-9]\\.gz\$}" "$marked" "second database" "$EXTRA_DB_SVC"
  [ -z "${DATA_DIR_ENV:-}" ] || wait_backup_started_after "$DATA_DIR_ENV" "$DATA_FILE_MATCH" "$marked" "data"
  say "exporting what an operator keeps off the host: the backup files and .env"
  cp .env "$OUT/env"
  local v dir
  for v in $(dirs); do
    dir="$(env_of "$v")"
    mkdir -p "$OUT/$v"
    docker cp "$(cid "$BACKUPS_SVC"):$dir/." "$OUT/$v/"
  done
  if [ -n "${EXTRA_DB_SVC:-}" ]; then
    dir="$(env_in "$EXTRA_DB_SVC" "$EXTRA_DB_DIR_ENV")"
    mkdir -p "$OUT/extra"
    docker cp "$(cid "$EXTRA_DB_SVC"):$dir/." "$OUT/extra/"
  fi
  local k
  for k in ${DR_KEEP:-}; do
    mkdir -p "$OUT/keep/$(dirname "$k")"
    cp -a "$k" "$OUT/keep/$k"
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
  if [ -z "$to" ] || ! git diff --quiet "$to" HEAD -- $DOCKER_COMPOSE_FILE; then to="main"; fi
  MARK="$(cat "$OUT/marker")"
  cp "$OUT/env" .env
  local k
  for k in ${DR_KEEP:-}; do
    rm -rf "$k"; mkdir -p "$(dirname "$k")"; cp -a "$OUT/keep/$k" "$k"
  done
  # THE NEW HOST'S BACKUP LOOP STARTS WITH THE STACK. With CI's 15-second
  # warm-up its first cycle wrote an empty backup into the same directory
  # before the restore ran, the drill restored "the newest file", which was
  # that one, and the file names are only minute-precise, so it can even
  # overwrite an imported backup of the same name. The first Gitea run failed
  # exactly so. A restored .env carries the documented 30-minute warm-up.
  sed -i -E 's/^([A-Z_]*BACKUP_INIT_SLEEP)=.*/\1=30m/' .env
  say "a clean machine: starting $to empty"
  cf "$DOCKER_COMPOSE_FILE"; docker compose "${CF[@]}" -p "$PROJECT" up -d
  wait_healthy "$DOCKER_COMPOSE_FILE"
  # The empty stack answers before anything is put back: a restore that runs
  # into an application still initialising is a different failure from a
  # restore that broke it, and the log should say which.
  wait_app "${DR_APP_WAIT:-600}" || { explain; exit 1; }
  say "the empty stack answers; putting the backups back"
  for v in $(dirs); do
    dir="$(env_of "$v")"
    docker cp "$OUT/$v/." "$(cid "$BACKUPS_SVC"):$dir/"
  done
  tr="$(date +%s)"
  if [ -n "${EXTRA_DB_SVC:-}" ]; then
    dir="$(env_in "$EXTRA_DB_SVC" "$EXTRA_DB_DIR_ENV")"
    docker cp "$OUT/extra/." "$(cid "$EXTRA_DB_SVC"):$dir/"
    local xpat xf
    xpat="$(bk_in "$EXTRA_DB_SVC" "printf '%s' \"${EXTRA_DB_FILE_MATCH:-[0-9]\\.gz\$}\"")"
    xf="$(find "$OUT/extra" -maxdepth 1 -type f -printf '%f\n' | grep -E -e "$xpat" | sort | tail -n 1)"
    say "restoring the second database from $xf"
    F="$xf" S="$(printf '%s' "$xf" | cycle_of)" bash -c "$EXTRA_DB_RESTORE"
  fi
  # The newest of the files brought from the dead host, by name: the names
  # carry the time, and a file this machine wrote itself is not a candidate.
  if [ -n "${DB_DIR_ENV:-}" ]; then
    dbf="$(newest "$DB_DIR_ENV" "$DB_FILE_MATCH")"
    say "restoring the database from $dbf"
    F="$dbf" S="$(printf '%s' "$dbf" | cycle_of)" bash -c "$DB_RESTORE"
  fi
  if [ -n "${DATA_DIR_ENV:-}" ]; then
    # THE STACK SETTLES BETWEEN THE TWO RESTORES. Each restore script stops
    # and starts the application; two stop-starts seconds apart left OTRS's
    # Apache on a stale pid file, and the container stayed unhealthy for the
    # rest of the run on two attempts out of six. An operator waits for the
    # first restore to come up before starting the second, and so does this.
    [ -z "${DB_DIR_ENV:-}" ] || wait_healthy "$DOCKER_COMPOSE_FILE" || { explain; exit 1; }
    dataf="$(newest "$DATA_DIR_ENV" "$DATA_FILE_MATCH")"
    say "restoring the data from $dataf"
    F="$dataf" S="$(printf '%s' "$dataf" | cycle_of)" bash -c "$DATA_RESTORE"
  fi
  if ! wait_healthy "$DOCKER_COMPOSE_FILE" || ! wait_app 900; then
    explain
    exit 1
  fi
  t1="$(date +%s)"

  local got_row="(no database row)" got_file="(no data directory)" ok=true
  if [ -n "$DB_ENGINE" ]; then
    got_row="$(mark_read | tr -d '[:space:]')"
    [ "$got_row" = "$MARK" ] || { echo "the marker row came back as '$got_row', expected '$MARK'" >&2; ok=false; }
  fi
  if [ -n "${DATA_PATH_ENV:-}" ]; then
    got_file="$(mark_file_read)"
    [ "$got_file" = "$MARK" ] || { echo "the marker file came back as '$got_file', expected '$MARK'" >&2; ok=false; }
  fi
  if [ -z "$DB_ENGINE" ] && [ -z "${DATA_PATH_ENV:-}" ]; then
    echo "nothing to check: neither a database row nor a data directory is configured" >&2; ok=false
  fi
  $ok || explain

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
