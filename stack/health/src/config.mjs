// Configuration from the environment. Invalid values stop the service at start-up with a clear message;
// an unset HEALTH_TOKEN is not an error (the authenticated endpoints then answer 503 "not configured").
import { readFileSync } from 'node:fs';

export class ConfigError extends Error {
  constructor(problems) {
    super(`invalid configuration:\n  - ${problems.join('\n  - ')}`);
    this.problems = problems;
  }
}

const TRUE = new Set(['1', 'true', 'yes', 'on']);
const FALSE = new Set(['0', 'false', 'no', 'off']);

export function loadConfig(env = process.env) {
  const problems = [];
  const has = (name) => env[name] !== undefined && env[name] !== '';
  const str = (name, fallback) => (has(name) ? env[name] : fallback);

  const number = (name, fallback, { min = -Infinity, max = Infinity, integer = false } = {}) => {
    if (!has(name)) return fallback;
    const raw = env[name].trim();
    const value = Number(raw);
    if (!/^-?\d+(\.\d+)?$/.test(raw) || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
      problems.push(`${name} must be ${integer ? 'an integer' : 'a number'} between ${min} and ${max} (got "${env[name]}")`);
      return fallback;
    }
    return value;
  };

  const bool = (name, fallback) => {
    if (!has(name)) return fallback;
    const raw = env[name].trim().toLowerCase();
    if (TRUE.has(raw)) return true;
    if (FALSE.has(raw)) return false;
    problems.push(`${name} must be true or false (got "${env[name]}")`);
    return fallback;
  };

  // NAME or NAME_FILE (Docker secrets). Setting both is ambiguous and rejected.
  const secret = (name) => {
    const file = env[`${name}_FILE`];
    if (has(name) && file) {
      problems.push(`set only one of ${name} and ${name}_FILE`);
      return undefined;
    }
    if (file) {
      try {
        const value = readFileSync(file, 'utf8').replace(/[\r\n]+$/, '');
        if (!value) problems.push(`${name}_FILE (${file}) is empty`);
        return value || undefined;
      } catch (err) {
        problems.push(`${name}_FILE: cannot read ${file} (${err.code || err.message})`);
        return undefined;
      }
    }
    return has(name) ? env[name] : undefined;
  };

  const cfg = {
    host: str('HEALTH_HOST', '0.0.0.0'),
    port: number('HEALTH_PORT', 8080, { min: 1, max: 65535, integer: true }),
    token: secret('HEALTH_TOKEN'),

    pg: {
      host: str('PG_HOST', 'postgres'),
      port: number('PG_PORT', 5432, { min: 1, max: 65535, integer: true }),
      database: str('PG_DATABASE', 'postgres'),
      user: str('PG_USER', 'cx_monitor'),
      password: secret('PG_PASSWORD'),
    },

    pgbouncer: {
      enabled: bool('PGBOUNCER_ENABLED', true),
      host: str('PGBOUNCER_HOST', 'pgbouncer'),
      port: number('PGBOUNCER_PORT', 6432, { min: 1, max: 65535, integer: true }),
      probeDatabase: str('PGBOUNCER_PROBE_DATABASE', 'postgres'),
    },

    backupStatusFile: str('BACKUP_STATUS_FILE', '/backups/status/status.json'),
    // CERT_FILE set to an empty string switches the tls_cert check off; unset means the default path.
    certFile: env.CERT_FILE === undefined ? '/certs/server.crt' : env.CERT_FILE,
    dataDir: str('DATA_DIR', '/pgdata'),

    thresholds: {
      warnConnPct: number('WARN_CONN_PCT', 70, { min: 0, max: 100 }),
      failConnPct: number('FAIL_CONN_PCT', 90, { min: 0, max: 100 }),
      warnDiskPct: number('WARN_DISK_PCT', 80, { min: 0, max: 100 }),
      failDiskPct: number('FAIL_DISK_PCT', 90, { min: 0, max: 100 }),
      longQuerySeconds: number('LONG_QUERY_SECONDS', 60, { min: 1 }),
      warnBlockedSeconds: number('WARN_BLOCKED_SECONDS', 30, { min: 0 }),
      backupMaxAgeHours: number('BACKUP_MAX_AGE_HOURS', 26, { min: 0 }),
      uploadMaxAgeHours: number('UPLOAD_MAX_AGE_HOURS', 26, { min: 0 }),
      verifyMaxAgeHours: number('VERIFY_MAX_AGE_HOURS', 192, { min: 0 }),
      walArchiveMaxAgeMinutes: number('WAL_ARCHIVE_MAX_AGE_MINUTES', 30, { min: 1 }),
      certWarnDays: number('CERT_WARN_DAYS', 14, { min: 0 }),
      certFailDays: number('CERT_FAIL_DAYS', 3, { min: 0 }),
      minCacheHitPct: number('MIN_CACHE_HIT_PCT', 90, { min: 0, max: 100 }),
    },

    cacheSeconds: number('CACHE_SECONDS', 15, { min: 0, max: 3600 }),
    includeQueryText: bool('STATUS_INCLUDE_QUERY_TEXT', false),
  };

  const t = cfg.thresholds;
  if (t.warnConnPct > t.failConnPct) problems.push('WARN_CONN_PCT must not exceed FAIL_CONN_PCT');
  if (t.warnDiskPct > t.failDiskPct) problems.push('WARN_DISK_PCT must not exceed FAIL_DISK_PCT');
  if (t.certFailDays > t.certWarnDays) problems.push('CERT_FAIL_DAYS must not exceed CERT_WARN_DAYS');

  if (problems.length) throw new ConfigError(problems);
  return cfg;
}

/** Start-up summary without secrets. */
export function describeConfig(cfg) {
  return [
    `listen=${cfg.host}:${cfg.port}`,
    `token=${cfg.token ? 'set' : 'UNSET'}`,
    `pg=${cfg.pg.user}@${cfg.pg.host}:${cfg.pg.port}/${cfg.pg.database}`,
    `pg_password=${cfg.pg.password ? 'set' : 'unset'}`,
    cfg.pgbouncer.enabled ? `pgbouncer=${cfg.pgbouncer.host}:${cfg.pgbouncer.port} probe_db=${cfg.pgbouncer.probeDatabase}` : 'pgbouncer=disabled',
    `cache=${cfg.cacheSeconds}s`,
    `query_text=${cfg.includeQueryText}`,
  ].join(' ');
}
