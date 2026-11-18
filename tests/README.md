# Testing on a disposable "VPS"

`tests/vps.sh` runs a fresh Debian 13 machine (`DEBIAN_RELEASE=bookworm tests/vps.sh up` for 12) in a
container: systemd as PID 1, sshd on port 22 and
root logging in with a throwaway key, nothing else. That is the state a new VPS arrives in, so the
real `bin/remote.sh` and `setup.sh` run against it unchanged, including Docker inside it.

```bash
tests/vps.sh up                       # build and start it (always fresh)
P=tests/.cache/project                # a copy of the project with a test config (see below)
rsync -a --exclude tests --exclude .git --exclude node_modules ./ "$P/"
(cd "$P" && ./bin/remote.sh apply)    # the whole setup, as on a real server
(cd "$P" && ./bin/remote.sh status)
tests/vps.sh exec cx-pgsql backup run  # anything on the "server"
tests/vps.sh down                     # remove it and its volumes
```

The test copy's `config/server.env` points at the container's mapped ports:

```bash
SERVER_HOSTNAME=cx-pgsql-test
SERVER_FQDN=psql-test.example.invalid      # never resolves → exercises the self-signed path
SERVER_IP=127.0.0.1
SSH_PORT=19225                             # mapped 1:1
BOOTSTRAP_SSH_PORT=2222                    # → the container's 22
REMOTE_SSH_IDENTITY=<absolute path>/tests/.cache/id_ed25519
SWAP_SIZE_MB=0                             # swap would land on Docker's VM, not the container
PG_MEMORY_LIMIT=1g
F2B_IGNORE_IPS="172.17.0.1"                # the Docker bridge gateway your connections come from
BACKUP_AGE_RECIPIENTS="<age1… from age-keygen>"
BACKUP_REMOTE_PATH=/srv/fake-dropbox/CX_PGSQL_Node_1
```

and `/etc/cx-pgsql/rclone.conf` on the "server" holds `[dropbox]` / `type = local`, so uploads land
in a folder instead of Dropbox.

Ports on your machine: 2222 (bootstrap SSH), 19225 (SSH), 28433 (PgBouncer), 8443 (HTTPS),
8080 (HTTP). Health endpoint: `curl -k --resolve psql-test.example.invalid:8443:127.0.0.1 https://psql-test.example.invalid:8443/healthz`.

## What was run (2026-10-20)

On Debian 12 first, then again on Debian 13 (13.7: full apply, idempotent re-run, TLS logins, health,
backup → verify → dump restore → in-place point-in-time restore, fail2ban ban, n8n and the Node/PM2 step):

- Fresh VPS → `remote.sh apply` (root on 22 → `connextar` on 19225, both changes confirmed from a
  new connection) → every step DONE; a second `apply` applies nothing.
- An unconfirmed SSH change reverting itself after `ROLLBACK_SECONDS` (sshd back on 22).
- PgBouncer from outside: TLS 1.3 login; plain text refused; advisory locks on `<db>_session`.
- `/healthz`, `/status` (401 without token), `/metrics` through nginx; no secret in either response.
- Backups: encrypted dump, pgBackRest full backup, upload, verify (dump restore + base backup restored
  into a throwaway container); restore of a dump into a new database; point-in-time copy from just
  before a dropped table; in-place restore of the live cluster to that moment.
- Drift: firewall table deleted, `pgbouncer.ini` edited, PgBouncer stopped, a timer disabled →
  `status` shows each BROKEN item → `apply` repairs them.
- fail2ban: six bad PgBouncer passwords from another container → banned in the firewall set before
  Docker's NAT, next connection times out; both filters checked with `fail2ban-regex`.
- Teardown of the stack and re-apply with the data intact; n8n enabled, healthy behind nginx, the
  alert workflow imported with `n8n import:workflow`.

Side effects on your machine: the container shares Docker Desktop's kernel, so the base step's
kernel-wide settings (`vm.swappiness`, `kernel.kptr_restrict`, `kernel.dmesg_restrict`) reach that
VM until Docker restarts. Put them back with
`docker run --rm --privileged alpine sysctl -w vm.swappiness=60 kernel.kptr_restrict=0` (your values
may differ: read them first with `sysctl`).

## Object storage (2026-10-31)

`steps/72-objects.sh` (Garage v2.5.0) on Debian 13, with the test config plus `ENABLE_OBJECTS=true`,
`OBJECTS_FQDN=s3-test.example.invalid`, `OBJECTS_CAPACITY=5G` and two apps in `config/objects/`
(`alted`: `alted-uploads alted-listing`; `other`: `other-files`). The stand-in Dropbox is
`[dropbox] type = local`, as above. `tests/objects-test.sh` holds the checks; run it on a fresh VPS
after the apply: `tests/vps.sh exec bash -s < tests/objects-test.sh`.

- **Final run:** fresh VPS → `remote.sh apply` (exit 0) → `status` all DONE (warnings: the
  self-signed certificates and, before the script sets it up, the Dropbox remote) → **68 of 68 checks
  passed**:
  - **Keys, through nginx with real signatures:**
    - Each app reads and writes only its own buckets. It can't create a bucket, delete its own
      bucket or set a lifecycle (not owner).
    - The backup key reads every bucket and writes none.
    - An unsigned request is refused, the admin API isn't reachable through nginx, and its port is
      on loopback only.
  - **Off-site copy:** names and contents encrypted (no plain key, bucket name or bytes in the
    folder). A deleted object lands in `deleted/<date>/`.
  - **Verify:**
    - Passes as normal, with the scratch bucket left empty.
    - Fails on a tampered `live/` copy and on a tampered `deleted/` copy, and health's
      `backup_verify` fails with it.
    - Passes again once the copy is repaired, even with a changed timestamp.
  - **Restore:** one object, one deleted object, `--all` after `teardown objects --purge`; all byte
    for byte. The backup key loses write again afterwards. An unknown bucket is refused.
  - **Keys rotate:** old and new both work until `drop-previous`; `key` hides the secret.
  - **Drift:** Garage stopped, an extra grant added, `garage.toml` edited → BROKEN, and `apply`
    repairs each. Health's `objects` fails while Garage is down.
  - **Isolation:** `apply stack --force` doesn't restart Garage, and tearing objects down leaves the
    database stack running.
- **Upgrade path, as the real server would take it** (fresh VPS): the committed version (`0c95a64`)
  → this version with `ENABLE_OBJECTS=false` → `true`.
  - With objects off, only the **health container was recreated**. Postgres and PgBouncer kept
    running, and nginx, fail2ban and the firewall were unchanged.
  - With objects on: the nginx site, the certificate placeholder, Garage, the buckets and keys and
    the timer were added, and health was recreated again. Postgres and PgBouncer were still not
    restarted. Every step was DONE.
  - `remote.sh status` runs the server's installed code: preview with `remote.sh sync` first.
- **Found and fixed on the way:**
  - Garage's compose project was being named by the exported `COMPOSE_PROJECT_NAME` (the stack's),
    so either side's `--remove-orphans` would have removed the other. Fixed with `-p`, and checked
    by the step.
  - A `local IFS` in the check leaked into the rest of it.
  - Restoring an empty bucket failed.
  - Verify's age filter also applied to the copy's timestamps.
  - A restore left `live/` behind until the next hourly copy, which made verify fail. A restore
    now refreshes the copy.
  - The `deleted/` archive wasn't checked at all. A sample is now read back in full.

## Maintenance windows and coming back after a reboot (2026-11-04)

`steps/87-maintenance.sh` + `lib/maintenance.sh` + the health service's `/maintenance.json`. `tests/maintenance-test.sh`
holds the checks; run it after an apply: `tests/vps.sh exec bash -s < tests/maintenance-test.sh`.

- **Upgrade path, as the real server would take it** (fresh VPS): the committed version (`5df95a3`) → this
  version. Only the health container was recreated, then PgBouncer once for its new restart policy; Postgres
  and Garage weren't touched. A second apply changed nothing; every step DONE.
- **17 of 17 checks passed:**
  - The feed is published through nginx with CORS and names the server.
  - A real `shutdown -r +180` becomes a 15-minute window through the path unit. Moving it replaces the
    window, and `shutdown -c` cancels it. Nothing internal is published (the wall message, packages, source).
  - `plan`, `start` (replacing the planned window), `extend`, `end` and `status` all work.
  - The settle job ends a reboot window that's under way.
  - An unreadable file is a 503.
  - `bin/remote.sh cx maintenance plan "<date> 03:15" 45m "It's a quoted message"` keeps both quoted arguments
    whole (it used to join them with `$*`).
- **A restart of the VPS** (`docker restart cxvps-test`) with a reboot window under way, and PgBouncer
  deliberately marked the old way (`docker kill -s HUP`): all four containers came back, and the settle job
  ended the window three seconds after boot. Restarting the container resets its hostname, so the base step
  then reads BROKEN; that's an artefact of the test container.
- **Found and fixed on the way:**
  - **PgBouncer would not have come back after a reboot.** Docker (29.9) counts `docker kill -s HUP` (how the
    stack, databases and TLS steps and `db rotate` made it re-read its configuration) as a manual stop
    (`HasBeenManuallyStopped`). Under `restart: unless-stopped` a container marked so isn't started again at
    boot. Now the reload is sent from inside the container (`pgbouncer_reload`), and PgBouncer has
    `restart: always`. The stack check warns about any running container that wouldn't come back.
  - `lib/maintenance.sh` read `$MAINTENANCE_DIR` before the config was loaded, so every unit failed.
  - Boot time came from `/proc/uptime`, which inside a container is the host's. It now comes from PID 1's age.
  - The settle job went on waiting after its window had been ended.

## The apps in the nightly report (2026-11-18)

`lib/report.sh` (`_rpt_apps`) gathers a section per app, `stack/health/src/app-report.mjs` reads it, and app sites log
in the `cx_app` format (`steps/60-nginx.sh`).

- **`cd stack/health && npm test`: 120 of 120**, of them 9 new in `test/app-report.test.mjs`, on the relay's real log
  lines. They check:
  - Multi-line entries are joined.
  - Events keep their name, numbers and enum values; no call id, phone number or caller's words survive, in the
    model, the HTML or the text.
  - A healthy relay is no warning.
  - Unhealthy, restarted, a certificate under 21 days, `fallback.xml` not served and WebSocket 502s are each
    flagged.
  - An error spike is a warning, and the same count on a usual day a note.
  - A missing container, a redeploy, an app that couldn't be gathered, and no apps at all.
- **`tests/report-nginx-test.sh`: 10 of 10**, the access-log reading, on macOS's awk and on Debian 13's mawk
  (`docker run … debian:trixie`, in the script's header).
- **Against the live server, read-only:** the new `lib/report.sh` was piped over SSH with the installed libraries,
  nothing installed. `_rpt_apps` took about a second, and the whole gather 2.6 s. Its output, rendered by this
  digest, is `report-preview.html`.
- **Not run yet:** the new checks in `tests/apps-test.sh` ("the nightly report"). They need the app VPS setup
  above.

## App containers (2026-11-18)

`steps/95-apps.sh` (docs/Apps.md) on Debian 13, with the test config plus one app,
`config/apps/cx-support-relay.env` from `example.env.sample` with `APP_FQDN=relay-test.example.invalid` and
`APP_REPO=/srv/git/cx-support.git`: a bare copy of cx-support with the relay's Dockerfile, put in the VPS with
`docker cp` and `chown -R root:root` (git refuses a repository owned by another user). `tests/apps-test.sh` holds the
checks: `tests/vps.sh exec bash -s < tests/apps-test.sh`. It commits to that bare repository to test deploys.

- **First apply, no secrets yet:** every database step DONE; `apps` checked out `main`, built the image and stopped,
  naming the missing secrets and `bin/remote.sh app-secrets`. `remote.sh apply` exits 1 here, by design: nothing
  after it is held up, because it is the last step.
- **`bin/remote.sh app-secrets cx-support-relay --from <dotenv file>`:** reads `"…"`, `'…'` and `export` lines;
  starts the relay (13 s once built).
- **Final run: 62 of 62 checks passed**, then `remote.sh apply` again: `apps: already done`, nothing restarted.
  - **Through nginx:** `/healthz` gives `ok 0.2.0 <commit>`. WebSocket upgrades: unsigned → 403, wrong signature →
    403, Twilio-signed → 101. HTTP → 301. A one-hour proxy timeout.
  - **Locked down:**
    - Read-only root, no capabilities, `no-new-privileges`, uid 10010, 512 MB, 256 processes.
    - Port on 127.0.0.1 only; its own network only.
    - It can't reach Postgres by address or name, nor the health service's loopback port; it can reach
      `api.anthropic.com:443`.
    - It writes `/tmp` only.
  - **Secrets:** 0600 files, single-quoted in `secrets.env`, never in `app.env` or `compose.yml`. `cx-pgsql app
    secrets` shows names only. A value with a quote, two lines or an unknown name is refused.
  - **Deploys:** a new commit on `main` is a status warning only. Apply doesn't restart; `cx-pgsql app deploy` does.
    The previous image is kept (two at most). `rollback` returns to the old commit; deploy again moves forward.
  - **Drift:** a stopped container, or an edited nginx site → BROKEN → `apply nginx apps` repairs both.
  - **Config:** a second app on the same port and name is refused.
    - With an SSH `APP_REPO` and no deploy key, the apply prints the key and where to add it. GitHub's pinned host
      key is accepted: the refusal is "Permission denied", not a host-key error.
    - Taking the file out removes its nginx site. certbot's deploy hook still runs.
  - **Teardown** removes the container and images, keeps the checkout; apply brings it back.
- **Static files (`APP_STATIC`), second fresh run (2026-11-18): 74 of 74**, then a second apply that changed
  nothing.
  - `/fallback.xml` (cx-support's 0800 fallback TwiML): GET and POST both return 200 `text/xml` with the same file.
    It still answers with the relay stopped (`/healthz` 502 meanwhile), and before the relay has ever run (a secret
    missing). It's published root-owned 0644.
  - A commit that adds a file, a dot-file and a symlink to `/etc/passwd`: only the file is published, and `/passwd`
    doesn't give `/etc/passwd`. Rollback takes the folder back to the old commit's.
- **Found and fixed on the way:**
  - Compose refuses `pids_limit` beside `deploy.resources.limits`, so it's `limits.pids`.
  - The checkout was made root-only (`chmod -R go-rwx`). `COPY` carried that into the image, where the relay (uid
    10010) couldn't read `package.json`, so `/healthz` lost its version. The checkout keeps git's modes now (its
    0750 directory keeps it private), and the relay's Dockerfile makes its files readable itself. `COPY --chmod`
    was no answer: it gives the directories it creates the same mode.
