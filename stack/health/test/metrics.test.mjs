import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { CONTENT_TYPE, MetricWriter, escapeHelp, escapeLabelValue, formatValue, renderMetrics } from '../src/metrics.mjs';
import { buildReport } from '../src/report.mjs';
import { NOW, healthyProbes, testConfig, unreachableProbes } from './helpers.mjs';

const cfg = testConfig();

// One sample line of the 0.0.4 text format: name, optional {label="value",...}, value.
const SAMPLE = /^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\\n]|\\["\\n])*"(,[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\\n]|\\["\\n])*")*\})? (-?\d+(\.\d+)?(e[+-]?\d+)?|NaN|[+-]Inf)$/;

function assertWellFormed(text) {
  assert.ok(text.endsWith('\n'), 'ends with a newline');
  const seenHelp = new Set();
  const seenType = new Set();
  let current = null;
  const closed = new Set();
  for (const line of text.trimEnd().split('\n')) {
    if (line.startsWith('# HELP ')) {
      const name = line.split(' ')[2];
      assert.ok(!seenHelp.has(name), `HELP for ${name} appears once`);
      seenHelp.add(name);
      continue;
    }
    if (line.startsWith('# TYPE ')) {
      const [, , name, type] = line.split(' ');
      assert.ok(['gauge', 'counter'].includes(type));
      assert.ok(!seenType.has(name), `TYPE for ${name} appears once`);
      seenType.add(name);
      if (current) closed.add(current);
      current = name;
      continue;
    }
    assert.match(line, SAMPLE);
    const name = line.split(/[{ ]/)[0];
    assert.equal(name, current, `sample ${name} sits in its own family block`);
    assert.ok(!closed.has(name), `family ${name} is contiguous`);
  }
}

describe('escaping and formatting', () => {
  test('label values escape backslash, double quote and newline', () => {
    assert.equal(escapeLabelValue('plain'), 'plain');
    assert.equal(escapeLabelValue('a\\b'), 'a\\\\b');
    assert.equal(escapeLabelValue('say "hi"'), 'say \\"hi\\"');
    assert.equal(escapeLabelValue('line1\nline2'), 'line1\\nline2');
    assert.equal(escapeLabelValue('\\"\n'), '\\\\\\"\\n');
    assert.equal(escapeLabelValue(42), '42');
  });

  test('help text escapes backslash and newline only', () => {
    assert.equal(escapeHelp('a "b" \\ c\nd'), 'a "b" \\\\ c\\nd');
  });

  test('values: special floats and booleans', () => {
    assert.equal(formatValue(1.5), '1.5');
    assert.equal(formatValue(Number.NaN), 'NaN');
    assert.equal(formatValue(Infinity), '+Inf');
    assert.equal(formatValue(-Infinity), '-Inf');
    assert.equal(formatValue(true), '1');
  });

  test('writer groups families, skips missing values and rejects bad names', () => {
    const m = new MetricWriter();
    m.add('x_total', 'counter', 'X.', { a: '1' }, 3);
    m.add('y', 'gauge', 'Y.', {}, null);
    m.add('y', 'gauge', 'Y.', {}, undefined);
    m.add('x_total', 'counter', 'X.', { a: '2' }, '12345678901');
    m.add('z', 'gauge', 'Z.', {}, Number.NaN);
    const text = m.render();
    assert.equal(text, '# HELP x_total X.\n# TYPE x_total counter\nx_total{a="1"} 3\nx_total{a="2"} 12345678901\n# HELP z Z.\n# TYPE z gauge\nz NaN\n');
    assert.throws(() => m.add('bad-name', 'gauge', 'B.', {}, 1));
    assert.throws(() => m.add('ok_name', 'gauge', 'B.', { 'bad-label': 'x' }, 1));
  });
});

describe('renderMetrics', () => {
  test('healthy report: well-formed and carries the expected series', () => {
    const p = healthyProbes();
    p.pgbouncer = {
      probe: { ok: true, ms: 2, database: 'postgres', error: null },
      admin: { ok: true, error: null, version: 'PgBouncer 1.24.1', pools: [{ database: 'alted', user: 'alted_app', cl_active: 3, cl_waiting: 1, sv_active: 3, sv_idle: 2, maxwait: 1, maxwait_us: 500000 }], stats: [], lists: {}, config: {} },
    };
    const text = renderMetrics(buildReport(p, cfg, NOW));
    assertWellFormed(text);
    for (const line of [
      'cx_pg_up 1',
      'cx_pgbouncer_up 1',
      'cx_pg_connections{state="idle"} 8',
      'cx_pg_connections{state="active"} 2',
      'cx_pg_connection_utilisation_ratio 0.1',
      'cx_pg_database_size_bytes{datname="alted"} 1200000000',
      'cx_pg_database_cache_hit_ratio{datname="alted"} 0.998',
      'cx_pg_blocked_sessions 0',
      'cx_pg_archiver_failed_total 0',
      'cx_pg_archiver_last_archive_age_seconds 120',
      'cx_host_disk_used_ratio{path="/pgdata"} 0.4',
      'cx_host_load5 0.4',
      'cx_host_memory_available_bytes 5368709120',
      'cx_backup_age_seconds{kind="logical"} 21348',
      'cx_backup_age_seconds{kind="upload"} 20850',
      'cx_pgbouncer_pool_cl_waiting{database="alted",user="alted_app"} 1',
      'cx_pgbouncer_pool_maxwait_seconds{database="alted",user="alted_app"} 1.5',
      'cx_check_status{check="disk"} 0',
      'cx_check_status{check="pgbouncer_connect"} 0',
      'cx_health_status 0',
    ]) assert.ok(text.split('\n').includes(line), `missing: ${line}`);
    assert.match(text, /^cx_tls_cert_days_left 72\.\d$/m);
    // template databases are not in the per-database series, but do have an xid age
    assert.doesNotMatch(text, /cx_pg_database_size_bytes\{datname="template0"\}/);
    assert.match(text, /cx_pg_database_frozen_xid_age\{datname="template0"\} 6000000/);
  });

  test('check states map to 0/1/2', () => {
    const p = healthyProbes();
    p.host.disk.used_pct = 85;
    p.postgres.data.connections[0].count = 95;
    const text = renderMetrics(buildReport(p, cfg, NOW));
    assert.match(text, /^cx_check_status\{check="disk"\} 1$/m);
    assert.match(text, /^cx_check_status\{check="connections"\} 2$/m);
    assert.match(text, /^cx_health_status 2$/m);
  });

  test('awkward database names are escaped in labels', () => {
    const p = healthyProbes();
    p.postgres.data.databases[1].datname = 'we"ird\\db\nname';
    const text = renderMetrics(buildReport(p, cfg, NOW));
    assertWellFormed(text);
    assert.ok(text.includes('cx_pg_database_numbackends{datname="we\\"ird\\\\db\\nname"} 1'));
  });

  test('PostgreSQL unreachable: up is 0 and no database series are invented', () => {
    const text = renderMetrics(buildReport(unreachableProbes(), cfg, NOW));
    assertWellFormed(text);
    assert.match(text, /^cx_pg_up 0$/m);
    assert.doesNotMatch(text, /cx_pg_database_size_bytes|cx_pg_connections\{/);
    assert.match(text, /^cx_check_status\{check="postgres_connect"\} 2$/m);
    assert.match(text, /^cx_host_disk_used_ratio/m);
  });

  test('content type is the 0.0.4 text format', () => {
    assert.equal(CONTENT_TYPE, 'text/plain; version=0.0.4; charset=utf-8');
  });
});
