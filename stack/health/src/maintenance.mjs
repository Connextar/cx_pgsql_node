// The public maintenance feed (GET /maintenance.json): the windows lib/maintenance.sh keeps in
// /var/lib/cx-pgsql/maintenance/windows.json, with each window's state worked out from its times when
// it's served. The apps on this server read it (@connextar/house/maintenance) to show a planned-
// maintenance notice beforehand and a maintenance page during. The contract is in cx-house's
// docs/Maintenance.md §2; only what's listed there leaves the server — never a reason or package names.
//
// Stored: { version: 1, windows: [{ id, kind, starts_at, ends_by, expected_minutes, ended_at?,
//           cancelled_at?, affects[], message?, … }] }

export const FEED_VERSION = 1;
const KINDS = new Set(['reboot', 'maintenance']);
const AFFECTS = new Set(['postgres', 'objects']);
const DAY_MS = 86_400_000;
const MESSAGE_MAX = 280;

const time = (value) => {
  if (typeof value !== 'string' || value === '') return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
};
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

/** planned · active · ended · cancelled, from the window's own times. */
export function windowState(w, now) {
  const t = now.getTime();
  if (time(w.cancelled_at) !== null) return 'cancelled';
  if (time(w.ended_at) !== null) return 'ended';
  if (t >= time(w.ends_by)) return 'ended';
  if (t >= time(w.starts_at)) return 'active';
  return 'planned';
}

/** When a window stopped mattering (ended, cancelled or ran out), or null while it still does. */
function closedAt(w, state) {
  if (state === 'cancelled') return time(w.cancelled_at);
  if (state === 'ended') return time(w.ended_at) ?? time(w.ends_by);
  return null;
}

/** One stored window as the feed shows it, or null when it's malformed. */
export function publicWindow(w, now) {
  if (!w || typeof w !== 'object') return null;
  const startsAt = time(w.starts_at);
  const endsBy = time(w.ends_by);
  if (typeof w.id !== 'string' || !w.id || startsAt === null || endsBy === null || endsBy <= startsAt) return null;
  const state = windowState(w, now);
  const ended = time(w.ended_at);
  const message = typeof w.message === 'string' && w.message.trim() ? w.message.trim().slice(0, MESSAGE_MAX) : null;
  const expected = Number.isFinite(w.expected_minutes) && w.expected_minutes > 0 ? Math.ceil(w.expected_minutes) : Math.ceil((endsBy - startsAt) / 60_000);
  return {
    id: w.id,
    kind: KINDS.has(w.kind) ? w.kind : 'maintenance',
    state,
    starts_at: iso(startsAt),
    ends_by: iso(endsBy),
    expected_minutes: expected,
    ended_at: ended === null ? null : iso(ended),
    affects: Array.isArray(w.affects) ? [...new Set(w.affects.filter((a) => AFFECTS.has(a)))] : ['postgres'],
    message,
  };
}

/**
 * The served document. Windows closed more than a day ago drop out; the rest are ordered by start.
 * `stored` null (no file yet) is an empty feed.
 */
export function maintenanceFeed(stored, now, server) {
  const windows = [];
  for (const w of Array.isArray(stored?.windows) ? stored.windows : []) {
    const pub = publicWindow(w, now);
    if (!pub) continue;
    const closed = closedAt(w, pub.state);
    if (closed !== null && now.getTime() - closed > DAY_MS) continue;
    windows.push(pub);
  }
  windows.sort((a, b) => a.starts_at.localeCompare(b.starts_at) || a.id.localeCompare(b.id));
  return { version: FEED_VERSION, server, generated_at: iso(now.getTime()), windows };
}
