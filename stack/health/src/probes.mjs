// Everything that touches the outside world: PostgreSQL, PgBouncer, /proc, the data-dir filesystem,
// the backup status file and the certificate. Every probe resolves (never rejects) to a plain object;
// failures are reported as `error` strings for the report to turn into failed checks.
import { readFile, stat, statfs } from 'node:fs/promises';
import { X509Certificate } from 'node:crypto';
import os from 'node:os';
import pg from 'pg';
import { errorMessage, isServerError, num, numericRow, maskSql } from './util.mjs';

const CONNECT_TIMEOUT_MS = 3_000;
const STATEMENT_TIMEOUT_MS = 5_000;
// Client-side backstop for a server that accepts the query but never answers.
const QUERY_TIMEOUT_MS = 6_000;
// The whole PostgreSQL probe stops starting new queries after this long.
const PG_PROBE_BUDGET_MS = 10_000;
const MAX_STATUS_FILE_BYTES = 1024 * 1024;

export function createPools(cfg, onPoolError) {
  const common = {
    user: cfg.pg.user,
    password: cfg.pg.password,
    max: 2,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
    query_timeout: QUERY_TIMEOUT_MS,
    keepAlive: true,
    application_name: 'cx-health',
  };
  const pools = {
    postgres: new pg.Pool({
      ...common,
      host: cfg.pg.host,
      port: cfg.pg.port,
      database: cfg.pg.database,
      // Sent in the startup packet, so it applies to the whole session.
      statement_timeout: STATEMENT_TIMEOUT_MS,
    }),
  };
  if (cfg.pgbouncer.enabled) {
    // PgBouncer rejects unknown startup parameters, so no statement_timeout here; the client-side
    // query_timeout bounds these instead. The admin console only speaks the simple-query protocol:
    // every query sent to it below is a parameterless string, which pg sends as a simple Query.
    pools.pgbouncerAdmin = new pg.Pool({ ...common, host: cfg.pgbouncer.host, port: cfg.pgbouncer.port, database: 'pgbouncer' });
    pools.pgbouncerProbe = new pg.Pool({ ...common, host: cfg.pgbouncer.host, port: cfg.pgbouncer.port, database: cfg.pgbouncer.probeDatabase });
  }
  for (const [name, pool] of Object.entries(pools)) {
    // An idle client whose server went away emits 'error' on the pool; without a listener that would crash the process.
    pool.on('error', (err) => onPoolError(name, err));
  }
  return pools;
}

/**
 * Checks out one client and runs `fn(client)`. A client that errors outside a query (server gone,
 * read timeout) is destroyed instead of being returned to the pool.
 */
async function withClient(pool, fn) {
  const client = await pool.connect();
  let broken = null;
  const onError = (err) => { broken = err; };
  client.on('error', onError);
  try {
    return await fn(client, () => broken);
  } catch (err) {
    if (!isServerError(err)) broken = err;
    throw err;
  } finally {
    client.removeListener('error', onError);
    client.release(broken ? (broken instanceof Error ? broken : new Error(String(broken))) : undefined);
  }
}

const SETTINGS = [
  'max_connections', 'superuser_reserved_connections', 'reserved_connections', 'shared_buffers',
  'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'max_wal_size', 'archive_mode',
  'archive_timeout', 'wal_level', 'ssl', 'shared_preload_libraries', 'track_io_timing',
];

const SQL = {
  server: `
    SELECT current_setting('server_version') AS version,
           current_setting('server_version_num')::int AS version_num,
           pg_postmaster_start_time() AS start_time,
           extract(epoch FROM now() - pg_postmaster_start_time())::float8 AS uptime_seconds,
           pg_is_in_recovery() AS in_recovery,
           current_database() AS probe_database`,

  // pg_settings hides settings the role may not read instead of raising an error.
  settings: `
    SELECT name, current_setting(name) AS value, setting
    FROM pg_settings
    WHERE name IN (${SETTINGS.map((s) => `'${s}'`).join(', ')})`,

  connections: `
    SELECT coalesce(datname, '') AS datname,
           coalesce(usename, '') AS usename,
           coalesce(state, 'unknown') AS state,
           count(*)::int AS count,
           max(CASE WHEN pid <> pg_backend_pid() THEN extract(epoch FROM now() - xact_start) END)::float8 AS oldest_xact_seconds,
           max(CASE WHEN pid <> pg_backend_pid() AND state = 'active' THEN extract(epoch FROM now() - query_start) END)::float8 AS longest_active_seconds
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
    GROUP BY 1, 2, 3
    ORDER BY 1, 2, 3`,

  databases: `
    SELECT d.datname,
           d.datistemplate AS is_template,
           d.datallowconn AS allow_connections,
           pg_database_size(d.oid)::float8 AS size_bytes,
           s.numbackends,
           s.xact_commit, s.xact_rollback,
           s.blks_read, s.blks_hit,
           s.deadlocks, s.temp_files, s.temp_bytes, s.conflicts,
           age(d.datfrozenxid) AS frozen_xid_age,
           mxid_age(d.datminmxid) AS min_mxid_age
    FROM pg_database d
    LEFT JOIN pg_stat_database s ON s.datid = d.oid
    ORDER BY d.datname`,

  longRunning: (withText) => `
    SELECT pid, datname, usename, state, wait_event_type, wait_event,
           CASE WHEN state = 'active' THEN 'query' ELSE 'transaction' END AS duration_basis,
           extract(epoch FROM now() - CASE WHEN state = 'active' THEN query_start ELSE xact_start END)::float8 AS duration_seconds,
           count(*) OVER ()::int AS total${withText ? ',\n           left(query, 1000) AS query' : ''}
    FROM pg_stat_activity
    WHERE backend_type = 'client backend'
      AND pid <> pg_backend_pid()
      AND ((state = 'active' AND query_start < now() - make_interval(secs => $1))
        OR (state LIKE 'idle in transaction%' AND xact_start < now() - make_interval(secs => $1)))
    ORDER BY duration_seconds DESC
    LIMIT 50`,

  blocked: (withText, hasWaitStart) => `
    SELECT a.pid, a.datname, a.usename, a.state, a.wait_event_type, a.wait_event,
           pg_blocking_pids(a.pid) AS blocked_by,
           extract(epoch FROM now() - coalesce(${hasWaitStart ? 'l.waitstart, ' : ''}a.query_start))::float8 AS blocked_seconds${withText ? ',\n           left(a.query, 1000) AS query' : ''}
    FROM pg_stat_activity a
    ${hasWaitStart ? 'LEFT JOIN LATERAL (SELECT min(waitstart) AS waitstart FROM pg_locks WHERE pid = a.pid AND NOT granted) l ON true' : ''}
    WHERE a.wait_event_type = 'Lock'
      AND a.pid <> pg_backend_pid()
      AND cardinality(pg_blocking_pids(a.pid)) > 0
    ORDER BY blocked_seconds DESC NULLS LAST
    LIMIT 50`,

  archiver: `
    SELECT archived_count, last_archived_wal, last_archived_time,
           extract(epoch FROM now() - last_archived_time)::float8 AS last_archived_age_seconds,
           failed_count, last_failed_wal, last_failed_time,
           extract(epoch FROM now() - last_failed_time)::float8 AS last_failed_age_seconds,
           stats_reset
    FROM pg_stat_archiver`,

  // Segments completed but not yet archived. Needs pg_monitor (or superuser).
  walPending: `
    SELECT count(*)::int AS ready,
           min(modification) AS oldest_ready_time,
           extract(epoch FROM now() - min(modification))::float8 AS oldest_ready_age_seconds
    FROM pg_ls_archive_statusdir()
    WHERE name LIKE '%.ready'`,

  statWal: 'SELECT * FROM pg_stat_wal',
  checkpointer: 'SELECT * FROM pg_stat_checkpointer',
  bgwriter: 'SELECT * FROM pg_stat_bgwriter',

  vacuum: `
    SELECT schemaname, relname, n_live_tup, n_dead_tup,
           last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
           vacuum_count, autovacuum_count
    FROM pg_stat_all_tables
    WHERE n_dead_tup > 0
    ORDER BY n_dead_tup DESC
    LIMIT 10`,

  statementsSchema: `
    SELECT n.nspname
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_stat_statements'`,

  statements: (schema) => `
    SELECT d.datname, r.rolname, s.queryid::text AS queryid,
           s.calls, s.total_exec_time, s.mean_exec_time, s.rows,
           s.shared_blks_hit, s.shared_blks_read,
           left(s.query, 1000) AS query
    FROM "${schema.replace(/"/g, '""')}".pg_stat_statements s
    LEFT JOIN pg_database d ON d.oid = s.dbid
    LEFT JOIN pg_roles r ON r.oid = s.userid
    ORDER BY s.total_exec_time DESC
    LIMIT 15`,
};

/** Names of the PostgreSQL probe sections, in the order they run (check inputs first). */
export const PG_SECTIONS = Object.freeze([
  'settings', 'connections', 'databases', 'long_running', 'blocked', 'archiver', 'wal_pending',
  'stat_wal', 'checkpointer', 'bgwriter', 'vacuum', 'statements',
]);

/**
 * Runs the PostgreSQL probe on one session. Returns
 * { connected, response_ms, error, data: { section: value }, errors: { section: message } }.
 */
export async function probePostgres(pool, cfg) {
  const started = Date.now();
  const result = { connected: false, response_ms: null, error: null, data: {}, errors: {} };

  // One retry covers a pooled connection that the server closed since its last use. A failure to
  // connect at all is not retried, so a down server costs one connect timeout, not two.
  for (let attempt = 1; attempt <= 2; attempt++) {
    let gotClient = false;
    try {
      const attemptStarted = Date.now();
      await withClient(pool, async (client, brokenError) => {
        gotClient = true;
        const server = (await client.query(SQL.server)).rows[0];
        result.connected = true;
        result.error = null;
        // Checkout (a new connection when the pool had none idle) plus the first query.
        result.response_ms = Date.now() - attemptStarted;
        result.data.server = server;
        await runSections(client, cfg, server.version_num, result, started, brokenError);
      });
      return result;
    } catch (err) {
      result.error = errorMessage(err);
      if (!gotClient || result.connected || isServerError(err)) return result;
    }
  }
  return result;
}

async function runSections(client, cfg, versionNum, result, started, brokenError) {
  const withText = cfg.includeQueryText;
  const sections = [
    ['settings', async () => Object.fromEntries((await client.query(SQL.settings)).rows.map((r) => [r.name, { value: r.value, setting: r.setting }]))],
    ['connections', async () => (await client.query(SQL.connections)).rows],
    ['databases', async () => (await client.query(SQL.databases)).rows.map(numericRow)],
    ['long_running', async () => (await client.query(SQL.longRunning(withText), [cfg.thresholds.longQuerySeconds])).rows],
    ['blocked', async () => (await client.query(SQL.blocked(withText, versionNum >= 140000))).rows],
    ['archiver', async () => { const row = (await client.query(SQL.archiver)).rows[0]; return row ? numericRow(row) : null; }],
    ['wal_pending', async () => (await client.query(SQL.walPending)).rows[0] ?? null],
    ['stat_wal', async () => (versionNum >= 140000 ? numericRow((await client.query(SQL.statWal)).rows[0] ?? {}) : null)],
    ['checkpointer', async () => (versionNum >= 170000 ? numericRow((await client.query(SQL.checkpointer)).rows[0] ?? {}) : null)],
    ['bgwriter', async () => numericRow((await client.query(SQL.bgwriter)).rows[0] ?? {})],
    ['vacuum', async () => (await client.query(SQL.vacuum)).rows.map(numericRow)],
    ['statements', async () => {
      const schema = (await client.query(SQL.statementsSchema)).rows[0]?.nspname;
      if (!schema) return { available: false, reason: `pg_stat_statements is not installed in database "${cfg.pg.database}"` };
      const rows = (await client.query(SQL.statements(schema))).rows.map(numericRow);
      return { available: true, rows };
    }],
  ];

  let stopReason = null;
  for (const [name, run] of sections) {
    if (!PG_SECTIONS.includes(name)) throw new Error(`unlisted probe section ${name}`);
    if (!stopReason && brokenError()) stopReason = `not run: ${errorMessage(brokenError())}`;
    if (!stopReason && Date.now() - started > PG_PROBE_BUDGET_MS) stopReason = 'not run: probe time budget exceeded';
    if (stopReason) {
      result.errors[name] = stopReason;
      continue;
    }
    try {
      result.data[name] = await run();
    } catch (err) {
      result.errors[name] = errorMessage(err);
      // A server error leaves the session usable; anything else (timeout, lost connection) ends the run.
      if (!isServerError(err)) stopReason = `not run: ${errorMessage(err)}`;
    }
  }
  // Raw query text never leaves this module unmasked.
  for (const key of ['long_running', 'blocked']) {
    for (const row of result.data[key] ?? []) if ('query' in row) row.query = maskSql(row.query, 200);
  }
  for (const row of result.data.statements?.rows ?? []) row.query = maskSql(row.query, 200);
}

const BOUNCER_CONFIG_KEYS = new Set([
  'pool_mode', 'max_client_conn', 'default_pool_size', 'min_pool_size', 'reserve_pool_size',
  'reserve_pool_timeout', 'max_db_connections', 'max_user_connections', 'server_idle_timeout',
  'server_lifetime', 'query_timeout', 'query_wait_timeout', 'client_idle_timeout',
  'idle_transaction_timeout', 'auth_type', 'listen_port', 'max_prepared_statements',
]);

export async function probePgbouncer(pools, cfg) {
  const out = {
    probe: { ok: false, ms: null, database: cfg.pgbouncer.probeDatabase, error: null },
    admin: { ok: false, error: null },
  };

  const probe = (async () => {
    const t0 = Date.now();
    try {
      await withClient(pools.pgbouncerProbe, (client) => client.query('SELECT 1'));
      out.probe.ok = true;
      out.probe.ms = Date.now() - t0;
    } catch (err) {
      out.probe.error = errorMessage(err);
    }
  })();

  const admin = (async () => {
    try {
      await withClient(pools.pgbouncerAdmin, async (client) => {
        const show = async (what) => (await client.query(`SHOW ${what}`)).rows;
        out.admin.version = (await show('VERSION'))[0]?.version ?? null;
        out.admin.pools = (await show('POOLS')).map(numericRow);
        out.admin.stats = (await show('STATS')).map(numericRow);
        out.admin.lists = Object.fromEntries((await show('LISTS')).map((r) => [r.list, num(r.items)]));
        out.admin.config = Object.fromEntries(
          (await show('CONFIG')).filter((r) => BOUNCER_CONFIG_KEYS.has(r.key)).map((r) => [r.key, num(r.value) ?? r.value]),
        );
      });
      out.admin.ok = true;
    } catch (err) {
      out.admin.error = errorMessage(err);
    }
  })();

  await Promise.all([probe, admin]);
  return out;
}

export async function probeHost(dataDir) {
  const out = { cpu_count: os.availableParallelism(), load: null, memory: null, disk: null, errors: {} };

  try {
    const [l1, l5, l15] = (await readFile('/proc/loadavg', 'utf8')).trim().split(/\s+/).map(Number);
    out.load = { load1: l1, load5: l5, load15: l15, source: '/proc/loadavg' };
  } catch {
    const [l1, l5, l15] = os.loadavg();
    out.load = { load1: l1, load5: l5, load15: l15, source: 'os.loadavg' };
  }

  try {
    const fields = {};
    for (const line of (await readFile('/proc/meminfo', 'utf8')).split('\n')) {
      const m = /^(\w+):\s+(\d+)(?:\s+kB)?$/.exec(line.trim());
      if (m) fields[m[1]] = Number(m[2]) * 1024;
    }
    out.memory = {
      total_bytes: fields.MemTotal ?? null,
      available_bytes: fields.MemAvailable ?? null,
      free_bytes: fields.MemFree ?? null,
      swap_total_bytes: fields.SwapTotal ?? null,
      swap_free_bytes: fields.SwapFree ?? null,
      source: '/proc/meminfo',
    };
  } catch {
    out.memory = { total_bytes: os.totalmem(), available_bytes: os.freemem(), free_bytes: os.freemem(), source: 'os' };
  }

  try {
    const s = await statfs(dataDir);
    const total = s.blocks * s.bsize;
    const free = s.bfree * s.bsize;
    const available = s.bavail * s.bsize;
    const used = total - free;
    // Same formula as df: blocks reserved for root count as neither used nor available.
    const usedPct = used + available > 0 ? (used / (used + available)) * 100 : null;
    out.disk = { path: dataDir, total_bytes: total, used_bytes: used, free_bytes: available, used_pct: usedPct };
  } catch (err) {
    out.errors.disk = `cannot statfs ${dataDir}: ${err.code || errorMessage(err)}`;
  }
  return out;
}

const OBJECTS_TIMEOUT_MS = 5_000;

/** Asks the object store (Garage's /health) how it is. Returns { url, http_status, response_ms } or { url, error }. */
export async function probeObjects(url) {
  const started = performance.now();
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(OBJECTS_TIMEOUT_MS), redirect: 'manual' });
    await res.arrayBuffer().catch(() => {});
    return { url, http_status: res.status, response_ms: Math.round((performance.now() - started) * 10) / 10 };
  } catch (err) {
    return { url, error: err?.name === 'TimeoutError' ? `no answer within ${OBJECTS_TIMEOUT_MS} ms` : errorMessage(err) };
  }
}

/** Reads the backup status file. Returns { path, present, data?, error?, mtime? }; never throws. */
export async function readBackupStatus(path) {
  const result = await readStatusFile(path);
  return { path, ...result };
}

async function readStatusFile(path) {
  try {
    const info = await stat(path);
    if (info.size > MAX_STATUS_FILE_BYTES) return { present: true, error: `larger than ${MAX_STATUS_FILE_BYTES} bytes` };
    const text = await readFile(path, 'utf8');
    let data;
    try {
      data = JSON.parse(text);
    } catch (err) {
      return { present: true, error: `not valid JSON (${errorMessage(err)})`, mtime: info.mtime };
    }
    if (data === null || typeof data !== 'object' || Array.isArray(data)) {
      return { present: true, error: 'not a JSON object', mtime: info.mtime };
    }
    return { present: true, data, mtime: info.mtime };
  } catch (err) {
    return { present: false, error: err.code === 'ENOENT' ? 'missing' : `unreadable (${err.code || errorMessage(err)})` };
  }
}

/** Reads the first certificate of a PEM file. Returns { subject, issuer, valid_from, valid_to, ... } or { error }. */
export async function readCertificate(path) {
  try {
    const cert = new X509Certificate(await readFile(path));
    const validTo = cert.validToDate ?? new Date(cert.validTo);
    const validFrom = cert.validFromDate ?? new Date(cert.validFrom);
    return {
      file: path,
      subject: cert.subject.split('\n').join(', '),
      issuer: cert.issuer.split('\n').join(', '),
      subject_alt_names: cert.subjectAltName ? cert.subjectAltName.split(', ') : [],
      valid_from: validFrom.toISOString(),
      valid_to: validTo.toISOString(),
      fingerprint256: cert.fingerprint256,
    };
  } catch (err) {
    return { file: path, error: err.code === 'ENOENT' ? 'missing' : `unreadable (${err.code || errorMessage(err)})` };
  }
}
