// The planned-downtime notice: sent when a reboot (or power-off) is booked, moved or cancelled, and when a
// maintenance window is booked by hand (`cx-pgsql maintenance plan|start|extend|cancel`), so nobody finds out
// from the outage. lib/report.sh and lib/maintenance.sh gather the facts; this turns them into the email.
// Same frame as the nightly report.
//
// Input: { server { hostname, fqdn }, timezone, notice: { kind: booked|moved|extended|cancelled,
//          mode: reboot|poweroff|maintenance, at, previous_at?, ends_by?, previous_ends_by?, expected_minutes?,
//          message?, reason?, packages[], last_reboot { at, offline_seconds }?, databases[], objects, feed? } }
import { C, FONT, emailPage, esc, rows, section, small } from './digest-html.mjs';
import { formatDuration, formatWhen } from './digest.mjs';

/** What the downtime will likely be: the last reboot's measured gap plus time for Postgres to be ready. */
export function expectedDowntime(lastReboot) {
  const offline = typeof lastReboot?.offline_seconds === 'number' && lastReboot.offline_seconds >= 0 ? lastReboot.offline_seconds : null;
  const minutes = Math.max(1, Math.ceil(((offline ?? 15) + 60) / 60));
  return { minutes, text: `about ${minutes} minute${minutes === 1 ? '' : 's'}`, measured: offline };
}

/** A window booked by hand states its own length. */
function statedDowntime(minutes) {
  const m = Math.max(1, Math.ceil(minutes));
  const text = m >= 120 && m % 60 === 0 ? `about ${m / 60} hours` : `about ${m} minute${m === 1 ? '' : 's'}`;
  return { minutes: m, text, measured: null };
}

const p = (text) => `<p style="margin:0 0 10px;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};">${text}</p>`;
const code = (text) => `<code style="font-size:13px;">${esc(text)}</code>`;

export function rebootNotice(input, nowArg) {
  const now = nowArg ?? new Date(input.generated_at ?? Date.now());
  const tz = input.timezone ?? 'Europe/London';
  const host = input.server?.hostname ?? 'server';
  const n = input.notice ?? {};
  const manual = n.mode === 'maintenance';
  const what = manual ? 'goes down for maintenance' : n.mode === 'poweroff' ? 'shuts down' : 'reboots';
  const noun = manual ? 'maintenance' : n.mode === 'poweroff' ? 'shutdown' : 'reboot';
  const when = formatWhen(n.at, tz);
  const whenUtc = n.at ? new Date(n.at).toISOString().replace('T', ' ').slice(0, 16) + ' UTC' : null;
  const until = manual && n.ends_by ? formatWhen(n.ends_by, tz, { date: false }) : null;
  const inHours = n.at ? (Date.parse(n.at) - now.getTime()) / 3_600_000 : null;
  const soon = inHours === null ? null : inHours > 0.01 ? `in ${formatDuration(Math.round(inHours * 3600)) ?? 'a moment'}` : 'now';
  const down = manual && n.expected_minutes > 0 ? statedDowntime(n.expected_minutes) : expectedDowntime(n.last_reboot);
  const affected = [
    n.databases?.length ? `PostgreSQL and PgBouncer — ${n.databases.join(', ')}` : 'PostgreSQL and PgBouncer',
    n.objects ? 'object storage (files and pictures)' : null,
    manual ? null : 'the health endpoint (/healthz answers nothing)',
  ].filter(Boolean);

  let subject;
  let title;
  let lead;
  if (n.kind === 'cancelled') {
    subject = `✅ ${host}: planned ${noun} cancelled`;
    title = `Planned ${noun} cancelled`;
    lead = `The ${noun} booked for ${formatWhen(n.previous_at ?? n.at, tz)} is off. Nothing will go down.`;
  } else if (n.kind === 'extended') {
    subject = `⏱ ${host}: maintenance running over — until ${until}`;
    title = 'Maintenance running over';
    lead = `The maintenance window now runs until ${formatWhen(n.ends_by, tz)}${n.previous_ends_by ? ` (it was ${formatWhen(n.previous_ends_by, tz, { date: false })})` : ''}.`;
  } else {
    const moved = n.kind === 'moved';
    subject = manual
      ? `🛠 ${host} maintenance ${formatWhen(n.at, tz)} — ${down.text} down${moved ? ' (moved)' : ''}`
      : `🔁 ${host} ${what} ${formatWhen(n.at, tz, { date: true, time: true })} — ${down.text} down${moved ? ' (moved)' : ''}`;
    title = soon === 'now' ? `${host} ${what} now` : `${host} ${what} ${soon ?? 'soon'}`;
    lead = moved
      ? `The ${noun} has moved from ${formatWhen(n.previous_at, tz)} to ${when}.`
      : soon === 'now'
        ? `Maintenance started at ${when}.`
        : `${manual ? 'Maintenance' : `A ${noun}`} is booked for ${when}.`;
  }

  const why = manual
    ? n.message || null
    : n.packages?.length
      ? `Updates that need it: ${n.packages.slice(0, 6).join(', ')}${n.packages.length > 6 ? ` and ${n.packages.length - 6} more` : ''}.`
      : n.reason || null;

  const appsRow = n.feed
    ? ['The apps', manual || n.kind !== 'cancelled' ? 'show a planned-maintenance notice until it starts, then a maintenance page; they come back by themselves when it ends' : null]
    : ['The apps', null];

  const fixRows = manual
    ? [
        ['Finished early', code('cx-pgsql maintenance end')],
        ['Running over', code('cx-pgsql maintenance extend 15m')],
        ['Call it off', code('cx-pgsql maintenance cancel')],
      ]
    : [
        ['Cancel it', code('sudo shutdown -c')],
        ['Move it', code('sudo shutdown -r 02:30')],
      ];

  let body;
  if (n.kind === 'cancelled') {
    body = section('What changed', `<p style="margin:0 0 14px;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};">${esc(lead)}</p>`);
  } else {
    const whenCell = `${esc(manual && until ? `${when} – ${until}` : when)}${whenUtc && !when.endsWith('UTC') ? `<br>${small(esc(whenUtc))}` : ''}`;
    const downNote =
      down.measured !== null
        ? `<br>${small(esc(`the last reboot${n.last_reboot?.at ? ` (${formatWhen(n.last_reboot.at, tz, { time: false })})` : ''} was offline for ${down.measured} s; Postgres then takes up to a minute to be ready`))}`
        : '';
    body = `${section(
      n.kind === 'extended' ? 'Maintenance running over' : 'Planned downtime',
      `${p(esc(lead))}
${rows([
  ['When', whenCell],
  [n.kind === 'extended' ? 'Now until' : 'Expected downtime', n.kind === 'extended' ? `<strong class="strong" style="color:${C.text};">${esc(formatWhen(n.ends_by, tz))}</strong>` : `<strong class="strong" style="color:${C.text};">${esc(down.text)}</strong>${downNote}`],
  ['Why', why ? esc(why) : null],
  ['Unavailable meanwhile', affected.map(esc).join('<br>')],
  appsRow,
  ['Comes back', manual ? 'when the work is done and the window is ended, or at the end of the window' : 'by itself: every container restarts at boot'],
])}`,
    )}
${section(
  manual ? 'If plans change' : 'If the time is wrong',
  `<p style="margin:0 0 6px;font-family:${FONT};font-size:14px;line-height:20px;color:${C.text};">On the server (<span style="white-space:nowrap;">bin/remote.sh ssh</span>):</p>
${rows(fixRows)}
<p class="muted" style="margin:0 0 14px;font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};">${manual ? 'Ending it early brings the apps back within seconds. Extending or calling it off sends another email.' : `Either way you'll get another email. The next morning's report shows how long the ${noun} actually took.`}</p>`,
)}`;
  }

  const sentWhen = n.kind === 'cancelled' ? 'cancelled' : n.kind === 'moved' ? 'moved' : n.kind === 'extended' ? 'extended' : 'booked';
  const html = emailPage({
    subject,
    preheader: n.kind === 'cancelled' || n.kind === 'extended' ? lead : `${lead} Expected downtime ${down.text}.`,
    band: n.kind === 'cancelled' ? C.ok.band : n.kind === 'extended' ? C.warn.band : C.info.band,
    kicker: `${host} · planned ${noun}`,
    title,
    subtitle: n.kind === 'cancelled' ? `Notice sent ${formatWhen(now, tz)}` : n.kind === 'extended' ? `until ${formatWhen(n.ends_by, tz)}` : `${when} · ${down.text} down`,
    body,
    footer: `Sent by ${esc(host)} (CX_PGSQL_Node_1) when the ${noun} was ${sentWhen}, at ${esc(formatWhen(now, tz))}.`,
  });

  const fixText = manual
    ? 'Finished early: cx-pgsql maintenance end   Running over: cx-pgsql maintenance extend 15m   Call it off: cx-pgsql maintenance cancel'
    : 'To cancel: sudo shutdown -c   To move: sudo shutdown -r 02:30   (another email follows either way)';
  const text =
    n.kind === 'cancelled'
      ? `${subject.replace(/^\S+\s/, '')}\n\n${lead}\n`
      : [
          subject.replace(/^\S+\s/, ''),
          '',
          lead,
          '',
          `  When                 ${manual && until ? `${when} – ${until}` : when}${whenUtc && !when.endsWith('UTC') ? ` (${whenUtc})` : ''}`,
          n.kind === 'extended'
            ? `  Now until            ${formatWhen(n.ends_by, tz)}`
            : `  Expected downtime    ${down.text}${down.measured !== null ? ` (last reboot offline ${down.measured} s, plus Postgres starting)` : ''}`,
          why ? `  Why                  ${why}` : null,
          `  Unavailable          ${affected.join('; ')}`,
          appsRow[1] ? `  The apps             ${appsRow[1]}` : null,
          `  Comes back           ${manual ? 'when the work is done and the window is ended, or at the end of the window' : 'by itself: every container restarts at boot'}`,
          '',
          fixText,
          '',
        ]
          .filter((l) => l !== null)
          .join('\n');

  return { subject, html, text };
}
