import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildDigest, counterDelta, digestText, formatBytes, maskLogMessage } from '../src/digest.mjs';
import { digestHtml, esc } from '../src/digest-html.mjs';
import { evaluateBackups } from '../src/report.mjs';
import { testConfig } from './helpers.mjs';

const NOW = new Date('2026-11-04T06:00:00Z');
const YESTERDAY = '2026-11-03T06:00:00Z';

function input(overrides = {}) {
  const base = {
    generated_at: NOW.toISOString(),
    server: { hostname: 'db-1', fqdn: 'db-1.example.test' },
    config: { slow_mean_ms: 100, ignore_users: ['cx_monitor'], timezone: 'Europe/London' },
    status: {
      status: 'ok',
      checks: [
        { name: 'postgres_connect', status: 'ok', message: 'PostgreSQL 17.11 answered in 2 ms' },
        { name: 'backup_logical', status: 'ok', message: 'last successful logical backup 4 h ago' },
      ],
      server: { version: '17.11 (Debian)', uptime_seconds: 400_000 },
      connections: { total: 5, max_connections: 200, utilisation_pct: 2.5 },
      databases: [{ name: 'app', size_bytes: 60_000_000, numbackends: 2, xact_commit: 10_000, xact_rollback: 10, cache_hit_pct: 99.9, deadlocks: 0, temp_bytes: 0 }],
      wal: { stats: { wal_bytes: 2_000_000_000 }, archiver: { archived_count: 1000, failed_count: 6 } },
      pgbouncer: { version: 'PgBouncer 1.26.1', pools: [{ database: 'app', user: 'app', maxwait: 0 }], stats: [{ database: 'app', total_xact_count: 5000, total_xact_time: 5_000_000, total_wait_time: 100_000, total_sent: 1e8 }], lists: { used_clients: 4 } },
      host: { cpu_count: 4, load: { load1: 0.1, load5: 0.1, load15: 0.05 }, memory: { total_bytes: 16e9, available_bytes: 14e9, swap_total_bytes: 2e9, swap_free_bytes: 2e9 } },
      backups: {
        status: {
          logical: { last_success: '2026-11-04T02:00:45Z', last_error: null, encrypted: true, databases: { app: { bytes: 5_000_000, verified: true } } },
          physical: { enabled: true, last_success: '2026-11-04T03:00:38Z', last_type: 'diff', backups: 11, repo_bytes: 2.2e9 },
          upload: { enabled: true, last_success: '2026-11-04T05:20:00Z', remote_bytes: 2.3e9 },
          verify: { last_success: '2026-11-01T05:03:49Z', databases: { app: { tables: 107, ok: true } } },
          objects: { measured: '2026-11-04T05:35:00Z', capacity_bytes: 40e9, bytes: 450e6, objects: 2183, buckets: { photos: { objects: 2179, bytes: 448e6 } } },
        },
      },
      tls: { days_left: 85.3, valid_to: '2027-01-28T17:24:31.000Z' },
    },
    host: {
      os: 'Debian GNU/Linux 13', kernel: '6.12.0', uptime_seconds: 600_000,
      filesystems: [{ mount: '/', fstype: 'ext4', size: 73e9, used: 9e9, avail: 61e9 }, { mount: '/boot/efi', fstype: 'vfat', size: 129e6, used: 9e6, avail: 120e6 }],
      usage: { postgres_data: 625e6, backups_dumps: 27e6, backups_pgbackrest: 2.2e9, objects_data: 457e6 },
      updates: { total: 0, security: 0, packages: [] },
      reboot_required: false,
      containers: [{ name: 'cx-pgsql-postgres', state: 'running', health: 'healthy', restarts: 0 }],
      jobs: [{ unit: 'cx-backup@logical.service', result: 'done' }, { unit: 'cx-backup@upload.service', result: 'done' }],
      ssh: { failed: 120, accepted: 3 },
      fail2ban: [{ jail: 'sshd', banned_now: 2, banned_period: 5 }],
      pg_log: { errors: [], slow: { count: 0, max_ms: null, threshold_ms: 500 } },
      dropbox: { total: 2e12, used: 1e12, free: 1e12 },
    },
    sql: {
      statements: {
        stats_reset: '2026-10-30T18:13:20Z',
        rows: [
          { dbname: 'app', user: 'app', queryid: '1', calls: 1000, total_ms: 2000, max_ms: 40, rows: 1000, query: 'SELECT * FROM "public"."user" WHERE id = $1' },
          { dbname: 'postgres', user: 'cx_monitor', queryid: '2', calls: 5000, total_ms: 90_000, max_ms: 80, rows: 1, query: 'SELECT datname FROM pg_stat_statements' },
        ],
      },
      tables: [{ db: 'app', schema: 'public', name: 'listing_image', total_bytes: 40e6, live_tup: 2000, dead_tup: 10 }],
    },
    previous: null,
  };
  return { ...base, ...overrides, status: { ...base.status, ...(overrides.status ?? {}) }, host: { ...base.host, ...(overrides.host ?? {}) }, sql: { ...base.sql, ...(overrides.sql ?? {}) } };
}

test('a quiet night is all healthy, with the numbers that matter in the subject and tiles', () => {
  const d = buildDigest(input(), NOW);
  assert.equal(d.status, 'ok');
  assert.match(d.subject, /^✅ db-1: All healthy — Wed 4 Nov 2026$/);
  assert.deepEqual(d.issues.filter((i) => i.severity !== 'info'), []);
  assert.equal(d.model.postgres.database_count, 1);
  assert.equal(d.model.server.filesystems.length, 1, 'filesystems under 1 GiB (the EFI partition) are left out');
  assert.equal(d.model.postgres.statements.totals.calls, 1000, 'monitoring queries are counted apart');
  assert.equal(d.model.postgres.statements.totals.monitoring_calls, 5000);
});

test('the second night reports the change since the first, and a counter reset is not a negative change', () => {
  const first = buildDigest(input(), new Date(YESTERDAY));
  const next = input({ previous: first.snapshot });
  next.sql.statements.rows = next.sql.statements.rows.map((r) => (r.queryid === '1' ? { ...r, calls: 1500, total_ms: 2500 } : r));
  next.status.databases = [{ ...next.status.databases[0], size_bytes: 61_000_000, xact_commit: 12_000 }];
  const d = buildDigest(next, NOW);
  const top = d.model.postgres.statements.top_total[0];
  assert.equal(top.calls, 500);
  assert.equal(top.mean_ms, 1);
  assert.equal(d.model.postgres.databases[0].commits, 2000);
  assert.equal(d.model.postgres.databases[0].size_delta, 1_000_000);
  assert.equal(d.model.period_hours, 24);
  assert.equal(counterDelta(5, 10), null);
});

test('slow app queries, a pending reboot, security updates and FATAL lines are warnings; ordinary errors are notes', () => {
  const d = buildDigest(
    input({
      host: {
        reboot_required: true,
        reboot_packages: ['linux-image-6.12'],
        updates: { total: 4, security: 1, packages: ['openssl'] },
        pg_log: {
          errors: [
            { severity: 'ERROR', who: 'app@app', message: 'duplicate key value violates unique constraint "cron_run_job_window_key_key"', count: 120 },
            { severity: 'FATAL', who: 'x@app', message: 'password authentication failed for user "x"', count: 2 },
          ],
          slow: { count: 3, max_ms: 812, threshold_ms: 500 },
        },
      },
      sql: { statements: { stats_reset: 'r', rows: [{ dbname: 'app', user: 'app', queryid: '9', calls: 10, total_ms: 3000, query: "SELECT pg_sleep($1)" }] } },
    }),
    NOW,
  );
  assert.equal(d.status, 'warn');
  const texts = d.issues.map((i) => `${i.severity} ${i.area}: ${i.text}`);
  assert.ok(texts.some((t) => /^warn Server: A reboot is pending \(for linux-image-6\.12\) and nothing has booked it/.test(t)), texts.join('\n'));
  assert.ok(texts.some((t) => /^warn Server: 1 security update waiting/.test(t)));
  assert.ok(texts.some((t) => /^warn Slow queries: app: 300 ms on average over 10 calls/.test(t)));
  assert.ok(texts.some((t) => /^warn PostgreSQL log: 2 FATAL lines/.test(t)));
  assert.ok(texts.some((t) => /^info PostgreSQL log: 120 statement errors, most often \(120×\): duplicate key value violates unique constraint "cron_run_job_window_key_key"/.test(t)));
  assert.ok(texts.some((t) => /^info Slow queries: 3 statements took over 500 ms \(longest 812 ms\)/.test(t)));
  assert.match(d.subject, /^⚠️ db-1: 4 warnings — /);
  assert.equal(d.issues[0].severity, 'warn', 'issues are ordered worst first');
});

test('FATAL lines inside a maintenance window are a note; the same message outside one, and any PANIC, still count', () => {
  const planned = buildDigest(
    input({
      host: {
        pg_log: {
          errors: [
            { severity: 'FATAL', who: 'cx_monitor@postgres', message: 'terminating connection due to administrator command', planned: true, count: 2 },
            { severity: 'FATAL', who: 'alted@alted', message: 'terminating connection due to administrator command', planned: true, count: 1 },
          ],
          slow: { count: 0, max_ms: null, threshold_ms: 500 },
        },
      },
    }),
    NOW,
  );
  const texts = planned.issues.map((i) => `${i.severity} ${i.area}: ${i.text}`);
  assert.ok(!texts.some((t) => /^warn PostgreSQL log/.test(t)), texts.join('\n'));
  assert.ok(texts.some((t) => /^info PostgreSQL log: 3 FATAL lines during planned maintenance \(expected: Postgres ends open connections as it stops\), most often: terminating connection due to administrator command/.test(t)), texts.join('\n'));
  assert.equal(planned.model.postgres.errors.counts.fatal, 3);
  assert.equal(planned.model.postgres.errors.counts.fatal_planned, 3);
  assert.match(digestText(planned), /terminating connection due to administrator command {2}\(planned maintenance\)/);
  assert.match(digestHtml(planned), /during planned maintenance/);

  const mixed = buildDigest(
    input({
      host: {
        pg_log: {
          errors: [
            { severity: 'FATAL', who: 'alted@alted', message: 'terminating connection due to administrator command', planned: true, count: 4 },
            { severity: 'FATAL', who: 'alted@alted', message: 'terminating connection due to administrator command', count: 1 },
            { severity: 'PANIC', who: null, message: 'could not write to file', planned: true, count: 1 },
          ],
          slow: { count: 0, max_ms: null, threshold_ms: 500 },
        },
      },
    }),
    NOW,
  );
  const mixedTexts = mixed.issues.map((i) => `${i.severity} ${i.area}: ${i.text}`);
  assert.ok(mixedTexts.some((t) => /^warn PostgreSQL log: 1 FATAL line, most often: terminating connection/.test(t)), mixedTexts.join('\n'));
  assert.ok(mixedTexts.some((t) => /^info PostgreSQL log: 4 FATAL lines during planned maintenance/.test(t)));
  assert.ok(mixedTexts.some((t) => /^fail PostgreSQL log: 1 PANIC line/.test(t)));
});

test('security updates: a note while the automatic updates are on and working; a warning otherwise', () => {
  const run = (auto, previous = null, security_packages = ['openssl', 'libssl3t64', 'tzdata']) => {
    const d = buildDigest(input({ host: { updates: { total: 7, security: 3, packages: [], security_packages, auto } }, ...(previous ? { previous } : {}) }), NOW);
    return { d, texts: d.issues.filter((i) => i.area === 'Server').map((i) => `${i.severity} ${i.text}`) };
  };
  const working = { enabled: true, last_run: '2026-11-04T05:23:11Z', last_ok: true };

  const fresh = run(working);
  assert.deepEqual(fresh.texts, ['info 3 security updates waiting; the automatic security updates install them on their next run (last run Wed 4 Nov 2026, 05:23 GMT, no errors).']);
  assert.deepEqual(fresh.d.snapshot.security_updates, ['openssl', 'libssl3t64', 'tzdata']);

  const passedBy = run(working, { at: YESTERDAY, security_updates: ['openssl', 'curl'] });
  assert.deepEqual(passedBy.texts, ["warn 3 security updates waiting; openssl was already waiting at the last report, so the automatic updates aren't installing it."]);

  assert.match(run({ ...working, enabled: false }).texts[0], /^warn 3 security updates waiting, and automatic security updates are off\.$/);
  assert.match(run({ ...working, last_ok: false }).texts[0], /^warn 3 security updates waiting; the last automatic run \(Wed 4 Nov 2026, 05:23 GMT\) logged an error\.$/);
  assert.match(run({ ...working, last_run: '2026-11-02T05:00:00Z' }).texts[0], /^warn 3 security updates waiting; the automatic updates last ran Mon 2 Nov 2026, 05:00 GMT\.$/);
  assert.match(run({ enabled: true, last_run: null, last_ok: null }).texts[0], /^warn 3 security updates waiting, and no automatic update run is recorded\.$/);
  // A collector from before this change sends no `auto`: the old warning.
  assert.match(run(undefined).texts[0], /^warn 3 security updates waiting\.$/);
});

test('failed backup runs, restarted containers and a full disk are reported', () => {
  const first = buildDigest(input(), new Date(YESTERDAY));
  const d = buildDigest(
    input({
      previous: first.snapshot,
      host: {
        filesystems: [{ mount: '/', fstype: 'ext4', size: 100e9, used: 92e9, avail: 8e9 }],
        containers: [{ name: 'cx-pgsql-postgres', state: 'running', health: 'healthy', restarts: 2 }],
        jobs: [{ unit: 'cx-backup@upload.service', result: 'done' }, { unit: 'cx-backup@upload.service', result: 'failed' }],
      },
    }),
    NOW,
  );
  assert.equal(d.status, 'fail');
  const texts = d.issues.map((i) => `${i.severity} ${i.text}`);
  assert.ok(texts.includes('fail / is 92% full (7.5 GiB free).'), texts.join('\n'));
  assert.ok(texts.includes('warn cx-pgsql-postgres restarted 2 times.'));
  assert.ok(texts.includes('warn Off-site upload: 1 of 2 runs failed.'));
});

test('a missing health report is itself the first problem', () => {
  const d = buildDigest(input({ status: { error: 'connection refused', checks: [] } }), NOW);
  assert.equal(d.status, 'fail');
  assert.match(d.issues[0].text, /health service gave no report: connection refused/);
});

test('log messages keep schema names and hide values', () => {
  assert.equal(maskLogMessage('duplicate key value violates unique constraint "cron_run_job_window_key_key"'), 'duplicate key value violates unique constraint "cron_run_job_window_key_key"');
  assert.equal(maskLogMessage('invalid input syntax for type uuid: "amara-khan"'), 'invalid input syntax for type uuid: "?"');
  assert.equal(maskLogMessage("Key (email)=(amara@example.com) already exists."), 'Key (email)=(?) already exists.');
  assert.equal(maskLogMessage("column t5.credit does not exist at character 1312"), 'column t5.credit does not exist at character N');
  assert.equal(maskLogMessage('archiving write-ahead log file "000000010000000000000001" failed too many times'), 'archiving write-ahead log file "?" failed too many times');
  assert.equal(maskLogMessage('password authentication failed for user "pgbouncer_auth"'), 'password authentication failed for user "pgbouncer_auth"');
  assert.equal(maskLogMessage("syntax error at or near 'secret'"), "syntax error at or near '?'");
});

test('the HTML escapes everything it is given and carries every section; the text part says the same', () => {
  const evil = input({ host: { pg_log: { errors: [{ severity: 'ERROR', who: 'a@b', message: 'relation "<script>x" does not exist', count: 1 }] } } });
  evil.sql.statements.rows[0].query = 'SELECT "<img src=x onerror=alert(1)>" FROM t';
  const d = buildDigest(evil, NOW);
  const html = digestHtml(d);
  assert.ok(!/<script/i.test(html) && !/<img/i.test(html), 'no markup from the data survives');
  for (const heading of ['Needs attention', 'Server', 'PostgreSQL', 'Backups', 'Object storage', 'All checks']) assert.ok(html.includes(`>${heading}</h2>`), heading);
  assert.ok(html.includes('max-width:600px'));
  assert.ok(html.includes('prefers-color-scheme: dark'));
  assert.equal(esc(`<a href="x">'&`), '&lt;a href=&quot;x&quot;&gt;&#39;&amp;');
  const text = digestText(d);
  assert.match(text, /^db-1: /);
  assert.match(text, /BACKUPS\n {2}Nightly dumps/);
  assert.match(text, /Disk \/ +8\.4 GiB used, 56\.8 GiB free of 68\.0 GiB/);
});

test('formatBytes reads like df -h', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(1536), '1.5 KiB');
  assert.equal(formatBytes(63297203), '60.4 MiB');
  assert.equal(formatBytes(2215396257), '2.1 GiB');
});

test('the report email check warns when the email failed or stopped, and never fails the server', () => {
  const t = testConfig().thresholds;
  const now = new Date('2026-11-04T08:00:00Z');
  const base = { updated: '2026-11-04T07:00:00Z', logical: { last_success: '2026-11-04T02:00:00Z' }, physical: { enabled: false }, verify: { last_success: '2026-11-01T05:00:00Z' } };
  const check = (report) => evaluateBackups({ present: true, data: { ...base, report } }, t, now).checks.find((c) => c.name === 'report_email');
  assert.equal(check(undefined), undefined, 'no check until the report is switched on');
  assert.equal(check({ enabled: true, last_success: '2026-11-04T06:00:00Z' }).status, 'ok');
  assert.equal(check({ enabled: true, last_attempt: '2026-11-04T06:00:00Z', last_success: '2026-11-03T06:00:00Z', last_error: 'Brevo answered 401' }).status, 'warn');
  assert.equal(check({ enabled: true, last_success: '2026-11-01T06:00:00Z' }).status, 'warn');
});

test('bulk COPY (pg_dump, imports) is counted apart and never called slow; a dropped database is named as such', () => {
  const d = buildDigest(
    input({ sql: { statements: { stats_reset: 'r', rows: [
      { dbname: 'app', user: 'postgres', queryid: '7', calls: 1, total_ms: 27_000, query: 'COPY public.listing_image (id, content) TO stdout' },
      { dbname: null, user: 'app', queryid: '8', calls: 2, total_ms: 10, query: 'SELECT $1' },
    ] } } }),
    NOW,
  );
  assert.deepEqual(d.model.postgres.statements.slow, []);
  assert.equal(d.model.postgres.statements.totals.bulk_calls, 1);
  assert.equal(d.model.postgres.statements.top_total[0].database, '(dropped database)');
});

test('a pending reboot that is already booked is a note with its time, not a warning', () => {
  const d = buildDigest(input({ host: { reboot_required: true, reboot_packages: ['linux-image-6.12'], reboot_scheduled: '2026-11-04T23:00:00Z' } }), NOW);
  assert.equal(d.status, 'ok');
  const note = d.issues.find((i) => i.area === 'Server' && /reboot/.test(i.text));
  assert.equal(note.severity, 'info');
  assert.match(note.text, /booked for Wed 4 Nov 2026, 23:00 GMT/);
  assert.match(digestHtml(d), />Booked</);
});

test('the last reboot shows when and how long the server was off', () => {
  const d = buildDigest(input({ host: { last_reboot: { at: '2026-11-04T23:00:52Z', offline_seconds: 9 } } }), NOW);
  assert.deepEqual(d.model.server.last_reboot, { at: 'Wed 4 Nov 2026, 23:00 GMT', offline_seconds: 9 });
  assert.match(digestText(d), /Last reboot +Wed 4 Nov 2026, 23:00 GMT, offline 9 s/);
});
