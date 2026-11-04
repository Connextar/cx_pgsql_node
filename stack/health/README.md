# cx-pgsql-health

A small HTTP service that reports the health of the CX_PGSQL_Node_1 PostgreSQL stack: PostgreSQL itself,
PgBouncer, WAL archiving, the backup jobs (via their status file), the data-directory disk, host load and
memory, and the TLS certificate.

It is plain Node.js 24 (built-in `http`) with one dependency, [`pg`](https://www.npmjs.com/package/pg)
(pinned to 8.23.1). nginx on the host terminates TLS and proxies `/healthz`, `/maintenance.json`, `/status` and `/metrics` to it on
`127.0.0.1`.

The first tenant database holds children's education records, so the service **never returns row data,
bind-parameter values or secrets** (see [What is never exposed](#what-is-never-exposed)).

## Endpoints

| Path | Auth | Answer |
| --- | --- | --- |
| `GET /healthz` | none (public) | `{ "status", "time", "checks": { "<name>": "ok"\|"warn"\|"fail" } }` — names and states only, no messages or numbers. **200** for `ok` and `warn`, **503** for `fail`. |
| `GET /maintenance.json` | none (public, `Access-Control-Allow-Origin: *`) | The maintenance windows (`MAINTENANCE_FILE`, kept by `lib/maintenance.sh`) for the apps on this server: `{ "version": 1, "server", "generated_at", "windows": [{ "id", "kind", "state", "starts_at", "ends_by", "expected_minutes", "ended_at", "affects", "message" }] }`. `state` is worked out from the times when served; windows closed over a day ago drop out; nothing else stored about a window is published. **200** (an empty list when there's no file), **503** when the file can't be read — the apps then keep the copy they have. Never touches PostgreSQL. The contract: cx-house `docs/Maintenance.md` §2. |
| `GET /status` | `Authorization: Bearer <token>` | The full JSON report (below). **200** whenever a report was produced — read `status` in the body. |
| `GET /metrics` | `Authorization: Bearer <token>` | Prometheus text exposition format 0.0.4. |

- `HEAD` works on every path and returns the same status and headers without a body.
- Any other method answers **405** (`Allow: GET, HEAD`); any other path answers **404** `{"error":"not found"}`.
- `/status` and `/metrics` answer **503** `{"error":"not configured"}` when no token is configured, and **401**
  `{"error":"unauthorized"}` (with `WWW-Authenticate: Bearer`) for a missing or wrong token. The token is only
  accepted in the `Authorization` header — never in the query string — and is compared in constant time.
- Every response carries `cache-control: no-store` and `x-content-type-options: nosniff`; JSON is
  `application/json; charset=utf-8`, metrics are `text/plain; version=0.0.4; charset=utf-8`.
- The report is computed at most once every `CACHE_SECONDS`; concurrent requests share the one computation in
  flight, so a burst of requests never multiplies the load on PostgreSQL.
- One log line per request (`<time> http GET /status 200 12.3ms` — the path only, never the query string or
  headers). A probe error is logged once when it starts or changes and once when it clears, not on every request.

### Overall status

Overall `status` is the worst of the checks (`fail` > `warn` > `ok`).

## Configuration

Every variable is optional. Invalid numbers or booleans, `WARN_*` above `FAIL_*`, setting both `X` and `X_FILE`,
or an unreadable `*_FILE` stop the service at start-up with a message listing every problem. An empty value
(as Compose passes an unset `${VAR}`) means "use the default".

| Variable | Default | Meaning |
| --- | --- | --- |
| `HEALTH_PORT` | `8080` | Listening port. |
| `HEALTH_HOST` | `0.0.0.0` | Listening address. Keep `0.0.0.0` in a container (the host publishes it on `127.0.0.1`); use `127.0.0.1` when running directly on a host. |
| `HEALTH_TOKEN` | *(unset)* | Bearer token for `/status` and `/metrics`. Unset means those endpoints answer 503 "not configured". Use 32+ random characters (`openssl rand -hex 32`); a shorter one logs a warning. |
| `HEALTH_TOKEN_FILE` | *(unset)* | File holding the token instead (Docker secret). Trailing newlines are stripped. |
| `PG_HOST` | `postgres` | PostgreSQL host. |
| `PG_PORT` | `5432` | PostgreSQL port. |
| `PG_DATABASE` | `postgres` | Database the probe connects to (pg_stat_statements and the vacuum table list come from here). |
| `PG_USER` | `cx_monitor` | Monitoring role (also used for PgBouncer). |
| `PG_PASSWORD` | *(unset)* | Its password. |
| `PG_PASSWORD_FILE` | *(unset)* | File holding the password instead. |
| `PGBOUNCER_ENABLED` | `true` | `false` skips everything PgBouncer (and the `pgbouncer_connect` check). |
| `PGBOUNCER_HOST` | `pgbouncer` | PgBouncer host. |
| `PGBOUNCER_PORT` | `6432` | PgBouncer port. |
| `PGBOUNCER_PROBE_DATABASE` | `postgres` | Real database for the `SELECT 1` through PgBouncer. |
| `BACKUP_STATUS_FILE` | `/backups/status/status.json` | JSON status written by the host backup scripts. |
| `CERT_FILE` | `/certs/server.crt` | PEM certificate whose expiry is checked (the first certificate in the file). Set to an empty string to switch the `tls_cert` check off. |
| `DATA_DIR` | `/pgdata` | Path on the filesystem holding the PostgreSQL data directory; used only for `statfs` (disk usage). A read-only mount is enough, and the service does not need permission to read the directory's contents. |
| `WARN_CONN_PCT` | `70` | Connections check warns at this % of `max_connections`. |
| `FAIL_CONN_PCT` | `90` | …and fails at this %. |
| `WARN_DISK_PCT` | `80` | Disk check warns at this % used. |
| `FAIL_DISK_PCT` | `90` | …and fails at this % used. |
| `LONG_QUERY_SECONDS` | `60` | A query running (or a transaction left idle) longer than this is "long". |
| `WARN_BLOCKED_SECONDS` | `30` | A session waiting on a lock longer than this warns. |
| `BACKUP_MAX_AGE_HOURS` | `26` | Maximum age of the last successful logical and pgBackRest backups. |
| `UPLOAD_MAX_AGE_HOURS` | `26` | Maximum age of the last successful off-site upload. |
| `VERIFY_MAX_AGE_HOURS` | `192` | Maximum age of the last successful restore verification (8 days). |
| `WAL_ARCHIVE_MAX_AGE_MINUTES` | `30` | How long a completed WAL segment may wait to be archived. |
| `CERT_WARN_DAYS` | `14` | Certificate check warns with this many days (or fewer) left. |
| `CERT_FAIL_DAYS` | `3` | …and fails with this many days (or fewer) left. |
| `MIN_CACHE_HIT_PCT` | `90` | Cache-hit check warns below this % (it never fails). |
| `OBJECTS_HEALTH_URL` | *(empty)* | The object store's health endpoint (Garage's admin API `/health`, e.g. `http://cx-pgsql-objects:3903/health`). Empty switches the `objects`, `objects_capacity` and `backup_objects` checks off. |
| `OBJECTS_BACKUP_MAX_AGE_HOURS` | `3` | Maximum age of the last successful off-site object copy (it runs hourly). |
| `WARN_OBJECTS_CAPACITY_PCT` | `50` | `objects_capacity` warns at this % of the store's capacity… |
| `FAIL_OBJECTS_CAPACITY_PCT` | `90` | …and fails at this %. |
| `REPORT_MAX_AGE_HOURS` | `50` | With the nightly report email on (`report.enabled` in the status file), the `report_email` check warns when the last email is older than this. |
| `CACHE_SECONDS` | `15` | Compute the report at most this often (`0` = on every request, still single-flight). |
| `STATUS_INCLUDE_QUERY_TEXT` | `false` | `true` adds running-query text (200 chars, string literals masked) to `/status`. |

PostgreSQL and PgBouncer connections are plain TCP on the Docker network: `pg_hba.conf` must allow `cx_monitor`
from that network with `scram-sha-256`.

## Checks

Each check is `ok`, `warn` or `fail` with a human-readable `message` and, where it makes sense, a numeric `value`.
A probe that fails (timeout, lost connection, permission error) becomes a failed check; when PostgreSQL itself is
unreachable, the checks that depend on it fail with "not evaluated: PostgreSQL unreachable" (`cache_hit` warns).
The process never crashes because PostgreSQL or PgBouncer is down.

| Check | ok / warn / fail | `value` |
| --- | --- | --- |
| `postgres_connect` | fail if the probe cannot connect and run its first query (connect timeout 3 s). | response ms |
| `pgbouncer_connect` | Only when `PGBOUNCER_ENABLED`. fail if `SELECT 1` through PgBouncer to `PGBOUNCER_PROBE_DATABASE` fails; warn if that works but the admin console (`SHOW …`) does not. | response ms |
| `connections` | client backends ÷ `max_connections`: warn ≥ `WARN_CONN_PCT`, fail ≥ `FAIL_CONN_PCT`. | % used |
| `disk` | data-directory filesystem used ÷ (used + available), as `df` shows it: warn ≥ `WARN_DISK_PCT`, fail ≥ `FAIL_DISK_PCT`; fail if `statfs` fails. | % used |
| `long_queries` | warn when any client session has a query active, or a transaction idle, longer than `LONG_QUERY_SECONDS`. | sessions |
| `blocked` | warn when any session has waited on a lock longer than `WARN_BLOCKED_SECONDS` (wait start from `pg_locks.waitstart`). | sessions |
| `wal_archive` | With `archive_mode` on: fail when the latest archive failure is newer than the latest success (`pg_stat_archiver`); fail when completed WAL has waited to be archived longer than `WAL_ARCHIVE_MAX_AGE_MINUTES` (oldest `.ready` file, via `pg_ls_archive_statusdir()`). With nothing waiting there has been no WAL to archive, so an old "last archived" time alone is not a failure. Not judged with `archive_mode` off. | oldest waiting, minutes |
| `backup_logical` | From the status file `logical` section (`BACKUP_MAX_AGE_HOURS`); also fail if any database entry has `verified: false`. | hours since success |
| `backup_physical` | `physical` section (pgBackRest, `BACKUP_MAX_AGE_HOURS`); ok with a note when `enabled: false`. | hours since success |
| `backup_upload` | Only when `upload.enabled` is `true` (`UPLOAD_MAX_AGE_HOURS`). | hours since success |
| `backup_verify` | `verify` section (`VERIFY_MAX_AGE_HOURS`); also fail if any database entry, or any bucket under `verify.objects`, has `ok: false`. | hours since success |
| `objects` | Only with `OBJECTS_HEALTH_URL`. fail unless Garage's `/health` answers 200 within 5 s (503 means the layout isn't applied or a partition is unavailable). | response ms |
| `objects_capacity` | Only with `OBJECTS_HEALTH_URL`. `objects.bytes` ÷ `objects.capacity_bytes` from the status file (written by every objects backup run): warn ≥ `WARN_OBJECTS_CAPACITY_PCT`, fail ≥ `FAIL_OBJECTS_CAPACITY_PCT`; warn when nothing has been measured yet. | % used |
| `backup_objects` | Only with `OBJECTS_HEALTH_URL`. `objects_backup` section (`OBJECTS_BACKUP_MAX_AGE_HOURS`); warn when `enabled: false` (no off-site copy at all). | hours since success |
| `report_email` | Only when the status file's `report.enabled` is `true` (steps/85-report.sh). The backup-section rules with `REPORT_MAX_AGE_HOURS`, except that it **warns** where they would fail: a missed email is never a 503. | hours since success |
| `status_file` | warn when the status file is missing, unreadable, larger than 1 MB or not a JSON object. | hours since `updated` |
| `tls_cert` | warn ≤ `CERT_WARN_DAYS` left, fail ≤ `CERT_FAIL_DAYS`, expired, not yet valid or unreadable. | days left |
| `cache_hit` | warn when a database with at least 10,000 block reads+hits has a shared-buffer hit ratio below `MIN_CACHE_HIT_PCT`. Never fails. | lowest % |
| `xid_wraparound` | highest `age(datfrozenxid)` over all databases: warn above 1.2 billion, fail above 1.6 billion (wraparound protection starts near 2.1 billion). | xid age |

**Backup sections.** Every field of the status file is optional. For each section: fail when `last_error` is set
and `last_attempt` is newer than `last_success` (the error goes in the message); fail when there were attempts but
never a success; fail when the last success is older than the limit; warn when the section is missing or records
nothing yet. An attempt newer than the last success *without* an error is a run in progress and is not a failure.
When the file itself is missing or unparseable, `status_file` warns and the backup checks warn "not evaluated".

## What is never exposed

- **Running-query text** (`pg_stat_activity.query`) is not even selected unless `STATUS_INCLUDE_QUERY_TEXT=true`.
  When it is, it is cut to 200 characters and every string literal is masked to `'?'` (numbers stay).
- **pg_stat_statements text** is normalised by PostgreSQL (constants become `$1`, `$2`, …) and cut to 200
  characters. PostgreSQL does *not* normalise utility statements, so `CREATE ROLE … PASSWORD '…'` is stored there
  verbatim; the service masks every remaining string literal and dollar-quoted body, so such passwords come out as
  `'?'`. (This was observed on PostgreSQL 17.11 during testing.)
- Error messages carry PostgreSQL's message only — never its `DETAIL` or `HINT`, which can quote row values.
- `/healthz` is built from check names and states alone. Passwords and the token never appear in responses or logs.
- `/status` does include database, role, schema and table names, PgBouncer pool names, WAL file names, the
  certificate subject and the backup status file as written by the host scripts — keep the token private.

## PostgreSQL and PgBouncer setup

```sql
-- as a superuser, in PG_DATABASE (postgres)
CREATE ROLE cx_monitor LOGIN PASSWORD '…';     -- prefer \password cx_monitor in psql: it sends a hash
GRANT pg_monitor TO cx_monitor;                 -- all of pg_stat_activity, sizes, settings, pg_ls_archive_statusdir()
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- needs shared_preload_libraries = 'pg_stat_statements'
```

Without the extension `/status` reports `"statements": { "available": false, "reason": "…" }` and carries on.

PgBouncer: list the role in `stats_users` (read-only `SHOW` commands on the admin console) and in the auth file.
The admin console speaks only the simple-query protocol; the service sends it parameterless `SHOW POOLS`,
`SHOW STATS`, `SHOW LISTS`, `SHOW CONFIG` (an allow-list of non-secret settings is kept) and `SHOW VERSION`.

Timeouts: connect 3 s; `statement_timeout` 5 s set for the session (in the startup packet) on the PostgreSQL
connection; a 6 s client-side read timeout on every query (PgBouncer rejects `statement_timeout` as a startup
parameter, so that is what bounds PgBouncer queries); and the whole PostgreSQL probe stops starting new queries
after 10 s. Pools hold at most 2 connections each and close idle ones after 30 s. A connection that errors outside
a query is discarded, not reused.

## Report shape (`GET /status`, abridged)

Based on test runs against PostgreSQL 17.11 and PgBouncer 1.26.1 with `LONG_QUERY_SECONDS=5` and
`WARN_BLOCKED_SECONDS=3`, while one session held a table lock and another waited for it. Arrays are cut to one
entry, and the `host` values are illustrative (the test ran on a workstation).

```json
{
  "status": "warn",
  "time": "2026-10-20T06:36:07.443Z",
  "generated_in_ms": 27,
  "checks": [
    { "name": "postgres_connect", "status": "ok", "message": "PostgreSQL 17.11 (Debian 17.11-1.pgdg12+2) answered in 3 ms", "value": 3 },
    { "name": "connections", "status": "ok", "message": "3 of 100 connections in use (3%)", "value": 3 },
    { "name": "long_queries", "status": "warn", "message": "2 session(s) over 5s; longest: query running 9s (pid 132, database alted_test, active)", "value": 2 },
    { "name": "blocked", "status": "warn", "message": "1 session(s) blocked longer than 3s; longest 8s (pid 139 blocked by 132)", "value": 1 },
    { "name": "wal_archive", "status": "ok", "message": "no WAL waiting to be archived; last archived 68s ago", "value": 0 },
    { "name": "backup_logical", "status": "ok", "message": "last successful logical backup 4.5 h ago", "value": 4.53 },
    { "name": "tls_cert", "status": "ok", "message": "certificate for CN=db.example.test expires in 3650 days (2036-10-17T06:29:28.000Z)", "value": 3650 }
  ],
  "server": {
    "version": "17.11 (Debian 17.11-1.pgdg12+2)", "version_num": 170011,
    "start_time": "2026-10-20T06:34:59.270Z", "uptime_seconds": 68, "max_connections": 100,
    "settings": { "shared_buffers": "128MB", "effective_cache_size": "4GB", "work_mem": "4MB", "archive_mode": "on", "wal_level": "replica", "ssl": "off" }
  },
  "connections": {
    "total": 3, "max_connections": 100, "utilisation_pct": 3, "by_state": { "active": 3 },
    "by_database_user": [ { "database": "alted_test", "user": "postgres", "count": 2, "states": { "active": 2 } } ],
    "oldest_transaction_seconds": 8.5, "longest_active_query_seconds": 8.5
  },
  "databases": [
    { "name": "alted_test", "size_bytes": 9590451, "numbackends": 2, "xact_commit": 12, "xact_rollback": 0,
      "cache_hit_pct": 100, "deadlocks": 0, "temp_files": 0, "temp_bytes": 0, "conflicts": 0 }
  ],
  "activity": {
    "long_query_seconds": 5,
    "query_text": "omitted",
    "long_running": { "total": 2, "sessions": [
      { "pid": 132, "database": "alted_test", "user": "postgres", "state": "active", "wait_event_type": "Timeout",
        "wait_event": "PgSleep", "duration_basis": "query", "duration_seconds": 8.5 } ] },
    "blocked": [
      { "pid": 139, "database": "alted_test", "user": "postgres", "state": "active", "wait_event_type": "Lock",
        "wait_event": "relation", "blocked_by": [132], "blocked_seconds": 7.5 } ]
  },
  "statements": {
    "available": true,
    "top_by_total_exec_time": [
      { "database": "alted_test", "user": "postgres", "queryid": "4818347821138336232", "calls": 1, "total_ms": 16.4,
        "mean_ms": 16.401, "rows": 20000, "shared_blks_hit": 80001, "shared_blks_read": 1,
        "query": "INSERT INTO learner (name, notes) SELECT $1 || g, $2 || g FROM generate_series($3, $4) g" } ]
  },
  "vacuum": {
    "database": "postgres",
    "top_dead_tuples": [ { "schemaname": "pg_catalog", "relname": "pg_attribute", "n_live_tup": 51, "n_dead_tup": 131, "last_autovacuum": null } ],
    "frozen_xid_age": [ { "name": "alted_test", "age": 16, "mxid_age": 0 } ]
  },
  "checkpointer": { "source": "pg_stat_checkpointer", "num_timed": 0, "num_requested": 1, "buffers_written": 0 },
  "bgwriter": { "buffers_clean": 0, "maxwritten_clean": 0, "buffers_alloc": 2297 },
  "wal": {
    "archive_mode": "on", "wal_level": "replica",
    "stats": { "wal_records": 73318, "wal_fpi": 1478, "wal_bytes": 13400763 },
    "archiver": { "archived_count": 1, "last_archived_wal": "000000010000000000000001", "last_archived_time": "2026-10-20T06:34:59.155Z",
                  "last_archived_age_seconds": 68.3, "failed_count": 0, "last_failed_time": null },
    "pending": { "ready": 0, "oldest_ready_time": null, "oldest_ready_age_seconds": null }
  },
  "pgbouncer": {
    "enabled": true,
    "probe": { "ok": true, "ms": 3, "database": "postgres", "error": null },
    "version": "PgBouncer 1.26.1",
    "pools": [ { "database": "postgres", "user": "cx_monitor", "cl_active": 1, "cl_waiting": 0, "sv_active": 0, "sv_idle": 1, "maxwait": 0, "pool_mode": "transaction" } ],
    "stats": [ { "database": "postgres", "total_xact_count": 2, "total_query_count": 2, "avg_query_time": 0 } ],
    "lists": { "databases": 3, "users": 2, "pools": 2, "free_clients": 48, "used_clients": 2 },
    "config": { "pool_mode": "transaction", "max_client_conn": 100, "default_pool_size": 10, "query_wait_timeout": 120 }
  },
  "host": {
    "cpu_count": 4,
    "load": { "load1": 0.31, "load5": 0.22, "load15": 0.18, "source": "/proc/loadavg" },
    "memory": { "total_bytes": 8323002368, "available_bytes": 5130235904, "source": "/proc/meminfo" },
    "disk": { "path": "/pgdata", "total_bytes": 105089261568, "used_bytes": 21017852313, "free_bytes": 78676561920, "used_pct": 21.08 }
  },
  "backups": {
    "file": "/backups/status/status.json", "present": true,
    "status": { "updated": "2026-10-20T02:31:10Z", "logical": { "last_success": "2026-10-20T02:04:12Z", "last_error": null, "databases": { "alted": { "verified": true } } } },
    "ages": { "updated_hours": 4.0838, "logical": { "last_success_hours": 4.5321, "last_attempt_hours": 4.6021 },
              "physical": { "last_success_hours": 4.9014, "last_attempt_hours": 5.1021, "last_full_hours": 52.6021 } }
  },
  "tls": {
    "file": "/certs/server.crt", "subject": "CN=db.example.test", "issuer": "CN=db.example.test",
    "subject_alt_names": ["DNS:db.example.test"], "valid_from": "2026-10-20T06:29:28.000Z",
    "valid_to": "2036-10-17T06:29:28.000Z", "days_left": 3650
  }
}
```

A section whose probe failed is replaced by `{ "error": "…" }`; with PgBouncer disabled `pgbouncer` is
`{ "enabled": false }`, and with `CERT_FILE=""` `tls` is `{ "enabled": false }`.

## Metrics (`GET /metrics`)

Metrics are left out (not reported as 0) when their source is unavailable.

| Metric | Labels | Meaning |
| --- | --- | --- |
| `cx_pg_up`, `cx_pgbouncer_up` | | 1 when the probe succeeded |
| `cx_pg_connections` | `state` | client backends by state |
| `cx_pg_connection_utilisation_ratio` | | backends ÷ `max_connections` (0–1) |
| `cx_pg_max_connections`, `cx_pg_uptime_seconds` | | |
| `cx_pg_oldest_transaction_seconds`, `cx_pg_longest_query_seconds` | | |
| `cx_pg_long_running_sessions`, `cx_pg_blocked_sessions` | | |
| `cx_pg_database_size_bytes`, `cx_pg_database_numbackends`, `cx_pg_database_cache_hit_ratio` | `datname` | gauges |
| `cx_pg_database_xact_commit_total`, `cx_pg_database_xact_rollback_total`, `cx_pg_database_deadlocks_total` | `datname` | counters |
| `cx_pg_database_frozen_xid_age` | `datname` | including template databases |
| `cx_pg_archiver_archived_total`, `cx_pg_archiver_failed_total` | | counters |
| `cx_pg_archiver_last_archive_age_seconds` | | seconds since the last successful archive |
| `cx_pg_wal_pending_segments`, `cx_pg_wal_oldest_pending_seconds` | | WAL waiting to be archived |
| `cx_host_disk_used_ratio`, `cx_host_disk_total_bytes`, `cx_host_disk_free_bytes` | `path` | data-directory filesystem |
| `cx_host_load1`, `cx_host_load5`, `cx_host_load15`, `cx_host_cpu_count` | | |
| `cx_host_memory_available_bytes`, `cx_host_memory_total_bytes` | | |
| `cx_backup_age_seconds` | `kind` = `logical`, `physical`, `upload`, `verify` (and `objects` with an object store) | since the last success |
| `cx_objects_up` | | 1 when the object store's health check answered 200 |
| `cx_objects_bytes`, `cx_objects_count`, `cx_objects_capacity_bytes` | | from the last measurement in the status file |
| `cx_backup_status_file_age_seconds` | | since `updated` |
| `cx_tls_cert_days_left` | | |
| `cx_pgbouncer_pool_cl_active`, `_cl_waiting`, `_sv_active`, `_sv_idle`, `_maxwait_seconds` | `database`, `user` | per pool |
| `cx_check_status` | `check` | 0 ok, 1 warn, 2 fail — one per check |
| `cx_health_status` | | overall: 0 ok, 1 warn, 2 fail |
| `cx_health_report_timestamp_seconds` | | when the report was computed |

Label values are escaped (`\\`, `\"`, `\n`) as the exposition format requires.

## The nightly report (`digest.mjs`)

`node digest.mjs` reads one JSON document of facts on stdin — this service's `/status`, host facts and
superuser SQL gathered by the host's `lib/report.sh`, and the previous night's snapshot — and writes
`{ status, subject, preheader, issues, html, text, snapshot }`. It opens no connections and writes no
files; the host sends the email and keeps the snapshot. `src/digest.mjs` works out the changes since the
snapshot and the issues; `src/digest-html.mjs` renders an email-client-safe HTML part (tables, inline
styles, one 600 px column, dark-mode and narrow-screen rules that degrade quietly); `digestText` the plain
part. Statement text goes through `maskSql`; Postgres log messages through `maskLogMessage`, which keeps
the identifier after words like `constraint` or `relation` and hides every other quoted value and number.

## Running it

```sh
npm ci --omit=dev
HEALTH_HOST=127.0.0.1 HEALTH_TOKEN_FILE=/path/to/token PG_HOST=127.0.0.1 PG_PASSWORD_FILE=/path/to/pw node server.mjs
```

### Docker

```sh
docker build -t cx-pgsql/health:local .
```

- Base `node:24-bookworm-slim`, production dependencies only (`npm ci --omit=dev`), runs as the image's
  unprivileged `node` user (uid 1000; Compose may override it with `user:`). Mounted files — the token and
  password files, the status file, the certificate — must be readable by that uid. Nothing is written to disk.
- `EXPOSE 8080`. Publish it on loopback only (`127.0.0.1:<port>:8080`); nginx is the public entry point.
- **Shutdown:** on SIGTERM (or SIGINT) the service stops accepting connections, closes idle keep-alive
  connections, ends the pools and exits 0; a hard deadline exits after 4.5 s, inside Docker's default 10 s. It
  handles the signal itself as PID 1, so tini is not required; `init: true` in Compose works too.
- **HEALTHCHECK** runs `node /app/healthcheck.mjs` every 30 s. It asks *is this service alive and answering?*:
  a 200 **or 503** from `/healthz` with a verdict counts as healthy, because a 503 means PostgreSQL (or a backup,
  the disk, …) is unhealthy, not this process. The database verdict is what `/healthz` itself reports to
  monitors; the container's health only says whether the monitor is working.

### nginx

The proxy needs nothing special: nginx forwards the `Authorization` header by default. Do not log it (the
default `combined` log format does not), and keep the token out of URLs — the service ignores query strings.

### Tests

```sh
npm ci
npm test
```

`node --test` covers threshold evaluation, overall status, the backup rules (including a missing or garbled
status file), the WAL-archive rules, Prometheus formatting and label escaping, token comparison, SQL literal
masking, configuration parsing, `/healthz` redaction and the maintenance feed (`test/maintenance.test.mjs`). `test/http.test.mjs` also starts the real server with
PostgreSQL pointed at a closed port to check routing, auth, headers, logging, survival of a database outage and
SIGTERM shutdown — no database needed.
