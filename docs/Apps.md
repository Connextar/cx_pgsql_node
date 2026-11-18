# App containers

Small services that need a server rather than Vercel run here, beside the databases. The first is
cx-support's **voice relay** (`relay.support.connextar.com`). It holds a WebSocket for every phone call, which Vercel
functions can't do. Render would have cost another $7 a month for one small process; this server has the room.

Each app is one file, `config/apps/<app>.env` (template: `config/apps/example.env.sample`; your files are
git-ignored). The `apps` step (`steps/95-apps.sh`, `lib/apps.sh`) does the rest:

- **Code:** a shallow checkout of `APP_REF` from `APP_REPO` in `/data/apps/cx-apps/<app>/src`. A private GitHub
  repository is read with a **deploy key of the app's own**, read-only, made on the server; GitHub's host key is
  pinned.
- **Image:** `docker build` of the app's own `APP_DOCKERFILE`, tagged with the commit (`cx-app/<app>:<sha>`). The
  build runs here, so a deploy uses CPU for a minute or two. The running image and the one before it are kept; older
  ones are deleted.
- **Container:** `cx-app-<app>`, restarted after a crash or reboot. It runs read-only, as uid 10010, without Linux
  capabilities, with `no-new-privileges`, a process cap and memory and CPU limits. It has a Docker network of its own,
  so it has **no route to Postgres, PgBouncer, Garage or the health service**. It reaches the internet like any
  client, and its port is published on loopback only.
- **nginx:** `https://APP_FQDN` → `127.0.0.1:APP_PORT`, with a Let's Encrypt certificate for that name once its A
  record points here (self-signed until then) and a request limit per address (`APP_RATE_LIMIT`).
  - With `APP_WEBSOCKET=true`, nginx passes the upgrade on and keeps the connection up to an hour.
  - The site is `/etc/nginx/sites-available/cx-app-<app>.conf`; one left behind by an app taken out of config is
    removed.
- **Settings:**
  - `APP_ENV`'s plain values go in `app.env`.
  - Each name in `APP_SECRETS` is a root-only secret, `app-<app>-<NAME>`, set from your machine and copied into
    `secrets.env` (0600). Values never go on a command line or into this project.

### Deploys are explicit

`bin/remote.sh apply` builds and runs **the commit already checked out**. It checks out `APP_REF` only the first
time, or when `APP_REF` or `APP_REPO` changes. So an apply for a database change never restarts an app (and never
cuts off a call). When the branch has moved on, `status` says so as a warning.

To put a new commit live:

```bash
bin/remote.sh app-deploy cx-support-relay      # fetch APP_REF's newest commit, build, restart
```

A restart drops live connections: for the relay, calls in progress lose the assistant, and the switchboard forwards
them as it does whenever the relay is unavailable. Deploy outside opening hours. To go back:

```bash
bin/remote.sh cx app rollback cx-support-relay # the image that ran before the last deploy
```

## Setting up cx-support's voice relay

1. **DNS:** an A record `relay.support.connextar.com` → this server's address (`SERVER_IP`).
2. **Config:** `config/apps/cx-support-relay.env` (already written: `example.env.sample` is this app's). Check the
   plain settings: `VOICE_APP_URL=https://support.connextar.com` and
   `VOICE_RELAY_URL=wss://relay.support.connextar.com/relay`. The relay checks Twilio's signature against that exact
   URL.
3. **Deploy key:** `bin/remote.sh app-key cx-support-relay --github` makes the key on the server and adds it to
   `Connextar/cx-support` as a read-only deploy key (needs `gh`, signed in). Without `--github` it prints the key, to
   add by hand under the repository's Settings → Deploy keys.
4. **Apply:** `bin/remote.sh apply` creates the certificate and the nginx site, checks out `main` and builds the image.
   It then stops at `apps`, waiting for the secrets; every database step is done before it.
5. **Secrets:** `bin/remote.sh app-secrets cx-support-relay --from ../../Projects/Shared/cx-support/.env.local`.
   - It sends `VOICE_SESSION_PUBLIC_KEY`, `TWILIO_AUTH_TOKEN` and `ANTHROPIC_API_KEY` over SSH on stdin, then applies,
     which starts the relay.
   - Without `--from` it asks for each one (hidden; an empty answer keeps the current value).
   - Name some to set only those: `… app-secrets cx-support-relay ANTHROPIC_API_KEY`.
6. **Check:** `curl https://relay.support.connextar.com/healthz` answers `ok 0.2.0 <commit>`. Then set `VOICE_RELAY_URL`
   on the app in Vercel (cx-support's `docs/Telephony.md`, "Hosting").
7. **Watch it:** add `https://relay.support.connextar.com/healthz` to the uptime monitor beside this server's
   `/healthz`. The server's own health and report don't include apps: a relay problem never marks the database server
   down.

## Day to day

| From your machine                                      | What it does                                                    |
| ------------------------------------------------------ | --------------------------------------------------------------- |
| `bin/remote.sh status apps`                            | each app: checkout, secrets, image, container, loopback, HTTPS  |
| `bin/remote.sh cx app list`                            | name, address, ref, commit and state                            |
| `bin/remote.sh app-deploy <app>`                       | newest commit of `APP_REF`, built and started                   |
| `bin/remote.sh cx app rollback <app>`                  | the previous image                                              |
| `bin/remote.sh cx app logs <app> [-f]`                 | its log (the relay logs events, never what callers say)         |
| `bin/remote.sh cx app restart <app>`                   | restart without rebuilding                                      |
| `bin/remote.sh app-secrets <app> [NAME…]`              | change a secret (e.g. after rotating the Anthropic key)         |
| `bin/remote.sh cx app secrets <app>`                   | which secrets are set (never the values)                        |
| take its file out of `config/apps/`, `apply`, then `bin/remote.sh cx app remove <app> --yes` | retire an app (secrets kept) |

## Adding another app

It needs a Dockerfile that builds a small image with nothing secret in it. It must listen on one port, answer
`APP_HEALTH_PATH` with 200, and run as any uid on a read-only filesystem (writes only to `/tmp`). Then:

1. Copy `example.env.sample` to `config/apps/<app>.env`.
2. Pick a free `APP_PORT`: the apps use 28510 and up.
3. Add the DNS record, then follow steps 3–6 above.

The step refuses a port or host name that another app or the server already uses.
