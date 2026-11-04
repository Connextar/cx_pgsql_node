// The nightly report's renderer: one JSON document of facts on stdin (lib/report.sh gathers them), one JSON
// document out: { status, subject, preheader, issues, html, text, snapshot }. Runs inside the health container
// (`docker exec -i cx-pgsql-health node /app/digest.mjs`), so it needs nothing the image doesn't have; it opens
// no connections and writes nothing — sending, and keeping the snapshot for tomorrow, are the host's job.
import { buildDigest, digestText } from './src/digest.mjs';
import { digestHtml } from './src/digest-html.mjs';

const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);

let input;
try {
  input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
} catch (err) {
  process.stderr.write(`digest: stdin is not JSON (${err.message})\n`);
  process.exit(2);
}

const digest = buildDigest(input);
process.stdout.write(
  JSON.stringify({
    status: digest.status,
    subject: digest.subject,
    preheader: digest.preheader,
    issues: digest.issues,
    html: digestHtml(digest),
    text: digestText(digest),
    snapshot: digest.snapshot,
  }),
);
