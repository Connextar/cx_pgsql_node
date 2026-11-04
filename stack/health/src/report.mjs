// Pure evaluation: raw probe results in, checks and the /status report out. No I/O here,
// so every rule can be tested with plain objects.
import { num, round } from './util.mjs';

export const RANK = Object.freeze({ ok: 0, warn: 1, fail: 2 });

export const XID_WARN_AGE = 1_200_000_000;
export const XID_FAIL_AGE = 1_600_000_000;
// Databases with fewer block reads+hits than this are too quiet for a meaningful cache-hit ratio.
export const CACHE_HIT_MIN_BLOCKS = 10_000;

const HOUR_MS = 3_600_000;

export function worstStatus(statuses) {
  let worst = 'ok';
  for (const s of statuses) {
    const status = RANK[s] === undefined ? 'fail' : s; // anything unrecognised counts as a failure
    if (RANK[status] > RANK[worst]) worst = status;
  }
  return worst;
}

export function overallStatus(checks) {
  return worstStatus(checks.map((c) => c.status));
}

/** ok below warnAt, warn from warnAt, fail from failAt (both inclusive). */
export function thresholdStatus(value, warnAt, failAt) {
  if (value === null || value === undefined || !Number.isFinite(value)) return null;
  if (value >= failAt) return 'fail';
  if (value >= warnAt) return 'warn';
  return 'ok';
}

export function makeCheck(name, status, message, value) {
  return value === null || value === undefined ? { name, status, message } : { name, status, message, value };
}

/** The public /healthz body: names and states only — no messages, numbers or report sections. */
export function healthzView(report) {
  const checks = {};
  for (const c of report.checks) checks[String(c.name)] = RANK[c.status] === undefined ? 'fail' : c.status;
  return { status: RANK[report.status] === undefined ? 'fail' : report.status, time: report.time, checks };
}

// ---------------------------------------------------------------- formatting

export function parseTime(value) {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value !== 'string' || value === '') return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

function hoursSince(date, now) {
  return date ? Math.max(0, (now.getTime() - date.getTime()) / HOUR_MS) : null;
}

export function formatHours(hours) {
  if (hours < 1) return `${Math.round(hours * 60)} min`;
  if (hours < 48) return `${round(hours, 1)} h`;
  return `${round(hours / 24, 1)} days`;
}

export function formatSeconds(seconds) {
  if (seconds < 120) return `${Math.round(seconds)}s`;
  if (seconds < 7200) return `${round(seconds / 60, 1)} min`;
  return formatHours(seconds / 3600);
}

function errorText(error) {
  const text = typeof error === 'string' ? error : JSON.stringify(error);
  const flat = String(text).replace(/\s+/g, ' ').trim();
  return flat.length > 300 ? `${flat.slice(0, 299)}…` : flat;
}

// ---------------------------------------------------------------- backups

function hasError(error) {
  return error !== null && error !== undefined && error !== '' && error !== false;
}

/**
 * One section of the backup status file. Fail when the latest attempt errored after the latest
 * success, when there was never a success despite attempts, or when the last success is too old.
 */
export function evaluateBackupSection(name, label, section, maxAgeHours, now) {
  if (!section || typeof section !== 'object' || Array.isArray(section)) {
    return makeCheck(name, 'warn', `no ${label} recorded in the backup status file`);
  }
  const attempt = parseTime(section.last_attempt);
  const success = parseTime(section.last_success);
  const ageHours = hoursSince(success, now);
  const value = ageHours === null ? undefined : round(ageHours, 2);

  if (hasError(section.last_error) && (attempt ? !success || attempt > success : !success)) {
    const when = attempt ? ` at ${attempt.toISOString()}` : '';
    return makeCheck(name, 'fail', `${label} failed${when}: ${errorText(section.last_error)}`, value);
  }
  if (!success) {
    return attempt
      ? makeCheck(name, 'fail', `${label} has no recorded success (last attempt ${attempt.toISOString()})`)
      : makeCheck(name, 'warn', `no successful ${label} recorded yet`);
  }
  if (ageHours > maxAgeHours) {
    return makeCheck(name, 'fail', `last successful ${label} was ${formatHours(ageHours)} ago (limit ${maxAgeHours} h)`, value);
  }
  return makeCheck(name, 'ok', `last successful ${label} ${formatHours(ageHours)} ago`, value);
}

function sectionAges(section, now, extra = []) {
  if (!section || typeof section !== 'object') return null;
  // Four decimals (about a third of a second) so the metrics can turn these back into seconds.
  const ages = {
    last_success_hours: round(hoursSince(parseTime(section.last_success), now), 4),
    last_attempt_hours: round(hoursSince(parseTime(section.last_attempt), now), 4),
  };
  for (const key of extra) ages[`${key}_hours`] = round(hoursSince(parseTime(section[key]), now), 4);
  return ages;
}

function databasesWhere(databases, predicate) {
  if (!databases || typeof databases !== 'object' || Array.isArray(databases)) return [];
  return Object.entries(databases)
    .filter(([, info]) => info && typeof info === 'object' && predicate(info))
    .map(([db]) => db);
}

/**
 * @param file { path, present, data?, error? } from readBackupStatus
 * @returns { checks, section }
 */
export function evaluateBackups(file, thresholds, now) {
  const t = thresholds;
  const section = { file: file.path ?? null, present: Boolean(file.present) };
  if (file.error) section.error = file.error;

  if (!file.data) {
    const why = `not evaluated: backup status file ${file.error ?? 'missing'}`;
    return {
      section,
      checks: [
        makeCheck('backup_logical', 'warn', why),
        makeCheck('backup_physical', 'warn', why),
        makeCheck('backup_verify', 'warn', why),
        makeCheck('status_file', 'warn', `backup status file ${file.error ?? 'missing'}${file.path ? ` (${file.path})` : ''}`),
      ],
    };
  }

  const data = file.data;
  const checks = [];

  let logical = evaluateBackupSection('backup_logical', 'logical backup', data.logical, t.backupMaxAgeHours, now);
  if (logical.status !== 'fail') {
    const unverified = databasesWhere(data.logical?.databases, (d) => d.verified === false);
    if (unverified.length) logical = makeCheck('backup_logical', 'fail', `logical dump not verified for: ${unverified.join(', ')}`, logical.value);
  }
  checks.push(logical);

  if (data.physical && typeof data.physical === 'object' && data.physical.enabled === false) {
    checks.push(makeCheck('backup_physical', 'ok', 'pgBackRest backups are disabled in the status file'));
  } else {
    checks.push(evaluateBackupSection('backup_physical', 'pgBackRest backup', data.physical, t.backupMaxAgeHours, now));
  }

  if (data.upload && typeof data.upload === 'object' && data.upload.enabled === true) {
    const dest = typeof data.upload.destination === 'string' ? ` to ${data.upload.destination}` : '';
    checks.push(evaluateBackupSection('backup_upload', `off-site upload${dest}`, data.upload, t.uploadMaxAgeHours, now));
  }

  let verify = evaluateBackupSection('backup_verify', 'restore verification', data.verify, t.verifyMaxAgeHours, now);
  if (verify.status !== 'fail') {
    const bad = [
      ...databasesWhere(data.verify?.databases, (d) => d.ok === false),
      ...databasesWhere(data.verify?.objects, (d) => d.ok === false).map((b) => (b === 'deleted/' ? 'deleted objects' : `bucket ${b}`)),
    ];
    if (bad.length) verify = makeCheck('backup_verify', 'fail', `restore verification failed for: ${bad.join(', ')}`, verify.value);
  }
  checks.push(verify);

  // The nightly report email (lib/report.sh). A missed email is worth knowing about, never a 503: warn at most.
  if (data.report && typeof data.report === 'object' && data.report.enabled === true) {
    const report = evaluateBackupSection('report_email', 'nightly report email', data.report, t.reportMaxAgeHours ?? 50, now);
    checks.push(report.status === 'fail' ? makeCheck('report_email', 'warn', report.message, report.value) : report);
  }

  const updated = parseTime(data.updated);
  const updatedHours = hoursSince(updated, now);
  checks.push(
    updated
      ? makeCheck('status_file', 'ok', `backup status file updated ${formatHours(updatedHours)} ago`, round(updatedHours, 2))
      : makeCheck('status_file', 'ok', 'backup status file parsed (no "updated" timestamp)'),
  );

  section.status = data;
  section.ages = {
    updated_hours: round(updatedHours, 4),
    logical: sectionAges(data.logical, now),
    physical: sectionAges(data.physical, now, ['last_full']),
    upload: sectionAges(data.upload, now),
    verify: sectionAges(data.verify, now),
    objects: sectionAges(data.objects_backup, now),
    report: sectionAges(data.report, now),
  };
  return { checks, section };
}

// ---------------------------------------------------------------- object store

/**
 * The object store: is Garage healthy, how full is it, and is its off-site copy recent.
 * @param probe      { url, http_status?, response_ms?, error? } from probeObjects
 * @param statusData the parsed backup status file (or undefined): `objects` (sizes, written by every
 *                   objects backup run) and `objects_backup` (the off-site copy)
 */
export function evaluateObjects(probe, statusData, t, now) {
  const checks = [];
  if (probe.error) {
    checks.push(makeCheck('objects', 'fail', `cannot reach the object store at ${probe.url}: ${errorText(probe.error)}`));
  } else if (probe.http_status === 200) {
    checks.push(makeCheck('objects', 'ok', `object store healthy, answered in ${probe.response_ms} ms`, probe.response_ms));
  } else {
    checks.push(makeCheck('objects', 'fail', `object store reports unhealthy (HTTP ${probe.http_status})`));
  }

  const store = statusData?.objects;
  const capacity = num(store?.capacity_bytes);
  const bytes = num(store?.bytes);
  if (!store || typeof store !== 'object' || capacity === null || bytes === null || capacity <= 0) {
    checks.push(makeCheck('objects_capacity', 'warn', 'no measurement of the object store yet (cx-pgsql backup objects writes one)'));
  } else {
    const pct = (bytes / capacity) * 100;
    const status = thresholdStatus(pct, t.warnObjectsCapacityPct, t.failObjectsCapacityPct);
    const measured = parseTime(store.measured);
    const when = measured ? `, measured ${formatHours(hoursSince(measured, now))} ago` : '';
    const advice = status === 'ok' ? '' : ' — time to add disk or move the buckets (docs/ObjectStorage.md)';
    checks.push(makeCheck('objects_capacity', status, `object store ${round(pct, 1)}% of its capacity (${num(store.objects) ?? '?'} objects)${when}${advice}`, round(pct, 2)));
  }

  const copy = statusData?.objects_backup;
  if (copy && typeof copy === 'object' && copy.enabled === false) {
    checks.push(makeCheck('backup_objects', 'warn', 'objects have no off-site copy (BACKUP_UPLOAD is off)'));
  } else if (statusData) {
    const dest = typeof copy?.destination === 'string' ? ` to ${copy.destination}` : '';
    checks.push(evaluateBackupSection('backup_objects', `off-site object copy${dest}`, copy, t.objectsBackupMaxAgeHours, now));
  }
  return {
    checks,
    section: {
      enabled: true,
      url: probe.url,
      ...(probe.error ? { error: probe.error } : { http_status: probe.http_status, response_ms: probe.response_ms }),
      store: store ?? null,
      used_pct: capacity && bytes !== null ? round((bytes / capacity) * 100, 2) : null,
    },
  };
}

// ---------------------------------------------------------------- PostgreSQL rules

export function evaluateConnections(total, maxConnections, t) {
  if (!maxConnections) return makeCheck('connections', 'fail', 'max_connections unknown');
  const pct = (total / maxConnections) * 100;
  const status = thresholdStatus(pct, t.warnConnPct, t.failConnPct);
  const limits = status === 'ok' ? '' : ` (warn ${t.warnConnPct}%, fail ${t.failConnPct}%)`;
  return makeCheck('connections', status, `${total} of ${maxConnections} connections in use (${round(pct, 1)}%)${limits}`, round(pct, 1));
}

export function evaluateDisk(disk, t) {
  if (!disk || disk.used_pct === null || disk.used_pct === undefined) return makeCheck('disk', 'fail', 'data directory usage unknown');
  const status = thresholdStatus(disk.used_pct, t.warnDiskPct, t.failDiskPct);
  const freeGiB = round(disk.free_bytes / 1024 ** 3, 1);
  const limits = status === 'ok' ? '' : ` (warn ${t.warnDiskPct}%, fail ${t.failDiskPct}%)`;
  return makeCheck('disk', status, `data directory ${round(disk.used_pct, 1)}% used, ${freeGiB} GiB free${limits}`, round(disk.used_pct, 1));
}

export function evaluateLongQueries(rows, t) {
  const count = rows.length ? (num(rows[0].total) ?? rows.length) : 0;
  if (!count) return makeCheck('long_queries', 'ok', `no queries or transactions running longer than ${t.longQuerySeconds}s`, 0);
  const top = rows[0];
  const what = top.duration_basis === 'transaction' ? 'transaction open' : 'query running';
  return makeCheck(
    'long_queries',
    'warn',
    `${count} session(s) over ${t.longQuerySeconds}s; longest: ${what} ${formatSeconds(top.duration_seconds)} (pid ${top.pid}, database ${top.datname ?? '?'}, ${top.state})`,
    count,
  );
}

export function evaluateBlocked(rows, t) {
  const over = rows.filter((r) => Number(r.blocked_seconds) > t.warnBlockedSeconds);
  if (!over.length) {
    const note = rows.length ? `${rows.length} briefly waiting on locks, none longer than ${t.warnBlockedSeconds}s` : 'no sessions blocked on locks';
    return makeCheck('blocked', 'ok', note, 0);
  }
  const top = over[0];
  return makeCheck(
    'blocked',
    'warn',
    `${over.length} session(s) blocked longer than ${t.warnBlockedSeconds}s; longest ${formatSeconds(top.blocked_seconds)} (pid ${top.pid} blocked by ${(top.blocked_by ?? []).join(', ') || '?'})`,
    over.length,
  );
}

/**
 * WAL archiving. Fails when the most recent archive attempt failed after the most recent success
 * (failed_count rising is reported alongside), or — with archive_mode on and WAL waiting to be
 * archived — when the oldest waiting segment has been waiting longer than the limit. With nothing
 * waiting there has been no WAL activity to archive, so the age of the last archive is not judged.
 */
export function evaluateWalArchive({ archiveMode, archiver, pending, pendingError }, t, previousFailedCount) {
  if (!archiveMode || archiveMode === 'off') {
    return makeCheck('wal_archive', 'ok', 'archive_mode is off; WAL archiving not judged');
  }
  if (!archiver) return makeCheck('wal_archive', 'fail', 'pg_stat_archiver unavailable');

  const failedCount = num(archiver.failed_count) ?? 0;
  const lastArchived = parseTime(archiver.last_archived_time);
  const lastFailed = parseTime(archiver.last_failed_time);
  const rose = previousFailedCount !== null && previousFailedCount !== undefined && failedCount > previousFailedCount;
  const limitSeconds = t.walArchiveMaxAgeMinutes * 60;

  if (lastFailed && (!lastArchived || lastFailed > lastArchived)) {
    const trend = rose ? `, ${failedCount - previousFailedCount} new since the previous check` : '';
    return makeCheck(
      'wal_archive',
      'fail',
      `archiving is failing: last failure ${lastFailed.toISOString()} (${archiver.last_failed_wal ?? '?'}) is newer than the last success ${lastArchived ? lastArchived.toISOString() : '(none)'}; ${failedCount} failures since stats reset${trend}`,
      failedCount,
    );
  }

  const lastAge = num(archiver.last_archived_age_seconds);
  const lastText = lastAge === null ? 'nothing archived since stats reset' : `last archived ${formatSeconds(lastAge)} ago`;

  if (!pending) {
    // Without archive_status visibility, fall back to the age of the last archive (cannot tell idle from stuck).
    if (lastAge !== null && lastAge > limitSeconds) {
      return makeCheck('wal_archive', 'warn', `${lastText}; cannot see pending WAL (${pendingError ?? 'unknown'}), so idle and stuck look the same`, round(lastAge / 60, 1));
    }
    return makeCheck('wal_archive', 'ok', `${lastText}; pending WAL not visible (${pendingError ?? 'unknown'})`, lastAge === null ? undefined : round(lastAge / 60, 1));
  }

  const ready = num(pending.ready) ?? 0;
  if (ready === 0) return makeCheck('wal_archive', 'ok', `no WAL waiting to be archived; ${lastText}`, 0);

  const oldest = num(pending.oldest_ready_age_seconds) ?? 0;
  if (oldest > limitSeconds) {
    return makeCheck(
      'wal_archive',
      'fail',
      `${ready} WAL segment(s) waiting; the oldest for ${formatSeconds(oldest)} (limit ${t.walArchiveMaxAgeMinutes} min); ${lastText}`,
      round(oldest / 60, 1),
    );
  }
  return makeCheck('wal_archive', 'ok', `${ready} WAL segment(s) waiting, oldest ${formatSeconds(oldest)}; ${lastText}`, round(oldest / 60, 1));
}

export function cacheHitPct(db) {
  const hit = num(db.blks_hit) ?? 0;
  const read = num(db.blks_read) ?? 0;
  return hit + read > 0 ? (hit / (hit + read)) * 100 : null;
}

/** Warn only: lists databases with enough traffic whose cache-hit ratio is under the minimum. */
export function evaluateCacheHit(databases, t) {
  const judged = databases.filter((d) => !d.is_template && (num(d.blks_hit) ?? 0) + (num(d.blks_read) ?? 0) >= CACHE_HIT_MIN_BLOCKS);
  if (!judged.length) return makeCheck('cache_hit', 'ok', 'not enough block traffic yet to judge the cache-hit ratio');
  const withPct = judged.map((d) => ({ name: d.datname, pct: cacheHitPct(d) })).sort((a, b) => a.pct - b.pct);
  const low = withPct.filter((d) => d.pct < t.minCacheHitPct);
  const lowest = withPct[0];
  if (low.length) {
    return makeCheck(
      'cache_hit',
      'warn',
      `cache-hit ratio below ${t.minCacheHitPct}%: ${low.map((d) => `${d.name} ${round(d.pct, 1)}%`).join(', ')}`,
      round(lowest.pct, 2),
    );
  }
  return makeCheck('cache_hit', 'ok', `lowest cache-hit ratio ${round(lowest.pct, 2)}% (${lowest.name})`, round(lowest.pct, 2));
}

export function evaluateXid(databases) {
  if (!databases.length) return makeCheck('xid_wraparound', 'fail', 'no databases visible');
  const oldest = databases.reduce((a, b) => ((num(b.frozen_xid_age) ?? 0) > (num(a.frozen_xid_age) ?? 0) ? b : a));
  const age = num(oldest.frozen_xid_age) ?? 0;
  const status = age > XID_FAIL_AGE ? 'fail' : age > XID_WARN_AGE ? 'warn' : 'ok';
  const pctOfLimit = round((age / 2 ** 31) * 100, 1);
  return makeCheck('xid_wraparound', status, `oldest datfrozenxid age ${age.toLocaleString('en-GB')} (${oldest.datname}, ${pctOfLimit}% of the wraparound limit)`, age);
}

export function evaluateCert(cert, t, now) {
  if (!cert || cert.error) return makeCheck('tls_cert', 'fail', `certificate ${cert?.error ?? 'unavailable'}${cert?.file ? ` (${cert.file})` : ''}`);
  const validTo = parseTime(cert.valid_to);
  const validFrom = parseTime(cert.valid_from);
  if (!validTo) return makeCheck('tls_cert', 'fail', 'certificate has no readable expiry date');
  const daysLeft = (validTo.getTime() - now.getTime()) / 86_400_000;
  const value = round(daysLeft, 1);
  if (validFrom && validFrom > now) return makeCheck('tls_cert', 'fail', `certificate not valid until ${validFrom.toISOString()}`, value);
  if (daysLeft <= 0) return makeCheck('tls_cert', 'fail', `certificate expired ${validTo.toISOString()}`, value);
  const status = daysLeft <= t.certFailDays ? 'fail' : daysLeft <= t.certWarnDays ? 'warn' : 'ok';
  return makeCheck('tls_cert', status, `certificate for ${cert.subject} expires in ${round(daysLeft, 1)} days (${validTo.toISOString()})`, value);
}

export function pgbouncerCheck(bouncer) {
  const { probe, admin } = bouncer;
  if (!probe.ok) return makeCheck('pgbouncer_connect', 'fail', `SELECT 1 through PgBouncer to ${probe.database} failed: ${probe.error}`);
  if (!admin.ok) return makeCheck('pgbouncer_connect', 'warn', `SELECT 1 through PgBouncer ok in ${probe.ms} ms, but the admin console failed: ${admin.error}`, probe.ms);
  const waiting = (admin.pools ?? []).reduce((sum, p) => sum + (num(p.cl_waiting) ?? 0), 0);
  const note = waiting ? `; ${waiting} client(s) waiting for a server connection` : '';
  return makeCheck('pgbouncer_connect', 'ok', `SELECT 1 through PgBouncer to ${probe.database} in ${probe.ms} ms${note}`, probe.ms);
}

// ---------------------------------------------------------------- assembly

function settingValue(settings, name) {
  return settings?.[name]?.value ?? null;
}

function buildConnections(rows, maxConnections) {
  const byState = {};
  const byDbUser = new Map();
  let total = 0;
  let oldestXact = null;
  let longestActive = null;
  for (const r of rows) {
    total += r.count;
    byState[r.state] = (byState[r.state] ?? 0) + r.count;
    const key = `${r.datname}\u0000${r.usename}`;
    const entry = byDbUser.get(key) ?? { database: r.datname, user: r.usename, count: 0, states: {} };
    entry.count += r.count;
    entry.states[r.state] = (entry.states[r.state] ?? 0) + r.count;
    byDbUser.set(key, entry);
    if (r.oldest_xact_seconds !== null && (oldestXact === null || r.oldest_xact_seconds > oldestXact)) oldestXact = r.oldest_xact_seconds;
    if (r.longest_active_seconds !== null && (longestActive === null || r.longest_active_seconds > longestActive)) longestActive = r.longest_active_seconds;
  }
  return {
    total,
    max_connections: maxConnections,
    utilisation_pct: maxConnections ? round((total / maxConnections) * 100, 2) : null,
    by_state: byState,
    by_database_user: [...byDbUser.values()].sort((a, b) => b.count - a.count),
    oldest_transaction_seconds: round(oldestXact, 1),
    longest_active_query_seconds: round(longestActive, 1),
  };
}

const PG_DEPENDENT_CHECKS = ['connections', 'long_queries', 'blocked', 'wal_archive', 'cache_hit', 'xid_wraparound'];

/**
 * @param probes { postgres, pgbouncer|null, host, backups, cert|null, objects|null } raw probe results
 * @param prev   { archiverFailedCount } from the previous report, for "failed_count rose"
 */
export function buildReport(probes, cfg, now, prev = {}) {
  const t = cfg.thresholds;
  const pgRes = probes.postgres;
  const d = pgRes.data ?? {};
  const e = pgRes.errors ?? {};
  const checks = [];
  const pgChecks = {};

  // -- PostgreSQL
  if (pgRes.connected) {
    checks.push(makeCheck('postgres_connect', 'ok', `PostgreSQL ${d.server.version} answered in ${pgRes.response_ms} ms`, pgRes.response_ms));
  } else {
    checks.push(makeCheck('postgres_connect', 'fail', `cannot query PostgreSQL at ${cfg.pg.host}:${cfg.pg.port}/${cfg.pg.database}: ${pgRes.error ?? 'unknown error'}`));
  }

  const maxConnections = num(d.settings?.max_connections?.setting);
  const nonTemplateDbs = (d.databases ?? []).filter((db) => !db.is_template);

  const guard = (name, needs, evaluate) => {
    const failing = needs.find((s) => d[s] === undefined);
    if (!pgRes.connected) {
      pgChecks[name] = makeCheck(name, name === 'cache_hit' ? 'warn' : 'fail', 'not evaluated: PostgreSQL unreachable');
    } else if (failing) {
      pgChecks[name] = makeCheck(name, name === 'cache_hit' ? 'warn' : 'fail', `probe failed: ${e[failing] ?? 'no data'}`);
    } else {
      pgChecks[name] = evaluate();
    }
  };

  guard('connections', ['settings', 'connections'], () =>
    evaluateConnections(d.connections.reduce((s, r) => s + r.count, 0), maxConnections, t));
  guard('long_queries', ['long_running'], () => evaluateLongQueries(d.long_running, t));
  guard('blocked', ['blocked'], () => evaluateBlocked(d.blocked, t));
  guard('wal_archive', ['settings', 'archiver'], () =>
    evaluateWalArchive(
      { archiveMode: settingValue(d.settings, 'archive_mode'), archiver: d.archiver, pending: d.wal_pending ?? null, pendingError: e.wal_pending },
      t,
      prev.archiverFailedCount,
    ));
  guard('cache_hit', ['databases'], () => evaluateCacheHit(nonTemplateDbs, t));
  guard('xid_wraparound', ['databases'], () => evaluateXid(d.databases));

  // -- PgBouncer
  const bouncer = probes.pgbouncer;
  const pgbouncerCheckResult = bouncer ? pgbouncerCheck(bouncer) : null;

  // -- host, backups, certificate
  const host = probes.host;
  const diskCheck = host.errors?.disk ? makeCheck('disk', 'fail', host.errors.disk) : evaluateDisk(host.disk, t);
  const backups = evaluateBackups(probes.backups, t, now);
  const objects = probes.objects ? evaluateObjects(probes.objects, probes.backups?.data, t, now) : null;
  const certCheck = probes.cert ? evaluateCert(probes.cert, t, now) : null;

  checks.push(...[
    pgbouncerCheckResult,
    pgChecks.connections,
    diskCheck,
    pgChecks.long_queries,
    pgChecks.blocked,
    pgChecks.wal_archive,
    ...backups.checks,
    ...(objects ? objects.checks : []),
    certCheck,
    pgChecks.cache_hit,
    pgChecks.xid_wraparound,
  ].filter(Boolean));

  const status = overallStatus(checks);
  const section = (name, build) => (d[name] !== undefined ? build(d[name]) : { error: pgRes.connected ? e[name] ?? 'no data' : 'PostgreSQL unreachable' });

  const report = {
    status,
    time: now.toISOString(),
    checks,
    server: pgRes.connected
      ? {
          version: d.server.version,
          version_num: d.server.version_num,
          start_time: d.server.start_time,
          uptime_seconds: round(d.server.uptime_seconds, 0),
          in_recovery: d.server.in_recovery,
          max_connections: maxConnections,
          probe_database: d.server.probe_database,
          settings: d.settings ? Object.fromEntries(Object.entries(d.settings).map(([k, v]) => [k, v.value])) : { error: e.settings },
        }
      : { error: pgRes.error ?? 'PostgreSQL unreachable' },
    connections: section('connections', (rows) => buildConnections(rows, maxConnections)),
    databases: section('databases', () =>
      nonTemplateDbs.map((db) => ({
        name: db.datname,
        size_bytes: db.size_bytes,
        numbackends: db.numbackends,
        xact_commit: db.xact_commit,
        xact_rollback: db.xact_rollback,
        cache_hit_pct: round(cacheHitPct(db), 2),
        deadlocks: db.deadlocks,
        temp_files: db.temp_files,
        temp_bytes: db.temp_bytes,
        conflicts: db.conflicts,
      }))),
    activity: {
      long_query_seconds: t.longQuerySeconds,
      query_text: cfg.includeQueryText ? 'included (string literals masked, 200 chars)' : 'omitted',
      long_running: section('long_running', (rows) => ({
        total: rows.length ? num(rows[0].total) : 0,
        sessions: rows.map((r) => ({
          pid: r.pid,
          database: r.datname,
          user: r.usename,
          state: r.state,
          wait_event_type: r.wait_event_type,
          wait_event: r.wait_event,
          duration_basis: r.duration_basis,
          duration_seconds: round(r.duration_seconds, 1),
          ...('query' in r ? { query: r.query } : {}),
        })),
      })),
      blocked: section('blocked', (rows) =>
        rows.map((r) => ({
          pid: r.pid,
          database: r.datname,
          user: r.usename,
          state: r.state,
          wait_event_type: r.wait_event_type,
          wait_event: r.wait_event,
          blocked_by: r.blocked_by,
          blocked_seconds: round(r.blocked_seconds, 1),
          ...('query' in r ? { query: r.query } : {}),
        }))),
    },
    statements: section('statements', (s) =>
      s.available
        ? {
            available: true,
            top_by_total_exec_time: s.rows.map((r) => ({
              database: r.datname,
              user: r.rolname,
              queryid: r.queryid,
              calls: r.calls,
              total_ms: round(r.total_exec_time, 2),
              mean_ms: round(r.mean_exec_time, 3),
              rows: r.rows,
              shared_blks_hit: r.shared_blks_hit,
              shared_blks_read: r.shared_blks_read,
              query: r.query,
            })),
          }
        : s),
    vacuum: {
      database: cfg.pg.database,
      top_dead_tuples: section('vacuum', (rows) => rows),
      frozen_xid_age: section('databases', (rows) =>
        rows.map((db) => ({ name: db.datname, age: db.frozen_xid_age, mxid_age: db.min_mxid_age })).sort((a, b) => b.age - a.age)),
    },
    checkpointer: d.checkpointer
      ? { source: 'pg_stat_checkpointer', ...d.checkpointer }
      : d.bgwriter && (d.server?.version_num ?? 0) < 170000
        ? {
            source: 'pg_stat_bgwriter',
            num_timed: d.bgwriter.checkpoints_timed,
            num_requested: d.bgwriter.checkpoints_req,
            write_time: d.bgwriter.checkpoint_write_time,
            sync_time: d.bgwriter.checkpoint_sync_time,
            buffers_written: d.bgwriter.buffers_checkpoint,
          }
        : { error: pgRes.connected ? e.checkpointer ?? e.bgwriter ?? 'no data' : 'PostgreSQL unreachable' },
    bgwriter: section('bgwriter', (b) => b),
    wal: {
      archive_mode: settingValue(d.settings, 'archive_mode'),
      wal_level: settingValue(d.settings, 'wal_level'),
      stats: section('stat_wal', (s) => s ?? { error: 'pg_stat_wal needs PostgreSQL 14+' }),
      archiver: section('archiver', (a) => a),
      pending: section('wal_pending', (p) => p),
    },
    pgbouncer: bouncer
      ? {
          enabled: true,
          probe: bouncer.probe,
          ...(bouncer.admin.ok
            ? { version: bouncer.admin.version, pools: bouncer.admin.pools, stats: bouncer.admin.stats, lists: bouncer.admin.lists, config: bouncer.admin.config }
            : { admin_error: bouncer.admin.error }),
        }
      : { enabled: false },
    host: {
      cpu_count: host.cpu_count,
      load: host.load,
      memory: host.memory,
      disk: host.disk ?? { path: cfg.dataDir, error: host.errors?.disk },
    },
    backups: backups.section,
    objects: objects ? objects.section : { enabled: false },
    tls: probes.cert
      ? probes.cert.error
        ? probes.cert
        : { ...probes.cert, days_left: certCheck?.value ?? null }
      : { enabled: false },
  };
  return report;
}
