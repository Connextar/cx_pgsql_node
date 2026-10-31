# Operations

Everything here runs on the server as root (`sudo -i`, or from your machine:
`bin/remote.sh cx <args>` for `cx-pgsql`, `bin/remote.sh ssh` for a shell).

## Checking on it

| Command | Shows |
| --- | --- |
| `bin/remote.sh status` | Every step: DONE / MISSING / BROKEN, and the failing items |
| `cx-pgsql info` | Ports, endpoints, certificate, containers, deploy key |
| `cx-pgsql health` | The full `/status` report (connections, slow queries, backups…) |
| `curl https://<fqdn>/healthz` | `ok` / `warn` / `fail` — 503 on fail. Point an uptime monitor at it |
| `cx-pgsql logs postgres` / `pgbouncer` / `health` | Container logs (Postgres also writes `$STACK_DIR/logs/postgres/`) |
| `cx-pgsql backup status` | When each backup job last ran and how it went |
| `fail2ban-client status cx-pgbouncer` | Banned addresses (also `sshd`, `cx-postgres`) |

When something is BROKEN, `bin/remote.sh apply` repairs it: each step re-applies only when its
check fails, so a re-run is safe at any time.

## Alerts

Two independent alarms are worth having:

1. **An external uptime monitor** (Better Stack, UptimeRobot, …) on `https://<fqdn>/healthz`:
   alert on non-200. It catches the whole server being down, which nothing on the server can.
2. **n8n** (`ENABLE_N8N=true`, `N8N_FQDN` pointed here): import `stack/n8n/cx-pgsql-health-watch.json`.
   It polls `/status` every 5 minutes and emails on any change of state, naming the failing checks
   (see `stack/n8n/README.md`). The token is `cx-pgsql secret show health-token`.

`/status` judges: connection use, disk, long and blocked queries, WAL archiving, backup ages (dumps,
base backups, upload, verify), certificate expiry, transaction-ID wraparound and cache hit rate.
Thresholds: `stack/health/README.md`; the main ones are in `config/server.env`.

## Databases

**Add one:** create `config/databases/<name>.env` (copy `example.env.sample`), then
`bin/remote.sh apply`. That creates the login (with a generated password), the database owned by
it, its extensions, an optional read-only login and its PgBouncer entries, and checks the login works
through PgBouncer over TLS.

```bash
bin/remote.sh cx db url <name> --show-password
```

prints three connection strings:

- **Pooled** `…:28433/<name>?sslmode=verify-full`: what the app uses (`DATABASE_URL`). Transaction
  pooling: no session state between transactions (session-level advisory locks, `SET`, `LISTEN`).
- **Session** `…:28433/<name>_session?sslmode=verify-full`: migrations and anything that needs a
  real session (`DATABASE_DIRECT_URL` for Prisma).
- **Direct** to Postgres: over an SSH tunnel (`bin/remote.sh tunnel`, then `localhost:28432`).

`sslmode=verify-full` needs the Let's Encrypt certificate, so DNS must point here first. Until then
`cx-pgsql db url` prints `sslmode=require`.

**Change a password:** `cx-pgsql db rotate <name>` (the old one is kept as `<secret>.previous` until you
delete it). **Remove one:** delete its file and run `cx-pgsql db drop <name> --yes`. The setup never drops
a database by itself; `cx-pgsql db list` flags any that are no longer in config.

## Object storage

Off unless `ENABLE_OBJECTS=true` ([ObjectStorage.md](ObjectStorage.md) says why and how). Garage runs
beside the stack as its own compose project in `$STACK_DIR/objects`, data in `OBJECTS_DATA_DIR`.

**Switching it on** for the first time: the steps are in [ObjectStorage.md §7](ObjectStorage.md#7-switching-it-on-the-real-server-when-you-say-so).
Preview any change with `bin/remote.sh sync` and then `bin/remote.sh status`. A plain `status` runs
the code already on the server.

**Add an app:** create `config/objects/<app>.env` (copy `example.env.sample`) with its buckets, point
`OBJECTS_FQDN`'s A record here, then `bin/remote.sh apply`. That creates the buckets, one access key for
the app with read and write on those buckets only (never owner), the TLS certificate and the nginx site,
and checks a signed request through `https://<OBJECTS_FQDN>`.

```bash
bin/remote.sh cx objects key <app> --show-secret    # OBJECTS_ENDPOINT, _REGION, _ACCESS_KEY_ID, _SECRET_ACCESS_KEY
bin/remote.sh cx objects list                       # buckets (objects, size, app), keys; flags anything not in config
bin/remote.sh cx objects status                     # Garage's nodes, layout and health
```

- Clients use **path-style** addressing, region `garage`. No bucket is public and none has website access:
  every request carries a signature from a key.
- **Change a key:** `cx-pgsql objects key <app> rotate` makes a new one; the old one keeps working until
  `cx-pgsql objects key <app> drop-previous`, so the app can be redeployed in between.
- **Remove an app:** delete its file. Buckets are never deleted by the setup; `objects list` shows them as
  "not in config". Empty and delete them deliberately (with the app's key, or Garage's CLI:
  `docker exec cx-pgsql-objects /garage bucket delete --yes <bucket>`).
- **Capacity** (`OBJECTS_CAPACITY`) is what Garage plans to use, not a quota. Health warns at 50 % and fails
  at 90 % (`objects_capacity`); that's when to add disk or move the buckets elsewhere.
- **Upgrading Garage:** take `cx-pgsql backup objects` first, then change `OBJECTS_IMAGE` and apply. Read the
  release notes: since v2.5.0 a node **can't go back** to an older version once upgraded.
- fail2ban on the S3 endpoint is **off** by default (`OBJECTS_FAIL2BAN`): a ban drops all traffic from
  the address, and Vercel's functions share theirs, so a misconfigured app would lose its database too.

## Moving AltEd off Neon

1. `config/databases/alted.env` with `DB_NAME=alted` (plus any extensions the schema uses), then
   `bin/remote.sh apply`. Wait until `tls` shows the Let's Encrypt certificate.
2. Pick a quiet window. Writes made to Neon after the copy starts are not carried over.
3. Copy the data. The source URL is read from stdin, never the command line. Use Neon's **direct**
   host (without `-pooler`):
   ```bash
   bin/remote.sh ssh
   sudo cx-pgsql db import alted      # paste the Neon URL when asked
   ```
   It runs `pg_dump | pg_restore` with every object owned by `alted`, `_prisma_migrations` included.
4. In Vercel (Production) and in `.env.local`, set from `cx-pgsql db url alted --show-password`:
   - `DATABASE_URL` = the pooled URL
   - `DATABASE_DIRECT_URL` = the session URL
   - leave `DATABASE_CA_CERT` unset (Let's Encrypt chains to a public CA).
   Redeploy, then check the app and `npx prisma migrate status` against the new URL.
5. Keep the Neon project for a week as a fallback, then delete it.

Vercel functions in `lhr1` (AWS London) are closest to a London VPS: every query is a round trip —
measured at 2.63 ms from `lhr1` (Neon: 0.98 ms). Figures, method and how to re-measure:
[Performance.md](Performance.md).

## Backups

| Timer | Default | Does |
| --- | --- | --- |
| `cx-backup-logical` | 02:00 daily | `pg_dump` every database (encrypted with age if `BACKUP_AGE_RECIPIENTS` is set), checks it reads back, prunes (7 daily / 4 weekly / 6 monthly) |
| `cx-backup-physical` | 03:00 daily | pgBackRest: full if the last is ≥ 7 days old, else differential; WAL is archived continuously |
| `cx-backup-upload` | :20 hourly | Mirrors the (encrypted) pgBackRest repository and copies encrypted dumps and secrets to the remote; remote dumps pruned 14 / 8 / 12 |
| `cx-backup-objects` | :35 hourly | Only with `ENABLE_OBJECTS`. Measures the buckets (for health), then `rclone sync`s every backed-up bucket to an rclone **crypt** remote at `BACKUP_REMOTE_PATH/objects`; deleted objects move to `deleted/<date>/` there, kept `OBJECTS_BACKUP_KEEP_DELETED_DAYS` |
| `cx-backup-verify` | Sunday 05:00 | Checksums every dump, restores a fresh dump of each database into a scratch database, restores the newest base backup into a throwaway container; with objects, compares every object older than 2 h with its encrypted copy and restores a sample (`OBJECTS_VERIFY_SAMPLE`) into the `cx-verify` bucket to compare byte for byte, and reads a sample of `deleted/` back in full |

Run any of them now: `cx-pgsql backup logical|physical|upload|objects|verify`, or `cx-pgsql backup run`
(dump + base backup + upload, and objects when on). Timer state: `systemctl list-timers 'cx-backup-*'`.

### Dropbox

Once, from your machine (needs `brew install rclone`):

```bash
bin/remote.sh dropbox-auth
```

A browser window opens; sign in to the Dropbox account that should hold the backups. The token is
installed on the server (`/etc/cx-pgsql/rclone.conf`, root only), and backups go to
`BACKUP_REMOTE_PATH` in that Dropbox.

**rclone's own app gets the whole Dropbox.** Anyone who takes the server could read every file in
it. To limit the server to one folder, create your own Dropbox app (the recommended set-up):

1. dropbox.com/developers/apps → **Create app** → Scoped access → **App folder** → a name (the
   folder becomes `Apps/<name>`).
2. **Permissions** tab: tick `account_info.read`, `files.metadata.write`, `files.content.write`,
   `files.content.read`, `sharing.write` (rclone asks for these when you sign in) → **Submit**.
3. **Settings** tab: OAuth 2 Redirect URIs → add `http://localhost:53682/`.
4. Then, with the app key from the Settings tab:

```bash
bin/remote.sh dropbox-auth --client-id <app key>
```

It asks for the app secret without echoing it (or reads `DROPBOX_CLIENT_SECRET`); the secret goes
to the server on stdin, never on a command line. Backups then live in
`Apps/<app name>/<BACKUP_REMOTE_PATH>`. If you switch from rclone's app, disconnect "rclone" under
Dropbox → Settings → Connected apps so the old whole-Dropbox token stops working.

### Encryption keys

- Dumps and the secrets bundle are encrypted to your **age** public key. Make a key pair on your
  machine (`brew install age && age-keygen -o ~/cx-pgsql-backup.key`), put the `age1…` public key in
  `BACKUP_AGE_RECIPIENTS`, and keep the private key in your password manager, not on the server.
- The pgBackRest repository is encrypted with the secret `pgbackrest-cipher-pass`. It is also inside
  the encrypted secrets bundle; keep a second copy: `cx-pgsql secret show pgbackrest-cipher-pass`.
- The objects' copy is encrypted by rclone crypt with the secrets `objects-crypt-pass` and
  `objects-crypt-salt`. They are in the secrets bundle too; keep a second copy of both
  (`cx-pgsql secret show objects-crypt-pass`, `… objects-crypt-salt`). Without them the copy can't be read.

Without an age recipient, dumps stay on the server and only the pgBackRest repository uploads.

Restores: [Restore.md](Restore.md).

## Changing settings

Edit `config/server.env` and run `bin/remote.sh apply`; only the affected steps change. Postgres
settings that need a restart are reported (`stack` shows "setting waiting for a restart"); restart
with `cx-pgsql restart postgres` at a quiet moment, or set `PG_ALLOW_AUTO_RESTART=true`. Your own
`postgresql.conf` overrides go in `$STACK_DIR/config/postgres/conf.d/local.conf`, which is never overwritten.

**Upgrading Postgres to a new major version** is deliberate, not a config change:

1. `cx-pgsql backup run` (fresh dumps, uploaded).
2. Move the old pgBackRest repository aside, because a new cluster can't continue its stanza:
   `mv /data/backups/pgbackrest /data/backups/pgbackrest-pg<old>`.
3. Change `PG_VERSION` and `bin/remote.sh apply`. That creates a new, empty data directory under
   `DATA_ROOT/<version>` and a new stanza.
4. For each database: `cx-pgsql restore dump <db> latest --identity <age key> --replace --yes`.
5. `cx-pgsql backup physical full`. Delete the old data directory and repository once satisfied.

## Updates

- **Debian**: security updates install themselves (unattended-upgrades); it never reboots. Check
  `/var/run/reboot-required` now and then and reboot at a quiet moment (the stack starts by itself).
- **Postgres minor releases** (17.11 → 17.12), PgBouncer and pgBackRest come with the images. Rebuild
  from the latest base images and restart, at a quiet moment:
  ```bash
  cd /data/apps/cx-pgsql && docker compose build --pull && docker compose up -d --wait
  ```
- **n8n**: change `N8N_IMAGE` in `config/server.env` (it is pinned), then `bin/remote.sh apply`.
- **Docker** itself: `apt-get upgrade` (its packages are deliberately left out of unattended-upgrades,
  which would restart it unannounced; `live-restore` keeps the containers running through an upgrade).

## Secrets

Generated on the server under `/etc/cx-pgsql/secrets/` (root only) and never overwritten:
`postgres-password`, `cx-monitor-password`, `pgbouncer-auth-password`, `health-token`,
`pgbackrest-cipher-pass`, `db-<user>-password`, n8n's, and with objects: `objects-rpc-secret`,
`objects-admin-token`, `objects-metrics-token`, `objects-crypt-pass`, `objects-crypt-salt` and each key's
`objects-key-<name>-id` / `-secret`. Read one with
`cx-pgsql secret show <name>`. They are uploaded only inside the age-encrypted bundle.

## Tearing down

`bin/remote.sh teardown <step…|all>` undoes steps in reverse order (after typing the hostname).
Data, backups and users are kept unless `--purge` is given; the firewall and SSH teardowns also use
the automatic undo.
