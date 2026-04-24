# Tests

End-to-end smoke tests for the Keycloak backup + restore flow. Exercises the
safety guards that landed in [PR #21](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose/pull/21) so a green CI run is the authoritative
proof that the flow works on every push.

## What's covered

`e2e-backup-restore.sh` runs seven test cases against a live `docker compose`
stack:

1. **`test_env_required`** — `docker compose config` fails with a helpful error
   when `.env` is absent. Guards the `${VAR:?set in .env...}` compose syntax.
2. **`test_backup_created`** — a `.gz` file with size > 0 appears in the
   backups volume within 120 seconds.
3. **`test_backup_gunzip_ok`** — `gunzip -t` on the first backup exits zero
   (not a zero-byte or truncated file).
4. **`test_backup_sql_valid`** — the first 50 lines of the decompressed dump
   contain `PostgreSQL database dump` and a `CREATE TABLE` or
   `CREATE SCHEMA` statement.
5. **`test_backup_failure_detected`** — stops postgres to force a failed
   backup cycle, asserts a `*.failed` file is produced and the `Backup FAILED`
   log line appears. Restarts postgres afterward.
6. **`test_restore_roundtrip`** — inserts a marker row, restores an earlier
   backup directly via `docker exec` (bypassing the interactive `DESTROY`
   prompt in `keycloak-restore-database.sh`), asserts the marker row is gone.
   End-to-end proof the backup is genuinely restorable — not a no-op.
7. **`test_prune_removes_old`** — places a fake file with `mtime` 14 days ago,
   waits for the next prune cycle, asserts the fake is gone and recent
   backups are still present.

## Prerequisites

- Docker Engine + Docker Compose v2.
- `keycloak-network` and `traefik-network` already created (`docker network create`).
- A `.env` file at the repo root with backup intervals tuned for the test
  timings. The tests assume:

  ```
  KEYCLOAK_BACKUP_INIT_SLEEP=10s
  KEYCLOAK_BACKUP_INTERVAL=30s
  KEYCLOAK_POSTGRES_BACKUP_PRUNE_DAYS=7
  ```

  The production defaults (`30m` warm-up, `24h` interval) would make the
  first-backup check time out. CI generates its own `.env` with these short
  intervals — see `.github/workflows/deployment-verification.yml`.

## Run locally

From the repo root:

```bash
docker compose -f keycloak-traefik-letsencrypt-docker-compose.yml -p keycloak up -d
./tests/e2e-backup-restore.sh
```

Expected runtime: 3-5 minutes (most of it waiting on backup cycles).

## Run in CI

The `backup-restore-e2e` job in `.github/workflows/deployment-verification.yml`
runs this same script on every push, every pull request, and every Monday
at 06:00 UTC. The job is parallel to `deploy-and-test` — backup/restore is
orthogonal to HTTPS routing, so both run on `needs: lint`.
