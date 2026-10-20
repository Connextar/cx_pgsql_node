import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { ProbeErrorLog, bearerToken, isServerError, maskSql, numericRow, tokensEqual } from '../src/util.mjs';

describe('token comparison', () => {
  const token = 'c0rrect-horse-battery-staple-0123456789';

  test('accepts only the exact token', () => {
    assert.equal(tokensEqual(token, token), true);
    assert.equal(tokensEqual(`${token} `, token), false);
    assert.equal(tokensEqual(token.slice(0, -1), token), false);
    assert.equal(tokensEqual(`${token.slice(0, -1)}X`, token), false); // same length, last char differs
    assert.equal(tokensEqual(token.toUpperCase(), token), false);
    assert.equal(tokensEqual('', token), false);
  });

  test('never matches when no token is configured or nothing was sent', () => {
    assert.equal(tokensEqual('', ''), false);
    assert.equal(tokensEqual('anything', undefined), false);
    assert.equal(tokensEqual(null, token), false);
    assert.equal(tokensEqual(undefined, token), false);
    assert.equal(tokensEqual(['x'], token), false);
  });

  test('bearer header parsing', () => {
    assert.equal(bearerToken('Bearer abc.def-123'), 'abc.def-123');
    assert.equal(bearerToken('bearer abc'), 'abc');
    assert.equal(bearerToken('Bearer   abc  '), 'abc');
    assert.equal(bearerToken('Basic dXNlcjpwYXNz'), null);
    assert.equal(bearerToken('Bearer'), null);
    assert.equal(bearerToken('Bearer a b'), null);
    assert.equal(bearerToken('abc'), null);
    assert.equal(bearerToken(undefined), null);
  });
});

describe('maskSql', () => {
  test('normalised pg_stat_statements text passes through', () => {
    assert.equal(maskSql('SELECT * FROM learner WHERE id = $1 AND guardian_id = ANY($2)'), 'SELECT * FROM learner WHERE id = $1 AND guardian_id = ANY($2)');
  });

  test('string literals are masked, including passwords in utility statements', () => {
    const out = maskSql("ALTER ROLE app PASSWORD 'hunter2' VALID UNTIL '2027-01-01'");
    assert.equal(out, "ALTER ROLE app PASSWORD '?' VALID UNTIL '?'");
    assert.equal(maskSql("SELECT 'it''s a secret', name FROM t"), "SELECT '?', name FROM t");
  });

  test('E-strings with backslash escapes do not leak their tail', () => {
    const out = maskSql("SELECT E'secret\\' AND x = ' AS a, y FROM t");
    assert.doesNotMatch(out, /secret|AND x/);
    assert.equal(out, "SELECT E'?' AS a, y FROM t");
  });

  test('dollar-quoted bodies are masked; $n placeholders are not', () => {
    assert.equal(maskSql('DO $$BEGIN PERFORM 1; END$$'), 'DO $$?$$');
    assert.equal(maskSql('SELECT $tag$ secret $tag$, $1'), 'SELECT $tag$?$tag$, $1');
  });

  test('quotes inside identifiers do not start a literal', () => {
    assert.equal(maskSql('SELECT "it\'s" FROM t WHERE a = \'x\''), 'SELECT "it\'s" FROM t WHERE a = \'?\'');
  });

  test('an unterminated literal (cut off upstream) masks to the end', () => {
    assert.equal(maskSql("INSERT INTO t VALUES ('Jane Doe, 12 Acacia"), "INSERT INTO t VALUES ('?'");
  });

  test('whitespace collapses and the result is at most 200 characters', () => {
    assert.equal(maskSql('SELECT\n   1\t\tFROM   t'), 'SELECT 1 FROM t');
    const long = maskSql(`SELECT ${'col, '.repeat(200)}x FROM t`);
    assert.equal(long.length, 200);
    assert.ok(long.endsWith('…'));
    assert.equal(maskSql(null), null);
  });
});

describe('row and error helpers', () => {
  test('numericRow converts pg bigint strings but keeps name columns as text', () => {
    const row = numericRow({ datname: '2024', relname: '123', calls: '42', total_exec_time: 1.5, last_archived_wal: '000000010000000000000003', note: 'abc' });
    assert.deepEqual(row, { datname: '2024', relname: '123', calls: 42, total_exec_time: 1.5, last_archived_wal: '000000010000000000000003', note: 'abc' });
  });

  test('isServerError recognises SQLSTATE codes only', () => {
    assert.equal(isServerError({ code: '57014' }), true);
    assert.equal(isServerError({ code: 'ECONNREFUSED' }), false);
    assert.equal(isServerError(new Error('Query read timeout')), false);
  });

  test('ProbeErrorLog logs an error once, again when it changes, and once on recovery', () => {
    const lines = [];
    const log = new ProbeErrorLog((...parts) => lines.push(parts.join(' ')));
    log.update({ postgres: 'connect ECONNREFUSED' });
    log.update({ postgres: 'connect ECONNREFUSED' });
    log.update({ postgres: 'connect ECONNREFUSED' });
    log.update({ postgres: 'timeout' });
    log.update({ postgres: null, disk: null });
    log.update({ postgres: null });
    assert.deepEqual(lines, ['probe postgres error: connect ECONNREFUSED', 'probe postgres error: timeout', 'probe postgres recovered']);
  });
});
