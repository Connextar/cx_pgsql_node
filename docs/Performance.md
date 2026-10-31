# Performance: what was measured, and what it means

Measured for the first app on this server, AltEd, when it moved off Neon (2026-10-30/31). Re-measure
after any change of server, region or provider, and add the new figures here with their date.

## 1. Round trips from the app (Vercel `lhr1`), 2026-10-30

**Method.** A temporary admin-only route in AltEd (`/api/admin/db-latency`, commit `a246fa7` in
`alt-ed-web-app`; removed in v0.151.1 — `git show a246fa7` brings it back). It ran in production on
Vercel's `lhr1` (AWS eu-west-2, London) and made 30 sequential trials against each database:

- **connect** — a TCP handshake: one network round trip.
- **protocol round trip** — Postgres's 8-byte `SSLRequest` and its one-byte reply, with no login: one
  round trip through the network stack and Postgres's front door. **Each sequential query costs about
  this much in travel**, before its execution time.
- **`SELECT 1` through the app's pool** (Neon only, the database the app used then): a real query
  through Prisma's pg adapter and Neon's pooler — round trip plus overhead.

| From Vercel `lhr1`, 30 trials         | This server (HostHatch London, PgBouncer `:28433`) | Neon (`eu-west-2`, pooler `:5432`) |
| ------------------------------------- | -------------------------------------------------- | ---------------------------------- |
| Protocol round trip — median          | **2.63 ms**                                        | **0.98 ms**                        |
| Protocol round trip — min / p90 / max | 2.21 / 2.89 / 2.96 ms                              | 0.36 / 2.67 / 2.72 ms              |
| TCP connect — median                  | 3.18 ms                                            | 2.70 ms                            |
| TCP connect — min / p90 / max         | 2.80 / 3.43 / 36.34 ms                             | 1.60 / 5.48 / 5.83 ms              |
| `SELECT 1` via the app's pool — median | —                                                  | 1.45 ms (min 1.32, p90 1.84, max 2.87) |
| Failures                              | 0 of 30                                            | 0 of 30                            |

**What it means.**

- **+1.65 ms per sequential round trip** (2.63 − 0.98 medians). A page whose queries wait on each other
  pays it once per query: 10 such queries ≈ +16 ms, 30 ≈ +50 ms. Queries run side by side
  (`Promise.all`) pay it once between them.
- **Expected `SELECT 1` from the app here: about 3 ms** (Neon's 1.45 ms − 0.98 + 2.63).
- **Steadier than Neon.** This server's p90 is within 0.3 ms of its median; Neon's is nearly 3× its
  median. One slow connect (36 ms) in 30; no failures.
- **No cold starts.** Neon scales to zero and wakes in hundreds of milliseconds on the first query
  after a quiet spell, which dwarfs the per-query difference; this server never sleeps.
- **A new connection** costs a TCP handshake, a TLS 1.3 handshake and SCRAM login: about six round
  trips (≈ 15 ms here). The app's pool keeps connections across requests on a warm instance, so most
  requests pay none of it.

Raw response (2026-10-30, `?n=30`):

```json
{"region":"lhr1","trials":30,
 "selfHosted":{"target":"pgsql-node-1.connextar.com:28433",
  "connect":{"trials":30,"failed":0,"minMs":2.8,"medianMs":3.18,"p90Ms":3.43,"maxMs":36.34},
  "protocolRoundTrip":{"trials":30,"failed":0,"minMs":2.21,"medianMs":2.63,"p90Ms":2.89,"maxMs":2.96}},
 "current":{"target":"ep-rapid-moon-abyjmwb3-pooler.eu-west-2.aws.neon.tech:5432",
  "connect":{"trials":30,"failed":0,"minMs":1.6,"medianMs":2.7,"p90Ms":5.48,"maxMs":5.83},
  "protocolRoundTrip":{"trials":30,"failed":0,"minMs":0.36,"medianMs":0.98,"p90Ms":2.67,"maxMs":2.72}},
 "currentSelect1ViaPool":{"trials":30,"failed":0,"minMs":1.32,"medianMs":1.45,"p90Ms":1.84,"maxMs":2.87}}
```

**The earlier estimate was pessimistic.** Before this, a round trip measured _from the server_ towards
AWS London came out at about 4.7 ms, which suggested ~+4 ms a query (~110 ms on a 30-query page). The
figure from where the app actually runs is the one to trust.

## 2. Inside the server, 2026-10-31

From `pg_stat_statements` and `pg_stat_database` on 2026-10-31 at about 11:15 UTC: a window that
opened 2026-10-30 18:13 and holds the two imports and the backups (which dominate its totals), but
only about an hour of the app's own traffic after the 10:09 switch — a quiet Saturday morning, so
re-read it after a busy week:

- **The app's queries execute in 0.001–0.3 ms** on average: session and user look-ups 0.03–0.06 ms,
  audit and rate-limit inserts 0.17–0.28 ms, listing reads ~0.04 ms.
- **Cache hit 99.95%.** The whole database (~480 MB) fits in memory: `shared_buffers` 2.3 GB, 16 GB RAM.
- **Settings:** `random_page_cost` 1.1 (SSD), `effective_io_concurrency` 200, `work_mem` 12 MB,
  `wal_compression` zstd, `jit` on.

**What it means:** execution is a small fraction of the ~2.6 ms of travel per query, so tuning
Postgres buys little. The lever is **fewer sequential round trips per page** — work in the app, not on
this server.

## 3. Backups

- AltEd's encrypted dump: **410 MB**, almost all of it listing pictures (`listing_image.content`,
  pictures stored in Postgres): its `COPY` takes 27–44 s of the dump's time.
- Dropbox held **1.6 GB** after the first full backup with production data (dumps plus the
  pgBackRest repository with its WAL).

## How to re-measure

- **From the app:** restore AltEd's probe (`git show a246fa7`), deploy, open
  `https://www.alted.ac/api/admin/db-latency?n=30` signed in as an administrator, then remove it again.
- **Inside the server:** `pg_stat_statements` (view in the `postgres` database; the counts cover every
  database). `SELECT pg_stat_statements_reset();` starts a clean window.
