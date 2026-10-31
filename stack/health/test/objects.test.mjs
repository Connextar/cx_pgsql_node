import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { loadConfig, ConfigError } from '../src/config.mjs';
import { probeObjects } from '../src/probes.mjs';
import { buildReport, evaluateBackups, evaluateObjects, healthzView } from '../src/report.mjs';
import { renderMetrics } from '../src/metrics.mjs';
import { NOW, byName, healthyProbes, statusFixture, testConfig } from './helpers.mjs';

const cfg = testConfig();
const t = cfg.thresholds;
const hoursAgo = (h) => new Date(NOW.getTime() - h * 3_600_000).toISOString();
const healthy = { url: 'http://cx-pgsql-objects:3903/health', http_status: 200, response_ms: 1.2 };

function statusWithObjects(extra = {}) {
  return {
    ...statusFixture(),
    objects: { measured: hoursAgo(0.5), capacity_bytes: 40e9, bytes: 4e9, objects: 2027, buckets: {} },
    objects_backup: { enabled: true, destination: 'dropbox:CX/objects (rclone crypt)', last_attempt: hoursAgo(0.5), last_success: hoursAgo(0.5), last_error: null },
    ...extra,
  };
}

describe('object store configuration', () => {
  test('off unless OBJECTS_HEALTH_URL is set; thresholds validated', () => {
    assert.equal(loadConfig({}).objects.healthUrl, '');
    assert.equal(loadConfig({ OBJECTS_HEALTH_URL: 'http://cx-pgsql-objects:3903/health' }).objects.healthUrl, 'http://cx-pgsql-objects:3903/health');
    assert.throws(() => loadConfig({ OBJECTS_HEALTH_URL: 'not a url' }), ConfigError);
    assert.throws(() => loadConfig({ WARN_OBJECTS_CAPACITY_PCT: '95', FAIL_OBJECTS_CAPACITY_PCT: '90' }), ConfigError);
  });
});

describe('evaluateObjects', () => {
  test('healthy, a tenth full, copied half an hour ago: all ok', () => {
    const { checks, section } = evaluateObjects(healthy, statusWithObjects(), t, NOW);
    assert.deepEqual(checks.map((c) => [c.name, c.status]), [['objects', 'ok'], ['objects_capacity', 'ok'], ['backup_objects', 'ok']]);
    assert.equal(section.used_pct, 10);
  });

  test('unreachable or unhealthy Garage fails', () => {
    assert.equal(evaluateObjects({ url: healthy.url, error: 'ECONNREFUSED' }, statusWithObjects(), t, NOW).checks[0].status, 'fail');
    const c = evaluateObjects({ url: healthy.url, http_status: 503, response_ms: 2 }, statusWithObjects(), t, NOW).checks[0];
    assert.equal(c.status, 'fail');
    assert.match(c.message, /HTTP 503/);
  });

  test('capacity warns at 50% and fails at 90%, with the advice', () => {
    const at = (bytes) => byName({ checks: evaluateObjects(healthy, statusWithObjects({ objects: { capacity_bytes: 100, bytes, objects: 1 } }), t, NOW).checks }).objects_capacity;
    assert.equal(at(49).status, 'ok');
    assert.equal(at(50).status, 'warn');
    assert.match(at(50).message, /add disk/);
    assert.equal(at(90).status, 'fail');
    const { checks } = evaluateObjects(healthy, { ...statusFixture() }, t, NOW);
    assert.equal(byName({ checks }).objects_capacity.status, 'warn');
  });

  test('off-site copy: stale fails, failed fails, switched off warns, never run warns', () => {
    const copy = (objects_backup) => byName({ checks: evaluateObjects(healthy, statusWithObjects({ objects_backup }), t, NOW).checks }).backup_objects;
    assert.equal(copy({ enabled: true, last_attempt: hoursAgo(4), last_success: hoursAgo(4) }).status, 'fail');
    assert.equal(copy({ enabled: true, last_attempt: hoursAgo(0.1), last_success: hoursAgo(1.1), last_error: 'failed: alted-uploads' }).status, 'fail');
    assert.equal(copy({ enabled: false }).status, 'warn');
    assert.equal(copy(undefined).status, 'warn');
  });

  test('a bucket that failed the restore test fails backup_verify', () => {
    const data = statusFixture();
    data.verify = { ...data.verify, objects: { 'alted-uploads': { checked: 10, restored: 10, ok: false } } };
    const v = byName({ checks: evaluateBackups({ path: '/s.json', present: true, data }, t, NOW).checks }).backup_verify;
    assert.equal(v.status, 'fail');
    assert.match(v.message, /bucket alted-uploads/);
    data.verify.objects = { 'deleted/': { read: 3, ok: false } };
    const d = byName({ checks: evaluateBackups({ path: '/s.json', present: true, data }, t, NOW).checks }).backup_verify;
    assert.match(d.message, /deleted objects/);
  });
});

describe('the report and metrics with an object store', () => {
  test('checks appear only when enabled; /healthz names them; metrics carry the sizes', () => {
    const off = buildReport(healthyProbes(), cfg, NOW);
    assert.equal(off.checks.some((c) => c.name.startsWith('objects') || c.name === 'backup_objects'), false);
    assert.deepEqual(off.objects, { enabled: false });

    const probes = { ...healthyProbes(), objects: healthy };
    probes.backups = { ...probes.backups, data: statusWithObjects() };
    const on = buildReport(probes, cfg, NOW);
    assert.equal(on.status, 'ok', JSON.stringify(on.checks.filter((c) => c.status !== 'ok')));
    const names = Object.keys(healthzView(on).checks);
    for (const n of ['objects', 'objects_capacity', 'backup_objects']) assert.ok(names.includes(n), n);
    const text = renderMetrics(on);
    assert.match(text, /^cx_objects_up 1$/m);
    assert.match(text, /^cx_objects_bytes 4000000000$/m);
    assert.match(text, /^cx_backup_age_seconds\{kind="objects"\} 1800$/m);
  });
});

describe('probeObjects', () => {
  test('reports the HTTP status and a refused connection', async () => {
    const server = createServer((req, res) => { res.statusCode = req.url === '/health' ? 200 : 503; res.end('x'); });
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const { port } = server.address();
    try {
      assert.equal((await probeObjects(`http://127.0.0.1:${port}/health`)).http_status, 200);
      assert.equal((await probeObjects(`http://127.0.0.1:${port}/nope`)).http_status, 503);
    } finally {
      await new Promise((r) => server.close(r));
    }
    assert.ok((await probeObjects(`http://127.0.0.1:${port}/health`)).error);
  });
});
