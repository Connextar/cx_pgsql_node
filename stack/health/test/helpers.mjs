// Fixture probe results shaped like the real probes' output, for the pure report/metrics tests.
import { readFileSync } from 'node:fs';
import { loadConfig } from '../src/config.mjs';

export const NOW = new Date('2026-10-20T08:00:00Z');
export const FIXTURES = new URL('./fixtures/', import.meta.url);

export function testConfig(env = {}) {
  return loadConfig({ HEALTH_TOKEN: 'test-token-0123456789abcdef', ...env });
}

export function statusFixture() {
  return JSON.parse(readFileSync(new URL('status.json', FIXTURES), 'utf8'));
}

const ago = (seconds) => new Date(NOW.getTime() - seconds * 1000);

export function healthyProbes() {
  return {
    postgres: {
      connected: true,
      response_ms: 4,
      error: null,
      errors: {},
      data: {
        server: {
          version: '17.6 (Debian 17.6-1.pgdg120+1)',
          version_num: 170006,
          start_time: ago(86_400),
          uptime_seconds: 86_400,
          in_recovery: false,
          probe_database: 'postgres',
        },
        settings: {
          max_connections: { value: '100', setting: '100' },
          shared_buffers: { value: '1GB', setting: '131072' },
          effective_cache_size: { value: '3GB', setting: '393216' },
          work_mem: { value: '16MB', setting: '16384' },
          archive_mode: { value: 'on', setting: 'on' },
          wal_level: { value: 'replica', setting: 'replica' },
          ssl: { value: 'on', setting: 'on' },
        },
        connections: [
          { datname: 'alted', usename: 'alted_app', state: 'idle', count: 8, oldest_xact_seconds: null, longest_active_seconds: null },
          { datname: 'alted', usename: 'alted_app', state: 'active', count: 1, oldest_xact_seconds: 0.4, longest_active_seconds: 0.4 },
          { datname: 'postgres', usename: 'cx_monitor', state: 'active', count: 1, oldest_xact_seconds: null, longest_active_seconds: null },
        ],
        databases: [
          { datname: 'alted', is_template: false, allow_connections: true, size_bytes: 1_200_000_000, numbackends: 9, xact_commit: 500_000, xact_rollback: 12, blks_read: 2_000, blks_hit: 998_000, deadlocks: 0, temp_files: 3, temp_bytes: 4096, conflicts: 0, frozen_xid_age: 5_000_000, min_mxid_age: 10 },
          { datname: 'postgres', is_template: false, allow_connections: true, size_bytes: 8_000_000, numbackends: 1, xact_commit: 9_000, xact_rollback: 0, blks_read: 100, blks_hit: 200, deadlocks: 0, temp_files: 0, temp_bytes: 0, conflicts: 0, frozen_xid_age: 4_000_000, min_mxid_age: 0 },
          { datname: 'template0', is_template: true, allow_connections: false, size_bytes: 7_500_000, numbackends: null, xact_commit: null, xact_rollback: null, blks_read: null, blks_hit: null, deadlocks: null, temp_files: null, temp_bytes: null, conflicts: null, frozen_xid_age: 6_000_000, min_mxid_age: 0 },
        ],
        long_running: [],
        blocked: [],
        archiver: {
          archived_count: 500,
          last_archived_wal: '0000000100000000000000F3',
          last_archived_time: ago(120),
          last_archived_age_seconds: 120,
          failed_count: 0,
          last_failed_wal: null,
          last_failed_time: null,
          last_failed_age_seconds: null,
        },
        wal_pending: { ready: 0, oldest_ready_time: null, oldest_ready_age_seconds: null },
        stat_wal: { wal_records: 1000, wal_fpi: 10, wal_bytes: 123456 },
        checkpointer: { num_timed: 10, num_requested: 1, buffers_written: 500 },
        bgwriter: { buffers_clean: 0, maxwritten_clean: 0, buffers_alloc: 1000 },
        vacuum: [],
        statements: { available: true, rows: [] },
      },
    },
    pgbouncer: null,
    host: {
      cpu_count: 4,
      load: { load1: 0.5, load5: 0.4, load15: 0.3, source: '/proc/loadavg' },
      memory: { total_bytes: 8 * 1024 ** 3, available_bytes: 5 * 1024 ** 3, free_bytes: 1024 ** 3, source: '/proc/meminfo' },
      disk: { path: '/pgdata', total_bytes: 100e9, used_bytes: 40e9, free_bytes: 60e9, used_pct: 40 },
      errors: {},
    },
    backups: { path: '/backups/status/status.json', present: true, data: statusFixture() },
    cert: {
      file: '/certs/server.crt',
      subject: 'CN=db.example.test',
      issuer: 'CN=db.example.test',
      subject_alt_names: ['DNS:db.example.test'],
      valid_from: '2026-01-01T00:00:00.000Z',
      valid_to: '2027-01-01T00:00:00.000Z',
    },
  };
}

export function unreachableProbes() {
  const p = healthyProbes();
  p.postgres = { connected: false, response_ms: null, error: 'connect ECONNREFUSED 127.0.0.1:5432', data: {}, errors: {} };
  return p;
}

export const byName = (report) => Object.fromEntries(report.checks.map((c) => [c.name, c]));
