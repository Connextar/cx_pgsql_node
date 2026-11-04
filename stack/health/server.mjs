// CX_PGSQL_Node_1 health service: GET /healthz and /maintenance.json (public), /status and /metrics (bearer token).
import { readFile } from 'node:fs/promises';
import http from 'node:http';
import { ConfigError, describeConfig, loadConfig } from './src/config.mjs';
import { maintenanceFeed } from './src/maintenance.mjs';
import { CONTENT_TYPE as METRICS_TYPE, renderMetrics } from './src/metrics.mjs';
import { PG_SECTIONS, createPools, probeHost, probeObjects, probePgbouncer, probePostgres, readBackupStatus, readCertificate } from './src/probes.mjs';
import { buildReport, healthzView, makeCheck } from './src/report.mjs';
import { ProbeErrorLog, bearerToken, errorMessage, log, tokensEqual } from './src/util.mjs';

const JSON_TYPE = 'application/json; charset=utf-8';
const SHUTDOWN_DEADLINE_MS = 4_500;

let cfg;
try {
  cfg = loadConfig();
} catch (err) {
  process.stderr.write(`${err instanceof ConfigError ? err.message : errorMessage(err)}\n`);
  process.exit(1);
}

log('starting', describeConfig(cfg));
if (!cfg.token) log('warning: HEALTH_TOKEN is not set; /status and /metrics answer 503');
else if (cfg.token.length < 24) log('warning: HEALTH_TOKEN is shorter than 24 characters');

const pools = createPools(cfg, (name, err) => log('pool', name, 'idle client error:', errorMessage(err)));
const probeErrors = new ProbeErrorLog();

// ------------------------------------------------------------------ report cache

let cached = null; // { at, report }
let inflight = null;
let previous = {}; // carried between reports (archiver failed_count)

async function computeReport() {
  const started = Date.now();
  try {
    const [postgres, pgbouncer, host, backups, cert, objects] = await Promise.all([
      probePostgres(pools.postgres, cfg),
      cfg.pgbouncer.enabled ? probePgbouncer(pools, cfg) : null,
      probeHost(cfg.dataDir),
      readBackupStatus(cfg.backupStatusFile),
      cfg.certFile ? readCertificate(cfg.certFile) : null,
      cfg.objects.healthUrl ? probeObjects(cfg.objects.healthUrl) : null,
    ]);

    const errors = { postgres: postgres.connected ? null : postgres.error };
    if (postgres.connected) for (const name of PG_SECTIONS) errors[`postgres.${name}`] = postgres.errors[name] ?? null;
    if (pgbouncer) {
      errors['pgbouncer.probe'] = pgbouncer.probe.error;
      errors['pgbouncer.admin'] = pgbouncer.admin.error;
    }
    errors.disk = host.errors.disk ?? null;
    errors.backup_status_file = backups.error ? `${cfg.backupStatusFile}: ${backups.error}` : null;
    if (cert) errors.certificate = cert.error ? `${cfg.certFile}: ${cert.error}` : null;
    if (objects) errors.objects = objects.error ? `${objects.url}: ${objects.error}` : null;
    probeErrors.update(errors);

    const report = buildReport({ postgres, pgbouncer, host, backups, cert, objects }, cfg, new Date(), previous);
    const failedCount = report.wal?.archiver?.failed_count;
    if (typeof failedCount === 'number') previous = { ...previous, archiverFailedCount: failedCount };
    return { status: report.status, time: report.time, generated_in_ms: Date.now() - started, ...report };
  } catch (err) {
    // A bug in report assembly must not take the service down; report it as a failure instead.
    log('report', 'internal error:', err?.stack ?? errorMessage(err));
    const checks = [makeCheck('health_service', 'fail', 'internal error while building the report')];
    return { status: 'fail', time: new Date().toISOString(), generated_in_ms: Date.now() - started, checks };
  }
}

/** At most one computation every CACHE_SECONDS; concurrent callers share the one in flight. */
function getReport() {
  if (cached && Date.now() - cached.at < cfg.cacheSeconds * 1000) return Promise.resolve(cached.report);
  if (!inflight) {
    inflight = computeReport()
      .then((report) => {
        cached = { at: Date.now(), report };
        return report;
      })
      .finally(() => {
        inflight = null;
      });
  }
  return inflight;
}

// ------------------------------------------------------------------ HTTP

let shuttingDown = false;

function safePath(path) {
  return path.slice(0, 200).replace(/[^\x21-\x7e]/g, '?');
}

function send(req, res, status, body, { type = JSON_TYPE, headers = {} } = {}) {
  const payload = Buffer.from(typeof body === 'string' ? body : `${JSON.stringify(body, null, 2)}\n`, 'utf8');
  res.writeHead(status, {
    'content-type': type,
    'content-length': payload.length,
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
    ...(shuttingDown ? { connection: 'close' } : {}),
    ...headers,
  });
  res.end(req.method === 'HEAD' ? undefined : payload);
}

async function route(req, res) {
  // Only the path is used; a query string (including any ?token=) is ignored and never logged.
  const path = (req.url ?? '/').split('?')[0];

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(req, res, 405, { error: 'method not allowed' }, { headers: { allow: 'GET, HEAD' } });
  }

  if (path === '/healthz') {
    const report = await getReport();
    return send(req, res, report.status === 'fail' ? 503 : 200, healthzView(report));
  }

  if (path === '/maintenance.json') {
    // Public, read by every app on this server (and by browsers, hence CORS). Never touches Postgres, so it
    // answers during a maintenance window. An unreadable file is a 503: the apps keep the copy they have.
    let stored = null;
    try {
      stored = JSON.parse(await readFile(cfg.maintenance.file, 'utf8'));
    } catch (err) {
      if (err?.code !== 'ENOENT') {
        log('maintenance', 'cannot read', cfg.maintenance.file, errorMessage(err));
        return send(req, res, 503, { error: 'maintenance windows unreadable' }, { headers: { 'access-control-allow-origin': '*' } });
      }
    }
    return send(req, res, 200, maintenanceFeed(stored, new Date(), cfg.maintenance.server), {
      headers: { 'access-control-allow-origin': '*' },
    });
  }

  if (path === '/status' || path === '/metrics') {
    if (!cfg.token) return send(req, res, 503, { error: 'not configured' });
    if (!tokensEqual(bearerToken(req.headers.authorization), cfg.token)) {
      return send(req, res, 401, { error: 'unauthorized' }, { headers: { 'www-authenticate': 'Bearer realm="cx-health"' } });
    }
    const report = await getReport();
    if (path === '/status') return send(req, res, 200, report);
    return send(req, res, 200, renderMetrics(report), { type: METRICS_TYPE });
  }

  return send(req, res, 404, { error: 'not found' });
}

const server = http.createServer((req, res) => {
  const started = process.hrtime.bigint();
  req.resume(); // discard any request body
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    log('http', req.method, safePath((req.url ?? '/').split('?')[0]), res.statusCode, `${ms.toFixed(1)}ms`);
  });
  route(req, res).catch((err) => {
    log('http', 'internal error:', err?.stack ?? errorMessage(err));
    if (!res.headersSent) send(req, res, 500, { error: 'internal error' });
    else res.destroy();
  });
});
server.headersTimeout = 10_000;
server.requestTimeout = 30_000;
server.keepAliveTimeout = 5_000;

server.on('error', (err) => {
  log('fatal: cannot listen:', errorMessage(err));
  process.exit(1);
});

server.listen(cfg.port, cfg.host, () => {
  log('listening on', `${cfg.host}:${cfg.port}`);
  getReport(); // warm the cache so probe errors show up in the log straight away
});

// ------------------------------------------------------------------ lifecycle

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('received', signal, '- shutting down');
  setTimeout(() => {
    log('shutdown deadline reached; exiting');
    process.exit(1);
  }, SHUTDOWN_DEADLINE_MS).unref();

  const closed = new Promise((resolve) => server.close(resolve)); // stop accepting; resolves when connections end
  server.closeIdleConnections();
  setTimeout(() => server.closeAllConnections(), 2_000).unref();

  Promise.allSettled([closed, ...Object.values(pools).map((p) => p.end())]).then(() => {
    log('stopped');
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (err) => log('unhandled rejection:', err?.stack ?? errorMessage(err)));
