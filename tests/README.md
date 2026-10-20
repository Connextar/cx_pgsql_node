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
