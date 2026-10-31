// Prometheus text exposition format 0.0.4, built only from the numeric parts of a report.
import { RANK } from './report.mjs';
import { num } from './util.mjs';

export const CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8';

/** Label values escape backslash, double quote and line feed. */
export function escapeLabelValue(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

/** HELP text escapes backslash and line feed. */
export function escapeHelp(text) {
  return String(text).replace(/\\/g, '\\\\').replace(/\n/g, '\\n');
}

export function formatValue(value) {
  if (value === true) return '1';
  if (value === false) return '0';
  if (Number.isNaN(value)) return 'NaN';
  if (value === Infinity) return '+Inf';
  if (value === -Infinity) return '-Inf';
  return String(value);
}

const NAME = /^[a-zA-Z_:][a-zA-Z0-9_:]*$/;
const LABEL = /^[a-zA-Z_][a-zA-Z0-9_]*$/;

/** Collects samples per metric family so each family is written once, contiguously. */
export class MetricWriter {
  #families = new Map();

  /** Adds one sample; null/undefined/non-numeric values are skipped (absent beats a fake zero). */
  add(name, type, help, labels, value) {
    if (!NAME.test(name)) throw new Error(`invalid metric name ${name}`);
    let v;
    if (typeof value === 'boolean') v = value ? 1 : 0;
    else if (typeof value === 'number') v = value; // NaN and ±Inf are valid sample values
    else v = num(value); // numeric strings and bigint; anything else is skipped
    if (v === null || v === undefined) return this;
    let family = this.#families.get(name);
    if (!family) {
      family = { type, help, samples: [] };
      this.#families.set(name, family);
    }
    const pairs = Object.entries(labels ?? {}).map(([k, val]) => {
      if (!LABEL.test(k)) throw new Error(`invalid label name ${k}`);
      return `${k}="${escapeLabelValue(val ?? '')}"`;
    });
    family.samples.push(`${name}${pairs.length ? `{${pairs.join(',')}}` : ''} ${formatValue(v)}`);
    return this;
  }

  render() {
    const lines = [];
    for (const [name, f] of this.#families) {
      lines.push(`# HELP ${name} ${escapeHelp(f.help)}`, `# TYPE ${name} ${f.type}`, ...f.samples);
    }
    return `${lines.join('\n')}\n`;
  }
}

const gauge = 'gauge';
const counter = 'counter';

export function renderMetrics(report) {
  const m = new MetricWriter();
  const checkByName = Object.fromEntries(report.checks.map((c) => [c.name, c]));
  const ok = (name) => (checkByName[name] ? checkByName[name].status !== 'fail' : null);

  m.add('cx_health_report_timestamp_seconds', gauge, 'When this report was computed (Unix time).', {}, Date.parse(report.time) / 1000);
  m.add('cx_pg_up', gauge, '1 when PostgreSQL answered the probe.', {}, ok('postgres_connect'));
  if (report.pgbouncer?.enabled) m.add('cx_pgbouncer_up', gauge, '1 when SELECT 1 through PgBouncer succeeded.', {}, report.pgbouncer.probe?.ok === true);

  const s = report.server ?? {};
  m.add('cx_pg_uptime_seconds', gauge, 'Seconds since the postmaster started.', {}, s.uptime_seconds);
  m.add('cx_pg_max_connections', gauge, 'max_connections setting.', {}, s.max_connections);

  const c = report.connections ?? {};
  for (const [state, count] of Object.entries(c.by_state ?? {})) {
    m.add('cx_pg_connections', gauge, 'Client backends by state.', { state }, count);
  }
  m.add('cx_pg_connection_utilisation_ratio', gauge, 'Client backends divided by max_connections (0-1).', {}, c.utilisation_pct == null ? null : c.utilisation_pct / 100);
  m.add('cx_pg_oldest_transaction_seconds', gauge, 'Age of the oldest open transaction.', {}, c.oldest_transaction_seconds);
  m.add('cx_pg_longest_query_seconds', gauge, 'Duration of the longest currently active query.', {}, c.longest_active_query_seconds ?? (c.by_state ? 0 : null));

  if (Array.isArray(report.databases)) {
    for (const db of report.databases) {
      const l = { datname: db.name };
      m.add('cx_pg_database_size_bytes', gauge, 'Database size on disk.', l, db.size_bytes);
      m.add('cx_pg_database_numbackends', gauge, 'Backends connected to the database.', l, db.numbackends);
      m.add('cx_pg_database_xact_commit_total', counter, 'Committed transactions.', l, db.xact_commit);
      m.add('cx_pg_database_xact_rollback_total', counter, 'Rolled-back transactions.', l, db.xact_rollback);
      m.add('cx_pg_database_deadlocks_total', counter, 'Deadlocks detected.', l, db.deadlocks);
      m.add('cx_pg_database_cache_hit_ratio', gauge, 'Shared-buffer hits divided by hits+reads (0-1).', l, db.cache_hit_pct == null ? null : db.cache_hit_pct / 100);
    }
  }
  if (Array.isArray(report.vacuum?.frozen_xid_age)) {
    for (const db of report.vacuum.frozen_xid_age) {
      m.add('cx_pg_database_frozen_xid_age', gauge, 'age(datfrozenxid); wraparound protection starts near 2^31.', { datname: db.name }, db.age);
    }
  }

  const lr = report.activity?.long_running;
  if (lr && !lr.error) m.add('cx_pg_long_running_sessions', gauge, 'Sessions active (or idle in transaction) longer than LONG_QUERY_SECONDS.', {}, lr.total);
  if (Array.isArray(report.activity?.blocked)) m.add('cx_pg_blocked_sessions', gauge, 'Sessions waiting on a lock held by another session.', {}, report.activity.blocked.length);

  const a = report.wal?.archiver;
  if (a && !a.error) {
    m.add('cx_pg_archiver_archived_total', counter, 'WAL files archived since stats reset.', {}, a.archived_count);
    m.add('cx_pg_archiver_failed_total', counter, 'Failed WAL archive attempts since stats reset.', {}, a.failed_count);
    m.add('cx_pg_archiver_last_archive_age_seconds', gauge, 'Seconds since the last successful WAL archive.', {}, a.last_archived_age_seconds);
  }
  const p = report.wal?.pending;
  if (p && !p.error) {
    m.add('cx_pg_wal_pending_segments', gauge, 'Completed WAL segments waiting to be archived.', {}, p.ready);
    m.add('cx_pg_wal_oldest_pending_seconds', gauge, 'How long the oldest waiting WAL segment has waited.', {}, p.ready ? p.oldest_ready_age_seconds : 0);
  }

  const h = report.host ?? {};
  if (h.disk && !h.disk.error) {
    m.add('cx_host_disk_used_ratio', gauge, 'Data-directory filesystem used / (used + available), as df reports it.', { path: h.disk.path }, h.disk.used_pct / 100);
    m.add('cx_host_disk_total_bytes', gauge, 'Data-directory filesystem size.', { path: h.disk.path }, h.disk.total_bytes);
    m.add('cx_host_disk_free_bytes', gauge, 'Data-directory filesystem bytes available to unprivileged users.', { path: h.disk.path }, h.disk.free_bytes);
  }
  if (h.load) {
    m.add('cx_host_load1', gauge, '1-minute load average.', {}, h.load.load1);
    m.add('cx_host_load5', gauge, '5-minute load average.', {}, h.load.load5);
    m.add('cx_host_load15', gauge, '15-minute load average.', {}, h.load.load15);
  }
  m.add('cx_host_cpu_count', gauge, 'CPUs available.', {}, h.cpu_count);
  m.add('cx_host_memory_available_bytes', gauge, 'MemAvailable from /proc/meminfo.', {}, h.memory?.available_bytes);
  m.add('cx_host_memory_total_bytes', gauge, 'MemTotal from /proc/meminfo.', {}, h.memory?.total_bytes);

  const ages = report.backups?.ages;
  if (ages) {
    for (const kind of ['logical', 'physical', 'upload', 'verify', ...(report.objects?.enabled ? ['objects'] : [])]) {
      const hours = ages[kind]?.last_success_hours;
      m.add('cx_backup_age_seconds', gauge, 'Seconds since the last successful backup step, from the status file.', { kind }, hours == null ? null : Math.round(hours * 3600));
    }
    m.add('cx_backup_status_file_age_seconds', gauge, 'Seconds since the status file "updated" timestamp.', {}, ages.updated_hours == null ? null : Math.round(ages.updated_hours * 3600));
  }

  const o = report.objects;
  if (o?.enabled) {
    m.add('cx_objects_up', gauge, 'The object store answered its health check with 200.', {}, o.http_status === 200 ? 1 : 0);
    if (o.store && typeof o.store === 'object') {
      m.add('cx_objects_bytes', gauge, 'Bytes held in the object store, from the last measurement.', {}, num(o.store.bytes));
      m.add('cx_objects_capacity_bytes', gauge, 'Capacity the object store may use.', {}, num(o.store.capacity_bytes));
      m.add('cx_objects_count', gauge, 'Objects held in the object store, from the last measurement.', {}, num(o.store.objects));
    }
  }

  if (report.tls && report.tls.days_left != null) m.add('cx_tls_cert_days_left', gauge, 'Days until the certificate expires.', {}, report.tls.days_left);

  if (Array.isArray(report.pgbouncer?.pools)) {
    for (const pool of report.pgbouncer.pools) {
      const l = { database: pool.database, user: pool.user };
      m.add('cx_pgbouncer_pool_cl_active', gauge, 'Client connections linked to a server connection.', l, pool.cl_active);
      m.add('cx_pgbouncer_pool_cl_waiting', gauge, 'Client connections waiting for a server connection.', l, pool.cl_waiting);
      m.add('cx_pgbouncer_pool_sv_active', gauge, 'Server connections linked to a client.', l, pool.sv_active);
      m.add('cx_pgbouncer_pool_sv_idle', gauge, 'Server connections idle and ready.', l, pool.sv_idle);
      const maxwait = num(pool.maxwait);
      const seconds = maxwait === null ? null : maxwait + (num(pool.maxwait_us) ?? 0) / 1e6;
      m.add('cx_pgbouncer_pool_maxwait_seconds', gauge, 'Longest current client wait for a server connection.', l, seconds);
    }
  }

  for (const check of report.checks) {
    m.add('cx_check_status', gauge, 'Check state: 0 ok, 1 warn, 2 fail.', { check: check.name }, RANK[check.status] ?? RANK.fail);
  }
  m.add('cx_health_status', gauge, 'Overall state: 0 ok, 1 warn, 2 fail.', {}, RANK[report.status] ?? RANK.fail);

  return m.render();
}
