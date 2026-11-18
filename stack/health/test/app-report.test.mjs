import { test } from 'node:test';
import assert from 'node:assert/strict';

import { joinLogLines, maskAppMessage, parseDetail, parseLogEntry, summariseAppLog, eventSeverity } from '../src/app-report.mjs';
import { buildDigest, digestText } from '../src/digest.mjs';
import { digestHtml } from '../src/digest-html.mjs';

const NOW = new Date('2026-11-19T06:00:00Z');
const SID = 'CA0123456789abcdef0123456789abcdef';

/** The voice relay's real output (cx-house's startRelay and cx-support's IntakeSession), as `docker logs` gives it. */
const RELAY_STDOUT = [
  '[voice-relay] 0.2.0 d0f33fa listening on :8787 (ws path /relay), agent API https://support.connextar.com, dialog model Anthropic claude-sonnet-5, Twilio upgrade signature enforce, effort low',
  "[voice-relay] upgrade_signature_invalid { mode: 'enforce', presented: false }",
  "[voice-relay] upgrade_signature_invalid { mode: 'enforce', presented: false }",
  `[voice-relay] call_started { callSid: '${SID}' }`,
  `[voice-relay] tool { callSid: '${SID}', name: 'transfer_to_team', kind: 'ok' }`,
  `[voice-relay] call_started { callSid: '${SID.replace('0', '1')}' }`,
  '[voice-relay] model_error {',
  `  callSid: '${SID}',`,
  "  message: 'Caller said: my number is +44 7700 900123 and I want to cancel'",
  '}',
  `[voice-relay] refused_tenant_busy { callSid: '${SID}', open: 20 }`,
  `[voice-relay] call_ended { callSid: '${SID}', outcome: 'TRANSFERRED', durationSeconds: 84, modelRequests: 6, caller: '+447700900123' }`,
  `[voice-relay] call_ended { callSid: '${SID}', outcome: 'ABANDONED', durationSeconds: 12, modelRequests: 1 }`,
];
const RELAY_STDERR = [
  'Error: connect ECONNREFUSED 10.0.0.5:443 while posting to https://support.connextar.com/api/voice/calls/abc?token=xyz',
  '    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1611:16)',
];

export function relayApp(overrides = {}) {
  return {
    name: 'cx-support-relay',
    fqdn: 'relay-support.connextar.com',
    websocket: true,
    health_path: '/healthz',
    container: {
      id: 'a6b1e9f27c7ee4d535fb5387e4829cf0caa634673d48b6dfca53c93b56a6c927',
      state: 'running', health: 'healthy', failing_streak: 0, health_output: '',
      started_at: '2026-11-18T14:05:43.73301543Z', restarts: 0, oom_killed: false, exit_code: 0,
      image: 'cx-app/cx-support-relay:d0f33fa8dbb9', commit: 'd0f33fa8dbb99dea0ba6f30f579357c1379100e5', nano_cpus: 1e9, memory_limit: 536870912,
    },
    resources: { memory_bytes: 24_899_584, memory_peak_bytes: 40_083_456, memory_limit_bytes: 536_870_912, cpu_usec: 19_059_568, oom_kills: 0, pids: 8 },
    disk: { logs_bytes: 7511, images_bytes: 328_452_555, images: 1 },
    endpoint: { url: 'https://relay-support.connextar.com/healthz', code: 200, seconds: 0.02, body: 'ok 0.2.0 d0f33fa', error: null },
    tls: { not_after: '2027-02-16T13:05:57Z', issuer: "Let's Encrypt", self_signed: false },
    static: { published: true, files: [{ path: '/fallback.xml', get: 200, post: 200, type: 'text/xml' }] },
    nginx: {
      requests: 131, status: { 101: 3, 200: 16, 403: 2, 404: 61, 502: 0 },
      upgrades: { total: 5, status: { 101: 3, 403: 2 } },
      sessions: { count: 3, timed: 3, total_s: 300, max_s: 200.5, at_timeout: 0 },
      health_requests: 16, health_5xx: 0,
    },
    log: { ok: true, stdout: { lines: RELAY_STDOUT.length, text: RELAY_STDOUT }, stderr: { lines: RELAY_STDERR.length, text: RELAY_STDERR } },
    ...overrides,
  };
}

function input(apps, previous = null) {
  return {
    generated_at: NOW.toISOString(),
    server: { hostname: 'db-1', fqdn: 'db-1.example.test' },
    config: { timezone: 'Europe/London' },
    status: { status: 'ok', checks: [{ name: 'postgres_connect', status: 'ok', message: 'ok' }] },
    host: {},
    sql: {},
    apps,
    previous,
  };
}

const issuesOf = (d, area = 'cx-support-relay') => d.issues.filter((i) => i.area === area);

test('a multi-line object and a stack trace are joined back to the line they belong to', () => {
  const entries = joinLogLines([...RELAY_STDOUT, ...RELAY_STDERR]);
  assert.equal(entries.length, RELAY_STDOUT.length - 3 + 1);
  assert.match(entries[6], /^\[voice-relay\] model_error \{\n {2}callSid/);
  assert.match(entries.at(-1), /^Error: connect ECONNREFUSED.*\n {4}at TCPConnectWrap/);
});

test("events keep their name, numbers and enum values, never an id, a number in a free-text field or anyone's words", () => {
  assert.deepEqual(parseDetail("{ mode: 'enforce', presented: false, open: 20 }"), [['mode', 'enforce'], ['presented', false], ['open', 20]]);
  const e = parseLogEntry(`[voice-relay] call_ended { callSid: '${SID}', outcome: 'TRANSFERRED', durationSeconds: 84, caller: '+447700900123', name: 'Jane' }`);
  assert.equal(e.event, 'call_ended');
  assert.deepEqual(e.numbers, { durationSeconds: 84 });
  assert.deepEqual(e.values, { outcome: 'TRANSFERRED' });
  const err = parseLogEntry(joinLogLines(RELAY_STDOUT)[6]);
  assert.equal(err.event, 'model_error');
  assert.deepEqual(err.values, {}, 'the message (which here quotes the caller) is dropped');
  assert.equal(eventSeverity('upgrade_signature_invalid'), 'warn');
  assert.equal(eventSeverity('log_call_failed'), 'error');
  assert.equal(eventSeverity('call_started'), 'info');
});

test('other lines are masked before they can leave the server', () => {
  const m = maskAppMessage(RELAY_STDERR[0]);
  assert.equal(m, 'Error: connect ECONNREFUSED <ip> while posting to https://support.connextar.com/…');
  assert.equal(maskAppMessage(`call ${SID} from +44 7700 900123 <a@b.co> said "cancel it" at 12:30`), 'call <sid> from <number> <<email>> said ? at N:N');
  const e = parseLogEntry('TypeError: Cannot read properties of undefined (reading \'x\')', 'stdout');
  assert.equal(e.severity, 'error');
  assert.equal(parseLogEntry('something happened', 'stderr').severity, 'error', 'stderr is an error unless it says warn');
});

test('the log summary counts entries and events, with the top errors first', () => {
  const s = summariseAppLog(relayApp().log);
  assert.equal(s.lines, RELAY_STDOUT.length + RELAY_STDERR.length);
  assert.equal(s.errors, 2, 'model_error and the ECONNREFUSED crash');
  assert.equal(s.warnings, 3, 'two invalid signatures, one tenant busy');
  const byName = Object.fromEntries(s.events.map((e) => [e.name, e]));
  assert.equal(byName.call_started.count, 2);
  assert.deepEqual(byName.call_ended.numbers.durationSeconds, { count: 2, sum: 96, max: 84, avg: 48 });
  assert.deepEqual(byName.call_ended.values.outcome, { TRANSFERRED: 1, ABANDONED: 1 });
  assert.equal(s.top[0].severity, 'error');
  assert.ok(!JSON.stringify(s).includes('7700'), 'no phone number survives');
  assert.ok(!JSON.stringify(s).includes(SID), 'no call id survives');
  assert.ok(!JSON.stringify(s).includes('cancel'), "no caller's words survive");
});

test('a healthy relay adds a section and no warning; the email names it', () => {
  const d = buildDigest(input([relayApp()]), NOW);
  assert.equal(d.status, 'ok', JSON.stringify(d.issues));
  assert.deepEqual(issuesOf(d).map((i) => i.severity).sort(), ['info', 'info'], 'two log errors and two refused upgrades are notes');
  const a = d.model.apps[0];
  assert.equal(a.version, '0.2.0 d0f33fa');
  assert.equal(a.traffic.sessions.count, 3);
  assert.equal(a.traffic.sessions.avg_s, 100);
  assert.equal(a.traffic.upgrades.refused, 2);
  assert.equal(a.tls.days_left, 89);
  assert.equal(a.resources.cpu_basis, 'start');
  assert.deepEqual(d.snapshot.apps['cx-support-relay'], { id: relayApp().container.id, restarts: 0, cpu_usec: 19_059_568, oom_kills: 0, errors: 2 });
  const html = digestHtml(d);
  const text = digestText(d);
  for (const out of [html, text]) {
    assert.match(out, /cx-support-relay/);
    assert.match(out, /fallback\.xml/);
    assert.match(out, /WebSocket sessions/);
    assert.ok(!out.includes(SID) && !out.includes('7700 900123') && !out.includes('cancel'), 'nothing private in the email');
  }
  assert.match(html, /Apps \(1\)/);
});

test('down, restarted, near its certificate expiry and without its fallback: each is flagged at the top', () => {
  const prev = { at: '2026-11-18T06:00:00Z', apps: { 'cx-support-relay': { id: relayApp().container.id, restarts: 1, cpu_usec: 1_000_000, oom_kills: 0, errors: 0 } } };
  const app = relayApp({
    container: { ...relayApp().container, health: 'unhealthy', failing_streak: 4, health_output: 'fetch failed', restarts: 3 },
    endpoint: { url: 'https://relay-support.connextar.com/healthz', code: 502, seconds: 0.01, body: null, error: null },
    tls: { not_after: '2026-12-01T00:00:00Z', issuer: "Let's Encrypt", self_signed: false },
    static: { published: true, files: [{ path: '/fallback.xml', get: 404, post: 404, type: 'text/html' }] },
    nginx: { ...relayApp().nginx, upgrades: { total: 7, status: { 101: 3, 403: 2, 502: 2 } } },
  });
  const d = buildDigest(input([app], prev), NOW);
  assert.equal(d.status, 'fail');
  const texts = issuesOf(d).map((i) => `${i.severity}: ${i.text}`);
  assert.ok(texts.some((t) => /^warn: The container is unhealthy \(4 failed checks in a row\): fetch failed/.test(t)), texts.join('\n'));
  assert.ok(texts.some((t) => /^warn: Docker restarted it 2 times/.test(t)));
  assert.ok(texts.some((t) => /^fail: https:\/\/relay-support\.connextar\.com\/healthz answered 502/.test(t)));
  assert.ok(texts.some((t) => /^warn: The certificate for relay-support\.connextar\.com expires in 11 days/.test(t)));
  assert.ok(texts.some((t) => /^fail: \/fallback\.xml isn't served \(GET 404, POST 404\)/.test(t)));
  assert.ok(texts.some((t) => /^warn: 2 WebSocket connections failed at nginx/.test(t)));
  assert.ok(texts.some((t) => /^warn: 2 errors in its log \(0 in the period before\)/.test(t)) === false, 'two errors are under the spike threshold');
  assert.equal(d.model.apps[0].resources.cpu_basis, 'period');
  assert.equal(d.model.apps[0].container.restart_delta, 2);
  assert.match(d.subject, /^❌ db-1: \d+ problems?/);
  assert.equal(d.issues[0].severity, 'fail', 'problems lead the email');
});

test('an error spike is a warning; the same count on a day that always has it is a note', () => {
  const many = Array.from({ length: 12 }, () => `[voice-relay] model_error { callSid: '${SID}', message: 'overloaded' }`);
  const app = relayApp({ log: { ok: true, stdout: { lines: 12, text: many }, stderr: { lines: 0, text: [] } } });
  const spike = buildDigest(input([app], { at: '2026-11-18T06:00:00Z', apps: { 'cx-support-relay': { id: 'x', errors: 2 } } }), NOW);
  assert.ok(issuesOf(spike).some((i) => i.severity === 'warn' && /^12 errors in its log \(2 in the period before\), most often \(12×\): model_error/.test(i.text)));
  const usual = buildDigest(input([app], { at: '2026-11-18T06:00:00Z', apps: { 'cx-support-relay': { id: 'x', errors: 10 } } }), NOW);
  assert.ok(issuesOf(usual).some((i) => i.severity === 'info' && /^12 errors in its log/.test(i.text)));
});

test('no container, a redeploy, and an app the host could not look at', () => {
  const gone = buildDigest(input([relayApp({ container: null, resources: null, log: null })]), NOW);
  assert.ok(issuesOf(gone).some((i) => i.severity === 'fail' && /There is no container/.test(i.text)));
  const prev = { at: '2026-11-18T06:00:00Z', apps: { 'cx-support-relay': { id: 'old', restarts: 5, cpu_usec: 1, errors: 0 } } };
  const redeployed = buildDigest(input([relayApp()], prev), NOW);
  assert.ok(issuesOf(redeployed).some((i) => i.severity === 'info' && /^Redeployed: now d0f33fa/.test(i.text)));
  assert.equal(redeployed.model.apps[0].container.restart_delta, 0, "a new container's restarts are its own");
  const broken = buildDigest(input([{ name: 'other', fqdn: 'o.example.test', error: 'its facts could not be gathered' }]), NOW);
  assert.ok(issuesOf(broken, 'other').some((i) => i.severity === 'warn'));
  assert.match(digestHtml(broken), /Not gathered/);
});

test('no apps: no section, no tile, nothing in the snapshot', () => {
  const d = buildDigest(input([]), NOW);
  assert.deepEqual(d.model.apps, []);
  assert.deepEqual(d.snapshot.apps, {});
  assert.doesNotMatch(digestHtml(d), /Apps \(/);
});
