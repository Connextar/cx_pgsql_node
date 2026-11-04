// Runs the real server with PostgreSQL pointed at a closed port: checks routing, auth, headers,
// redaction, that a database outage does not crash the process, and graceful SIGTERM shutdown.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const fixture = (name) => fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));
const TOKEN = 'http-test-token-6b1f0c2a9d8e7f65';

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function startServer(extraEnv) {
  const port = await freePort();
  const closedPort = await freePort();
  const env = {
    PATH: process.env.PATH,
    HEALTH_HOST: '127.0.0.1',
    HEALTH_PORT: String(port),
    PG_HOST: '127.0.0.1',
    PG_PORT: String(closedPort),
    PG_PASSWORD: 'not-a-real-password',
    PGBOUNCER_ENABLED: 'false',
    BACKUP_STATUS_FILE: fixture('status.json'),
    CERT_FILE: fixture('cert.pem'),
    DATA_DIR: root,
    CACHE_SECONDS: '0', // recompute on every request, so the once-per-occurrence logging is exercised
    ...extraEnv,
  };
  const child = spawn(process.execPath, ['server.mjs'], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  child.stdout.on('data', (d) => { output += d; });
  child.stderr.on('data', (d) => { output += d; });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`server did not start:\n${output}`)), 5000);
    const check = () => {
      if (output.includes('listening on')) { clearTimeout(timer); resolve(); }
    };
    child.stdout.on('data', check);
    child.once('exit', (code) => reject(new Error(`server exited ${code}:\n${output}`)));
  });
  return { child, base: `http://127.0.0.1:${port}`, output: () => output };
}

let srv;
before(async () => { srv = await startServer({ HEALTH_TOKEN: TOKEN }); });
after(() => { if (srv.child.exitCode === null) srv.child.kill('SIGKILL'); });

const auth = { authorization: `Bearer ${TOKEN}` };

test('/healthz answers 503 with names and states only when PostgreSQL is down', async () => {
  const res = await fetch(`${srv.base}/healthz`);
  assert.equal(res.status, 503);
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  const body = await res.json();
  assert.deepEqual(Object.keys(body).sort(), ['checks', 'status', 'time']);
  assert.equal(body.status, 'fail');
  assert.equal(body.checks.postgres_connect, 'fail');
  assert.equal(body.checks.tls_cert, 'ok');
  assert.equal(body.checks.backup_logical !== undefined, true);
  assert.doesNotMatch(JSON.stringify(body), /ECONNREFUSED|127\.0\.0\.1|message/);
});

test('HEAD /healthz: same status and headers, no body', async () => {
  const res = await fetch(`${srv.base}/healthz`, { method: 'HEAD' });
  assert.equal(res.status, 503);
  assert.equal(res.headers.get('content-type'), 'application/json; charset=utf-8');
  assert.equal(await res.text(), '');
});

test('/status and /metrics need the bearer token; a query-string token is ignored', async () => {
  for (const path of ['/status', '/metrics']) {
    let res = await fetch(`${srv.base}${path}`);
    assert.equal(res.status, 401, path);
    assert.match(res.headers.get('www-authenticate'), /^Bearer/);
    res = await fetch(`${srv.base}${path}?token=${TOKEN}&access_token=${TOKEN}`);
    assert.equal(res.status, 401, `${path} with query token`);
    res = await fetch(`${srv.base}${path}`, { headers: { authorization: `Bearer ${TOKEN}x` } });
    assert.equal(res.status, 401, `${path} with wrong token`);
    res = await fetch(`${srv.base}${path}`, { headers: { authorization: `Basic ${Buffer.from(`u:${TOKEN}`).toString('base64')}` } });
    assert.equal(res.status, 401, `${path} with basic auth`);
  }
});

test('/status with the token: full report, process still up while PostgreSQL is down', async () => {
  const res = await fetch(`${srv.base}/status`, { headers: auth });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const body = await res.json();
  assert.equal(body.status, 'fail');
  const pgCheck = body.checks.find((c) => c.name === 'postgres_connect');
  assert.equal(pgCheck.status, 'fail');
  assert.match(pgCheck.message, /ECONNREFUSED/);
  assert.equal(body.backups.status.upload.destination, 'dropbox:CX_PGSQL_Node_1');
  assert.match(body.tls.subject, /db\.example\.test/);
  assert.ok(body.host.disk.total_bytes > 0);
  assert.equal(body.pgbouncer.enabled, false);
});

test('/metrics with the token: Prometheus text', async () => {
  const res = await fetch(`${srv.base}/metrics`, { headers: auth });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'text/plain; version=0.0.4; charset=utf-8');
  const text = await res.text();
  assert.match(text, /^cx_pg_up 0$/m);
  assert.match(text, /^cx_check_status\{check="postgres_connect"\} 2$/m);
  assert.match(text, /^cx_tls_cert_days_left \d+/m);
});

test('unknown paths 404, other methods 405', async () => {
  let res = await fetch(`${srv.base}/nope`);
  assert.equal(res.status, 404);
  assert.deepEqual(await res.json(), { error: 'not found' });
  res = await fetch(`${srv.base}/healthz/`);
  assert.equal(res.status, 404);
  for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
    res = await fetch(`${srv.base}/healthz`, { method });
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get('allow'), 'GET, HEAD');
  }
});

test('without a configured token /status and /metrics answer 503 "not configured"', async () => {
  const other = await startServer({});
  try {
    for (const path of ['/status', '/metrics']) {
      const res = await fetch(`${other.base}${path}`, { headers: auth });
      assert.equal(res.status, 503);
      assert.deepEqual(await res.json(), { error: 'not configured' });
    }
    assert.equal((await fetch(`${other.base}/healthz`)).status, 503);
  } finally {
    other.child.kill('SIGKILL');
  }
});

test('/maintenance.json: public, CORS, served while PostgreSQL is down; missing file empty, unreadable 503', async () => {
  const { mkdtempSync, writeFileSync, rmSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const dir = mkdtempSync(join(tmpdir(), 'cx-maint-'));
  const file = join(dir, 'windows.json');
  const starts = new Date(Date.now() + 3_600_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const ends = new Date(Date.now() + 4_500_000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  writeFileSync(file, JSON.stringify({ version: 1, windows: [{ id: 'reboot-t', kind: 'reboot', starts_at: starts, ends_by: ends, expected_minutes: 2, affects: ['postgres'], packages: ['linux-image-x'], reason: 'secret reason' }] }));
  const m = await startServer({ MAINTENANCE_FILE: file, SERVER_NAME: 'db-test' });
  try {
    const res = await fetch(`${m.base}/maintenance.json`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('access-control-allow-origin'), '*');
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const body = await res.json();
    assert.equal(body.server, 'db-test');
    assert.deepEqual(body.windows.map((w) => [w.id, w.state]), [['reboot-t', 'planned']]);
    assert.doesNotMatch(JSON.stringify(body), /linux-image|secret reason/);

    writeFileSync(file, '{broken');
    assert.equal((await fetch(`${m.base}/maintenance.json`)).status, 503);
    rmSync(file);
    const empty = await fetch(`${m.base}/maintenance.json`);
    assert.equal(empty.status, 200);
    assert.deepEqual((await empty.json()).windows, []);
  } finally {
    m.child.kill('SIGKILL');
    rmSync(dir, { recursive: true, force: true });
  }
});

test('logs: one line per request, no token, probe error logged once; SIGTERM exits 0 within 5s', async () => {
  for (let i = 0; i < 3; i++) await fetch(`${srv.base}/healthz`);
  const exited = new Promise((resolve) => srv.child.once('exit', (code, signal) => resolve({ code, signal })));
  const t0 = Date.now();
  srv.child.kill('SIGTERM');
  const { code } = await exited;
  assert.equal(code, 0);
  assert.ok(Date.now() - t0 < 5000);

  const out = srv.output();
  assert.doesNotMatch(out, new RegExp(TOKEN));
  assert.doesNotMatch(out, /not-a-real-password/);
  assert.match(out, /http GET \/healthz 503 [\d.]+ms/);
  assert.match(out, /http GET \/status 401 [\d.]+ms/); // path only, no query string
  assert.equal(out.match(/probe postgres error/g)?.length, 1, out);
  assert.match(out, /received SIGTERM/);
  assert.match(out, /stopped/);
});
