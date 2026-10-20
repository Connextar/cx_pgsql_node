# CX PGSQL health watch (n8n)

`cx-pgsql-health-watch.json` is an n8n workflow that polls the health service's `/status` every 5 minutes and
emails (and optionally posts to Slack or Discord) when the database's overall state changes.

```
Every 5 minutes → Settings → GET /status → Evaluate → Alert needed? → Send alert email
                                                                   └→ Chat webhook set? → Post to chat webhook
```

## What it alerts on

- **A change of overall state:** ok → warn, ok → fail, warn → fail, fail → warn ("improved"), and recovery back to
  ok. Staying in the same state is silent.
- **A reminder every 6 hours** (`reminderHours`) while the state stays at fail.
- On the very first run after activation it alerts only if the state is not ok.
- A request error (DNS, TLS, timeout, connection refused) or any non-2xx answer (401 wrong token, 503 token not
  configured, 502 from nginx, …) counts as **fail**. The request is retried once after 5 s before it counts.

The alert lists every failing and warning check with its message, for example:

```
Subject: [CX_PGSQL_Node_1] FAIL (was WARN) - 1 failing, 1 warning

CX_PGSQL_Node_1 database health is FAIL (was WARN).
Checked at 2026-10-20T08:20:00.000Z; in this state since 2026-10-20T08:20:00.000Z.

Failing:
  - backup_logical: logical backup failed at 2026-10-20T02:00:00.000Z: pg_dump exited 1

Warnings:
  - disk: data directory 85% used, 14.2 GiB free (warn 80%, fail 90%)

Details: https://db.example.com/status (needs the bearer token)
While this stays at FAIL a reminder is sent every 6 h.
```

The previous state is kept in the workflow's static data (`$getWorkflowStaticData('global')`). n8n saves static
data only for **production** runs — the workflow is active and started by its schedule. A manual "Execute
workflow" run neither reads back nor keeps it, so every manual run behaves like a first check (it alerts whenever
the state is not ok), which is handy for testing email delivery.

## Set it up

### 1. Create the two credentials (before importing)

In n8n: **Credentials → Add credential**.

1. **Header Auth** — the health token. Name it exactly **`CX PGSQL health token`**.
   - *Name*: `Authorization`
   - *Value*: `Bearer <token>` — the token the health service reads from `HEALTH_TOKEN_FILE`. Print it on the
     server with `cx-pgsql secret show health-token`. The workflow only references the credential; the token is
     stored encrypted in n8n and never in the workflow file.
2. **SMTP** — for the alert email. Name it **`SMTP account`** (or anything; you pick it in step 3).
   - Host, port, user, password and SSL/TLS of your mail provider.

### 2. Import the workflow

- **UI:** *Workflows → Create workflow*, then the **⋯** menu → **Import from File…** and choose
  `cx-pgsql-health-watch.json` (or paste the file's contents onto the canvas).
- **CLI** (n8n in Docker):
  ```sh
  docker cp cx-pgsql-health-watch.json <n8n-container>:/tmp/
  docker exec -u node <n8n-container> n8n import:workflow --input=/tmp/cx-pgsql-health-watch.json
  ```

### 3. Link the credentials

Open **GET /status** and choose `CX PGSQL health token` under *Credential for Header Auth*; open
**Send alert email** and choose your SMTP credential. (The file carries placeholder credential ids, so n8n asks
you to pick them; nothing secret is in the file.)

### 4. Edit the Settings node

Everything you need to change is in the **Settings** node:

| Field | Example | Meaning |
| --- | --- | --- |
| `statusUrl` | `https://db.example.com/status` | The health service's `/status` through nginx. |
| `alertTo` | `ops@example.com` | Recipient(s); separate several with commas. |
| `alertFrom` | `n8n@example.com` | Sender address your SMTP account may send as. |
| `serverName` | `CX_PGSQL_Node_1` | Shown in the subject line. |
| `reminderHours` | `6` | Reminder interval while failing. |
| `chatWebhookUrl` | *(empty)* | Optional Slack or Discord incoming-webhook URL. Empty = email only. A URL containing `discord` gets `{"content": …}`, anything else gets Slack's `{"text": …}`. |

Polling through the public URL tests DNS, TLS and nginx as well. n8n runs on the same Docker network as the health
service, so `http://health:8080/status` also works if you would rather not depend on the proxy — the external
`/healthz` monitor below then covers the public path.

### 5. Test, then activate

1. Click **Execute workflow** once. **GET /status** should show `statusCode: 200` and a body with `status` and
   `checks`. If the state is not ok you get an email (manual runs always alert when not ok).
2. Toggle the workflow **Active**. From now on it runs every 5 minutes and remembers the last state.

The workflow settings keep failed executions but do not store successful ones (288 a day, each holding a full
`/status` body); change *Workflow settings → Save successful production executions* if you want them.

## A second, independent alarm

n8n runs on the same server it is watching, so it cannot tell you when that whole server, its network or Docker is
down. Point any external uptime monitor (UptimeRobot, Better Stack, Healthchecks.io, Uptime Kuma elsewhere, …) at
the public, unauthenticated health endpoint:

```
https://<fqdn>/healthz   → 200 = ok or warn, 503 = fail, no answer = server or proxy down
```

It needs no token and reveals only check names and states. Monitors that can match a keyword can also alert on
warn by expecting `"status": "ok"` in the body.

## Troubleshooting

- **An alert every 5 minutes for the same state:** static data is not being saved — check the workflow is active
  (manual runs never save it) and that your n8n version supports `$getWorkflowStaticData` in the Code node with
  task runners enabled (`N8N_RUNNERS_ENABLED=true`).
- **`status_request: the status endpoint answered HTTP 401`:** the Header Auth value must be `Bearer <token>`,
  including the word `Bearer` and one space, and the header name must be `Authorization`.
- **HTTP 503 `not configured`:** the health service has no token (`HEALTH_TOKEN`/`HEALTH_TOKEN_FILE`).
