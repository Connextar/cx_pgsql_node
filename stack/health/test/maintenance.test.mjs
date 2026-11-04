import { test } from 'node:test';
import assert from 'node:assert/strict';
import { maintenanceFeed, publicWindow, windowState } from '../src/maintenance.mjs';

const reboot = {
  id: 'reboot-20261104T2300Z',
  kind: 'reboot',
  starts_at: '2026-11-04T23:00:00Z',
  ends_by: '2026-11-04T23:15:00Z',
  expected_minutes: 2,
  affects: ['postgres', 'objects'],
  source: 'reboot',
  packages: ['linux-image-6.12.57+deb13-amd64'],
  reason: 'Kernel update',
};
const at = (s) => new Date(s);

test('state follows the clock: planned, active, ended when ends_by passes', () => {
  assert.equal(windowState(reboot, at('2026-11-04T22:59:59Z')), 'planned');
  assert.equal(windowState(reboot, at('2026-11-04T23:00:00Z')), 'active');
  assert.equal(windowState(reboot, at('2026-11-04T23:14:59Z')), 'active');
  assert.equal(windowState(reboot, at('2026-11-04T23:15:00Z')), 'ended');
});

test('ended_at ends a window early; cancelled_at wins over everything', () => {
  assert.equal(windowState({ ...reboot, ended_at: '2026-11-04T23:02:10Z' }, at('2026-11-04T23:03:00Z')), 'ended');
  assert.equal(windowState({ ...reboot, cancelled_at: '2026-11-04T20:00:00Z', ended_at: '2026-11-04T23:02:10Z' }, at('2026-11-04T23:03:00Z')), 'cancelled');
});

test('only the contract leaves the server: no packages, reason or source', () => {
  const pub = publicWindow(reboot, at('2026-11-04T18:00:00Z'));
  assert.deepEqual(pub, {
    id: 'reboot-20261104T2300Z',
    kind: 'reboot',
    state: 'planned',
    starts_at: '2026-11-04T23:00:00Z',
    ends_by: '2026-11-04T23:15:00Z',
    expected_minutes: 2,
    ended_at: null,
    affects: ['postgres', 'objects'],
    message: null,
  });
});

test('malformed windows are dropped, odd values tidied', () => {
  const now = at('2026-11-04T18:00:00Z');
  assert.equal(publicWindow({ ...reboot, id: '' }, now), null);
  assert.equal(publicWindow({ ...reboot, starts_at: 'soon' }, now), null);
  assert.equal(publicWindow({ ...reboot, ends_by: reboot.starts_at }, now), null);
  const odd = publicWindow({ ...reboot, kind: 'weird', affects: ['postgres', 'cpu', 'postgres'], expected_minutes: undefined, message: `  ${'x'.repeat(400)} ` }, now);
  assert.equal(odd.kind, 'maintenance');
  assert.deepEqual(odd.affects, ['postgres']);
  assert.equal(odd.expected_minutes, 15); // the window's length when no estimate was stored
  assert.equal(odd.message.length, 280);
  assert.equal(publicWindow({ ...reboot, starts_at: '2026-11-04T23:00:00.500Z' }, now).starts_at, '2026-11-04T23:00:00Z');
});

test('the feed: ordered by start, closed windows kept for a day then dropped', () => {
  const now = at('2026-11-06T09:00:00Z');
  const stored = {
    version: 1,
    windows: [
      { ...reboot, id: 'later', starts_at: '2026-11-10T02:00:00Z', ends_by: '2026-11-10T02:30:00Z', kind: 'maintenance', message: 'Upgrading the database' },
      { ...reboot, id: 'old', ended_at: '2026-11-04T23:02:00Z' }, // closed > a day ago
      { ...reboot, id: 'yesterday', starts_at: '2026-11-05T23:00:00Z', ends_by: '2026-11-05T23:15:00Z', ended_at: '2026-11-05T23:01:30Z' },
      { ...reboot, id: 'ran-out', starts_at: '2026-11-05T10:00:00Z', ends_by: '2026-11-05T10:20:00Z' }, // ends_by 22h40m ago
      { ...reboot, id: 'called-off', starts_at: '2026-11-08T23:00:00Z', ends_by: '2026-11-08T23:15:00Z', cancelled_at: '2026-11-06T08:00:00Z' },
      'junk',
    ],
  };
  const feed = maintenanceFeed(stored, now, 'cx-pgsql-node-1');
  assert.equal(feed.version, 1);
  assert.equal(feed.server, 'cx-pgsql-node-1');
  assert.equal(feed.generated_at, '2026-11-06T09:00:00Z');
  assert.deepEqual(
    feed.windows.map((w) => [w.id, w.state]),
    [
      ['ran-out', 'ended'],
      ['yesterday', 'ended'],
      ['called-off', 'cancelled'],
      ['later', 'planned'],
    ],
  );
  assert.equal(feed.windows.at(-1).message, 'Upgrading the database');
});

test('no file yet, or a file without windows, is an empty feed', () => {
  assert.deepEqual(maintenanceFeed(null, at('2026-11-04T18:00:00Z'), 'x').windows, []);
  assert.deepEqual(maintenanceFeed({ version: 1 }, at('2026-11-04T18:00:00Z'), 'x').windows, []);
});
