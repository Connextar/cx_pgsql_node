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
