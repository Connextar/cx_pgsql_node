// Small shared helpers: token comparison, logging, number coercion and SQL text masking.
import { createHash, timingSafeEqual } from 'node:crypto';

/** Constant-time token comparison. Hashing first makes the comparison independent of length. */
export function tokensEqual(provided, expected) {
  if (typeof provided !== 'string' || typeof expected !== 'string' || expected.length === 0) return false;
  const a = createHash('sha256').update(provided, 'utf8').digest();
  const b = createHash('sha256').update(expected, 'utf8').digest();
  return timingSafeEqual(a, b);
}

/** Extracts the token from an `Authorization: Bearer <token>` header, or null. */
export function bearerToken(header) {
  if (typeof header !== 'string') return null;
  const match = /^Bearer[ \t]+([^\s]+)[ \t]*$/i.exec(header);
  return match ? match[1] : null;
}

/** One log line on stdout, prefixed with an ISO timestamp. */
export function log(...parts) {
  process.stdout.write(`${new Date().toISOString()} ${parts.join(' ')}\n`);
}

/**
 * Logs each probe error once when it starts or changes, and once when it clears,
 * instead of on every report computation.
 */
export class ProbeErrorLog {
  #last = new Map();
  #write;

  constructor(write = log) {
    this.#write = write;
  }

  /** @param {Record<string, string|null|undefined>} errors probe key -> error message (or empty when fine) */
  update(errors) {
    for (const [key, message] of Object.entries(errors)) {
      const previous = this.#last.get(key);
      if (message) {
        if (message !== previous) this.#write('probe', key, 'error:', oneLine(message));
        this.#last.set(key, message);
      } else if (previous) {
        this.#write('probe', key, 'recovered');
        this.#last.delete(key);
      }
    }
  }
}

/** Collapses whitespace so a message always fits on one log line. */
export function oneLine(text) {
  return String(text).replace(/\s+/g, ' ').trim();
}

/** Error message without stack, detail or hint (those can carry values). */
export function errorMessage(err) {
  if (err == null) return 'unknown error';
  if (typeof err === 'string') return oneLine(err);
  const message = err.message || err.code || String(err);
  return oneLine(message).slice(0, 300);
}

/** True when the error came back from PostgreSQL itself (it has a SQLSTATE), so the session is still usable. */
export function isServerError(err) {
  return Boolean(err && typeof err.code === 'string' && /^[0-9A-Z]{5}$/.test(err.code));
}

/** Coerces pg values (bigint and numeric arrive as strings) to numbers; null when not numeric. */
export function num(value) {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'bigint') return Number(value);
  if (typeof value === 'string' && /^-?\d+(\.\d+)?(e[+-]?\d+)?$/i.test(value.trim())) return Number(value);
  return null;
}

// Columns that hold names or identifiers: never coerced, even when they look numeric
// (a database called "2024", a WAL file name, a queryid beyond 2^53).
const TEXT_COLUMNS = new Set([
  'datname', 'usename', 'rolname', 'schemaname', 'relname', 'database', 'user', 'pool_mode', 'list',
  'key', 'name', 'state', 'queryid', 'query', 'last_archived_wal', 'last_failed_wal', 'version',
]);

/** Copies a row, turning numeric strings (pg bigint/numeric) into numbers, except name columns. */
export function numericRow(row) {
  const out = {};
  for (const [key, value] of Object.entries(row)) {
    const n = typeof value === 'string' && !TEXT_COLUMNS.has(key) ? num(value) : null;
    out[key] = n === null ? value : n;
  }
  return out;
}

export function round(value, places = 1) {
  if (value === null || value === undefined || !Number.isFinite(value)) return null;
  const f = 10 ** places;
  return Math.round(value * f) / f;
}

/**
 * Masks string literals and dollar-quoted bodies in SQL text, collapses whitespace and truncates.
 * pg_stat_statements already replaces constants in normal statements with $n, so this is a no-op
 * for them; it matters for utility statements (e.g. ALTER ROLE ... PASSWORD '...'), which keep
 * their literals, and for raw pg_stat_activity text. Masking errs towards over-masking.
 */
export function maskSql(sql, maxLength = 200) {
  if (typeof sql !== 'string') return null;
  let out = '';
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const ch = sql[i];
    if (ch === '"') {
      // Quoted identifier: copy verbatim so a quote inside it does not start a literal.
      let j = i + 1;
      while (j < n) {
        if (sql[j] === '"') {
          if (sql[j + 1] === '"') { j += 2; continue; }
          break;
        }
        j++;
      }
      out += sql.slice(i, Math.min(j + 1, n));
      i = j + 1;
      continue;
    }
    if (ch === "'") {
      // E'...' strings treat backslash as an escape; plain strings only double the quote.
      const prefix = sql[i - 1];
      const escapes = (prefix === 'E' || prefix === 'e') && !/[A-Za-z0-9_$]/.test(sql[i - 2] ?? '');
      let j = i + 1;
      while (j < n) {
        if (escapes && sql[j] === '\\') { j += 2; continue; }
        if (sql[j] === "'") {
          if (sql[j + 1] === "'") { j += 2; continue; }
          break;
        }
        j++;
      }
      out += "'?'";
      i = j + 1;
      continue;
    }
    if (ch === '$') {
      const tag = /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i, i + 66));
      if (tag) {
        const end = sql.indexOf(tag[0], i + tag[0].length);
        out += `${tag[0]}?${tag[0]}`;
        i = end === -1 ? n : end + tag[0].length;
        continue;
      }
    }
    out += ch;
    i++;
  }
  const flat = oneLine(out);
  return flat.length > maxLength ? `${flat.slice(0, maxLength - 1)}…` : flat;
}
