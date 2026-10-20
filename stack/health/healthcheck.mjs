// Docker HEALTHCHECK: is this service alive and answering? A 503 from /healthz means PostgreSQL (or a
// backup, disk, ...) is unhealthy, not this process, so both 200 and 503 with a verdict count as alive.
// That keeps a database outage from also marking the monitor itself unhealthy.
const port = process.env.HEALTH_PORT || '8080';
const host = ['', '0.0.0.0', '::'].includes(process.env.HEALTH_HOST ?? '') ? '127.0.0.1' : process.env.HEALTH_HOST;

try {
  const res = await fetch(`http://${host.includes(':') ? `[${host}]` : host}:${port}/healthz`, { signal: AbortSignal.timeout(12_000) });
  const body = await res.json();
  const alive = (res.status === 200 || res.status === 503) && ['ok', 'warn', 'fail'].includes(body?.status);
  process.exit(alive ? 0 : 1);
} catch {
  process.exit(1);
}
