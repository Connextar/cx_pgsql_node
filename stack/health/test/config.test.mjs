import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { ConfigError, describeConfig, loadConfig } from '../src/config.mjs';

const tokenFile = fileURLToPath(new URL('./fixtures/token.txt', import.meta.url));

test('defaults match the documented values', () => {
  const cfg = loadConfig({});
  assert.equal(cfg.port, 8080);
  assert.equal(cfg.token, undefined);
  assert.deepEqual(cfg.pg, { host: 'postgres', port: 5432, database: 'postgres', user: 'cx_monitor', password: undefined });
  assert.deepEqual(cfg.pgbouncer, { enabled: true, host: 'pgbouncer', port: 6432, probeDatabase: 'postgres' });
  assert.equal(cfg.backupStatusFile, '/backups/status/status.json');
  assert.equal(cfg.certFile, '/certs/server.crt');
  assert.equal(cfg.dataDir, '/pgdata');
  assert.deepEqual(cfg.thresholds, {
    warnConnPct: 70, failConnPct: 90, warnDiskPct: 80, failDiskPct: 90, longQuerySeconds: 60, warnBlockedSeconds: 30,
    backupMaxAgeHours: 26, uploadMaxAgeHours: 26, verifyMaxAgeHours: 192, walArchiveMaxAgeMinutes: 30,
    certWarnDays: 14, certFailDays: 3, minCacheHitPct: 90,
    objectsBackupMaxAgeHours: 3, warnObjectsCapacityPct: 50, failObjectsCapacityPct: 90,
    reportMaxAgeHours: 50,
  });
  assert.deepEqual(cfg.objects, { healthUrl: '' });
  assert.deepEqual(cfg.maintenance, { file: '/maintenance/windows.json', server: 'cx-pgsql' });
  assert.equal(cfg.cacheSeconds, 15);
  assert.equal(cfg.includeQueryText, false);
});

test('empty values (as compose passes unset ${VARS}) fall back to defaults', () => {
  const cfg = loadConfig({ LONG_QUERY_SECONDS: '', STATUS_INCLUDE_QUERY_TEXT: '', PG_HOST: '' });
  assert.equal(cfg.thresholds.longQuerySeconds, 60);
  assert.equal(cfg.includeQueryText, false);
  assert.equal(cfg.pg.host, 'postgres');
});

test('_FILE secrets are read and lose their trailing newline', () => {
  const cfg = loadConfig({ HEALTH_TOKEN_FILE: tokenFile, PG_PASSWORD_FILE: tokenFile });
  assert.equal(cfg.token, 'fixture-token-0123456789abcdef');
  assert.equal(cfg.pg.password, 'fixture-token-0123456789abcdef');
});

test('invalid values are rejected with every problem listed', () => {
  assert.throws(
    () => loadConfig({ HEALTH_PORT: 'eighty', WARN_DISK_PCT: '95', STATUS_INCLUDE_QUERY_TEXT: 'maybe', HEALTH_TOKEN: 'a', HEALTH_TOKEN_FILE: tokenFile, PG_PASSWORD_FILE: '/nonexistent/pw' }),
    (err) => {
      assert.ok(err instanceof ConfigError);
      const text = err.problems.join('\n');
      assert.match(text, /HEALTH_PORT/);
      assert.match(text, /WARN_DISK_PCT must not exceed FAIL_DISK_PCT/);
      assert.match(text, /STATUS_INCLUDE_QUERY_TEXT/);
      assert.match(text, /only one of HEALTH_TOKEN and HEALTH_TOKEN_FILE/);
      assert.match(text, /PG_PASSWORD_FILE: cannot read/);
      return true;
    },
  );
  assert.throws(() => loadConfig({ FAIL_CONN_PCT: '101' }), ConfigError);
  assert.throws(() => loadConfig({ CERT_FAIL_DAYS: '30' }), /CERT_FAIL_DAYS must not exceed CERT_WARN_DAYS/);
});

test('booleans, CERT_FILE="" and the secret-free summary', () => {
  const cfg = loadConfig({ PGBOUNCER_ENABLED: 'false', STATUS_INCLUDE_QUERY_TEXT: 'yes', CERT_FILE: '', HEALTH_TOKEN: 'sekrit-value', PG_PASSWORD: 'pw-value' });
  assert.equal(cfg.pgbouncer.enabled, false);
  assert.equal(cfg.includeQueryText, true);
  assert.equal(cfg.certFile, '');
  const summary = describeConfig(cfg);
  assert.doesNotMatch(summary, /sekrit|pw-value/);
  assert.match(summary, /token=set/);
});
