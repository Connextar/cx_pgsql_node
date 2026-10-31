# CX_PGSQL_Node_1

A self-hosted PostgreSQL server for Connextar's apps (first tenant: AltEd, moving off Neon), set up
from a bare Debian VPS by one re-runnable script. Every step checks the live system and does only
what's missing or broken, so the same command installs, repairs and confirms.

- **PostgreSQL 17** in Docker, with **PgBouncer** in front (transaction pooling for serverless
  apps, a session pool per database for migrations), TLS required from outside, SCRAM passwords.
- **Many databases and logins**: one small file per database in `config/databases/`.
- **Hardened host**: SSH on its own port, keys only, no root; nftables firewall that also guards
  Docker-published ports; fail2ban on SSH, Postgres and PgBouncer; automatic security updates.
  Default ports are closed: Postgres and PgBouncer are published on alternative host ports.
- **Health endpoint**: `https://<fqdn>/healthz` (public, ok/warn/fail), `/status` (token: connections,
  slow and blocked queries, top statements, cache hit, vacuum, WAL archiving, PgBouncer pools, disk,
  backups, certificate) and `/metrics` (Prometheus).
- **Backups**: pgBackRest point-in-time recovery + nightly encrypted `pg_dump`s, synced to a
  Dropbox folder on a schedule, verified weekly by actually restoring them.
- Optional **object storage** (`ENABLE_OBJECTS`): Garage, S3-compatible, for apps' files (pictures,
  uploads) so they stay out of Postgres. Private buckets and one key per app from `config/objects/`,
  HTTPS through nginx, an hourly encrypted copy in the same Dropbox folder, restore-tested weekly.
  Why and how: [docs/ObjectStorage.md](docs/ObjectStorage.md).
- Optional **n8n** (alerts from `/status`, or anything else) and the Node/PM2 app stack from the
  old Contabo runbook.

## Quick start

On your machine, in this folder:

```bash
cp config/server.env.sample config/server.env          # hostname, FQDN, IP, ports, backups…
cp config/authorized_keys.sample config/authorized_keys && cat ~/.ssh/id_ed25519.pub >> config/authorized_keys
cp config/databases/example.env.sample config/databases/alted.env
```

Order a Debian 13 VPS (the choice: HostHatch London, 16 GB; see
[docs/VPS-Comparison.md](docs/VPS-Comparison.md)). Put your SSH key on it for root (`ssh-copy-id root@<ip>`
if it came with a password only), set `SERVER_IP`, point `SERVER_FQDN`'s A record at it, then:

```bash
bin/remote.sh apply                 # everything; re-run any time — finished steps are skipped
bin/remote.sh status                # DONE / MISSING / BROKEN, item by item
bin/remote.sh dropbox-auth          # once: authorise the Dropbox folder for backups (needs rclone here)
bin/remote.sh cx db url alted --show-password      # connection strings for the app
```

`apply` copies the project to `/opt/cx-pgsql` and runs `setup.sh` there. SSH and firewall changes
revert themselves after `ROLLBACK_SECONDS` unless confirmed from a **new** connection on the new
port. `remote.sh` does that for you; if it can't get in, nothing is left locked.

## Steps

| Step | What it sets up |
| --- | --- |
| `base` | packages, hostname, time zone, locale, unattended security upgrades, swap, sysctl, journal cap |
| `users` | admin user, groups (`apps`, `ssh-users`, `docker`), SSH keys, sudo, git identity, `/data/apps` |
| `ssh` | sshd on `SSH_PORT` only, keys only, no root, `AllowGroups` — with automatic undo |
| `firewall` | nftables: SSH, 80, 443 and the database port in; Docker-safe; with automatic undo |
| `fail2ban` | jails for sshd, Postgres and PgBouncer, banning in the firewall before Docker's NAT |
| `docker` | Docker Engine + compose plugin from Docker's repository, log rotation |
| `nginx` | HTTPS front for the health endpoint (and n8n), refuses unknown host names |
| `tls` | Let's Encrypt via webroot once DNS points here (self-signed until then), renewal hook |
| `stack` | Postgres + pgBackRest, PgBouncer, health, optional n8n; tuning; cluster roles |
| `objects` | optional: Garage object store, its layout, each `config/objects/*.env`: buckets and a key (`ENABLE_OBJECTS`) |
| `databases` | each `config/databases/*.env`: login, database, extensions, read-only login |
| `backups` | timers for dumps, base backups, upload and verify; `cx-pgsql` on the PATH |
| `node` | optional: nvm, Node, shared PM2 daemon (`ENABLE_NODE_STACK`) |

`setup.sh status|apply|repair|teardown|confirm [step…]` on the server; `bin/remote.sh` with the same
words from your machine. Teardown runs in reverse order and keeps data unless given `--purge`.

## Ports

| Host port | What | Exposure |
| --- | --- | --- |
| `SSH_PORT` (19225) | SSH | public, keys only, fail2ban |
| 80 / 443 | nginx: ACME, `/healthz`, `/status`, `/metrics` (and n8n) | public |
| `PGBOUNCER_PUBLIC_PORT` (28433) → 6432 | PgBouncer — what apps connect to | public, TLS + SCRAM, fail2ban, optional allow-list |
| `PG_DIRECT_PORT` (28432) → 5432 | Postgres direct | loopback (SSH tunnel) unless `PG_DIRECT_BIND` says otherwise |
| `HEALTH_PORT` (28480), `N8N_PORT` (28567) | health service, n8n | loopback, behind nginx |
| `OBJECTS_S3_PORT` (28490), `OBJECTS_ADMIN_PORT` (28491) | Garage's S3 API (behind nginx on `OBJECTS_FQDN`), its admin API | loopback |

22, 5432 and 6432 are not open.

## Layout

```
setup.sh            the step runner (status / apply / repair / teardown / confirm)
steps/NN-*.sh       one file per step: describe, check, apply, teardown
lib/                core (runner, templates, secrets, rollback), tls, pg, databases, backup, restore
bin/cx-pgsql         operations on the server: databases, URLs, backups, restores, logs
bin/remote.sh       from your machine: sync + apply + confirm, tunnel, Dropbox authorisation
stack/              compose.yml, Dockerfiles, postgresql.conf template, health service, n8n workflow,
                    objects/compose.yml (Garage)
config/             server.env, authorized_keys, databases/*.env, objects/*.env (samples committed; yours ignored)
docs/               Operations, Restore, VPS comparison
tests/              a disposable "VPS" (systemd + Docker in a container) to run all of this locally
```

More: [docs/Operations.md](docs/Operations.md) (day-to-day, adding a database or an app's buckets, moving
AltEd off Neon, alerts) · [docs/Restore.md](docs/Restore.md) (every kind of restore, disaster recovery) ·
[docs/ObjectStorage.md](docs/ObjectStorage.md) (the object store: options, design, decisions) ·
[stack/health/README.md](stack/health/README.md) (every check and threshold).
