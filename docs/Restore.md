# Restoring from these backups

This file is copied next to the backups in Dropbox, so it is there when the server is not.

## What the folder holds

| Folder | What it is | Encrypted with |
| --- | --- | --- |
| `pgbackrest/` | A mirror of the pgBackRest repository: full and differential base backups plus every archived WAL segment. Restores the **whole cluster to any moment** covered. | pgBackRest's own AES-256 key: the secret `pgbackrest-cipher-pass` |
| `dumps/<database>/` | Nightly `pg_dump` files (`<db>-YYYYmmddTHHMMZ.dump.age`) with a `.sha256` beside each. Restores **one database**, on any Postgres of the same or a newer version. | Your age key (`BACKUP_AGE_RECIPIENTS`) |
| `dumps/_globals/` | Roles and their password hashes (`pg_dumpall --globals-only`). | Your age key |
| `secrets/` | The server's secrets as a tarball: every password, the health token, the pgBackRest key and the Dropbox token. | Your age key |
| `status.json` | When each backup job last ran and how it went. | — |

**Keep two things off the server:** your **age private key** (`AGE-SECRET-KEY-1…`) and, as a
second copy, the **pgBackRest key** (`cx-pgsql secret show pgbackrest-cipher-pass`). With the age
key alone you can decrypt `secrets/`, which contains the pgBackRest key. Without both, the backups
can't be read by anyone, including you.

## One database, on the same server

```bash
cx-pgsql backup list                                   # what's on the server
cx-pgsql restore dump alted latest --identity /root/age.key            # → alted_restored_<time>
cx-pgsql restore dump alted alted-20261020T0200Z.dump.age --identity /root/age.key --into alted_copy
cx-pgsql restore dump alted latest --identity /root/age.key --replace --yes   # overwrite the live one
shred -u /root/age.key                                 # don't leave the key behind
```

Copy the age key up just for this (`scp -P <ssh port> age.key connextar@server:/tmp/`, then `sudo mv`).
A dump that's only in Dropbox: `cx-pgsql restore fetch dumps` first.

## The whole cluster, to a moment

```bash
cx-pgsql restore pitr --time "2026-10-20 09:30:00+00"   # a copy on 127.0.0.1:28439 to look at
cx-pgsql restore cleanup                                 # remove that copy
cx-pgsql restore in-place --time "2026-10-20 09:30:00+00" --yes   # replace the live cluster
```

`in-place` stops the stack, moves the current data directory aside (it is kept, named
`…/data.before-<time>`), restores, starts the stack and takes a fresh full backup. Leave `--time`
out to restore to the latest moment archived.

## A new server after a disaster

1. Order a VPS and set up `config/server.env` exactly as before (same `PG_VERSION`, `SERVER_FQDN`).
2. Recover the secrets with your age key, on your machine:
   `age -d -i age.key secrets-<hostname>.tar.age | tar -x` → a `secrets/` folder and `rclone.conf`.
3. Copy them to the new server **before** the first apply, so the cluster comes back with the
   same passwords and the same pgBackRest key:
   `scp -r secrets rclone.conf root@new-server:/tmp/` then, on it,
   `install -d -m 700 /etc/cx-pgsql && mv /tmp/secrets /etc/cx-pgsql/ && mv /tmp/rclone.conf /etc/cx-pgsql/ && chmod -R go-rwx /etc/cx-pgsql`.
4. From your machine: `bin/remote.sh apply` (it builds an empty cluster first; that's fine).
5. On the server: `cx-pgsql restore fetch repo` then `cx-pgsql restore in-place --yes`.
6. Point DNS at the new address. Applications keep their connection strings.

## Without this project at all

The dumps are ordinary `pg_dump` custom-format files:

```bash
age -d -i age.key alted-20261020T0200Z.dump.age > alted.dump
sha256sum -c alted-20261020T0200Z.dump.age.sha256   # (checks the encrypted file)
createdb alted && pg_restore -d alted alted.dump
```

The pgBackRest repository needs pgBackRest (≥ 2.50) and a `pgbackrest.conf` with
`repo1-path=<the folder>`, `repo1-cipher-type=aes-256-cbc`, `repo1-cipher-pass=<the key>` and the
stanza `[main]`; then `pgbackrest --stanza=main --pg1-path=<empty dir> restore`.
