// The nightly report as an HTML email. Email clients are the constraint: Outlook for Windows renders with
// Word, Gmail drops most of <style>, phones are 320–430px wide. So: tables for layout, inline styles on
// everything, one 600px column that shrinks, system fonts, no images, colour never the only signal (every
// status also has a word), and a <style> block only for what can degrade — dark mode and narrow screens.
import { formatBytes, formatCount, formatDeltaBytes, formatMs, USAGE_LABELS, withDelta } from './digest.mjs';

const C = {
  page: '#eef0f3',
  card: '#ffffff',
  text: '#111827',
  muted: '#5b6472',
  line: '#e3e6ea',
  track: '#e8ebef',
  mono: '#f5f6f8',
  ok: { fg: '#166534', bg: '#dcfce7', bar: '#22a35a', band: '#15803d' },
  warn: { fg: '#854d0e', bg: '#fef3c7', bar: '#d99a06', band: '#b45309' },
  fail: { fg: '#991b1b', bg: '#fee2e2', bar: '#dc2626', band: '#b91c1c' },
  info: { fg: '#1e40af', bg: '#dbeafe', bar: '#3b82f6', band: '#1d4ed8' },
};
const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
const MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace";
const WORD = { ok: 'OK', warn: 'Warning', fail: 'Problem', info: 'Note' };

export function esc(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const pill = (status, text = WORD[status]) =>
  `<span class="pill-${status}" style="display:inline-block;font-family:${FONT};padding:2px 8px;border-radius:10px;background:${C[status].bg};color:${C[status].fg};font-size:12px;font-weight:600;line-height:18px;white-space:nowrap;">${esc(text)}</span>`;

/** A usage bar: a two-cell table, which Outlook draws as faithfully as anyone. */
function bar(usedPct, status) {
  const p = Math.max(0, Math.min(100, Number(usedPct) || 0));
  const fill = Math.max(p, 1);
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;margin:6px 0 2px;"><tr>
<td class="bar-fill" width="${fill}%" height="8" style="background:${C[status].bar};height:8px;line-height:8px;font-size:0;border-radius:4px 0 0 4px;">&nbsp;</td>
${p < 100 ? `<td class="bar-track" height="8" style="background:${C.track};height:8px;line-height:8px;font-size:0;border-radius:0 4px 4px 0;">&nbsp;</td>` : ''}
</tr></table>`;
}

const usageStatus = (p) => (p >= 90 ? 'fail' : p >= 80 ? 'warn' : 'ok');

function section(title, body, subtitle) {
  return `<tr><td class="card" style="background:${C.card};padding:20px 24px 8px;border-top:1px solid ${C.line};">
<h2 class="h2" style="margin:0 0 ${subtitle ? '2px' : '10px'};font-family:${FONT};font-size:17px;line-height:24px;color:${C.text};font-weight:700;">${esc(title)}</h2>
${subtitle ? `<p class="muted" style="margin:0 0 10px;font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};">${esc(subtitle)}</p>` : ''}
${body}
</td></tr>`;
}

/** Label/value rows. Values are pre-escaped HTML. */
function rows(pairs) {
  const body = pairs
    .filter(([, v]) => v !== null && v !== undefined && v !== '')
    .map(
      ([k, v]) => `<tr>
<td class="muted rowline" valign="top" style="padding:7px 12px 7px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.muted};width:42%;">${esc(k)}</td>
<td class="rowline" valign="top" style="padding:7px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};text-align:right;">${v}</td>
</tr>`,
    )
    .join('');
  return body ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${body}</table>` : '';
}

function subhead(text) {
  return `<p class="muted" style="margin:14px 0 6px;font-family:${FONT};font-size:12px;line-height:16px;letter-spacing:.06em;text-transform:uppercase;color:${C.muted};font-weight:600;">${esc(text)}</p>`;
}

function code(text) {
  return `<div class="mono" style="margin:4px 0 0;padding:6px 8px;background:${C.mono};border-radius:4px;font-family:${MONO};font-size:12px;line-height:17px;color:${C.text};word-break:break-all;overflow-wrap:anywhere;">${esc(text)}</div>`;
}

const small = (html) => `<span class="muted" style="color:${C.muted};font-size:13px;">${html}</span>`;

/** A 2×2 grid of headline numbers. Two columns stay readable down to 320px. */
function tiles(items) {
  const cell = (t) =>
    t
      ? `<td class="tile" width="50%" valign="top" style="padding:12px 14px;background:${C.card};border:1px solid ${C.line};border-radius:8px;">
<p class="muted" style="margin:0;font-family:${FONT};font-size:12px;line-height:16px;color:${C.muted};">${esc(t.label)}</p>
<p class="big" style="margin:4px 0 0;font-family:${FONT};font-size:20px;line-height:26px;font-weight:700;color:${C.text};">${esc(t.value)}</p>
<p class="muted" style="margin:2px 0 0;font-family:${FONT};font-size:12px;line-height:16px;color:${C.muted};">${t.sub ?? '&nbsp;'}</p>
${t.pct !== undefined && t.pct !== null ? bar(t.pct, t.status ?? usageStatus(t.pct)) : ''}
</td>`
      : '<td width="50%">&nbsp;</td>';
  const out = [];
  for (let i = 0; i < items.length; i += 2) {
    out.push(`<tr>${cell(items[i])}<td width="10" style="font-size:0;">&nbsp;</td>${cell(items[i + 1])}</tr><tr><td colspan="3" height="10" style="font-size:0;line-height:10px;">&nbsp;</td></tr>`);
  }
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;">${out.join('')}</table>`;
}

export function digestHtml({ model: m, subject, preheader }) {
  const band = C[m.overall].band;
  const statusWord = m.overall === 'ok' ? 'All healthy' : m.headline;
  const disk = m.server.filesystems[0];
  const backupStatus = m.backups.rows.reduce((w, b) => (b.status === 'fail' ? 'fail' : b.status === 'warn' && w !== 'fail' ? 'warn' : w), 'ok');
  const backupsOk = m.backups.rows.filter((b) => b.status === 'ok').length;

  // -- what needs attention
  const issues = m.issues.length
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${m.issues
        .map(
          (i) => `<tr><td class="rowline" valign="top" style="padding:8px 10px 8px 0;border-bottom:1px solid ${C.line};width:1%;">${pill(i.severity)}</td>
<td class="rowline" valign="top" style="padding:8px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>${esc(i.area)}</strong> — ${esc(i.text)}</td></tr>`,
        )
        .join('')}</table>`
    : `<p style="margin:0 0 14px;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};">Nothing needs attention: every check passed and nothing unusual turned up in the logs.</p>`;

  // -- server
  const fsRows = m.server.filesystems
    .map(
      (f) => `<p style="margin:10px 0 0;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>${esc(f.mount)}</strong> ${small(`${esc(f.fstype ?? '')}`)}<span style="float:right;">${pill(usageStatus(f.used_pct), `${f.used_pct}% used`)}</span></p>
${bar(f.used_pct, usageStatus(f.used_pct))}
<p class="muted" style="margin:0 0 6px;font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};">${esc(formatBytes(f.used))} used · <strong class="strong" style="color:${C.text};">${esc(formatBytes(f.free))} free</strong> · ${esc(formatBytes(f.size))} total</p>`,
    )
    .join('');
  const usage = Object.entries(USAGE_LABELS)
    .filter(([k]) => m.server.usage[k] !== undefined && m.server.usage[k] !== null)
    .map(([k, label]) => [label, esc(withDelta(formatBytes(m.server.usage[k]), m.server.usage_delta[k]))]);
  const containerRows = m.server.containers.map((c) => [
    c.name.replace(/^cx-pgsql-/, ''),
    `${pill(c.state !== 'running' ? 'fail' : c.health && c.health !== 'healthy' ? 'warn' : 'ok', c.state === 'running' ? c.health ?? 'running' : c.state)}${c.restart_delta ? ` ${small(`restarted ${c.restart_delta}×`)}` : ''}`,
  ]);
  const server = section(
    'Server',
    `${fsRows}
${subhead('Space by area')}${rows(usage)}
${rows([
  ['Uptime', esc(m.server.uptime)],
  ['Load (1 / 5 / 15 min)', m.server.load ? `${esc(m.server.load.join(' / '))} ${small(`on ${m.server.cpus} cores`)}` : null],
  ['Memory', m.server.memory.total ? `${esc(formatBytes(m.server.memory.used))} of ${esc(formatBytes(m.server.memory.total))} ${small(`${m.server.memory.used_pct}%`)}` : null],
  ['Swap', m.server.swap.total ? `${esc(formatBytes(m.server.swap.used ?? 0))} of ${esc(formatBytes(m.server.swap.total))}` : null],
  ['Updates waiting', m.server.updates ? `${esc(m.server.updates.total)} ${small(`${m.server.updates.security} security`)}` : null],
  ['Reboot pending', m.server.reboot_required ? pill('warn', 'Yes') : pill('ok', 'No')],
  ['TLS certificate', m.server.tls ? `${esc(m.server.tls.days_left)} days left` : null],
  ['SSH logins', m.server.ssh ? `${esc(formatCount(m.server.ssh.accepted))} accepted ${small(`${formatCount(m.server.ssh.failed)} failed`)}` : null],
  ...m.server.fail2ban.map((j) => [`fail2ban: ${j.jail}`, `${esc(formatCount(j.attempts ?? 0))} attempts ${small(`${j.banned_period} banned · ${j.banned_now} now`)}`]),
  ['OS', m.server.os ? `${esc(m.server.os)} ${small(esc(m.server.kernel ?? ''))}` : null],
])}
${containerRows.length ? `${subhead('Containers')}${rows(containerRows)}` : ''}`,
    m.server.fqdn,
  );

  // -- PostgreSQL
  const p = m.postgres;
  const dbRows = p.databases
    .map(
      (d) => `<tr>
<td class="rowline" style="padding:7px 8px 7px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>${esc(d.name)}</strong><br>${small(`${d.connections ?? 0} connected · cache ${d.cache_hit_pct ?? '?'}%`)}</td>
<td class="rowline" style="padding:7px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};text-align:right;white-space:nowrap;">${esc(formatBytes(d.size))}${d.size_delta ? `<br>${small(esc(formatDeltaBytes(d.size_delta)))}` : ''}</td>
<td class="rowline" style="padding:7px 0 7px 8px;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};text-align:right;white-space:nowrap;">${d.commits !== null ? `${esc(formatCount(d.commits))}<br>${small(`commits${d.rollbacks ? ` · ${formatCount(d.rollbacks)} rolled back` : ''}`)}` : '&nbsp;'}</td>
</tr>`,
    )
    .join('');
  const stmt = p.statements;
  const stmtList = (list, slow) =>
    list
      .map(
        (s) => `<tr><td class="rowline" style="padding:8px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:13px;line-height:18px;color:${C.text};">
<strong>${esc(formatMs(slow ? s.mean_ms : s.total_ms))}</strong> ${small(slow ? `average · ${formatCount(s.calls)} calls · ${s.database}` : `in all · ${formatCount(s.calls)} calls · ${formatMs(s.mean_ms)} average · ${s.database}`)}
${code(s.query)}</td></tr>`,
      )
      .join('');
  const errorList = p.errors.groups
    .map(
      (e) => `<tr><td class="rowline" style="padding:8px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:13px;line-height:18px;color:${C.text};">
${pill(e.severity === 'ERROR' || e.severity === 'WARNING' ? 'info' : e.severity === 'PANIC' ? 'fail' : 'warn', e.severity)} <strong>${esc(formatCount(e.count))}×</strong> ${small(esc(e.who ?? ''))}
${code(e.message)}</td></tr>`,
    )
    .join('');
  const tableRows = p.tables.map((t) => [`${t.database}.${t.name}`, `${esc(formatBytes(t.size))}${t.size_delta ? ` ${small(esc(formatDeltaBytes(t.size_delta)))}` : ''}${t.dead_pct >= 20 && t.dead >= 1000 ? ` ${small(`${t.dead_pct}% dead`)}` : ''}`]);
  // Only once there's a previous report to compare with: PgBouncer's counters run from its own start.
  const bouncerRows = p.pgbouncer.stats
    .filter((s) => s.transactions)
    .map((s) => [`PgBouncer · ${s.database}`, `${esc(formatCount(s.transactions))} transactions ${small(`${formatMs(s.avg_xact_ms)} avg${s.avg_wait_ms ? ` · ${formatMs(s.avg_wait_ms)} waiting` : ''}`)}`]);

  const postgres = section(
    'PostgreSQL',
    `${rows([
      ['Version', `${esc(p.version)} ${small(`up ${p.uptime}`)}`],
      ['Connections', p.connections.total !== null ? `${esc(p.connections.total)} of ${esc(p.connections.max)} ${small(`${p.connections.pct}%`)}` : null],
      ['Databases', `${esc(p.database_count)} ${small(`${formatBytes(p.total_size)} in all`)}`],
      ['Queries from apps', `${esc(formatCount(stmt.totals.calls))} ${small(`${formatMs(stmt.totals.total_ms)} of database time`)}`],
      ['Maintenance and monitoring', stmt.totals.monitoring_calls ? `${esc(formatCount(stmt.totals.monitoring_calls))} ${small(`${formatMs(stmt.totals.monitoring_ms)}`)}` : null],
      ['Bulk copies (dumps, imports)', stmt.totals.bulk_calls ? `${esc(formatCount(stmt.totals.bulk_calls))} ${small(`${formatMs(stmt.totals.bulk_ms)}`)}` : null],
      ['WAL written', p.wal.bytes !== null ? `${esc(formatBytes(p.wal.bytes))} ${small(`${formatCount(p.wal.archived)} segments archived`)}` : null],
      ['Errors in the log', `${esc(formatCount(p.errors.counts.error))} ${small(`${p.errors.counts.fatal} fatal · ${p.errors.counts.panic} panic`)}`],
      ['Over ' + formatMs(p.slow_logged.threshold_ms ?? 500), `${esc(formatCount(p.slow_logged.count))}${p.slow_logged.max_ms ? ` ${small(`longest ${formatMs(p.slow_logged.max_ms)}`)}` : ''}`],
      ...bouncerRows,
    ])}
${dbRows ? `${subhead('Databases')}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${dbRows}</table>` : ''}
${stmt.slow.length ? `${subhead(`Slow queries — over ${formatMs(stmt.slow_threshold_ms)} on average`)}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${stmtList(stmt.slow.slice(0, 5), true)}</table>` : ''}
${stmt.top_total.length ? `${subhead('Where the database spent its time')}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${stmtList(stmt.top_total, false)}</table>` : ''}
${errorList ? `${subhead('Log errors, values hidden')}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${errorList}</table>${p.errors.more ? `<p style="margin:0 0 12px;">${small(`…and ${p.errors.more} other kinds`)}</p>` : ''}` : ''}
${tableRows.length ? `${subhead('Largest tables')}${rows(tableRows)}` : ''}`,
    stmt.since_reset ? `Query counts since statistics were reset${stmt.stats_reset ? ` (${stmt.stats_reset.slice(0, 10)})` : ''}` : null,
  );

  // -- backups
  const backupRows = m.backups.rows
    .map(
      (b) => `<tr>
<td class="rowline" valign="top" style="padding:8px 8px 8px 0;border-bottom:1px solid ${C.line};width:1%;">${pill(b.status)}</td>
<td class="rowline" valign="top" style="padding:8px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>${esc(b.label)}</strong> ${small(b.last_success_ago ? `last ok ${esc(b.last_success_ago)} ago` : 'never succeeded')}
${b.runs.ok + b.runs.failed ? `<br>${small(`${b.runs.ok} run${b.runs.ok === 1 ? '' : 's'} ok${b.runs.failed ? `, <strong style="color:${C.fail.fg};">${b.runs.failed} failed</strong>` : ''} in the period`)}` : ''}
${b.detail ? `<br>${small(esc(b.detail))}` : ''}${b.last_error && b.status !== 'ok' ? code(b.last_error) : ''}</td></tr>`,
    )
    .join('');
  const dbx = m.backups.dropbox;
  const backups = section(
    'Backups',
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${backupRows}</table>
${dbx && dbx.total ? `<p style="margin:10px 0 0;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>Dropbox</strong> ${small('(off-site)')}<span style="float:right;">${pill(usageStatus(Math.round((dbx.used / dbx.total) * 100)), `${Math.round((dbx.used / dbx.total) * 100)}% used`)}</span></p>
${bar((dbx.used / dbx.total) * 100, usageStatus((dbx.used / dbx.total) * 100))}
<p class="muted" style="margin:0 0 12px;font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};">${esc(formatBytes(dbx.used))} used · <strong class="strong" style="color:${C.text};">${esc(formatBytes(dbx.free))} free</strong> · ${esc(formatBytes(dbx.total))} total</p>` : ''}`,
  );

  // -- object storage
  const o = m.objects;
  const objects = o
    ? section(
        'Object storage',
        `<p style="margin:4px 0 0;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};"><strong>${esc(formatBytes(o.bytes))}</strong> in ${esc(formatCount(o.objects))} objects<span style="float:right;">${pill(o.healthy === 'ok' || o.healthy === null ? usageStatus(o.used_pct) : o.healthy, `${o.used_pct}% of capacity`)}</span></p>
${bar(o.used_pct, usageStatus(o.used_pct))}
<p class="muted" style="margin:0 0 8px;font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};">capacity ${esc(formatBytes(o.capacity))}${o.bytes_delta ? ` · ${esc(formatDeltaBytes(o.bytes_delta))} in the period` : ''}${o.on_disk ? ` · ${esc(formatBytes(o.on_disk))} on disk` : ''}</p>
${rows(o.buckets.map((b) => [b.name, `${esc(formatBytes(b.bytes))} ${small(`${formatCount(b.objects)} objects${b.objects_delta ? ` · ${b.objects_delta > 0 ? '+' : ''}${formatCount(b.objects_delta)}` : ''}`)}`]))}`,
      )
    : '';

  // -- every check
  const checks = section(
    'All checks',
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;margin:0 0 12px;">${m.checks
      .map(
        (c) => `<tr><td class="rowline" valign="top" style="padding:6px 8px 6px 0;border-bottom:1px solid ${C.line};width:1%;">${pill(c.status)}</td>
<td class="rowline" valign="top" style="padding:6px 0;border-bottom:1px solid ${C.line};font-family:${FONT};font-size:13px;line-height:18px;color:${C.text};"><strong>${esc(c.label)}</strong><br>${small(esc(c.message))}</td></tr>`,
      )
      .join('')}</table>`,
  );

  const tileItems = [
    disk && { label: `Disk ${disk.mount}`, value: `${formatBytes(disk.free)} free`, sub: esc(`${formatBytes(disk.used)} of ${formatBytes(disk.size)} used`), pct: disk.used_pct },
    { label: `Databases (${p.database_count})`, value: formatBytes(p.total_size), sub: esc(`${formatCount(stmt.totals.calls)} app queries`) },
    o && { label: 'Object storage', value: formatBytes(o.bytes), sub: esc(`${formatCount(o.objects)} objects · ${o.used_pct}% of capacity`), pct: o.used_pct },
    { label: 'Backups', value: `${backupsOk} of ${m.backups.rows.length} OK`, sub: m.backups.dropbox ? esc(`${formatBytes(m.backups.dropbox.free)} free in Dropbox`) : '&nbsp;', status: backupStatus },
  ].filter(Boolean);

  return `<!DOCTYPE html>
<html lang="en-GB" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>${esc(subject)}</title>
<style>
  body { margin:0; padding:0; -webkit-text-size-adjust:100%; }
  table { border-collapse:collapse; }
  @media (max-width: 480px) {
    .outer { padding:0 !important; }
    .card, .head { padding-left:16px !important; padding-right:16px !important; }
    .big { font-size:17px !important; line-height:22px !important; }
    .tile { padding:10px !important; }
  }
  @media (prefers-color-scheme: dark) {
    .page { background:#0f1115 !important; }
    .card, .tile { background:#181b21 !important; border-color:#2a2f37 !important; }
    .h2, .big, .rowline, .strong, p, td { color:#e6e8eb !important; }
    .muted, .muted * { color:#9aa3af !important; }
    .rowline, .card { border-color:#2a2f37 !important; }
    .mono { background:#232730 !important; color:#e6e8eb !important; }
    .bar-track { background:#2a2f37 !important; }
  }
  [data-ogsc] .page { background:#0f1115 !important; }
  [data-ogsc] .card, [data-ogsc] .tile { background:#181b21 !important; }
</style>
</head>
<body class="page" style="margin:0;padding:0;background:${C.page};">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:${C.page};">${esc(preheader)}&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;</div>
<table role="presentation" class="page" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:${C.page};">
<tr><td class="outer" align="center" style="padding:24px 12px;">
<!--[if mso]><table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:600px;width:100%;border-radius:10px;overflow:hidden;">
<tr><td class="head" style="background:${band};padding:22px 24px;">
<p style="margin:0;font-family:${FONT};font-size:13px;line-height:18px;color:#ffffff;opacity:.9;">${esc(m.server.hostname)} · nightly report</p>
<h1 style="margin:4px 0 0;font-family:${FONT};font-size:24px;line-height:30px;color:#ffffff;font-weight:700;">${m.overall === 'ok' ? '✓' : m.overall === 'warn' ? '!' : '✕'} ${esc(statusWord)}</h1>
<p style="margin:6px 0 0;font-family:${FONT};font-size:13px;line-height:18px;color:#ffffff;opacity:.9;">${esc(m.generated_local)}${m.previous_local ? ` · covering the ${m.period_hours} h since ${esc(m.previous_local)}` : ' · first report: totals since statistics began'}</p>
</td></tr>
<tr><td class="card" style="background:${C.card};padding:18px 24px 8px;">${tiles(tileItems)}</td></tr>
${section('Needs attention', issues)}
${server}
${postgres}
${backups}
${objects}
${checks}
<tr><td class="card" style="background:${C.card};padding:16px 24px 22px;border-top:1px solid ${C.line};">
<p class="muted" style="margin:0;font-family:${FONT};font-size:12px;line-height:17px;color:${C.muted};">Sent by ${esc(m.server.hostname)} (CX_PGSQL_Node_1) at ${esc(m.generated_local)}. Query text is normalised by PostgreSQL and every literal is masked; log messages have their values hidden. Live status: <span style="white-space:nowrap;">cx-pgsql health</span> on the server.</p>
</td></tr>
</table>
<!--[if mso]></td></tr></table><![endif]-->
</td></tr>
</table>
</body>
</html>`;
}
