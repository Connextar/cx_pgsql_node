// The apps this server hosts (config/apps/, lib/apps.sh) as the nightly report tells them: one section each,
// and their problems among the issues the email leads with.
//
// Input: `apps[]`, gathered by the host's lib/report.sh (_rpt_apps). Per app:
//   name, fqdn, websocket, health_path        from config/apps/<name>.env
//   container  docker inspect: id, state, health, failing_streak, health_output (the last probe's), started_at,
//              restarts (Docker's own count, for this container), oom_killed, exit_code, image, commit
//              (null: there is no container)
//   resources  its cgroup: memory_bytes, memory_peak_bytes (since it started), memory_limit_bytes,
//              cpu_usec (since it started), oom_kills, pids
//   disk       logs_bytes (Docker's json log files), images_bytes, images (how many are kept)
//   endpoint   https://<fqdn><health_path> fetched on this server through nginx: code, seconds, body (its first
//              line), error
//   tls        the certificate nginx serves for <fqdn>: not_after, issuer, self_signed
//   static     APP_STATIC's files as nginx serves them: { published, files: [{ path, get, post, type }] } (null: none)
//   nginx      the period in its access log: requests, status{}, upgrades { total, status{} },
//              sessions { count, timed, total_s, max_s, at_timeout }, health_requests, health_5xx
//   log        the container's own output in the period, raw: { ok, stdout: { lines, text[] }, stderr: { … } }
//   error      instead of the above, when the host couldn't gather them
//
// What reaches the email: counts, durations, event names and masked messages. The log lines arrive raw and are
// never copied out whole. An event line (`[voice-relay] call_started { callSid: 'CA…' }`) gives its name, its
// numeric details summed and short enum-like values counted; ids, numbers in id-like fields, messages and any
// free text are dropped. Any other line is masked (quoted text, numbers, ids, phone numbers, addresses) before
// it's shown. Nothing here reads the network or the disk.
import { round } from './util.mjs';

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const plural = (n, word, many = `${word}s`) => `${n} ${n === 1 ? word : many}`;

// ---------------------------------------------------------------- log lines

/**
 * Joins a multi-line entry back together: Node prints a larger object (`console.log(event, detail)`) over several
 * lines, and an error's stack follows its message. A line that starts with white space or a closing bracket
 * belongs to the one before it.
 */
export function joinLogLines(lines) {
  const out = [];
  for (const raw of Array.isArray(lines) ? lines : []) {
    if (typeof raw !== 'string' || raw === '') continue;
    if (out.length && /^(\s|[}\]])/.test(raw)) out[out.length - 1] += `\n${raw}`;
    else out.push(raw);
  }
  return out;
}

const EVENT_LINE = /^\[([^\]\n]{1,40})\] ([a-z][a-z0-9_]{1,48})(?=$|[\s{])([\s\S]*)$/;

// Detail keys whose values are never kept, whatever they look like: who, what was said, where, which call.
const PRIVATE_KEY = /(sid|_?ids?|token|caller|callee|from|^to$|phone|number|msisdn|text|prompt|transcript|speech|utterance|message|description|reason|name|user|person|customer|contact|email|address|url|uri|ip|host|body|digit|dtmf|query|path)$/i;
const ENUM_VALUE = /^[A-Za-z][A-Za-z0-9_.-]{0,31}$/;

/** `{ mode: 'enforce', presented: false, open: 3 }` (util.inspect's form) → [['mode','enforce'], ['presented',false], ['open',3]]. */
export function parseDetail(detail) {
  const pairs = [];
  if (typeof detail !== 'string') return pairs;
  const re = /([A-Za-z_$][\w$]*): (?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)|(true|false|null|undefined))/g;
  for (const m of detail.matchAll(re)) {
    if (m[4] !== undefined) pairs.push([m[1], Number(m[4])]);
    else if (m[5] !== undefined) pairs.push([m[1], m[5] === 'true' ? true : m[5] === 'false' ? false : null]);
    else pairs.push([m[1], m[2] ?? m[3] ?? '']);
  }
  return pairs;
}

const ERROR_WORD = /(^|_)(error|errors|err|failed|fail|failure|crash|crashed|exception|fatal|panic|unhandled|uncaught)($|_)/;
const WARN_WORD = /(^|_)(invalid|rejected|refused|reused|limit|incomplete|timeout|timed|busy|missing|warning|warn|denied|dropped|bad|retry|retrying|slow)($|_)/;

/** An event's severity, from its name: model_error → error, upgrade_signature_invalid → warn, call_started → info. */
export function eventSeverity(name) {
  if (ERROR_WORD.test(name)) return 'error';
  if (WARN_WORD.test(name)) return 'warn';
  return 'info';
}

/**
 * A log line that isn't an event, masked so it can leave the server: quoted text, phone numbers, e-mail and IP
 * addresses, URLs' paths, ids and numbers are replaced. Only the first line (a stack trace's message) is kept.
 */
export function maskAppMessage(message, maxLength = 140) {
  if (typeof message !== 'string') return '';
  let s = message.split('\n')[0];
  s = s
    .replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`[^`]*`/g, '?')
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, '<email>')
    .replace(/\b(https?|wss?):\/\/([^/\s?#]+)[^\s]*/gi, '$1://$2/…')
    .replace(/\b(\d{1,3}\.){3}\d{1,3}(:\d+)?\b/g, '<ip>')
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '<id>')
    .replace(/\b[A-Z]{2}[0-9a-f]{32}\b/g, '<sid>')
    .replace(/\+?\d[\d ()-]{6,}\d/g, '<number>')
    .replace(/\b[0-9a-f]{12,}\b/gi, '<id>')
    .replace(/\b[A-Za-z0-9_-]{24,}\b/g, '<id>')
    .replace(/\b\d+(\.\d+)?\b/g, 'N')
    .replace(/\s+/g, ' ')
    .trim();
  return s.length > maxLength ? `${s.slice(0, maxLength - 1)}…` : s;
}

/** One entry: an event (name, severity, its keepable details) or another line (severity, masked message). */
export function parseLogEntry(entry, stream = 'stdout') {
  const m = EVENT_LINE.exec(entry);
  if (m && !/\n\s+at /.test(entry)) {
    const numbers = {};
    const values = {};
    for (const [k, v] of parseDetail(m[3])) {
      if (PRIVATE_KEY.test(k)) continue;
      if (typeof v === 'number') numbers[k] = v;
      else if (typeof v === 'boolean') values[k] = String(v);
      else if (typeof v === 'string' && ENUM_VALUE.test(v) && !/\d{4,}/.test(v)) values[k] = v;
    }
    return { event: m[2], tag: m[1], severity: eventSeverity(m[2]), numbers, values };
  }
  const first = entry.split('\n')[0];
  let severity = 'info';
  if (/\b(error|exception|fatal|panic|uncaught|unhandled|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN)\b/i.test(first) || /^\w*Error\b/.test(first)) severity = 'error';
  else if (/\bwarn(ing)?\b/i.test(first)) severity = 'warn';
  else if (stream === 'stderr') severity = 'error';
  return { severity, message: maskAppMessage(first) };
}

/**
 * The period's log, summed: lines, error and warning entries, every event with its count, its numeric details
 * (sum, max, average over the entries that had them) and its enum-like values, and the most frequent error and
 * warning messages.
 */
export function summariseAppLog(log) {
  const empty = { ok: false, lines: 0, truncated: false, entries: 0, errors: 0, warnings: 0, events: [], top: [] };
  if (!isObj(log)) return empty;
  const events = new Map();
  const top = new Map();
  let errors = 0;
  let warnings = 0;
  let entries = 0;
  let lines = 0;
  let truncated = false;
  for (const stream of ['stdout', 'stderr']) {
    const s = log[stream];
    if (!isObj(s)) continue;
    const text = Array.isArray(s.text) ? s.text : [];
    lines += num(s.lines) ?? text.length;
    if ((num(s.lines) ?? 0) > text.length) truncated = true;
    for (const entry of joinLogLines(text)) {
      entries++;
      const e = parseLogEntry(entry, stream);
      if (e.severity === 'error') errors++;
      else if (e.severity === 'warn') warnings++;
      if (e.event) {
        const ev = events.get(e.event) ?? { name: e.event, severity: e.severity, count: 0, numbers: {}, values: {} };
        ev.count++;
        for (const [k, v] of Object.entries(e.numbers)) {
          const agg = (ev.numbers[k] ??= { count: 0, sum: 0, max: -Infinity });
          agg.count++;
          agg.sum += v;
          agg.max = Math.max(agg.max, v);
        }
        for (const [k, v] of Object.entries(e.values)) {
          ev.values[k] ??= {};
          ev.values[k][v] = (ev.values[k][v] ?? 0) + 1;
        }
        events.set(e.event, ev);
      }
      if (e.severity === 'error' || e.severity === 'warn') {
        const message = e.event ?? e.message;
        const key = `${e.severity}|${message}`;
        const hit = top.get(key) ?? { severity: e.severity, message, event: Boolean(e.event), count: 0 };
        hit.count++;
        top.set(key, hit);
      }
    }
  }
  const rank = { error: 0, warn: 1, info: 2 };
  return {
    ok: log.ok !== false,
    lines,
    truncated,
    entries,
    errors,
    warnings,
    events: [...events.values()]
      .map((ev) => ({
        ...ev,
        numbers: Object.fromEntries(Object.entries(ev.numbers).map(([k, a]) => [k, { count: a.count, sum: round(a.sum, 2), max: a.max, avg: round(a.sum / a.count, 1) }])),
      }))
      .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)),
    top: [...top.values()].sort((a, b) => rank[a.severity] - rank[b.severity] || b.count - a.count).slice(0, 6),
  };
}

// ---------------------------------------------------------------- the model

export const APP_LIMITS = Object.freeze({
  tls_warn_days: 21,
  tls_fail_days: 7,
  slow_endpoint_ms: 2000,
  memory_warn_pct: 90,
  error_spike_min: 5,
  error_spike_factor: 3,
});

const shortCommit = (c) => (typeof c === 'string' && /^[0-9a-f]{7,40}$/i.test(c) ? c.slice(0, 7) : null);

function statusCounts(status) {
  const by = { '1xx': 0, '2xx': 0, '3xx': 0, '4xx': 0, '5xx': 0 };
  for (const [code, count] of Object.entries(isObj(status) ? status : {})) {
    const c = `${String(code)[0]}xx`;
    if (c in by) by[c] += num(count) ?? 0;
  }
  return by;
}
const sumCodes = (status, test) => Object.entries(isObj(status) ? status : {}).filter(([k]) => test(Number(k))).reduce((s, [, v]) => s + (num(v) ?? 0), 0);

/**
 * Builds each app's section and adds its issues through `issue(severity, area, text)`. `prev` is the last
 * report's snapshot (its `apps` and `at`); `fmt` carries the digest's formatters (formatWhen, formatDuration …).
 * Returns { apps: [model…], snapshot: { <name>: { id, restarts, cpu_usec, oom_kills, errors } } }.
 */
export function buildApps(apps, { now, prev, issue, fmt, timezone }) {
  const list = Array.isArray(apps) ? apps.filter((a) => isObj(a) && typeof a.name === 'string') : [];
  const snapshot = {};
  const models = list.map((a) => {
    const before = isObj(prev?.apps?.[a.name]) ? prev.apps[a.name] : null;
    const area = a.name;
    const local = [];
    const flag = (severity, text) => {
      local.push(severity);
      issue(severity, area, text);
    };

    if (a.error) {
      flag('warn', `The report couldn't look at this app: ${a.error}`);
      return { name: a.name, fqdn: a.fqdn ?? null, status: 'warn', error: a.error };
    }

    // -- container
    const c = isObj(a.container) ? a.container : null;
    const sameContainer = Boolean(c && before && before.id === c.id);
    // Docker's count is per container: compared with the last report's for the same one, or all of a new one's.
    const restartDelta = !c ? null : sameContainer ? Math.max(0, (num(c.restarts) ?? 0) - (num(before.restarts) ?? 0)) : before ? num(c.restarts) : null;
    const started = c?.started_at && !c.started_at.startsWith('0001') ? c.started_at : null;
    const startedMs = started ? Date.parse(started) : NaN;
    const uptimeSeconds = Number.isFinite(startedMs) && c?.state === 'running' ? Math.max(0, (now.getTime() - startedMs) / 1000) : null;
    const redeployed = Boolean(c && before && before.id && before.id !== c.id);
    const startedInPeriod = Number.isFinite(startedMs) && prev?.at && startedMs > Date.parse(prev.at);
    if (!c) flag('fail', `There is no container ${a.websocket ? '(calls and connections fail) ' : ''}— not deployed, or removed. cx-pgsql app list shows the apps.`);
    else if (c.state !== 'running') flag('fail', `The container is ${c.state}${num(c.exit_code) ? ` (exit code ${c.exit_code})` : ''}${c.oom_killed ? ', killed for running out of memory' : ''}.`);
    else if (c.health && c.health !== 'healthy') {
      const probe = maskAppMessage(c.health_output ?? '', 100);
      flag(c.health === 'starting' ? 'info' : 'warn', `The container is ${c.health}${num(c.failing_streak) ? ` (${plural(c.failing_streak, 'failed check')} in a row)` : ''}${probe ? `: ${probe}` : ''}.`);
    }
    if (restartDelta > 0) flag('warn', `Docker restarted it ${plural(restartDelta, 'time')} (it stopped by itself: a crash, or out of memory).`);
    if (redeployed) flag('info', `Redeployed: now ${shortCommit(c.commit) ?? c.image ?? 'a new container'}, started ${fmt.formatWhen(started, timezone)}.`);
    else if (c && startedInPeriod && !before) flag('info', `New since the last report: started ${fmt.formatWhen(started, timezone)}.`);
    else if (c && startedInPeriod && !restartDelta) flag('info', `Restarted (started ${fmt.formatWhen(started, timezone)}).`);

    // -- resources
    const r = isObj(a.resources) ? a.resources : {};
    const limit = num(r.memory_limit_bytes) ?? num(c?.memory_limit) ?? null;
    const memPct = limit && num(r.memory_bytes) !== null ? round((r.memory_bytes / limit) * 100, 1) : null;
    const peakPct = limit && num(r.memory_peak_bytes) !== null ? round((r.memory_peak_bytes / limit) * 100, 1) : null;
    let cpuPct = null;
    let cpuBasis = null;
    const prevAt = prev?.at ? Date.parse(prev.at) : NaN;
    if (sameContainer && num(r.cpu_usec) !== null && num(before.cpu_usec) !== null && r.cpu_usec >= before.cpu_usec && Number.isFinite(prevAt) && now.getTime() > prevAt) {
      cpuPct = round(((r.cpu_usec - before.cpu_usec) / 1e6 / ((now.getTime() - prevAt) / 1000)) * 100, 2);
      cpuBasis = 'period';
    } else if (num(r.cpu_usec) !== null && uptimeSeconds > 0) {
      cpuPct = round((r.cpu_usec / 1e6 / uptimeSeconds) * 100, 2);
      cpuBasis = 'start';
    }
    const oomDelta = sameContainer ? Math.max(0, (num(r.oom_kills) ?? 0) - (num(before.oom_kills) ?? 0)) : num(r.oom_kills);
    if (oomDelta > 0) flag('warn', `${plural(oomDelta, 'process', 'processes')} killed for running out of memory (limit ${fmt.formatBytes(limit)}).`);
    if (peakPct !== null && peakPct >= APP_LIMITS.memory_warn_pct) flag('warn', `Memory peaked at ${peakPct}% of its ${fmt.formatBytes(limit)} limit.`);

    // -- endpoint, certificate, static files
    const e = isObj(a.endpoint) ? a.endpoint : null;
    const endpointMs = num(e?.seconds) !== null ? Math.round(e.seconds * 1000) : null;
    const endpointOk = Boolean(e && e.code >= 200 && e.code < 300);
    if (e && !endpointOk) flag('fail', `${e.url} ${e.code ? `answered ${e.code}` : `didn't answer${e.error ? ` (${maskAppMessage(e.error, 80)})` : ''}`} from this server.`);
    else if (endpointOk && endpointMs >= APP_LIMITS.slow_endpoint_ms) flag('warn', `${e.url} took ${fmt.formatMs(endpointMs)} to answer.`);
    const version = typeof e?.body === 'string' && /^ok\b/i.test(e.body) ? e.body.replace(/^ok\s*/i, '').slice(0, 40) || null : null;

    const t = isObj(a.tls) ? a.tls : null;
    const notAfter = t?.not_after ? Date.parse(t.not_after) : NaN;
    const daysLeft = Number.isFinite(notAfter) ? Math.floor((notAfter - now.getTime()) / 86_400_000) : null;
    if (t && daysLeft === null) flag('warn', `The certificate for ${a.fqdn} couldn't be read from nginx.`);
    else if (daysLeft !== null && daysLeft < 0) flag('fail', `The certificate for ${a.fqdn} expired on ${fmt.formatWhen(t.not_after, timezone, { time: false })}.`);
    else if (daysLeft !== null && daysLeft < APP_LIMITS.tls_fail_days) flag('fail', `The certificate for ${a.fqdn} expires in ${plural(daysLeft, 'day')} and hasn't renewed.`);
    else if (daysLeft !== null && daysLeft < APP_LIMITS.tls_warn_days) flag('warn', `The certificate for ${a.fqdn} expires in ${plural(daysLeft, 'day')} (${fmt.formatWhen(t.not_after, timezone, { time: false })}); it should have renewed by now.`);
    if (t?.self_signed) flag('warn', `${a.fqdn} is still served with the self-signed placeholder certificate (is its DNS A record pointing here?).`);

    let staticFiles = null;
    if (isObj(a.static)) {
      const files = (Array.isArray(a.static.files) ? a.static.files : []).map((f) => ({
        path: typeof f.path === 'string' ? f.path : '?',
        get: num(f.get) ?? 0,
        post: num(f.post),
        type: typeof f.type === 'string' ? f.type : null,
        ok: num(f.get) === 200 && (num(f.post) === null || num(f.post) === 200),
      }));
      staticFiles = { published: a.static.published !== false, files };
      if (!staticFiles.published) flag('fail', `Its static files (APP_STATIC) aren't published, so nothing answers in their place.`);
      for (const f of files.filter((x) => !x.ok)) flag('fail', `${f.path} isn't served (GET ${f.get || 'no answer'}${f.post !== null ? `, POST ${f.post || 'no answer'}` : ''}).`);
    }

    // -- traffic, from nginx
    const ng = isObj(a.nginx) ? a.nginx : null;
    let traffic = null;
    if (ng) {
      const up = isObj(ng.upgrades) ? ng.upgrades : { total: 0, status: {} };
      const s = isObj(ng.sessions) ? ng.sessions : {};
      const sessions = num(s.count) ?? num(up.status?.['101']) ?? 0;
      const timed = num(s.timed) ?? 0;
      traffic = {
        requests: num(ng.requests) ?? 0,
        by_class: statusCounts(ng.status),
        rate_limited: num(ng.status?.['429']) ?? 0,
        not_found: num(ng.status?.['404']) ?? 0,
        upstream_failed: sumCodes(ng.status, (k) => k === 502 || k === 503 || k === 504),
        upgrades: {
          total: num(up.total) ?? 0,
          sessions,
          refused: sumCodes(up.status, (k) => k === 401 || k === 403),
          rate_limited: num(up.status?.['429']) ?? 0,
          failed: sumCodes(up.status, (k) => k >= 500),
        },
        sessions: {
          count: sessions,
          timed,
          avg_s: timed ? round(s.total_s / timed, 1) : null,
          max_s: timed ? num(s.max_s) : null,
          at_timeout: num(s.at_timeout) ?? 0,
        },
        health_requests: num(ng.health_requests) ?? 0,
        health_5xx: num(ng.health_5xx) ?? 0,
      };
      const tu = traffic.upgrades;
      if (tu.failed) flag('warn', `${plural(tu.failed, 'WebSocket connection')} failed at nginx: the app didn't answer${a.websocket ? ' (for a voice relay, a call that went to the fallback)' : ''}.`);
      const otherFailed = traffic.upstream_failed - sumCodes(up.status, (k) => k === 502 || k === 503 || k === 504);
      if (traffic.health_5xx) flag('warn', `${a.health_path ?? 'The health path'} answered with an error (5xx) ${plural(traffic.health_5xx, 'time')} through nginx in the period: the app was down or not answering then.`);
      else if (otherFailed > 0) flag('info', `${plural(otherFailed, 'request')} got a 502–504 from nginx: the app didn't answer.`);
      if (tu.refused) flag('info', `${plural(tu.refused, 'WebSocket upgrade')} refused (unsigned, or a bad signature): scanners, or a misconfigured caller.`);
      if (traffic.sessions.at_timeout) flag('info', `${plural(traffic.sessions.at_timeout, 'WebSocket session')} reached nginx's one-hour limit and was cut off.`);
    }

    // -- its own log
    const log = summariseAppLog(a.log);
    const errorsBefore = num(before?.errors);
    if (c && isObj(a.log) && a.log.ok === false) flag('info', `Its log couldn't be read in time; the counts below are partial.`);
    if (log.errors) {
      const topError = log.top.find((x) => x.severity === 'error');
      const what = topError ? `, most often (${topError.count}×): ${topError.message}` : '';
      const spike = log.errors >= APP_LIMITS.error_spike_min && (errorsBefore === null || log.errors >= APP_LIMITS.error_spike_factor * Math.max(errorsBefore, 1));
      if (spike) flag('warn', `${plural(log.errors, 'error')} in its log${errorsBefore !== null ? ` (${errorsBefore} in the period before)` : ''}${what}.`);
      else flag('info', `${plural(log.errors, 'error')} in its log${what}.`);
    }
    if (log.truncated) flag('info', `Only the last ${log.entries} log entries were read; the counts are partial.`);

    snapshot[a.name] = { id: c?.id ?? null, restarts: num(c?.restarts), cpu_usec: num(r.cpu_usec), oom_kills: num(r.oom_kills), errors: log.errors };

    const status = local.includes('fail') ? 'fail' : local.includes('warn') ? 'warn' : 'ok';
    return {
      name: a.name,
      fqdn: a.fqdn ?? null,
      websocket: Boolean(a.websocket),
      status,
      container: c
        ? {
            state: c.state,
            health: c.health ?? null,
            failing_streak: num(c.failing_streak),
            started: started ? fmt.formatWhen(started, timezone) : null,
            uptime: uptimeSeconds !== null ? fmt.formatDuration(uptimeSeconds) : null,
            restarts: num(c.restarts),
            restart_delta: restartDelta,
            redeployed,
            image: c.image ?? null,
            commit: shortCommit(c.commit),
          }
        : null,
      version,
      resources: {
        cpu_pct: cpuPct,
        cpu_basis: cpuBasis,
        cpu_limit: num(c?.nano_cpus) ? c.nano_cpus / 1e9 : null,
        memory: num(r.memory_bytes),
        memory_peak: num(r.memory_peak_bytes),
        memory_limit: limit,
        memory_pct: memPct,
        peak_pct: peakPct,
        oom_kills: oomDelta,
        pids: num(r.pids),
      },
      disk: isObj(a.disk) ? { logs: num(a.disk.logs_bytes), images: num(a.disk.images_bytes), image_count: num(a.disk.images) } : null,
      endpoint: e ? { url: e.url, code: num(e.code), ms: endpointMs, ok: endpointOk, error: e.error ? maskAppMessage(e.error, 80) : null } : null,
      tls: t ? { days_left: daysLeft, expires: Number.isFinite(notAfter) ? fmt.formatWhen(t.not_after, timezone, { time: false }) : null, issuer: typeof t.issuer === 'string' ? t.issuer.slice(0, 60) : null, self_signed: Boolean(t.self_signed) } : null,
      static: staticFiles,
      traffic,
      log: { ...log, errors_before: errorsBefore },
    };
  });
  return { apps: models, snapshot };
}

/** An event's details in a few words: "durationSeconds avg 84, max 300 · outcome TRANSFERRED 4, ABANDONED 1". */
export function eventDetail(ev, formatCount) {
  const parts = [];
  for (const [k, a] of Object.entries(ev.numbers ?? {})) {
    parts.push(a.count > 1 ? `${k} avg ${formatCount(a.avg)}, max ${formatCount(a.max)}, ${formatCount(a.sum)} in all` : `${k} ${formatCount(a.sum)}`);
  }
  for (const [k, vals] of Object.entries(ev.values ?? {})) {
    const top = Object.entries(vals).sort((x, y) => y[1] - x[1]);
    parts.push(`${k} ${top.slice(0, 4).map(([v, n]) => (top.length === 1 && n === ev.count ? v : `${v} ${n}`)).join(', ')}${top.length > 4 ? ` +${top.length - 4}` : ''}`);
  }
  return parts.join(' · ');
}
