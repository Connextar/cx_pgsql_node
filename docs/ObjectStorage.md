# Object storage on this server

_Proposed 2026-10-31. The owner chose Garage the same day and asked for the server side to be built
and tested on the disposable VPS, **not applied to the real server yet**. Built and tested 2026-10-31
(§3–4, and tests/README.md). The app's side, for AltEd, is `alt-ed-web-app/docs/ObjectStorage.md`._

## 1. Why

AltEd keeps its files in Postgres as `bytea`: tutors' listing pictures (`listing_image`, about 2,027
rows, almost all of the ~480 MB database) and learners' evidence (`upload`). On Neon that cost
GB-months. On this server disk is flat-rate, so the cost now is in the backups:

- **Every dump holds every file.** The nightly dump is 410 MB, and the pictures' `COPY` takes 27–44 s
  of it. Dropbox keeps 14 daily, 8 weekly and 12 monthly dumps, so it ends up with about 34 copies of
  each file: about 14 GB at today's size, growing at 34 times the rate the files do.
- **pgBackRest** copies them again in each weekly full and in the WAL each time one is written.
  `cx-backup-verify` restores them all every Sunday.
- **The ceiling.** Plans promise up to 2 GB of evidence per family. About 60 GB is free, so about 30
  families at their limit would fill the disk, with Postgres on the same disk. Files in an S3 store
  can move to a bigger disk or another S3 provider without touching the database. Files in `bytea`
  can't.

At 480 MB none of this hurts yet. That is why now is the cheap moment to move: about 2,000 rows to
copy, not 200,000.

## 2. Options

| | **Garage** (recommended) | **Files on disk + nginx** | **SeaweedFS** | **MinIO** | **Stay in Postgres** |
|---|---|---|---|---|---|
| What | One Rust binary with an S3 API. Single node with `replication_factor = 1` | nginx `dav_methods PUT DELETE` to write, `secure_link` or the app to read | Master, volume and filer in one `weed mini` process. S3 gateway | The usual S3 server | Today's setup |
| Licence and state | AGPLv3; unmodified use is fine. Deuxfleurs, in production since 2020; v2.5.0 stable on 2026-10-24 | nginx (BSD) | Apache-2.0, very active (4.x) | **Community edition in maintenance mode Dec 2025, "no longer maintained" Feb 2026, archived since. No images published since Oct 2025, no security fixes.** Ruled out | — |
| Memory / CPU next to Postgres | Tens of MB, up to a few hundred at most; container capped at 512 MB. CPU close to nothing | None | 512 MB–2 GB (index in memory, grows with object count) | — | — |
| S3 compatible | Core API: Put/Get/Head/Delete, List, multipart, presigned URLs, CORS, SSE-C. **No versioning, object lock or bucket policies** (per-key permissions instead) | No. A custom adapter in the app | Broad | — | — |
| Effort | One compose service, a TOML template, one-time layout/bucket/key commands, an nginx site, backups. About 1–2 days with tests | Least on the server, but a write path, access tokens and listing to build ourselves | More moving parts and filer metadata to back up | — | None |
| Backup | rclone from its S3 API to an rclone **crypt** remote on Dropbox: one copy per file | rclone crypt of a directory, the simplest of all | Same as Garage | — | Already covered, but 34× over |
| How it fails | Lost metadata (LMDB) → rebuild Garage, copy back from Dropbox. Full disk → writes fail, as Postgres's would | Partial writes (nginx renames atomically); no checksums unless we add them | More states to understand | — | Dumps and restores slow down as files grow |
| Can move later | Any S3 (a bigger Garage, R2, B2, AWS `eu-west-2`) by changing the endpoint | The app's adapter has to be rewritten | Any S3 | — | Only by doing this migration later, when it's bigger |

**RustFS** (Apache-2.0, a fast-moving MinIO look-alike) is too young to hold children's files.
**A hosted S3** (AWS S3 `eu-west-2` sits beside `lhr1` at about 1 ms) would be a new processor for
children's data, with its own bill and egress. It stays the fallback if this server outgrows itself,
and the S3 API keeps that door open.

**Recommendation: Garage.** It is light enough to sit beside Postgres and speaks S3, so AltEd's code
and the backups use ordinary tools. A file can later move off this server with nothing more than a
config change. Plain files on disk are a close second, simpler on the server but with more code in
the app and no way out except a rewrite.

## 3. As built

Step **`72-objects.sh`**, between `stack` and `databases`, in the same check / apply / teardown style.
It is off unless `ENABLE_OBJECTS=true`. Day-to-day use is in [Operations.md](Operations.md#object-storage),
restores in [Restore.md](Restore.md#objects-pictures-and-uploaded-files).

- **Garage `dxflrs/garage:v2.5.0`** (pinned, `OBJECTS_IMAGE`; 2.5.0 is the stable release of
  2026-10-24, with two security fixes).
  - It runs as uid 10003 with a 512 MB limit, in **its own compose project** (`cx-pgsql-objects`,
    `stack/objects/compose.yml` → `$STACK_DIR/objects`), joined to the stack's network so the health
    service can reach it.
  - The project is named with `-p`, because the setup's exported `COMPOSE_PROJECT_NAME` otherwise wins
    over compose.yml's `name:`. Inside the stack's project, either side's `--remove-orphans` would
    remove the other. The test VPS caught this, and the step now checks the container's project.
- **`garage.toml`:**
  - `replication_factor = 1`, LMDB, and `metadata_fsync` and `data_fsync` on (one node, so nothing
    else holds a copy until the hourly one).
  - Metadata snapshots every 6 h, and `public_endpoint` set (recommended from 2.5.0).
  - No web endpoint. No secret is in the file: the RPC secret, admin token and metrics token are
    read from files.
- **Ports:** the S3 API (`28490`) and admin API (`28491`) are on loopback only. nginx serves the S3 API
  on `OBJECTS_FQDN`, passing the request and its `Host` header through unchanged (both are part of
  the signature). Bodies stream both ways, with `limit_req` and `client_max_body_size 16m`. The admin
  API is never proxied. **No firewall change:** 443 was already open.
- **Apps** are declared in `config/objects/<app>.env`: name and buckets.
  - Each app gets **one key with read and write on its own buckets only**. It is never owner, so it
    can't delete a bucket, change its settings, or set a lifecycle (owner-only from 2.5.0).
  - The key's halves are generated on the server in Garage's format and imported, so nothing is
    parsed out of Garage's output. Admin API calls take the token on stdin and bodies from a
    root-only file, so no secret is ever on a command line.
- **The server's own key, `cx-backup`,** reads every bucket and writes only `cx-verify`, the restore
  test's scratch bucket. During `objects restore` it gets write on the target bucket, and loses it
  again afterwards whatever happens.
- **Checks** (DONE / MISSING / BROKEN):
  - directories, generated files, secret copies
  - container healthy, current, and in its own project
  - layout, Garage's `/health`, every bucket, every key's grants exactly as configured
  - a signed request on loopback, an unsigned one refused, and a signed request through
    `https://OBJECTS_FQDN` via nginx (`curl --aws-sigv4`)

  A grant added by hand shows as BROKEN, and `apply` takes it away.
- **fail2ban on the endpoint is built but off** (`OBJECTS_FAIL2BAN=false`). The proposal had it on.
  On reflection, a ban drops *all* traffic from an address, and Vercel's functions share theirs: a
  misconfigured app would then lose its database as well as its files. Guessing a 256-bit key gains
  nothing anyway.
- **Health** (`stack/health`):
  - `objects`: Garage's `/health`.
  - `objects_capacity`: from the status file; warns at 50 %, fails at 90 %.
  - `backup_objects`: the off-site copy, stale after 3 h; warns when there's no copy at all.
  - `backup_verify` also fails for a bucket that failed its restore test.
  - New metrics: `cx_objects_*`, and `cx_backup_age_seconds{kind="objects"}`.

## 4. Backups, as built

- **`cx-backup-objects`, hourly at :35:**
  1. Measures every bucket for the capacity check.
  2. `rclone sync`s each backed-up bucket into `cxcrypt:live/<bucket>`. That is an rclone crypt
     remote over the existing Dropbox remote, at `BACKUP_REMOTE_PATH/objects`, with names and contents
     encrypted.
  3. Anything deleted or replaced moves to `cxcrypt:deleted/<date>/<bucket>` and is pruned after
     `OBJECTS_BACKUP_KEEP_DELETED_DAYS` (90).

  The remotes exist only in the job's environment, so there's no second rclone config holding keys.
- **Why rclone crypt and not age:** a mirror needs per-file encryption that can be compared and synced
  incrementally. The two passwords (`objects-crypt-pass`, `objects-crypt-salt`) are server secrets
  inside the age-encrypted secrets bundle. **Keep a second copy of both**, as with the pgBackRest key.
- **Weekly, in `cx-backup-verify`:**
  1. Every object older than 2 h is compared with its encrypted copy (`rclone cryptcheck`, by hash).
     The name list comes from the live side only.
  2. A random sample (`OBJECTS_VERIFY_SAMPLE`, 25 a bucket) is restored into `cx-verify` and
     compared byte for byte, then removed.
  3. A sample of the `deleted/` archive is read back in full. There is nothing live to compare it
     with, but crypt authenticates every block, so a damaged file fails to decrypt. The test VPS
     showed that without this step, a tampered file there went unnoticed.
- **A restore refreshes the off-site copy when it finishes**, so what came back from `deleted/` is in
  `live/` again at once. The test VPS showed why: until then, the weekly verify reported those
  objects missing from the copy.
- **Garage's own counts lag:** `GetBucketInfo`'s object and byte counts are updated in the background,
  so a measurement straight after a big change can read low. They catch up within minutes, so the
  hourly capacity figure is fine.

## 5. Capacity and bandwidth

- **Disk.** 69 GB with about 60 GB free, shared with Postgres, its WAL, the local pgBackRest repository
  and the dumps. Start Garage at 40 GB of capacity. Today's files are under 1 GB. The disk check
  already warns. Add a `/status` warning at 50 % of `OBJECTS_CAPACITY`, which is when to choose:
  HostHatch block storage, a larger plan, or moving the buckets to a hosted S3 (a config change in
  the app).
- **Dropbox.** One copy per file, plus deleted files for the retention period. Check the account's
  plan has the room, and how much of it the dumps take now (1.6 GB after the first full backup).
- **Egress.** Files go to Vercel and come back on the same link the `bytea` uses today, so traffic
  barely changes. The one new stream is the hourly mirror to Dropbox, which only sends new files.
  **The HostHatch plan's monthly allowance isn't recorded.** Third-party listings say "allowance,
  then throttled" at 1 TB or more. Read it from the HostHatch panel and note it in
  VPS-Comparison.md.
- **Latency.** The same 2.6 ms round trip from `lhr1` as Postgres (Performance.md). A 200 KB picture
  costs one round trip plus about 2 ms of transfer, a 4 MB file a few tens of ms. That is the same
  as reading it out of `bytea` across the same link today.

## 6. What the owner decides (server side)

1. ~~Garage, files on disk, or neither~~ — **Garage** (owner, 2026-10-31).
2. **The hostname** for the S3 endpoint (default `s3-node-1.connextar.com`) and its A record.
3. **How long deleted files stay in Dropbox** (`OBJECTS_BACKUP_KEEP_DELETED_DAYS`, default 90). Dumps
   already keep a deleted row for up to 12 months, but a shorter limit for files is easier to explain
   in the privacy policy.
4. **The rclone crypt passwords**: you keep a second copy, like the pgBackRest key.
5. **When to buy more disk**: at 50 % of capacity, or another trigger.
6. **When to switch it on for real** (§7). Nothing changes for AltEd until its own code uses the store.

## 7. Switching it on (the real server, when you say so)

The test VPS ran exactly this path on 2026-10-31: the committed version, then this one with objects
off, then on (tests/README.md).

1. **DNS:** an A record (and AAAA) for `OBJECTS_FQDN` → the server, **DNS only** in Cloudflare (as for
   `pgsql-node-1`): the proxy would break the certificate and signatures.
2. **Preview:** `bin/remote.sh sync`, then `bin/remote.sh status`. A plain `status` runs the code
   already on the server, so it shows nothing new.
3. **This version with objects still off:** `bin/remote.sh apply`. Only the **health container is
   recreated**. Postgres and PgBouncer weren't restarted, and nginx, fail2ban and the firewall were
   unchanged.
4. **Objects on:** `ENABLE_OBJECTS=true` in `config/server.env`, and `config/objects/alted.env` with
   `OBJ_BUCKETS="alted-uploads alted-listing"`, then `bin/remote.sh apply`. This adds the nginx site,
   the certificate, Garage, the buckets and keys, and the `cx-backup-objects` timer, and recreates
   the health container once more. Postgres and PgBouncer are still untouched.
5. **Second copies:** `cx-pgsql secret show objects-crypt-pass` and `… objects-crypt-salt` into your
   password manager.
6. **Run it once:** `cx-pgsql backup objects`, then `cx-pgsql health`. `objects`, `objects_capacity`
   and `backup_objects` should all be ok.
7. **For the app:** `cx-pgsql objects key alted --show-secret` → Vercel env (the app proposal's
   release A). Like the database URLs, you run this, not me.
