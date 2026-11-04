// The nightly report: turns one evening's facts into what the email says.
//
// Input (one JSON document on stdin, gathered by the host's lib/report.sh):
//   generated_at, server { hostname, fqdn }, config { to, slow_mean_ms, ignore_users[], timezone },
//   status   the health service's own /status report (or { error })
//   host     facts only the host can see: filesystems, space by area, updates, reboot, containers,
//            the last day's backup job runs, SSH and fail2ban, Postgres and PgBouncer log errors, Dropbox space
//   sql      what needs a superuser and every database: all of pg_stat_statements, the largest tables
//   previous the snapshot the last report left (or null)
//
// Output: { status, subject, preheader, issues[], model, snapshot }. The renderers (digest-html.mjs and
// digestText below) turn `model` into the email. Nothing here reads the network or the disk.
import { worstStatus, formatHours } from './report.mjs';
import { maskSql, round } from './util.mjs';

export const SEVERITIES = Object.freeze(['fail', 'warn', 'info']);
const SEVERITY_RANK = { fail: 0, warn: 1, info: 2 };

// ---------------------------------------------------------------- formatting

const IEC = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];

/** 1536 → "1.5 KiB". Null for anything that isn't a finite number. */
export function formatBytes(bytes) {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes)) return null;
  const sign = bytes < 0 ? '-' : '';
  let v = Math.abs(bytes);
  let i = 0;
  while (v >= 1024 && i < IEC.length - 1) {
    v /= 1024;
    i++;
  }
  const places = i === 0 || v >= 100 ? 0 : 1;
  return `${sign}${v.toFixed(places)} ${IEC[i]}`;
}

/** A change, signed: "+1.2 MiB", "−340 KiB", "no change". */
export function formatDeltaBytes(delta) {
  if (typeof delta !== 'number' || !Number.isFinite(delta)) return null;
  if (delta === 0) return 'no change';
  return `${delta > 0 ? '+' : '−'}${formatBytes(Math.abs(delta))}`;
}

export function formatCount(n) {
  if (typeof n !== 'number' || !Number.isFinite(n)) return null;
  return Math.round(n).toLocaleString('en-GB');
}

export function formatMs(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms)) return null;
  if (ms < 1) return `${round(ms, 2)} ms`;
  if (ms < 1000) return `${round(ms, ms < 10 ? 1 : 0)} ms`;
  if (ms < 60_000) return `${round(ms / 1000, 1)} s`;
  return `${round(ms / 60_000, 1)} min`;
}

export function formatDuration(seconds) {
  if (typeof seconds !== 'number' || !Number.isFinite(seconds)) return null;
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3600);
  if (days > 0) return `${days} day${days === 1 ? '' : 's'}${hours ? ` ${hours} h` : ''}`;
  const minutes = Math.floor((seconds % 3600) / 60);
  return hours ? `${hours} h ${minutes} min` : `${minutes} min`;
}

export function pct(part, whole) {
  if (typeof part !== 'number' || typeof whole !== 'number' || !(whole > 0)) return null;
  return round((part / whole) * 100, 1);
}

/** "Wed 4 Nov 2026, 06:00 GMT" in the report's time zone. */
export function formatWhen(iso, timeZone = 'Europe/London', { date = true, time = true } = {}) {
  const d = iso instanceof Date ? iso : new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-GB', {
      timeZone, weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
      hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZoneName: 'short',
    }).formatToParts(d).map((p) => [p.type, p.value]),
  );
  const day = `${parts.weekday} ${parts.day} ${parts.month} ${parts.year}`;
  const clock = `${parts.hour}:${parts.minute} ${parts.timeZoneName}`;
  return date && time ? `${day}, ${clock}` : date ? day : clock;
}

// Never negative: a clock a few seconds apart shouldn't read "-1 min ago".
function hoursBetween(fromIso, now) {
  const t = Date.parse(fromIso ?? '');
  return Number.isFinite(t) ? Math.max(0, (now.getTime() - t) / 3_600_000) : null;
}

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const n = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) ? Number(v) : null);

/** A counter's change since the snapshot; null when there's no snapshot or the counter went backwards (a reset). */
export function counterDelta(now, before) {
  const a = n(now);
  const b = n(before);
  if (a === null || b === null || a < b) return null;
  return a - b;
}

// ---------------------------------------------------------------- Postgres log lines

/**
 * Masks a Postgres log message so it can leave the server: quoted values become "?", except the
 * identifier Postgres names after a word like constraint/relation/column (those are schema, not data).
 * Numbers inside messages are kept only as part of identifiers.
 */
export function maskLogMessage(message, maxLength = 160) {
  if (typeof message !== 'string') return '';
  const IDENT_BEFORE = /\b(constraint|relation|column|table|index|database|role|user|schema|function|type|extension|sequence|view|trigger|operator|slot|tablespace|publication|subscription|file)\s*$/i;
  let out = '';
  let i = 0;
  while (i < message.length) {
    const ch = message[i];
    if (ch === '"' || ch === "'") {
      const end = message.indexOf(ch, i + 1);
      const body = end === -1 ? message.slice(i + 1) : message.slice(i + 1, end);
      const keep = ch === '"' && IDENT_BEFORE.test(message.slice(0, i)) && /^[A-Za-z_][A-Za-z0-9_.$-]{0,62}$/.test(body);
      out += keep ? `"${body}"` : `${ch}?${ch}`;
      i = end === -1 ? message.length : end + 1;
      continue;
    }
    out += ch;
    i++;
  }
  // Values Postgres prints bare: "Key (email)=(x@y)", "at character 1312", WAL file names, numbers in general.
  out = out
    .replace(/\)=\([^)]*\)/g, ')=(?)')
    .replace(/\b[0-9A-F]{24}\b/g, '<wal>')
    .replace(/\b\d+(\.\d+)?\b/g, 'N')
    .replace(/\s+/g, ' ')
    .trim();
  return out.length > maxLength ? `${out.slice(0, maxLength - 1)}…` : out;
}

// ---------------------------------------------------------------- the model

const LABELS = {
  postgres_connect: 'PostgreSQL answers',
  pgbouncer_connect: 'PgBouncer answers',
  connections: 'Connections',
  disk: 'Data disk',
  long_queries: 'Long-running queries',
  blocked: 'Sessions blocked on locks',
  wal_archive: 'WAL archiving',
  backup_logical: 'Nightly dumps',
  backup_physical: 'pgBackRest (point-in-time)',
  backup_upload: 'Off-site upload',
  backup_verify: 'Restore test',
  status_file: 'Backup status file',
  objects: 'Object store answers',
  objects_capacity: 'Object store capacity',
  backup_objects: 'Object store off-site copy',
  tls_cert: 'TLS certificate',
  cache_hit: 'Cache hit ratio',
  xid_wraparound: 'Transaction ID age',
  report_email: 'Nightly report email',
};
export const checkLabel = (name) => LABELS[name] ?? name.replace(/_/g, ' ');

const JOB_LABELS = { logical: 'Nightly dumps', physical: 'pgBackRest', upload: 'Off-site upload', objects: 'Object store copy', verify: 'Restore test' };

/** Builds everything the email says, the issues it leads with, and the snapshot for tomorrow. */
export function buildDigest(input, nowArg) {
  const now = nowArg ?? new Date(input.generated_at ?? Date.now());
  const cfg = { slow_mean_ms: 100, ignore_users: ['cx_monitor', 'postgres'], timezone: 'Europe/London', dropbox_warn_free_pct: 10, ...(input.config ?? {}) };
  const status = isObj(input.status) ? input.status : {};
  const host = isObj(input.host) ? input.host : {};
  const sql = isObj(input.sql) ? input.sql : {};
  const prev = isObj(input.previous) ? input.previous : null;
  const periodHours = prev?.at ? round(hoursBetween(prev.at, now), 1) : null;
  const issues = [];
  const issue = (severity, area, text) => issues.push({ severity, area, text });

  // -- health checks
  const checks = Array.isArray(status.checks) ? status.checks : [];
  if (status.error || !checks.length) {
    issue('fail', 'Health', `The health service gave no report: ${status.error ?? 'empty answer'}`);
  }
  for (const c of checks) {
    if (c.status === 'fail' || c.status === 'warn') issue(c.status, checkLabel(c.name), c.message);
  }

  // -- server
  const mem = status.host?.memory ?? {};
  const memUsed = n(mem.total_bytes) !== null && n(mem.available_bytes) !== null ? mem.total_bytes - mem.available_bytes : null;
  const swapUsed = n(mem.swap_total_bytes) && n(mem.swap_free_bytes) !== null ? mem.swap_total_bytes - mem.swap_free_bytes : null;
  const load = status.host?.load ?? {};
  const cpus = n(status.host?.cpu_count) ?? n(host.cpu_count);
  if (cpus && n(load.load15) !== null && load.load15 > cpus) {
    issue('warn', 'Server', `Load over the last 15 minutes is ${load.load15} on ${cpus} cores.`);
  }
  if (memUsed !== null && pct(memUsed, mem.total_bytes) >= 90) {
    issue('warn', 'Server', `Memory is ${pct(memUsed, mem.total_bytes)}% used.`);
  }
  if (swapUsed !== null && swapUsed > 256 * 1024 * 1024) {
    issue('info', 'Server', `${formatBytes(swapUsed)} of swap in use.`);
  }

  const filesystems = (Array.isArray(host.filesystems) ? host.filesystems : [])
    .filter((f) => n(f.size) >= 1024 ** 3)
    .map((f) => {
      const usedPct = pct(f.used, f.used + f.avail);
      if (usedPct >= 90) issue('fail', 'Disk', `${f.mount} is ${usedPct}% full (${formatBytes(f.avail)} free).`);
      else if (usedPct >= 80) issue('warn', 'Disk', `${f.mount} is ${usedPct}% full (${formatBytes(f.avail)} free).`);
      return { mount: f.mount, fstype: f.fstype, size: f.size, used: f.used, free: f.avail, used_pct: usedPct };
    });

  const updates = isObj(host.updates) ? host.updates : null;
  if (host.reboot_required) {
    const why = Array.isArray(host.reboot_packages) && host.reboot_packages.length ? ` (for ${host.reboot_packages.slice(0, 4).join(', ')})` : '';
    // Already booked (AUTO_REBOOT, or by hand): a note, not a warning.
    if (host.reboot_scheduled) issue('info', 'Server', `A reboot is pending${why} and booked for ${formatWhen(host.reboot_scheduled, cfg.timezone)}.`);
    else issue('warn', 'Server', `A reboot is pending${why} and nothing has booked it.`);
  }
  if (updates && n(updates.security) > 0) issue('warn', 'Server', `${updates.security} security update${updates.security === 1 ? '' : 's'} waiting.`);
  else if (updates && n(updates.total) > 0) issue('info', 'Server', `${updates.total} package update${updates.total === 1 ? '' : 's'} waiting (none marked security).`);

  const containers = (Array.isArray(host.containers) ? host.containers : []).map((c) => {
    const restartsBefore = prev?.containers?.[c.name];
    const restartDelta = counterDelta(c.restarts, restartsBefore);
    if (c.state !== 'running') issue('fail', 'Containers', `${c.name} is ${c.state}.`);
    else if (c.health && c.health !== 'healthy') issue('warn', 'Containers', `${c.name} is ${c.health}.`);
    if (restartDelta > 0) issue('warn', 'Containers', `${c.name} restarted ${restartDelta} time${restartDelta === 1 ? '' : 's'}.`);
    return { ...c, restart_delta: restartDelta };
  });

  // -- PostgreSQL
  const dbs = (Array.isArray(status.databases) ? status.databases : []).map((d) => {
    const p = prev?.databases?.[d.name];
    const deadlocks = counterDelta(d.deadlocks, p?.deadlocks);
    if (deadlocks > 0) issue('warn', 'PostgreSQL', `${deadlocks} deadlock${deadlocks === 1 ? '' : 's'} in ${d.name}.`);
    return {
      name: d.name,
      size: n(d.size_bytes),
      size_delta: p ? (n(d.size_bytes) ?? 0) - (n(p.size) ?? 0) : null,
      connections: n(d.numbackends),
      commits: counterDelta(d.xact_commit, p?.commits),
      rollbacks: counterDelta(d.xact_rollback, p?.rollbacks),
      deadlocks,
      temp_bytes: counterDelta(d.temp_bytes, p?.temp_bytes),
      cache_hit_pct: n(d.cache_hit_pct),
    };
  });
  const totalDbSize = dbs.reduce((s, d) => s + (d.size ?? 0), 0);

  const wal = status.wal ?? {};
  const walBytes = counterDelta(wal.stats?.wal_bytes, prev?.wal_bytes);
  const archived = counterDelta(wal.archiver?.archived_count, prev?.archived_count);
  const archiveFailed = counterDelta(wal.archiver?.failed_count, prev?.archive_failed_count);
  if (archiveFailed > 0) issue('warn', 'PostgreSQL', `${archiveFailed} WAL archive attempt${archiveFailed === 1 ? '' : 's'} failed (they're retried).`);

  // Statements: the change since the last report, per statement; a reset (or the first report) shows totals.
  const ignore = new Set(cfg.ignore_users ?? []);
  const stmtRows = Array.isArray(sql.statements?.rows) ? sql.statements.rows : [];
  const resetChanged = prev && sql.statements?.stats_reset && prev.statements_reset && sql.statements.stats_reset !== prev.statements_reset;
  const sinceReset = !prev || resetChanged;
  const statements = [];
  for (const r of stmtRows) {
    const key = `${r.dbname}|${r.user}|${r.queryid}`;
    const before = sinceReset ? null : prev?.statements?.[key];
    const calls = before ? counterDelta(r.calls, before.calls) : n(r.calls);
    const total = before ? counterDelta(r.total_ms, before.total_ms) : n(r.total_ms);
    if (!calls || total === null) continue;
    statements.push({
      database: r.dbname ?? '(dropped database)',
      user: r.user,
      monitoring: ignore.has(r.user),
      // pg_dump's and imports' COPY: bulk by nature, so never "slow" — counted on their own.
      bulk: /^\s*COPY\b/i.test(r.query ?? ''),
      calls,
      total_ms: round(total, 1),
      mean_ms: round(total / calls, 2),
      max_ms: n(r.max_ms),
      rows: n(r.rows),
      query: maskSql(r.query, 220),
    });
  }
  const appStatements = statements.filter((s) => !s.monitoring && !s.bulk);
  const bulkStatements = statements.filter((s) => !s.monitoring && s.bulk);
  const monitorStatements = statements.filter((s) => s.monitoring);
  const byTotal = (a, b) => b.total_ms - a.total_ms;
  const slow = appStatements.filter((s) => s.mean_ms >= cfg.slow_mean_ms).sort((a, b) => b.mean_ms - a.mean_ms);
  for (const s of slow.slice(0, 3)) {
    issue('warn', 'Slow queries', `${s.database}: ${formatMs(s.mean_ms)} on average over ${formatCount(s.calls)} call${s.calls === 1 ? '' : 's'} — ${s.query}`);
  }
  if (slow.length > 3) issue('warn', 'Slow queries', `…and ${slow.length - 3} more averaging over ${formatMs(cfg.slow_mean_ms)}.`);

  const statementTotals = {
    calls: appStatements.reduce((s, r) => s + r.calls, 0),
    total_ms: round(appStatements.reduce((s, r) => s + r.total_ms, 0), 0),
    monitoring_calls: monitorStatements.reduce((s, r) => s + r.calls, 0),
    monitoring_ms: round(monitorStatements.reduce((s, r) => s + r.total_ms, 0), 0),
    bulk_calls: bulkStatements.reduce((s, r) => s + r.calls, 0),
    bulk_ms: round(bulkStatements.reduce((s, r) => s + r.total_ms, 0), 0),
  };

  // Postgres log: errors grouped by masked message, statements over log_min_duration_statement.
  const pgLog = isObj(host.pg_log) ? host.pg_log : {};
  const logErrors = (Array.isArray(pgLog.errors) ? pgLog.errors : [])
    .map((e) => ({ severity: e.severity, who: e.who ?? null, message: maskLogMessage(e.message), count: n(e.count) ?? 1 }))
    .reduce((acc, e) => {
      const k = `${e.severity}|${e.who}|${e.message}`;
      const hit = acc.get(k);
      if (hit) hit.count += e.count;
      else acc.set(k, { ...e });
      return acc;
    }, new Map());
  const errorGroups = [...logErrors.values()].sort((a, b) => b.count - a.count);
  const errorCount = (sev) => errorGroups.filter((e) => e.severity === sev).reduce((s, e) => s + e.count, 0);
  const pgErrors = { panic: errorCount('PANIC'), fatal: errorCount('FATAL'), error: errorCount('ERROR'), warning: errorCount('WARNING') };
  if (pgErrors.panic) issue('fail', 'PostgreSQL log', `${pgErrors.panic} PANIC line${pgErrors.panic === 1 ? '' : 's'} in the log.`);
  if (pgErrors.fatal) {
    const top = errorGroups.find((e) => e.severity === 'FATAL');
    issue('warn', 'PostgreSQL log', `${pgErrors.fatal} FATAL line${pgErrors.fatal === 1 ? '' : 's'}, most often: ${top.message}`);
  }
  if (pgErrors.error) {
    const top = errorGroups.find((e) => e.severity === 'ERROR');
    issue('info', 'PostgreSQL log', `${formatCount(pgErrors.error)} statement error${pgErrors.error === 1 ? '' : 's'}, most often (${formatCount(top.count)}×): ${top.message}`);
  }
  const slowLogged = { count: n(pgLog.slow?.count) ?? 0, max_ms: n(pgLog.slow?.max_ms), threshold_ms: n(pgLog.slow?.threshold_ms) };
  if (slowLogged.count) issue('info', 'Slow queries', `${formatCount(slowLogged.count)} statement${slowLogged.count === 1 ? '' : 's'} took over ${formatMs(slowLogged.threshold_ms ?? 500)} (longest ${formatMs(slowLogged.max_ms)}).`);

  const bouncerLog = (Array.isArray(host.pgbouncer_log?.errors) ? host.pgbouncer_log.errors : [])
    .map((e) => ({ severity: e.severity, message: maskLogMessage(e.message), count: n(e.count) ?? 1 }))
    .sort((a, b) => b.count - a.count);
  const bouncerErrors = bouncerLog.reduce((s, e) => s + e.count, 0);
  if (bouncerErrors) issue('info', 'PgBouncer log', `${formatCount(bouncerErrors)} warning/error line${bouncerErrors === 1 ? '' : 's'}, most often: ${bouncerLog[0].message}`);

  // PgBouncer traffic and waiting clients.
  const bouncer = status.pgbouncer ?? {};
  const pools = (Array.isArray(bouncer.pools) ? bouncer.pools : []).filter((p) => p.database !== 'pgbouncer');
  const maxWaitSeconds = pools.reduce((m, p) => Math.max(m, n(p.maxwait) ?? 0), 0);
  if (maxWaitSeconds >= 1) issue('warn', 'PgBouncer', `A client waited ${maxWaitSeconds}s for a server connection.`);
  const bouncerStats = (Array.isArray(bouncer.stats) ? bouncer.stats : [])
    .filter((s) => s.database !== 'pgbouncer')
    .map((s) => {
      const p = prev?.pgbouncer?.[s.database];
      const xacts = counterDelta(s.total_xact_count, p?.xacts);
      const xactTime = counterDelta(s.total_xact_time, p?.xact_us);
      const waitTime = counterDelta(s.total_wait_time, p?.wait_us);
      return {
        database: s.database,
        transactions: xacts,
        avg_xact_ms: xacts ? round(xactTime / xacts / 1000, 2) : null,
        avg_wait_ms: xacts ? round(waitTime / xacts / 1000, 2) : null,
        sent: counterDelta(s.total_sent, p?.sent),
      };
    });

  // Largest tables, and change since the last report.
  const tables = (Array.isArray(sql.tables) ? sql.tables : []).map((t) => {
    const key = `${t.db}.${t.schema}.${t.name}`;
    const before = n(prev?.tables?.[key]);
    const dead = n(t.dead_tup) ?? 0;
    const live = n(t.live_tup) ?? 0;
    return {
      key,
      database: t.db,
      name: t.schema === 'public' ? t.name : `${t.schema}.${t.name}`,
      size: n(t.total_bytes),
      size_delta: before === null ? null : (n(t.total_bytes) ?? 0) - before,
      rows: live,
      dead_pct: live + dead > 0 ? pct(dead, live + dead) : null,
      dead,
      last_vacuum: t.last_vacuum ?? null,
    };
  });
  for (const t of tables) {
    if (t.dead >= 10_000 && t.dead_pct >= 20) issue('info', 'PostgreSQL', `${t.database}.${t.name} has ${t.dead_pct}% dead rows (${formatCount(t.dead)}); autovacuum hasn't caught up.`);
  }

  // -- backups
  const bstat = status.backups?.status ?? {};
  const jobs = Array.isArray(host.jobs) ? host.jobs : [];
  const runs = {};
  for (const j of jobs) {
    const m = /^cx-backup@(\w+)\.service$/.exec(j.unit ?? '');
    const kind = m ? m[1] : j.unit;
    runs[kind] ??= { ok: 0, failed: 0, last_failed: null };
    if (j.result === 'done') runs[kind].ok++;
    else {
      runs[kind].failed++;
      runs[kind].last_failed = j.time ?? runs[kind].last_failed;
    }
  }
  for (const [kind, r] of Object.entries(runs)) {
    if (r.failed) issue('warn', 'Backups', `${JOB_LABELS[kind] ?? kind}: ${r.failed} of ${r.ok + r.failed} run${r.ok + r.failed === 1 ? '' : 's'} failed.`);
  }
  const backupRows = [
    { kind: 'logical', section: bstat.logical, detail: dumpDetail(bstat.logical) },
    { kind: 'physical', section: bstat.physical, detail: physicalDetail(bstat.physical) },
    { kind: 'upload', section: bstat.upload, detail: isObj(bstat.upload) && n(bstat.upload.remote_bytes) !== null ? `${formatBytes(bstat.upload.remote_bytes)} off-site` : null },
    { kind: 'objects', section: bstat.objects_backup, detail: bstat.objects_backup?.destination ? 'encrypted copy' : null },
    { kind: 'verify', section: bstat.verify, detail: verifyDetail(bstat.verify) },
  ]
    .filter((b) => isObj(b.section) && b.section.enabled !== false)
    .map((b) => ({
      kind: b.kind,
      label: JOB_LABELS[b.kind],
      last_success: b.section.last_success ?? null,
      last_success_ago: b.section.last_success ? formatHours(hoursBetween(b.section.last_success, now)) : null,
      last_error: b.section.last_error ?? null,
      runs: runs[b.kind] ?? { ok: 0, failed: 0 },
      detail: b.detail,
      status: checks.find((c) => c.name === ({ logical: 'backup_logical', physical: 'backup_physical', upload: 'backup_upload', objects: 'backup_objects', verify: 'backup_verify' })[b.kind])?.status ?? 'ok',
    }));

  const dropbox = isObj(host.dropbox) ? host.dropbox : null;
  if (dropbox && n(dropbox.total) > 0) {
    const freePct = pct(dropbox.free, dropbox.total);
    if (freePct !== null && freePct < cfg.dropbox_warn_free_pct) issue('warn', 'Backups', `Dropbox has ${formatBytes(dropbox.free)} free (${freePct}%).`);
  }

  // -- object store
  const store = isObj(bstat.objects) ? bstat.objects : null;
  const buckets = store && isObj(store.buckets)
    ? Object.entries(store.buckets).map(([name, b]) => {
        const before = prev?.buckets?.[name];
        return {
          name,
          objects: n(b.objects),
          bytes: n(b.bytes),
          objects_delta: before ? (n(b.objects) ?? 0) - (n(before.objects) ?? 0) : null,
          bytes_delta: before ? (n(b.bytes) ?? 0) - (n(before.bytes) ?? 0) : null,
        };
      })
    : [];

  // -- certificate
  const tls = status.tls ?? {};
  if (n(tls.days_left) !== null && tls.days_left <= 21 && !checks.some((c) => c.name === 'tls_cert' && c.status !== 'ok')) {
    issue('info', 'TLS', `The certificate renews automatically; ${Math.floor(tls.days_left)} days left.`);
  }

  // -- security
  const ssh = isObj(host.ssh) ? host.ssh : null;
  const jails = Array.isArray(host.fail2ban) ? host.fail2ban : [];

  issues.sort((a, b) => SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]);
  const overall = worstStatus([status.status === 'fail' ? 'fail' : status.status === 'warn' ? 'warn' : 'ok', ...issues.filter((i) => i.severity !== 'info').map((i) => i.severity)]);
  const counts = { fail: issues.filter((i) => i.severity === 'fail').length, warn: issues.filter((i) => i.severity === 'warn').length, info: issues.filter((i) => i.severity === 'info').length };

  const server = input.server ?? {};
  const name = server.hostname ?? 'server';
  const day = formatWhen(now, cfg.timezone, { time: false });
  const headline =
    overall === 'ok'
      ? 'All healthy'
      : [counts.fail && `${counts.fail} problem${counts.fail === 1 ? '' : 's'}`, counts.warn && `${counts.warn} warning${counts.warn === 1 ? '' : 's'}`].filter(Boolean).join(', ');
  const subject = `${overall === 'ok' ? '✅' : overall === 'warn' ? '⚠️' : '❌'} ${name}: ${headline} — ${day}`;

  const firstIssue = issues.find((i) => i.severity !== 'info');
  const preheader = firstIssue
    ? `${firstIssue.area}: ${firstIssue.text}`.slice(0, 140)
    : `Disk ${filesystems[0] ? `${filesystems[0].used_pct}% used` : 'n/a'} · databases ${formatBytes(totalDbSize)} · backups ok · ${formatCount(statementTotals.calls) ?? 0} queries`;

  const model = {
    overall,
    headline,
    counts,
    server: {
      hostname: name,
      fqdn: server.fqdn ?? null,
      os: host.os ?? null,
      kernel: host.kernel ?? null,
      uptime: formatDuration(n(host.uptime_seconds)),
      cpus,
      load: n(load.load1) !== null ? [load.load1, load.load5, load.load15] : null,
      memory: { total: n(mem.total_bytes), used: memUsed, used_pct: pct(memUsed, mem.total_bytes) },
      swap: { total: n(mem.swap_total_bytes), used: swapUsed },
      filesystems,
      usage: isObj(host.usage) ? host.usage : {},
      usage_delta: usageDelta(host.usage, prev?.usage),
      updates,
      reboot_required: Boolean(host.reboot_required),
      reboot_scheduled: host.reboot_scheduled ? formatWhen(host.reboot_scheduled, cfg.timezone) : null,
      containers,
      ssh,
      fail2ban: jails,
      tls: n(tls.days_left) !== null ? { days_left: Math.floor(tls.days_left), valid_to: tls.valid_to ?? null, subject: tls.subject ?? null } : null,
    },
    postgres: {
      version: status.server?.version ? String(status.server.version).split(' ')[0] : null,
      uptime: formatDuration(n(status.server?.uptime_seconds)),
      connections: { total: n(status.connections?.total), max: n(status.connections?.max_connections), pct: n(status.connections?.utilisation_pct) },
      databases: dbs,
      database_count: dbs.length,
      total_size: totalDbSize,
      wal: { bytes: walBytes, archived, archive_failed: archiveFailed },
      statements: {
        available: sql.statements?.available !== false && stmtRows.length > 0,
        since_reset: Boolean(sinceReset),
        stats_reset: sql.statements?.stats_reset ?? null,
        totals: statementTotals,
        top_total: appStatements.sort(byTotal).slice(0, 5),
        slow,
        slow_threshold_ms: cfg.slow_mean_ms,
      },
      errors: { counts: pgErrors, groups: errorGroups.slice(0, 8), more: Math.max(0, errorGroups.length - 8) },
      slow_logged: slowLogged,
      tables: [...tables].sort((a, b) => (b.size ?? 0) - (a.size ?? 0)).slice(0, 8),
      pgbouncer: { version: bouncer.version ?? null, stats: bouncerStats, max_wait_s: maxWaitSeconds, clients: n(bouncer.lists?.used_clients), errors: bouncerLog.slice(0, 5), error_count: bouncerErrors },
    },
    backups: { rows: backupRows, dropbox, local: { dumps: n(host.usage?.backups_dumps), pgbackrest: n(host.usage?.backups_pgbackrest) } },
    objects: store
      ? {
          bytes: n(store.bytes),
          objects: n(store.objects),
          capacity: n(store.capacity_bytes),
          used_pct: pct(n(store.bytes), n(store.capacity_bytes)),
          bytes_delta: prev?.objects ? (n(store.bytes) ?? 0) - (n(prev.objects.bytes) ?? 0) : null,
          on_disk: n(host.usage?.objects_data),
          measured: store.measured ?? null,
          buckets,
          healthy: checks.find((c) => c.name === 'objects')?.status ?? null,
        }
      : null,
    checks: checks.map((c) => ({ name: c.name, label: checkLabel(c.name), status: c.status, message: c.message })),
    issues,
    period_hours: periodHours,
    generated_at: now.toISOString(),
    generated_local: formatWhen(now, cfg.timezone),
    previous_local: prev?.at ? formatWhen(prev.at, cfg.timezone) : null,
    timezone: cfg.timezone,
  };

  const snapshot = {
    at: now.toISOString(),
    databases: Object.fromEntries((Array.isArray(status.databases) ? status.databases : []).map((d) => [d.name, { size: n(d.size_bytes), commits: n(d.xact_commit), rollbacks: n(d.xact_rollback), deadlocks: n(d.deadlocks), temp_bytes: n(d.temp_bytes) }])),
    statements_reset: sql.statements?.stats_reset ?? null,
    statements: Object.fromEntries(stmtRows.map((r) => [`${r.dbname}|${r.user}|${r.queryid}`, { calls: n(r.calls), total_ms: n(r.total_ms) }])),
    wal_bytes: n(wal.stats?.wal_bytes),
    archived_count: n(wal.archiver?.archived_count),
    archive_failed_count: n(wal.archiver?.failed_count),
    pgbouncer: Object.fromEntries((Array.isArray(bouncer.stats) ? bouncer.stats : []).map((s) => [s.database, { xacts: n(s.total_xact_count), xact_us: n(s.total_xact_time), wait_us: n(s.total_wait_time), sent: n(s.total_sent) }])),
    tables: Object.fromEntries((Array.isArray(sql.tables) ? sql.tables : []).map((t) => [`${t.db}.${t.schema}.${t.name}`, n(t.total_bytes)])),
    objects: store ? { bytes: n(store.bytes), objects: n(store.objects) } : null,
    buckets: store && isObj(store.buckets) ? Object.fromEntries(Object.entries(store.buckets).map(([k, b]) => [k, { bytes: n(b.bytes), objects: n(b.objects) }])) : {},
    usage: isObj(host.usage) ? host.usage : {},
    containers: Object.fromEntries(containers.map((c) => [c.name, n(c.restarts)])),
  };

  return { status: overall, subject, preheader, issues, model, snapshot };
}

function usageDelta(now, before) {
  if (!isObj(now) || !isObj(before)) return {};
  return Object.fromEntries(Object.keys(now).map((k) => [k, n(now[k]) !== null && n(before[k]) !== null ? now[k] - before[k] : null]));
}

function dumpDetail(logical) {
  if (!isObj(logical?.databases)) return null;
  const parts = Object.entries(logical.databases).map(([db, d]) => `${db} ${formatBytes(n(d.bytes)) ?? '?'}${d.verified === false ? ' (unverified)' : ''}`);
  return parts.length ? `${parts.join(', ')}${logical.encrypted ? ', encrypted' : ''}` : null;
}

function physicalDetail(p) {
  if (!isObj(p)) return null;
  const bits = [];
  if (p.last_type) bits.push(`last ${p.last_type}`);
  if (n(p.backups) !== null) bits.push(`${p.backups} kept`);
  if (n(p.repo_bytes) !== null) bits.push(`repository ${formatBytes(p.repo_bytes)}`);
  return bits.join(', ') || null;
}

function verifyDetail(v) {
  if (!isObj(v)) return null;
  const dbs = isObj(v.databases) ? Object.entries(v.databases).map(([db, d]) => `${db} ${d.ok === false ? 'failed' : `ok${d.tables ? ` (${d.tables} tables)` : ''}`}`) : [];
  const objs = isObj(v.objects) ? Object.values(v.objects).filter((o) => n(o.restored)).reduce((s, o) => s + o.restored, 0) : 0;
  return [...dbs, objs ? `${objs} objects restored` : null].filter(Boolean).join(', ') || null;
}

// ---------------------------------------------------------------- plain text

const MARK = { ok: 'OK', warn: 'WARN', fail: 'FAIL', info: 'NOTE' };

/** The plain-text part: the same content, readable in any client and in a terminal. */
export function digestText({ model, subject }) {
  const m = model;
  const L = [];
  const line = (s = '') => L.push(s);
  const kv = (k, v) => v !== null && v !== undefined && v !== '' && line(`  ${k.padEnd(22)} ${v}`);
  line(subject.replace(/^\S+\s/, ''));
  line(`${m.generated_local}${m.previous_local ? ` · since ${m.previous_local}` : ''}`);
  line();
  line(m.issues.length ? 'NEEDS ATTENTION' : 'NOTHING NEEDS ATTENTION');
  for (const i of m.issues) line(`  [${MARK[i.severity]}] ${i.area}: ${i.text}`);
  line();
  line('SERVER');
  kv('Uptime', m.server.uptime);
  kv('Load (1/5/15 min)', m.server.load ? `${m.server.load.join(' / ')} on ${m.server.cpus} cores` : null);
  kv('Memory', m.server.memory.total ? `${formatBytes(m.server.memory.used)} of ${formatBytes(m.server.memory.total)} (${m.server.memory.used_pct}%)` : null);
  for (const f of m.server.filesystems) kv(`Disk ${f.mount}`, `${formatBytes(f.used)} used, ${formatBytes(f.free)} free of ${formatBytes(f.size)} (${f.used_pct}%)`);
  for (const [k, v] of Object.entries(USAGE_LABELS)) kv(v, m.server.usage[k] !== undefined ? withDelta(formatBytes(m.server.usage[k]), m.server.usage_delta[k]) : null);
  kv('Updates waiting', m.server.updates ? `${m.server.updates.total} (${m.server.updates.security} security)` : null);
  kv('Reboot pending', m.server.reboot_required ? `yes${m.server.reboot_scheduled ? `, booked for ${m.server.reboot_scheduled}` : ''}` : 'no');
  kv('TLS certificate', m.server.tls ? `${m.server.tls.days_left} days left` : null);
  kv('SSH', m.server.ssh ? `${formatCount(m.server.ssh.failed)} failed logins, ${formatCount(m.server.ssh.accepted)} accepted` : null);
  for (const j of m.server.fail2ban) kv(`fail2ban ${j.jail}`, `${formatCount(j.attempts ?? 0)} attempts seen, ${j.banned_period} banned (${j.banned_now} now)`);
  for (const c of m.server.containers) kv(c.name, `${c.state}${c.health ? `, ${c.health}` : ''}${c.restart_delta ? `, restarted ${c.restart_delta}×` : ''}`);
  line();
  line('POSTGRESQL');
  kv('Version, uptime', `${m.postgres.version ?? '?'}, up ${m.postgres.uptime ?? '?'}`);
  kv('Connections', m.postgres.connections.total !== null ? `${m.postgres.connections.total} of ${m.postgres.connections.max}` : null);
  kv('Databases', `${m.postgres.database_count}, ${formatBytes(m.postgres.total_size)} in all`);
  for (const d of m.postgres.databases) {
    kv(`  ${d.name}`, [withDelta(formatBytes(d.size), d.size_delta), d.commits !== null && `${formatCount(d.commits)} commits`, d.rollbacks && `${formatCount(d.rollbacks)} rollbacks`, d.cache_hit_pct !== null && `cache ${d.cache_hit_pct}%`].filter(Boolean).join(', '));
  }
  kv('WAL written', m.postgres.wal.bytes !== null ? `${formatBytes(m.postgres.wal.bytes)}, ${formatCount(m.postgres.wal.archived)} segments archived` : null);
  kv('Queries (apps)', `${formatCount(m.postgres.statements.totals.calls)} calls, ${formatMs(m.postgres.statements.totals.total_ms)} in all`);
  kv('Bulk copies', m.postgres.statements.totals.bulk_calls ? `${formatCount(m.postgres.statements.totals.bulk_calls)} (dumps, imports), ${formatMs(m.postgres.statements.totals.bulk_ms)}` : null);
  kv('Errors in the log', `${formatCount(m.postgres.errors.counts.error)} error, ${formatCount(m.postgres.errors.counts.fatal)} fatal, ${formatCount(m.postgres.errors.counts.panic)} panic`);
  if (m.postgres.statements.top_total.length) {
    line('  Most time spent (apps):');
    for (const s of m.postgres.statements.top_total) line(`    ${formatMs(s.total_ms).padStart(9)}  ${formatCount(s.calls).padStart(7)}×  ${formatMs(s.mean_ms).padStart(8)} avg  ${s.database}: ${s.query}`);
  }
  if (m.postgres.errors.groups.length) {
    line('  Log errors:');
    for (const e of m.postgres.errors.groups) line(`    ${formatCount(e.count).padStart(6)}×  ${e.severity}  ${e.who ? `${e.who}  ` : ''}${e.message}`);
  }
  if (m.postgres.tables.length) {
    line('  Largest tables:');
    for (const t of m.postgres.tables) line(`    ${(formatBytes(t.size) ?? '?').padStart(9)}  ${t.database}.${t.name}${t.size_delta ? ` (${formatDeltaBytes(t.size_delta)})` : ''}`);
  }
  line();
  line('BACKUPS');
  for (const b of m.backups.rows) {
    kv(b.label, `${MARK[b.status]} · last ok ${b.last_success_ago ?? 'never'} ago${b.runs.ok + b.runs.failed ? ` · runs ${b.runs.ok} ok, ${b.runs.failed} failed` : ''}${b.detail ? ` · ${b.detail}` : ''}`);
  }
  kv('Dropbox', m.backups.dropbox ? `${formatBytes(m.backups.dropbox.used)} used, ${formatBytes(m.backups.dropbox.free)} free of ${formatBytes(m.backups.dropbox.total)}` : null);
  if (m.objects) {
    line();
    line('OBJECT STORAGE');
    kv('Stored', `${formatBytes(m.objects.bytes)} in ${formatCount(m.objects.objects)} objects (${m.objects.used_pct}% of ${formatBytes(m.objects.capacity)})${m.objects.bytes_delta ? `, ${formatDeltaBytes(m.objects.bytes_delta)}` : ''}`);
    for (const b of m.objects.buckets) kv(`  ${b.name}`, `${formatBytes(b.bytes)}, ${formatCount(b.objects)} objects${b.objects_delta ? ` (${b.objects_delta > 0 ? '+' : ''}${b.objects_delta})` : ''}`);
  }
  line();
  line('ALL CHECKS');
  for (const c of m.checks) line(`  [${MARK[c.status]}] ${c.label}: ${c.message}`);
  return `${L.join('\n')}\n`;
}

export const USAGE_LABELS = {
  postgres_data: 'Postgres data',
  backups_dumps: 'Dumps (local)',
  backups_pgbackrest: 'pgBackRest (local)',
  objects_data: 'Object store data',
  docker: 'Docker images',
};

export function withDelta(value, delta) {
  if (value === null || value === undefined) return null;
  return delta ? `${value} (${formatDeltaBytes(delta)})` : value;
}

