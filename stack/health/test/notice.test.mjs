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

const manual = (notice) => ({
  server: { hostname: 'db-1' },
  timezone: 'Europe/London',
  notice: { mode: 'maintenance', at: '2026-11-10T02:00:00Z', ends_by: '2026-11-10T02:30:00Z', expected_minutes: 30, message: 'Upgrading the database', databases: ['app'], objects: true, feed: true, ...notice },
});

test('maintenance booked by hand: its own length, its message, the window end, and the maintenance commands', () => {
  const n = rebootNotice(manual({ kind: 'booked' }), NOW);
  assert.equal(n.subject, '🛠 db-1 maintenance Tue 10 Nov 2026, 02:00 GMT — about 30 minutes down');
  for (const bit of ['Maintenance is booked for Tue 10 Nov 2026, 02:00 GMT.', 'Tue 10 Nov 2026, 02:00 GMT – 02:30 GMT', 'Upgrading the database', 'cx-pgsql maintenance end', 'cx-pgsql maintenance extend 15m', 'maintenance page']) {
    assert.ok(n.html.includes(bit), bit);
  }
  assert.ok(!n.html.includes('shutdown -c'));
  assert.ok(!n.html.includes('/healthz'), 'the health endpoint stays up during maintenance by hand');
  assert.match(n.text, /The apps +show a planned-maintenance notice/);
});

test('maintenance started now, extended, and called off', () => {
  const started = rebootNotice(manual({ kind: 'booked', at: '2026-11-04T11:30:00Z', ends_by: '2026-11-04T11:50:00Z', expected_minutes: 20 }), NOW);
  assert.ok(started.html.includes('Maintenance started at Wed 4 Nov 2026, 11:30 GMT.'));
  assert.ok(started.html.includes('db-1 goes down for maintenance now'));
  const over = rebootNotice(manual({ kind: 'extended', at: '2026-11-04T11:30:00Z', previous_ends_by: '2026-11-04T11:50:00Z', ends_by: '2026-11-04T12:05:00Z' }), NOW);
  assert.equal(over.subject, '⏱ db-1: maintenance running over — until 12:05 GMT');
  assert.ok(over.html.includes('now runs until Wed 4 Nov 2026, 12:05 GMT (it was 11:50 GMT)'));
  const off = rebootNotice(manual({ kind: 'cancelled', previous_at: '2026-11-10T02:00:00Z' }), NOW);
  assert.equal(off.subject, '✅ db-1: planned maintenance cancelled');
});

test('a 3-hour window reads in hours', () => {
  const n = rebootNotice(manual({ kind: 'booked', ends_by: '2026-11-10T05:00:00Z', expected_minutes: 180 }), NOW);
  assert.match(n.subject, /about 3 hours down$/);
});
