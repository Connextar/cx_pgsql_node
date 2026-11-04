import { test } from 'node:test';
import assert from 'node:assert/strict';

import { expectedDowntime, rebootNotice } from '../src/notice.mjs';

const NOW = new Date('2026-11-04T11:30:00Z');
const base = (notice) => ({
  server: { hostname: 'db-1' },
  timezone: 'Europe/London',
  notice: { mode: 'reboot', at: '2026-11-04T23:00:00Z', packages: ['linux-image-6.12.115'], last_reboot: { at: '2026-10-30T17:59:17Z', offline_seconds: 5 }, databases: ['app'], objects: true, ...notice },
});

test('a booked reboot says when, for how long, why, and what goes down', () => {
  const n = rebootNotice(base({ kind: 'booked' }), NOW);
  assert.equal(n.subject, '🔁 db-1 reboots Wed 4 Nov 2026, 23:00 GMT — about 2 minutes down');
  for (const bit of ['A reboot is booked for Wed 4 Nov 2026, 23:00 GMT.', 'about 2 minutes', 'offline for 5 s', 'linux-image-6.12.115', 'PostgreSQL and PgBouncer — app', 'object storage', 'sudo shutdown -c', 'in 11 h 30 min']) {
    assert.ok(n.html.includes(bit), bit);
  }
  assert.match(n.text, /Expected downtime +about 2 minutes \(last reboot offline 5 s/);
});

test('a moved booking names both times; a cancelled one says nothing will go down', () => {
  const moved = rebootNotice(base({ kind: 'moved', previous_at: '2026-11-04T23:00:00Z', at: '2026-11-05T02:30:00Z' }), NOW);
  assert.match(moved.subject, /reboots Thu 5 Nov 2026, 02:30 GMT — about 2 minutes down \(moved\)$/);
  assert.ok(moved.html.includes('moved from Wed 4 Nov 2026, 23:00 GMT to Thu 5 Nov 2026, 02:30 GMT'));
  const off = rebootNotice(base({ kind: 'cancelled', previous_at: '2026-11-04T23:00:00Z', at: null }), NOW);
  assert.equal(off.subject, '✅ db-1: planned reboot cancelled');
  assert.ok(off.html.includes('Nothing will go down.'));
});

test('summer time is shown as BST, with UTC beside it; text from the server is escaped', () => {
  const n = rebootNotice(base({ kind: 'booked', at: '2027-06-01T22:00:00Z', packages: ['<b>pkg</b>'] }), new Date('2027-06-01T07:00:00Z'));
  assert.ok(n.html.includes('Tue 1 Jun 2027, 23:00 BST'));
  assert.ok(n.html.includes('2027-06-01 22:00 UTC'));
  assert.ok(!n.html.includes('<b>pkg'));
});

test('expected downtime: measured gap plus a minute for Postgres, never under a minute', () => {
  assert.equal(expectedDowntime({ offline_seconds: 5 }).minutes, 2);
  assert.equal(expectedDowntime({ offline_seconds: 0 }).minutes, 1);
  assert.equal(expectedDowntime(null).text, 'about 2 minutes');
  assert.equal(expectedDowntime({ offline_seconds: 200 }).minutes, 5);
});
