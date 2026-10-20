// The file readers on real fixture files: they must never throw, whatever is on disk.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { readBackupStatus, readCertificate } from '../src/probes.mjs';
import { evaluateBackups } from '../src/report.mjs';
import { NOW, testConfig } from './helpers.mjs';

const fixture = (name) => fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));
const t = testConfig().thresholds;

test('a valid status file is read as an object', async () => {
  const r = await readBackupStatus(fixture('status.json'));
  assert.equal(r.present, true);
  assert.equal(r.error, undefined);
  assert.equal(r.data.physical.last_type, 'diff');
  assert.equal(r.path, fixture('status.json'));
});

test('a garbled status file is reported, not thrown, and warns', async () => {
  const r = await readBackupStatus(fixture('garbled.json'));
  assert.equal(r.present, true);
  assert.match(r.error, /^not valid JSON/);
  const sf = evaluateBackups(r, t, NOW).checks.find((c) => c.name === 'status_file');
  assert.equal(sf.status, 'warn');
  assert.match(sf.message, /not valid JSON/);
});

test('a missing status file and a JSON non-object are reported', async () => {
  const missing = await readBackupStatus(fixture('does-not-exist.json'));
  assert.deepEqual({ present: missing.present, error: missing.error }, { present: false, error: 'missing' });
  const notObject = await readBackupStatus(fixture('token.txt')); // not JSON at all
  assert.match(notObject.error, /not valid JSON/);
  const directory = await readBackupStatus(fixture(''));
  assert.match(directory.error, /^unreadable|not valid JSON/);
});

test('the certificate reader extracts subject and dates; a missing file is an error', async () => {
  const c = await readCertificate(fixture('cert.pem'));
  assert.match(c.subject, /CN=db\.example\.test/);
  assert.deepEqual(c.subject_alt_names, ['DNS:db.example.test']);
  assert.ok(Date.parse(c.valid_to) > Date.parse(c.valid_from));
  assert.deepEqual(await readCertificate(fixture('nope.pem')), { file: fixture('nope.pem'), error: 'missing' });
  assert.match((await readCertificate(fixture('status.json'))).error, /^unreadable/);
});
