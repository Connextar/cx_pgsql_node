# shellcheck shell=bash
# The nightly report email: the night's facts gathered here, turned into an email by the health container
# (stack/health/digest.mjs), sent through Brevo's API. Scheduled by steps/85-report.sh.
#
#   gather   the health service's /status, host facts (disks, space by area, updates, reboot, containers,
#            the period's backup runs, fail2ban, Postgres and PgBouncer log errors, Dropbox space) and
#            superuser SQL (all of pg_stat_statements, the largest tables in every database)
#   render   docker exec the health container's digest.mjs: facts in, { subject, html, text, snapshot } out
#   send     POST to Brevo; the API key is a root-only secret and goes to curl on stdin, never as an argument
#
# The snapshot (counters as they stood) is kept only after a send succeeds, so a missed night's numbers roll
# into the next email instead of vanishing. Everything that leaves the server is masked by digest.mjs:
# statement text is PostgreSQL's normalised form with literals masked, log messages lose their values.

REPORT_STATE_DIR=/var/lib/cx-pgsql/report
BREVO_API=https://api.brevo.com/v3

rpt_lock() {
  mkdir -p /run/cx-pgsql
  exec 7>/run/cx-pgsql/report.lock
  flock -w 600 7 || die "Another report has held the lock for ten minutes."
}

# Since when the email reports: the last sent report, or a day ago.
rpt_since() {
  local at
  at=$(jq -r '.at // empty' "$REPORT_STATE_DIR/snapshot.json" 2>/dev/null || true)
  if [[ -n "$at" ]] && date -u -d "$at" >/dev/null 2>&1; then date -u -d "$at" '+%Y-%m-%d %H:%M:%S'; else date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S'; fi
}

rpt_status_json() {
  local token
  token=$(cat "$(secret_path health-token)" 2>/dev/null) || { jq -nc '{error: "no health token"}'; return; }
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --max-time 30 -H @- "http://127.0.0.1:$HEALTH_PORT/status" 2>/dev/null ||
    jq -nc --arg e "the health service on 127.0.0.1:$HEALTH_PORT didn't answer" '{error: $e}'
}

# Bytes under a path (0 when it's missing).
_rpt_du() { [[ -e "$1" ]] && du -sb "$1" 2>/dev/null | cut -f1 || echo 0; }

# Lines of a log at or after a UTC "YYYY-MM-DD HH:MM:SS" (the first 19 characters of every line).
_rpt_since_lines() { # since file...
  local since=$1
  shift
  awk -v s="$since" 'substr($0, 1, 19) >= s' "$@" 2>/dev/null || true
}

# Postgres log: ERROR/FATAL/PANIC/WARNING grouped (severity, user@db, message), and statements over
# log_min_duration_statement. The raw message stays on this server: digest.mjs masks it before it's sent.
_rpt_pg_log() { # since
  local since=$1 files=() f
  for f in "$STACK_LOGS_DIR"/postgres/postgresql-*.log; do [[ -s "$f" ]] && files+=("$f"); done
  if ((${#files[@]} == 0)); then
    jq -nc --argjson t "${PG_LOG_MIN_DURATION_MS:-500}" '{errors: [], slow: {count: 0, max_ms: null, threshold_ms: $t}}'
    return
  fi
  _rpt_since_lines "$since" "${files[@]}" |
    awk '
      match($0, / (ERROR|FATAL|PANIC|WARNING):  /) {
        sev = substr($0, RSTART + 1, RLENGTH - 4); msg = substr($0, RSTART + RLENGTH)
        pre = substr($0, 1, RSTART - 1); who = ""
        if (match(pre, /[^ ]+@[^ ]+$/)) who = substr(pre, RSTART, RLENGTH)
        if (who == "@") who = ""
        printf "E\t%s\t%s\t%s\n", sev, who, substr(msg, 1, 300); next
      }
      match($0, / LOG:  duration: [0-9.]+ ms/) {
        d = substr($0, RSTART + 17, RLENGTH - 20); printf "D\t%s\n", d
      }' |
    jq -Rsc --argjson t "${PG_LOG_MIN_DURATION_MS:-500}" '
      split("\n") | map(select(length > 0) | split("\t")) as $rows
      | {
          errors: ($rows | map(select(.[0] == "E") | {severity: .[1], who: (.[2] | if . == "" then null else . end), message: .[3]})
                   | group_by([.severity, .who, .message]) | map(.[0] + {count: length}) | sort_by(-.count) | .[:50]),
          slow: ($rows | map(select(.[0] == "D") | (.[1] | tonumber)) | {count: length, max_ms: (max // null), threshold_ms: $t})
        }'
}

# PgBouncer log: WARNING/ERROR/FATAL lines, without the client id and address in front.
_rpt_pgbouncer_log() { # since
  local since=$1 files=() f
  for f in "$STACK_LOGS_DIR"/pgbouncer/pgbouncer.log "$STACK_LOGS_DIR"/pgbouncer/pgbouncer.log.1; do [[ -s "$f" ]] && files+=("$f"); done
  ((${#files[@]})) || { jq -nc '{errors: []}'; return; }
  _rpt_since_lines "$since" "${files[@]}" |
    sed -nE 's/^.{19}[^ ]* UTC \[[0-9]+\] (WARNING|ERROR|FATAL) ([CS]-0x[0-9a-f]+: [^ ]+ )?(.*)$/\1\t\3/p' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {severity: .[0], message: (.[1] // "")[:300]})
             | group_by([.severity, .message]) | map(.[0] + {count: length}) | sort_by(-.count) | .[:20] | {errors: .}'
}

# fail2ban: per jail, how many attempts it saw ("Found") and bans it made in the period, and who's banned now.
_rpt_fail2ban() { # since
  local since=$1 jail now found banned
  command -v fail2ban-client >/dev/null || { echo '[]'; return; }
  for jail in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ',' ); do
    now=$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*//p')
    found=$(_rpt_since_lines "$since" /var/log/fail2ban.log | grep -c "\[$jail\] Found" || true)
    banned=$(_rpt_since_lines "$since" /var/log/fail2ban.log | grep -c "\[$jail\] Ban " || true)
    jq -nc --arg j "$jail" --argjson n "${now:-0}" --argjson f "${found:-0}" --argjson b "${banned:-0}" \
      '{jail: $j, banned_now: $n, attempts: $f, banned_period: $b}'
  done | jq -sc .
}

# A reboot already booked (shutdown -r <time>, or unattended-upgrades' Automatic-Reboot-Time): when, in UTC.
_rpt_reboot_scheduled() {
  local usec
  usec=$(sed -n 's/^USEC=//p' /run/systemd/shutdown/scheduled 2>/dev/null || true)
  [[ -n "$usec" ]] && date -u -d "@$((usec / 1000000))" +%Y-%m-%dT%H:%M:%SZ || true
}

# The last reboot, from the journal: when the machine came back, and how long it was off (the previous
# boot's last entry to this one's first). Null when the journal holds only one boot.
_rpt_last_reboot() {
  journalctl --list-boots -o json 2>/dev/null |
    jq -c 'if length >= 2 then {at: (.[-1].first_entry / 1000000 | floor | todate),
             offline_seconds: ((.[-1].first_entry - .[-2].last_entry) / 1000000 | floor)} else null end' 2>/dev/null || echo null
}

_rpt_containers() {
  local ids
  ids=$(docker ps -aq --filter "name=^${STACK_NAME}-" 2>/dev/null)
  [[ -n "$ids" ]] || { echo '[]'; return; }
  # shellcheck disable=SC2086 # one id per word
  docker inspect -f '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}' $ids |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("|") | {name: (.[0] | ltrimstr("/")), state: .[1], health: (.[2] | if . == "" then null else . end), restarts: (.[3] | tonumber)}) | sort_by(.name)'
}

# The period's backup job runs, from systemd's own record of each job finishing.
_rpt_jobs() { # since
  journalctl -o json --since "$1 UTC" _PID=1 2>/dev/null |
    jq -c 'select((.UNIT // "") | startswith("cx-backup@")) | select(.JOB_RESULT != null) | {unit: .UNIT, result: .JOB_RESULT, time: (.__REALTIME_TIMESTAMP | tonumber / 1000000 | floor | todate)}' |
    jq -sc .
}

_rpt_updates() {
  apt list --upgradable 2>/dev/null | awk -F/ 'NR > 1 && NF > 1 { print $1 "\t" $2 }' |
    jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")) | {total: length, security: (map(select(.[1] | test("security"))) | length), packages: (map(.[0]) | .[:15])}'
}

_rpt_dropbox() {
  is_true "$BACKUP_UPLOAD" && remote_configured || { echo null; return; }
  rclone_x about "$BACKUP_REMOTE:" --json 2>/dev/null | jq -c '{total, used, free}' 2>/dev/null || echo null
}

rpt_host_json() { # since
  local since=$1 accepted os
  os=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}")
  accepted=$(journalctl -u ssh --since "$since UTC" --no-pager 2>/dev/null | grep -c 'Accepted ' || true)
  jq -nc \
    --arg os "$os" --arg kernel "$(uname -r)" --argjson up "$(cut -d. -f1 /proc/uptime)" --argjson cpus "$(nproc)" \
    --argjson fs "$(df -B1 --output=target,fstype,size,used,avail -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null |
      awk 'NR > 1 { printf "{\"mount\":\"%s\",\"fstype\":\"%s\",\"size\":%s,\"used\":%s,\"avail\":%s}\n", $1, $2, $3, $4, $5 }' | jq -sc .)" \
    --argjson usage "$(jq -nc --argjson pg "$(_rpt_du "$DATA_ROOT")" --argjson d "$(_rpt_du "$DUMPS_DIR")" --argjson r "$(_rpt_du "$REPO_DIR")" \
      --argjson o "$(is_true "$ENABLE_OBJECTS" && _rpt_du "$OBJECTS_DATA_DIR" || echo null)" \
      '{postgres_data: $pg, backups_dumps: $d, backups_pgbackrest: $r} + (if $o == null then {} else {objects_data: $o} end)')" \
    --argjson updates "$(_rpt_updates)" \
    --argjson reboot "$([[ -f /var/run/reboot-required ]] && echo true || echo false)" \
    --argjson rpkgs "$( (cat /var/run/reboot-required.pkgs 2>/dev/null || true) | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" \
    --arg rat "$(_rpt_reboot_scheduled)" \
    --argjson lastboot "$(_rpt_last_reboot)" \
    --argjson containers "$(_rpt_containers)" \
    --argjson jobs "$(_rpt_jobs "$since")" \
    --argjson f2b "$(_rpt_fail2ban "$since")" \
    --argjson accepted "${accepted:-0}" \
    --argjson pglog "$(_rpt_pg_log "$since")" \
    --argjson bouncer "$(_rpt_pgbouncer_log "$since")" \
    --argjson dropbox "$(_rpt_dropbox)" \
    '{os: $os, kernel: $kernel, uptime_seconds: $up, cpu_count: $cpus, filesystems: $fs, usage: $usage, updates: $updates,
      reboot_required: $reboot, reboot_packages: $rpkgs, reboot_scheduled: (if $rat == "" then null else $rat end), last_reboot: $lastboot, containers: $containers, jobs: $jobs,
      ssh: {accepted: $accepted, failed: ([$f2b[] | select(.jail == "sshd") | .attempts] | add // 0)},
      fail2ban: $f2b, pg_log: $pglog, pgbouncer_log: $bouncer, dropbox: $dropbox}'
}

# Superuser SQL: every pg_stat_statements row (for the change since the last report) and each database's
# largest tables. Statement text is PostgreSQL's normalised form; digest.mjs masks what literals remain.
rpt_sql_json() {
  local stmts tables db
  stmts=$(pg_sql -At -d postgres -c "
    SELECT json_build_object(
      'stats_reset', (SELECT stats_reset FROM pg_stat_statements_info),
      'rows', coalesce(json_agg(json_build_object(
        'dbname', d.datname, 'user', r.rolname, 'queryid', s.queryid::text, 'calls', s.calls,
        'total_ms', round(s.total_exec_time::numeric, 3), 'max_ms', round(s.max_exec_time::numeric, 3),
        'rows', s.rows, 'query', left(s.query, 400))), '[]'::json))
    FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid JOIN pg_roles r ON r.oid = s.userid
    WHERE s.calls > 0" 2>/dev/null) || stmts='{"available": false, "rows": []}'
  tables=$(for db in $(pg_sql -At -d postgres -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> 'postgres'" 2>/dev/null); do
    pg_sql -At -d "$db" -c "
      SELECT coalesce(json_agg(t), '[]'::json) FROM (
        SELECT current_database() AS db, schemaname AS schema, relname AS name, pg_total_relation_size(relid) AS total_bytes,
               n_live_tup AS live_tup, n_dead_tup AS dead_tup, greatest(last_vacuum, last_autovacuum) AS last_vacuum
        FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10) t" 2>/dev/null || echo '[]'
  done | jq -sc 'add // []')
  # Through files, not arguments: all of pg_stat_statements is easily more than one argument may hold (128 KiB).
  jq -nc --slurpfile s <(printf '%s' "$stmts") --slurpfile t <(printf '%s' "$tables") '{statements: $s[0], tables: $t[0]}'
}

# Everything digest.mjs needs, as one document.
rpt_gather() { # → stdout
  local since
  since=$(rpt_since)
  jq -nc \
    --arg at "$(now_iso)" --arg hostname "$SERVER_HOSTNAME" --arg fqdn "$SERVER_FQDN" \
    --arg to "$REPORT_TO" --arg tz "${REPORT_TIMEZONE:-Europe/London}" --argjson slow "${REPORT_SLOW_MEAN_MS:-100}" \
    --arg ignore "${REPORT_IGNORE_USERS:-cx_monitor postgres}" \
    --slurpfile status <(rpt_status_json) \
    --slurpfile host <(rpt_host_json "$since") \
    --slurpfile sql <(rpt_sql_json) \
    --slurpfile prev <(cat "$REPORT_STATE_DIR/snapshot.json" 2>/dev/null || echo null) \
    '{generated_at: $at, server: {hostname: $hostname, fqdn: $fqdn},
      config: {to: $to, timezone: $tz, slow_mean_ms: $slow, ignore_users: ($ignore | split(" ") | map(select(length > 0)))},
      status: $status[0], host: $host[0], sql: $sql[0], previous: $prev[0]}'
}

rpt_render() { # input file → stdout
  docker exec -i "$HEALTH_CONTAINER" node /app/digest.mjs <"$1"
}

# POST the email to Brevo. Prints Brevo's messageId; on failure prints Brevo's own message and returns 1.
rpt_send() { # digest file [tag] [to]
  local digest=$1 tag=${2:-server-report} to=${3:-$REPORT_TO} body out code key
  key=$(secret_path brevo-api-key)
  body=$(mktemp "$REPORT_STATE_DIR/send.XXXXXX")
  out=$(mktemp "$REPORT_STATE_DIR/answer.XXXXXX")
  jq -c --arg to "$to" --arg from "$REPORT_FROM" --arg name "${REPORT_FROM_NAME:-$SERVER_HOSTNAME}" --arg tag "$tag" \
    '{sender: {name: $name, email: $from}, to: ($to | split(",") | map(gsub("^ +| +$"; "") | select(length > 0) | {email: .})),
      subject, htmlContent: .html, textContent: .text, tags: [$tag]}' "$digest" >"$body"
  code=$(printf 'api-key: %s\n' "$(cat "$key")" |
    curl -sS --max-time 60 -o "$out" -w '%{http_code}' -H @- -H 'content-type: application/json' -H 'accept: application/json' \
      --data-binary @"$body" "$BREVO_API/smtp/email" 2>&1) || code=${code:-000}
  rm -f "$body"
  if [[ "$code" == 2* ]]; then
    jq -r '.messageId // "sent"' "$out" 2>/dev/null || echo sent
    rm -f "$out"
    return 0
  fi
  local why
  why=$(jq -r '[.code, .message] | map(select(. != null)) | join(": ")' "$out" 2>/dev/null || head -c 300 "$out")
  rm -f "$out"
  printf 'Brevo answered %s%s' "$code" "${why:+ — $why}"
  return 1
}

# Gather, render, and send (or only save, with --no-send). Saves the last email beside the snapshot either way.
rpt_run() { # [--no-send]
  local send=1 input digest status subject id
  [[ "${1:-}" == --no-send ]] && send=0
  rpt_lock
  install -d -m 0700 "$REPORT_STATE_DIR"
  input=$(mktemp "$REPORT_STATE_DIR/input.XXXXXX")
  digest=$(mktemp "$REPORT_STATE_DIR/digest.XXXXXX")
  if ((send)); then
    status_update '.report.enabled = true | .report.last_attempt = $now'
    if ! secret_exists brevo-api-key; then
      status_update '.report.last_error = "no Brevo API key on the server (bin/remote.sh brevo-auth)"'
      die "No Brevo API key on this server — from your machine run  bin/remote.sh brevo-auth"
    fi
  fi
  if ! rpt_gather >"$input" || ! rpt_render "$input" >"$digest" || ! jq -e .subject "$digest" >/dev/null 2>&1; then
    rm -f "$input" "$digest"
    ((send)) && status_update '.report.last_error = "the report could not be built (see /var/log/cx-pgsql.log)"'
    die "The report could not be built."
  fi
  rm -f "$input"
  jq -r .html "$digest" >"$REPORT_STATE_DIR/last.html"
  jq -r .text "$digest" >"$REPORT_STATE_DIR/last.txt"
  status=$(jq -r .status "$digest")
  subject=$(jq -r .subject "$digest")
  if ((!send)); then
    rm -f "$digest"
    info "Built, not sent: $subject"
    info "Saved to $REPORT_STATE_DIR/last.html and last.txt"
    return 0
  fi
  if id=$(rpt_send "$digest"); then
    jq .snapshot "$digest" >"$REPORT_STATE_DIR/snapshot.json"
    status_update '.report.last_success = $now | .report.last_error = null | .report.last_status = $s | .report.to = $to' --arg s "$status" --arg to "$REPORT_TO"
    rm -f "$digest"
    ok "Sent to $REPORT_TO ($status): $subject [$id]"
  else
    status_update '.report.last_error = $e' --arg e "$id"
    rm -f "$digest"
    die "Not sent: $id"
  fi
}

# Install the Brevo API key (read from stdin) after checking Brevo accepts it.
rpt_configure_brevo() {
  local key out code
  IFS= read -r key || [[ -n "$key" ]] || die "No API key on stdin."
  key=${key//[$'\r\n ']/}
  [[ "$key" =~ ^xkeysib-[A-Za-z0-9-]+$ ]] || warn "That doesn't look like a Brevo API key (they start xkeysib-); trying it anyway."
  out=$(mktemp)
  code=$(printf 'api-key: %s\n' "$key" | curl -sS --max-time 30 -o "$out" -w '%{http_code}' -H @- -H 'accept: application/json' "$BREVO_API/account" 2>&1) || code=${code:-000}
  if [[ "$code" != 200 ]]; then
    local why
    why=$(jq -r '.message // empty' "$out" 2>/dev/null || true)
    rm -f "$out"
    die "Brevo refused the key ($code${why:+: $why}). If it mentions an unrecognised IP, allow this server's address in Brevo: Settings → Security → Authorised IPs."
  fi
  ok "Brevo accepted the key (account $(jq -r '.email // "?"' "$out"))."
  rm -f "$out"
  install -d -m 0700 "$SECRETS_DIR"
  (umask 077 && printf '%s' "$key" >"$(secret_path brevo-api-key)")
  _log "SECRET installed brevo-api-key"
  ok "Saved as a root-only secret. Send a report now with:  cx-pgsql report send"
}

# ─── Planned-downtime notice ────────────────────────────────────────────────────────
# A reboot (or power-off) booked with `shutdown -r <time>` — by hand, or by unattended-upgrades'
# Automatic-Reboot-Time — leaves /run/systemd/shutdown/scheduled. cx-reboot-notice.path runs this the moment
# that changes (and a half-hourly timer as a safety net): one email per booking, another if it moves or is
# cancelled. What was announced is kept in reboot-notice.json; /run is emptied by the reboot itself.
REBOOT_SCHEDULE_FILE=/run/systemd/shutdown/scheduled

rpt_reboot_notice() { # [--preview]
  local preview=0 state="$REPORT_STATE_DIR/reboot-notice.json" usec mode reason prev_usec now kind at="" prev_at="" input digest id
  [[ "${1:-}" == --preview ]] && preview=1
  rpt_lock
  install -d -m 0700 "$REPORT_STATE_DIR"
  usec=$(sed -n 's/^USEC=//p' "$REBOOT_SCHEDULE_FILE" 2>/dev/null || true)
  mode=$(sed -n 's/^MODE=//p' "$REBOOT_SCHEDULE_FILE" 2>/dev/null || true)
  reason=$(sed -n 's/^WALL_MESSAGE=//p' "$REBOOT_SCHEDULE_FILE" 2>/dev/null || true)
  reason=$(printf '%b' "$reason")
  prev_usec=$(jq -r '.usec // empty' "$state" 2>/dev/null || true)
  now=$(date +%s)

  if [[ -z "$usec" ]]; then
    if ((preview)); then
      # Nothing booked: show what tonight's automatic reboot would announce.
      usec=$(($(date -u -d "today ${AUTO_REBOOT_TIME:-23:00}" +%s) * 1000000))
      ((usec / 1000000 > now)) || usec=$(($(date -u -d "tomorrow ${AUTO_REBOOT_TIME:-23:00}" +%s) * 1000000))
      kind=booked mode=reboot
    elif [[ -n "$prev_usec" ]] && ((prev_usec / 1000000 > now + 60)); then
      kind=cancelled # announced, still in the future, and gone: cancelled (not the reboot happening)
    else
      rm -f "$state"
      return 0
    fi
  elif [[ "$usec" == "$prev_usec" ]] && ((!preview)); then
    return 0 # already announced
  elif [[ -n "$prev_usec" ]] && ((prev_usec / 1000000 > now)); then
    kind=moved
  else
    kind=booked
  fi
  case $mode in poweroff | halt) mode=poweroff ;; *) mode=reboot ;; esac
  [[ -n "$usec" ]] && at=$(date -u -d "@$((usec / 1000000))" +%Y-%m-%dT%H:%M:%SZ)
  [[ -n "$prev_usec" ]] && prev_at=$(date -u -d "@$((prev_usec / 1000000))" +%Y-%m-%dT%H:%M:%SZ)

  input=$(mktemp "$REPORT_STATE_DIR/notice-input.XXXXXX")
  digest=$(mktemp "$REPORT_STATE_DIR/notice.XXXXXX")
  jq -nc --arg host "$SERVER_HOSTNAME" --arg fqdn "$SERVER_FQDN" --arg tz "${REPORT_TIMEZONE:-Europe/London}" \
    --arg kind "$kind" --arg mode "$mode" --arg at "$at" --arg prev "$prev_at" --arg reason "$reason" \
    --argjson pkgs "$( (cat /var/run/reboot-required.pkgs 2>/dev/null || true) | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')" \
    --argjson last "$(_rpt_last_reboot)" \
    --argjson dbs "$(pg_sql -At -d postgres -c "SELECT coalesce(json_agg(datname ORDER BY datname), '[]') FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" 2>/dev/null || echo '[]')" \
    --argjson objects "$(is_true "$ENABLE_OBJECTS" && echo true || echo false)" \
    --argjson feed "$(is_true "${MAINTENANCE_FEED:-true}" && echo true || echo false)" \
    '{server: {hostname: $host, fqdn: $fqdn}, timezone: $tz,
      notice: {kind: $kind, mode: $mode, at: (if $at == "" then null else $at end), previous_at: (if $prev == "" then null else $prev end),
               reason: (if $reason == "" then null else $reason end), packages: $pkgs, last_reboot: $last, databases: $dbs, objects: $objects,
               feed: $feed}}' >"$input"
  if ! docker exec -i "$HEALTH_CONTAINER" node /app/digest.mjs notice <"$input" >"$digest" || ! jq -e .subject "$digest" >/dev/null 2>&1; then
    rm -f "$input" "$digest"
    die "The reboot notice could not be built (is $HEALTH_CONTAINER running?) — the timer tries again."
  fi
  rm -f "$input"
  jq -r .html "$digest" >"$REPORT_STATE_DIR/notice.html"
  if ((preview)); then
    info "Built, not sent: $(jq -r .subject "$digest")"
    rm -f "$digest"
    return 0
  fi
  if id=$(rpt_send "$digest" server-reboot "${REBOOT_NOTICE_TO:-$REPORT_TO}"); then
    if [[ $kind == cancelled ]]; then rm -f "$state"; else jq -nc --arg u "$usec" --arg at "$at" --arg k "$kind" '{usec: $u, at: $at, kind: $k}' >"$state"; fi
    status_update '.reboot_notice = {last_sent: $now, kind: $k, at: (if $at == "" then null else $at end)}' --arg k "$kind" --arg at "$at"
    ok "Reboot notice ($kind) sent to ${REBOOT_NOTICE_TO:-$REPORT_TO}: $(jq -r .subject "$digest") [$id]"
    rm -f "$digest"
  else
    rm -f "$digest"
    die "Reboot notice not sent: $id — the timer tries again."
  fi
}

