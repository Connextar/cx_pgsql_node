import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildReport, evaluateBackupSection, evaluateBackups, evaluateCert, evaluateWalArchive, healthzView,
  overallStatus, thresholdStatus, worstStatus, XID_FAIL_AGE, XID_WARN_AGE,
} from '../src/report.mjs';
import { NOW, byName, healthyProbes, statusFixture, testConfig, unreachableProbes } from './helpers.mjs';

const cfg = testConfig();
const t = cfg.thresholds;
const hoursAgo = (h) => new Date(NOW.getTime() - h * 3_600_000).toISOString();

describe('thresholds and overall status', () => {
  test('thresholdStatus: warn and fail limits are inclusive', () => {
    assert.equal(thresholdStatus(69.99, 70, 90), 'ok');
    assert.equal(thresholdStatus(70, 70, 90), 'warn');
    assert.equal(thresholdStatus(89.99, 70, 90), 'warn');
    assert.equal(thresholdStatus(90, 70, 90), 'fail');
    assert.equal(thresholdStatus(150, 70, 90), 'fail');
    assert.equal(thresholdStatus(null, 70, 90), null);
    assert.equal(thresholdStatus(Number.NaN, 70, 90), null);
  });

  test('overall status is the worst check; unknown states count as fail', () => {
    assert.equal(worstStatus([]), 'ok');
    assert.equal(worstStatus(['ok', 'ok']), 'ok');
    assert.equal(worstStatus(['ok', 'warn', 'ok']), 'warn');
    assert.equal(worstStatus(['warn', 'fail', 'ok']), 'fail');
    assert.equal(worstStatus(['ok', 'bogus']), 'fail');
    assert.equal(overallStatus([{ status: 'ok' }, { status: 'warn' }]), 'warn');
  });

  test('healthy fixture: every check ok and the expected names present', () => {
    const report = buildReport(healthyProbes(), cfg, NOW);
    assert.equal(report.status, 'ok', JSON.stringify(report.checks.filter((c) => c.status !== 'ok')));
    assert.deepEqual(report.checks.map((c) => c.name), [
      'postgres_connect', 'connections', 'disk', 'long_queries', 'blocked', 'wal_archive',
      'backup_logical', 'backup_physical', 'backup_upload', 'backup_verify', 'status_file',
      'tls_cert', 'cache_hit', 'xid_wraparound',
    ]);
    for (const c of report.checks) assert.ok(typeof c.message === 'string' && c.message.length > 0, c.name);
  });

  test('connections: utilisation counts every client backend against max_connections', () => {
    const p = healthyProbes();
    p.postgres.data.connections[0].count = 73; // 73 + 1 + 1 = 75 of 100
    let c = byName(buildReport(p, cfg, NOW)).connections;
    assert.equal(c.status, 'warn');
    assert.equal(c.value, 75);
    p.postgres.data.connections[0].count = 88; // 90%
    c = byName(buildReport(p, cfg, NOW)).connections;
    assert.equal(c.status, 'fail');
  });

  test('disk thresholds', () => {
    const p = healthyProbes();
    p.host.disk.used_pct = 85;
    assert.equal(byName(buildReport(p, cfg, NOW)).disk.status, 'warn');
    p.host.disk.used_pct = 91;
    assert.equal(byName(buildReport(p, cfg, NOW)).disk.status, 'fail');
    delete p.host.disk;
    p.host.errors.disk = 'cannot statfs /pgdata: ENOENT';
    const d = byName(buildReport(p, cfg, NOW)).disk;
    assert.equal(d.status, 'fail');
    assert.match(d.message, /ENOENT/);
  });

  test('long queries warn; blocked warns only beyond WARN_BLOCKED_SECONDS', () => {
    const p = healthyProbes();
    p.postgres.data.long_running = [
      { pid: 41, datname: 'alted', usename: 'alted_app', state: 'active', duration_basis: 'query', duration_seconds: 412, total: 2 },
      { pid: 42, datname: 'alted', usename: 'alted_app', state: 'idle in transaction', duration_basis: 'transaction', duration_seconds: 75, total: 2 },
    ];
    p.postgres.data.blocked = [{ pid: 50, blocked_by: [41], blocked_seconds: 12 }];
    let checks = byName(buildReport(p, cfg, NOW));
    assert.equal(checks.long_queries.status, 'warn');
    assert.equal(checks.long_queries.value, 2);
    assert.match(checks.long_queries.message, /pid 41/);
    assert.equal(checks.blocked.status, 'ok');
    p.postgres.data.blocked = [{ pid: 50, blocked_by: [41], blocked_seconds: 31 }];
    checks = byName(buildReport(p, cfg, NOW));
    assert.equal(checks.blocked.status, 'warn');
    assert.match(checks.blocked.message, /blocked by 41/);
  });

  test('xid wraparound: warn above 1.2 billion, fail above 1.6 billion', () => {
    const p = healthyProbes();
    p.postgres.data.databases[2].frozen_xid_age = XID_WARN_AGE;
    assert.equal(byName(buildReport(p, cfg, NOW)).xid_wraparound.status, 'ok');
    p.postgres.data.databases[2].frozen_xid_age = XID_WARN_AGE + 1;
    assert.equal(byName(buildReport(p, cfg, NOW)).xid_wraparound.status, 'warn');
    p.postgres.data.databases[2].frozen_xid_age = XID_FAIL_AGE + 1;
    const x = byName(buildReport(p, cfg, NOW)).xid_wraparound;
    assert.equal(x.status, 'fail');
    assert.match(x.message, /template0/);
  });

  test('cache hit is warn-only and ignores quiet databases', () => {
    const p = healthyProbes();
    p.postgres.data.databases[0].blks_read = 200_000; // alted: 998k / 1.198m = 83%
    const c = byName(buildReport(p, cfg, NOW)).cache_hit;
    assert.equal(c.status, 'warn');
    assert.match(c.message, /alted/);
    assert.doesNotMatch(c.message, /postgres/); // 300 blocks: too quiet to judge
    const quiet = healthyProbes();
    for (const db of quiet.postgres.data.databases) db.blks_hit = db.blks_read = 1;
    assert.equal(byName(buildReport(quiet, cfg, NOW)).cache_hit.status, 'ok');
  });

  test('PostgreSQL unreachable: dependent checks fail (cache_hit warns), others still evaluated', () => {
    const report = buildReport(unreachableProbes(), cfg, NOW);
    const checks = byName(report);
    assert.equal(report.status, 'fail');
    assert.equal(checks.postgres_connect.status, 'fail');
    assert.match(checks.postgres_connect.message, /ECONNREFUSED/);
    for (const name of ['connections', 'long_queries', 'blocked', 'wal_archive', 'xid_wraparound']) {
      assert.equal(checks[name].status, 'fail', name);
      assert.match(checks[name].message, /not evaluated/);
    }
    assert.equal(checks.cache_hit.status, 'warn');
    assert.equal(checks.disk.status, 'ok');
    assert.equal(checks.backup_logical.status, 'ok');
    assert.ok(report.server.error);
    assert.ok(report.connections.error);
  });

  test('a section probe that errored becomes a failed check', () => {
    const p = healthyProbes();
    delete p.postgres.data.blocked;
    p.postgres.errors.blocked = 'canceling statement due to statement timeout';
    const b = byName(buildReport(p, cfg, NOW)).blocked;
    assert.equal(b.status, 'fail');
    assert.match(b.message, /statement timeout/);
  });

  test('pgbouncer_connect: absent when disabled, fail when SELECT 1 fails, warn when only the console fails', () => {
    const p = healthyProbes();
    assert.equal(byName(buildReport(p, cfg, NOW)).pgbouncer_connect, undefined);
    p.pgbouncer = { probe: { ok: false, ms: null, database: 'postgres', error: 'connect ECONNREFUSED' }, admin: { ok: false, error: 'connect ECONNREFUSED' } };
    assert.equal(byName(buildReport(p, cfg, NOW)).pgbouncer_connect.status, 'fail');
    p.pgbouncer.probe = { ok: true, ms: 3, database: 'postgres', error: null };
    assert.equal(byName(buildReport(p, cfg, NOW)).pgbouncer_connect.status, 'warn');
    p.pgbouncer.admin = { ok: true, error: null, version: 'PgBouncer 1.24.1', pools: [{ database: 'alted', user: 'alted_app', cl_waiting: 2 }], stats: [], lists: {}, config: {} };
    const c = byName(buildReport(p, cfg, NOW)).pgbouncer_connect;
    assert.equal(c.status, 'ok');
    assert.match(c.message, /2 client\(s\) waiting/);
  });
});

describe('wal_archive', () => {
  const base = () => ({
    archiveMode: 'on',
    archiver: { failed_count: 0, last_archived_time: hoursAgo(5), last_archived_age_seconds: 5 * 3600, last_failed_time: null },
    pending: { ready: 0, oldest_ready_age_seconds: null },
  });

  test('not judged when archive_mode is off', () => {
    assert.equal(evaluateWalArchive({ ...base(), archiveMode: 'off' }, t).status, 'ok');
  });

  test('an old last archive with nothing waiting is idle, not stuck', () => {
    const c = evaluateWalArchive(base(), t);
    assert.equal(c.status, 'ok');
    assert.match(c.message, /no WAL waiting/);
  });

  test('fails when the oldest waiting segment exceeds the limit', () => {
    const c = evaluateWalArchive({ ...base(), pending: { ready: 3, oldest_ready_age_seconds: 31 * 60 } }, t);
    assert.equal(c.status, 'fail');
    assert.match(c.message, /3 WAL segment/);
    assert.equal(evaluateWalArchive({ ...base(), pending: { ready: 1, oldest_ready_age_seconds: 60 } }, t).status, 'ok');
  });

  test('fails when the last failure is newer than the last success, and says when the count rose', () => {
    const input = base();
    input.archiver = { ...input.archiver, failed_count: 7, last_failed_time: hoursAgo(0.01), last_failed_wal: '0000000100000000000000F4' };
    const c = evaluateWalArchive(input, t, 5);
    assert.equal(c.status, 'fail');
    assert.match(c.message, /2 new since the previous check/);
    input.archiver.last_archived_time = hoursAgo(0.001); // a later success clears it
    assert.equal(evaluateWalArchive(input, t, 7).status, 'ok');
  });

  test('without archive_status visibility an old last archive only warns', () => {
    const c = evaluateWalArchive({ ...base(), pending: null, pendingError: 'permission denied for function pg_ls_archive_statusdir' }, t);
    assert.equal(c.status, 'warn');
  });
});

describe('backups', () => {
  test('a recent success is ok and carries its age in hours', () => {
    const c = evaluateBackupSection('backup_logical', 'logical backup', { last_attempt: hoursAgo(2), last_success: hoursAgo(2) }, 26, NOW);
    assert.equal(c.status, 'ok');
    assert.equal(c.value, 2);
  });

  test('a success older than the limit fails', () => {
    const c = evaluateBackupSection('backup_logical', 'logical backup', { last_success: hoursAgo(27) }, 26, NOW);
    assert.equal(c.status, 'fail');
    assert.match(c.message, /limit 26 h/);
  });

  test('last_error with an attempt newer than the success fails with the error in the message', () => {
    const c = evaluateBackupSection('backup_physical', 'pgBackRest backup', {
      last_attempt: hoursAgo(1), last_success: hoursAgo(25), last_error: 'ERROR [082]: WAL segment was not archived before the 60000ms timeout',
    }, 26, NOW);
    assert.equal(c.status, 'fail');
    assert.match(c.message, /WAL segment was not archived/);
  });

  test('an error older than the latest success is ignored', () => {
    const c = evaluateBackupSection('backup_upload', 'upload', { last_attempt: hoursAgo(3), last_success: hoursAgo(2), last_error: 'old failure' }, 26, NOW);
    assert.equal(c.status, 'ok');
  });

  test('an attempt in progress (newer than the success, no error) is ok', () => {
    const c = evaluateBackupSection('backup_logical', 'logical backup', { last_attempt: hoursAgo(0.1), last_success: hoursAgo(24), last_error: null }, 26, NOW);
    assert.equal(c.status, 'ok');
  });

  test('attempts but never a success fails; nothing recorded warns', () => {
    assert.equal(evaluateBackupSection('backup_logical', 'logical backup', { last_attempt: hoursAgo(1) }, 26, NOW).status, 'fail');
    assert.equal(evaluateBackupSection('backup_logical', 'logical backup', {}, 26, NOW).status, 'warn');
    assert.equal(evaluateBackupSection('backup_logical', 'logical backup', { last_error: 'boom' }, 26, NOW).status, 'fail');
  });

  test('missing, non-object or garbage-timestamp sections do not throw', () => {
    for (const section of [undefined, null, 'yes', 42, [], { last_success: 'not a date', last_attempt: 17 }]) {
      const c = evaluateBackupSection('backup_logical', 'logical backup', section, 26, NOW);
      assert.ok(['warn', 'fail'].includes(c.status), JSON.stringify(section));
    }
  });

  test('the full fixture file: all ok, with computed ages', () => {
    const { checks, section } = evaluateBackups({ path: '/s.json', present: true, data: statusFixture() }, t, NOW);
    assert.deepEqual(checks.map((c) => [c.name, c.status]), [
      ['backup_logical', 'ok'], ['backup_physical', 'ok'], ['backup_upload', 'ok'], ['backup_verify', 'ok'], ['status_file', 'ok'],
    ]);
    assert.equal(section.ages.updated_hours, 5.4806);
    assert.equal(section.ages.physical.last_full_hours, 54.5);
    assert.equal(section.status.logical.databases.alted.verified, true);
  });

  test('missing status file: status_file and backup checks warn (not fail); upload not judged', () => {
    const { checks } = evaluateBackups({ path: '/s.json', present: false, error: 'missing' }, t, NOW);
    const map = Object.fromEntries(checks.map((c) => [c.name, c]));
    assert.equal(map.status_file.status, 'warn');
    assert.match(map.status_file.message, /missing/);
    for (const name of ['backup_logical', 'backup_physical', 'backup_verify']) assert.equal(map[name].status, 'warn');
    assert.equal(map.backup_upload, undefined);
    assert.equal(overallStatus(checks), 'warn');
  });

  test('garbled status file warns with the parse problem', () => {
    const { checks, section } = evaluateBackups({ path: '/s.json', present: true, error: 'not valid JSON (Unexpected end of JSON input)' }, t, NOW);
    const sf = checks.find((c) => c.name === 'status_file');
    assert.equal(sf.status, 'warn');
    assert.match(sf.message, /not valid JSON/);
    assert.equal(section.present, true);
  });

  test('a file with only some sections is tolerated', () => {
    const { checks } = evaluateBackups({ path: '/s.json', present: true, data: { updated: hoursAgo(1), logical: { last_success: hoursAgo(1) } } }, t, NOW);
    const map = Object.fromEntries(checks.map((c) => [c.name, c.status]));
    assert.deepEqual(map, { backup_logical: 'ok', backup_physical: 'warn', backup_verify: 'warn', status_file: 'ok' });
  });

  test('upload is judged only when enabled; physical.enabled=false is ok', () => {
    const data = statusFixture();
    data.upload.enabled = false;
    data.physical = { enabled: false };
    const { checks } = evaluateBackups({ present: true, data }, t, NOW);
    assert.equal(checks.find((c) => c.name === 'backup_upload'), undefined);
    assert.equal(checks.find((c) => c.name === 'backup_physical').status, 'ok');
  });

  test('a stale upload fails against UPLOAD_MAX_AGE_HOURS', () => {
    const data = statusFixture();
    data.upload.last_success = hoursAgo(30);
    data.upload.last_attempt = hoursAgo(30);
    const c = evaluateBackups({ present: true, data }, t, NOW).checks.find((x) => x.name === 'backup_upload');
    assert.equal(c.status, 'fail');
    assert.match(c.message, /dropbox:CX_PGSQL_Node_1/);
  });

  test('an unverified dump or a failed restore check fails', () => {
    const data = statusFixture();
    data.logical.databases.alted.verified = false;
    data.verify.databases.alted.ok = false;
    const map = Object.fromEntries(evaluateBackups({ present: true, data }, t, NOW).checks.map((c) => [c.name, c]));
    assert.equal(map.backup_logical.status, 'fail');
    assert.match(map.backup_logical.message, /alted/);
    assert.equal(map.backup_verify.status, 'fail');
  });

  test('verification uses VERIFY_MAX_AGE_HOURS (192 h)', () => {
    const data = statusFixture();
    data.verify.last_success = hoursAgo(100);
    data.verify.last_attempt = hoursAgo(100);
    assert.equal(evaluateBackups({ present: true, data }, t, NOW).checks.find((c) => c.name === 'backup_verify').status, 'ok');
    data.verify.last_success = hoursAgo(193);
    assert.equal(evaluateBackups({ present: true, data }, t, NOW).checks.find((c) => c.name === 'backup_verify').status, 'fail');
  });
});

describe('tls_cert', () => {
  const cert = (days) => ({ subject: 'CN=x', valid_from: '2026-01-01T00:00:00Z', valid_to: new Date(NOW.getTime() + days * 86_400_000).toISOString() });
  test('ok, warn and fail by days left', () => {
    assert.equal(evaluateCert(cert(20), t, NOW).status, 'ok');
    assert.equal(evaluateCert(cert(14), t, NOW).status, 'warn');
    assert.equal(evaluateCert(cert(3.5), t, NOW).status, 'warn');
    assert.equal(evaluateCert(cert(3), t, NOW).status, 'fail');
    assert.equal(evaluateCert(cert(-1), t, NOW).status, 'fail');
    assert.equal(evaluateCert(cert(20), t, NOW).value, 20);
  });
  test('an unreadable certificate fails; CERT_FILE="" leaves the check out', () => {
    assert.equal(evaluateCert({ file: '/certs/server.crt', error: 'missing' }, t, NOW).status, 'fail');
    const p = healthyProbes();
    p.cert = null;
    assert.equal(byName(buildReport(p, testConfig({ CERT_FILE: '' }), NOW)).tls_cert, undefined);
  });
});

describe('/healthz redaction', () => {
  test('only names and states leave the public endpoint', () => {
    const p = healthyProbes();
    p.postgres.error = 'SECRET-connection-detail';
    p.postgres.connected = false;
    p.backups.data.logical.last_error = 'SECRET pg_dump: password authentication failed';
    p.backups.data.logical.last_attempt = NOW.toISOString();
    const report = buildReport(p, cfg, NOW);
    const view = healthzView(report);

    assert.deepEqual(Object.keys(view).sort(), ['checks', 'status', 'time']);
    assert.equal(view.status, 'fail');
    assert.equal(view.time, NOW.toISOString());
    assert.deepEqual(Object.keys(view.checks), report.checks.map((c) => c.name));
    for (const state of Object.values(view.checks)) assert.ok(['ok', 'warn', 'fail'].includes(state));

    const json = JSON.stringify(view);
    assert.doesNotMatch(json, /SECRET|password|ECONN|alted|dropbox|message|value|\d+ (h|ms|min)/);
    // The only digits are in the timestamp.
    assert.equal(json.replace(view.time, '').match(/\d/), null);
  });
});

describe('activity section', () => {
  test('rows use database/user names and carry query text only when the probe selected it', () => {
    const p = healthyProbes();
    p.postgres.data.long_running = [{ pid: 7, datname: 'alted', usename: 'app', state: 'active', wait_event_type: null, wait_event: null, duration_basis: 'query', duration_seconds: 61.26, total: 1 }];
    p.postgres.data.blocked = [{ pid: 8, datname: 'alted', usename: 'app', state: 'active', wait_event_type: 'Lock', wait_event: 'relation', blocked_by: [7], blocked_seconds: 3.04, query: "SELECT '?'" }];
    const a = buildReport(p, cfg, NOW).activity;
    assert.deepEqual(a.long_running, { total: 1, sessions: [{ pid: 7, database: 'alted', user: 'app', state: 'active', wait_event_type: null, wait_event: null, duration_basis: 'query', duration_seconds: 61.3 }] });
    assert.equal('query' in a.long_running.sessions[0], false);
    assert.equal(a.blocked[0].query, "SELECT '?'");
    assert.deepEqual(a.blocked[0].blocked_by, [7]);
    assert.equal(a.query_text, 'omitted');
  });
});
