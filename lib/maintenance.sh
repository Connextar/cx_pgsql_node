# shellcheck shell=bash
# Maintenance windows: when the apps on this server should expect it down. The windows live in
# $MAINTENANCE_DIR/windows.json; the health service publishes them as GET /maintenance.json (stack/health/
# src/maintenance.mjs), and every app reading that shows a planned-maintenance notice beforehand and a
# maintenance page during (@connextar/house/maintenance; the contract is cx-house's docs/Maintenance.md).
#
#   sync     a reboot booked with `shutdown -r <time>` (unattended-upgrades' AUTO_REBOOT, or by hand) becomes a
#            window; moved, it's replaced; `shutdown -c` cancels it. Run by cx-maintenance.path the moment the
#            booking changes, and by a timer as a safety net.
#   settle   at boot: once Postgres, PgBouncer and the object store are healthy, the reboot's window ends —
#            the apps come back within seconds instead of waiting for the window to run out.
#   plan | start | extend | end | cancel | status   windows booked by hand (cx-pgsql maintenance …).
#
# Stored window: { id, kind: reboot|maintenance, source, starts_at, ends_by, expected_minutes, ended_at,
# cancelled_at, affects[], message, created_at }. Times are UTC "YYYY-MM-DDTHH:MM:SSZ" (what jq's
# fromdateiso8601 reads). Only what the feed's contract lists leaves the server; `message` is public.

# Sourced before the config is loaded (derive_config sets the same directory): a default, not a read.
: "${MAINTENANCE_DIR:=/var/lib/cx-pgsql/maintenance}"
MAINTENANCE_FILE="$MAINTENANCE_DIR/windows.json"
MNT_KEEP_DAYS=7

# Shared jq definitions: a window is open while it's neither ended nor cancelled and its end hasn't passed.
MNT_JQ='def t: fromdateiso8601;
def open($now): .cancelled_at == null and .ended_at == null and (.ends_by | t) > $now;
def started($now): (.starts_at | t) <= $now;'

# Held until the process exits; taking it again in the same process is a no-op.
mnt_lock() {
  [[ -z "${MNT_LOCKED:-}" ]] || return 0
  install -d -m 0755 "$MAINTENANCE_DIR"
  exec 8>"$MAINTENANCE_DIR/.lock"
  flock -w 60 8 || die "Another maintenance command has held the lock for a minute."
  MNT_LOCKED=1
}

mnt_read() {
  if [[ -s "$MAINTENANCE_FILE" ]] && jq -e '.windows | type == "array"' "$MAINTENANCE_FILE" >/dev/null 2>&1; then
    cat "$MAINTENANCE_FILE"
  else
    printf '{"version":1,"windows":[]}\n'
  fi
}

# stdin (the whole document) → the file, atomically (a rename in the same directory: the health container
# mounts the directory, so it sees the new file). Windows closed more than MNT_KEEP_DAYS ago are dropped.
mnt_write() {
  local tmp now
  now=$(date +%s)
  tmp=$(mktemp "$MAINTENANCE_DIR/.windows.XXXXXX")
  jq --argjson now "$now" --argjson keep $((MNT_KEEP_DAYS * 86400)) "$MNT_JQ"'
    .version = 1
    | .windows |= map(select(
        ((.cancelled_at // .ended_at // .ends_by) | t) > ($now - $keep)))' >"$tmp" || { rm -f "$tmp"; die "Could not write the maintenance windows."; }
  chmod 0644 "$tmp"
  mv -f "$tmp" "$MAINTENANCE_FILE"
}

mnt_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# When this machine booted: PID 1's age. Not /proc/uptime, which inside a container is the host's.
mnt_boot_epoch() { echo $(($(date +%s) - $(ps -o etimes= -p 1 | tr -d ' '))); }

# "30m", "2h", "1h30m", "90" (minutes) → minutes; dies on anything else or outside 1 min–24 h.
mnt_minutes() {
  local s=${1:-} m=0
  [[ "$s" =~ ^([0-9]+h)?([0-9]+m?)?$ && -n "$s" ]] || die "A duration is like 30m, 2h or 1h30m (got '$s')."
  [[ -n "${BASH_REMATCH[1]}" ]] && m=$((10#${BASH_REMATCH[1]%h} * 60))
  [[ -n "${BASH_REMATCH[2]}" ]] && m=$((m + 10#${BASH_REMATCH[2]%m}))
  ((m >= 1 && m <= 1440)) || die "A window is between a minute and a day (got $m minutes)."
  echo "$m"
}

# A time as typed (UK time unless it names a zone, like the emails) → epoch seconds.
mnt_parse_when() {
  local e
  e=$(TZ="${REPORT_TIMEZONE:-Europe/London}" date -d "$1" +%s 2>/dev/null) || die "Can't read '$1' as a time (try \"2026-11-10 02:00\")."
  echo "$e"
}

mnt_affects() { is_true "$ENABLE_OBJECTS" && echo '["postgres","objects"]' || echo '["postgres"]'; }

# Public text: one line, no control characters, at most 280 characters.
mnt_message() { printf '%s' "$*" | tr -d '\000-\037\177' | cut -c1-280; }

# The open window matching a jq filter (newest start first), or nothing.
mnt_find() { # filter
  mnt_read | jq -c --argjson now "$(date +%s)" "$MNT_JQ"' [.windows[] | select(open($now)) | select('"$1"')] | sort_by(.starts_at) | last // empty'
}

# Change the window with this id: jq update applied to it.
mnt_update() { # id jq-update [jq args…]
  local id=$1 upd=$2
  shift 2
  mnt_read | jq --arg id "$id" "$@" "$MNT_JQ"' .windows |= map(if .id == $id then ('"$upd"') else . end)' | mnt_write
}

# Ids stay unique (updates go by id): a time booked again after a cancellation gets "-2", "-3"…
mnt_add() { # window json
  mnt_read | jq --argjson w "$1" '[.windows[].id] as $ids
    | first(($w.id, ($w.id + "-" + (range(2; 1000) | tostring))) | select(. as $x | $ids | any(. == $x) | not)) as $id
    | .windows += [$w + {id: $id}]' | mnt_write
}

mnt_window() { # id kind source starts ends expected message
  jq -nc --arg id "$1" --arg kind "$2" --arg src "$3" --arg s "$(mnt_iso "$4")" --arg e "$(mnt_iso "$5")" --argjson x "$6" \
    --arg msg "$7" --argjson aff "$(mnt_affects)" --arg now "$(mnt_iso "$(date +%s)")" \
    '{id: $id, kind: $kind, source: $src, starts_at: $s, ends_by: $e, expected_minutes: $x, ended_at: null, cancelled_at: null,
      affects: $aff, message: (if $msg == "" then null else $msg end), created_at: $now}'
}

mnt_id() { echo "$1-$(date -u -d "@$2" +%Y%m%dT%H%MZ)"; } # prefix epoch

# ─── Reboots ───────────────────────────────────────────────────────────────────────

# How long a reboot is likely to take, in minutes (the notice's rule: the last reboot's gap plus a minute for
# Postgres), and how long the window is: at least MAINTENANCE_MIN_MINUTES, or three times that.
mnt_reboot_minutes() {
  local offline expected
  offline=$(_rpt_last_reboot | jq -r '.offline_seconds // 15' 2>/dev/null || echo 15)
  [[ "$offline" =~ ^[0-9]+$ ]] || offline=15
  expected=$(((offline + 60 + 59) / 60))
  ((expected >= 1)) || expected=1
  echo "$expected $((expected * 3 > ${MAINTENANCE_MIN_MINUTES:-15} ? expected * 3 : ${MAINTENANCE_MIN_MINUTES:-15}))"
}

mnt_sync() {
  is_true "${MAINTENANCE_FEED:-true}" || return 0
  mnt_lock
  local usec at now win w_start w_id expected length
  usec=$(sed -n 's/^USEC=//p' "${REBOOT_SCHEDULE_FILE:-/run/systemd/shutdown/scheduled}" 2>/dev/null || true)
  now=$(date +%s)
  win=$(mnt_find '.kind == "reboot"')
  w_start=$(jq -r '.starts_at // empty | fromdateiso8601' <<<"${win:-null}" 2>/dev/null || true)
  w_id=$(jq -r '.id // empty' <<<"${win:-null}" 2>/dev/null || true)

  if [[ -n "$usec" ]]; then
    at=$((usec / 1000000))
    [[ "$w_start" == "$at" ]] && return 0 # already written
    if [[ -n "$w_id" ]] && ((w_start > now)); then
      mnt_update "$w_id" '.cancelled_at = $c' --arg c "$(mnt_iso "$now")" # moved: the new booking replaces it
      info "Reboot window $w_id replaced (the reboot moved)."
    fi
    read -r expected length < <(mnt_reboot_minutes)
    mnt_add "$(mnt_window "$(mnt_id reboot "$at")" reboot reboot "$at" $((at + length * 60)) "$expected" "")"
    ok "Reboot window: $(mnt_iso "$at"), expected $expected min, the apps gate for up to $length min."
    return 0
  fi

  [[ -n "$w_id" ]] || return 0
  if ((w_start > now + 60)); then
    mnt_update "$w_id" '.cancelled_at = $c' --arg c "$(mnt_iso "$now")"
    ok "Reboot window $w_id cancelled (the booking is gone)."
  elif (($(mnt_boot_epoch) < w_start && now > w_start + 300)); then
    # Its time passed five minutes ago and this machine never went down: the reboot didn't happen.
    mnt_update "$w_id" '.ended_at = $c' --arg c "$(mnt_iso "$now")"
    warn "Reboot window $w_id ended: its time passed without a reboot."
  fi
  return 0
}

# Postgres, PgBouncer and the object store as /healthz sees them: 0 when every one of them is ok.
mnt_healthy() {
  curl -fsS --max-time 5 "http://127.0.0.1:$HEALTH_PORT/healthz" 2>/dev/null |
    jq -e '.checks as $c | ["postgres_connect", "pgbouncer_connect", "objects"] | map(select($c[.] != null))
           | any(.[]; . == "postgres_connect") and all(.[]; $c[.] == "ok")' >/dev/null 2>&1
}

mnt_settle() {
  is_true "${MAINTENANCE_FEED:-true}" || return 0
  local win id deadline
  win=$(mnt_find '.kind == "reboot" and started($now)')
  [[ -n "$win" ]] || { info "No reboot window in progress."; return 0; }
  id=$(jq -r .id <<<"$win")
  deadline=$(($(date +%s) + ${MAINTENANCE_SETTLE_SECONDS:-600}))
  info "Reboot window $id: waiting for Postgres, PgBouncer and the object store."
  until mnt_healthy; do
    if [[ -z "$(mnt_find '.id == "'"$id"'"')" ]]; then
      info "Reboot window $id was ended or cancelled meanwhile."
      return 0
    fi
    if (($(date +%s) >= deadline)); then
      err "Still not healthy after ${MAINTENANCE_SETTLE_SECONDS:-600} s: the window ($id) runs to its end. End it with  cx-pgsql maintenance end"
      return 1
    fi
    sleep 5
  done
  mnt_lock
  mnt_update "$id" 'if .ended_at == null then .ended_at = $c else . end' --arg c "$(mnt_iso "$(date +%s)")"
  ok "Reboot window $id ended: everything is healthy again."
}

# ─── Windows booked by hand ────────────────────────────────────────────────────────

# The planned-downtime email for a window booked by hand. A failure is a warning: the window is recorded and
# the apps already see it.
mnt_notice() { # kind window-json [previous_at] [previous_ends_by]
  local kind=$1 win=$2 prev=${3:-} prev_ends=${4:-} input digest id
  is_true "$REBOOT_NOTICE" || return 0
  secret_exists brevo-api-key || { warn "No Brevo key: no email sent (bin/remote.sh brevo-auth)."; return 0; }
  install -d -m 0700 "$REPORT_STATE_DIR"
  input=$(mktemp "$REPORT_STATE_DIR/notice-input.XXXXXX")
  digest=$(mktemp "$REPORT_STATE_DIR/notice.XXXXXX")
  jq -nc --arg host "$SERVER_HOSTNAME" --arg fqdn "$SERVER_FQDN" --arg tz "${REPORT_TIMEZONE:-Europe/London}" \
    --arg kind "$kind" --argjson w "$win" --arg prev "$prev" --arg prevEnds "$prev_ends" \
    --argjson dbs "$(pg_sql -At -d postgres -c "SELECT coalesce(json_agg(datname ORDER BY datname), '[]') FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" 2>/dev/null || echo '[]')" \
    '{server: {hostname: $host, fqdn: $fqdn}, timezone: $tz,
      notice: {kind: $kind, mode: "maintenance", at: $w.starts_at, ends_by: $w.ends_by, expected_minutes: $w.expected_minutes,
               previous_at: (if $prev == "" then null else $prev end), previous_ends_by: (if $prevEnds == "" then null else $prevEnds end),
               message: $w.message, databases: $dbs, objects: ($w.affects | index("objects") != null), feed: true}}' >"$input"
  if docker exec -i "$HEALTH_CONTAINER" node /app/digest.mjs notice <"$input" >"$digest" 2>/dev/null && jq -e .subject "$digest" >/dev/null 2>&1; then
    jq -r .html "$digest" >"$REPORT_STATE_DIR/notice.html"
    if id=$(rpt_send "$digest" server-maintenance "${REBOOT_NOTICE_TO:-$REPORT_TO}"); then
      ok "Emailed ${REBOOT_NOTICE_TO:-$REPORT_TO}: $(jq -r .subject "$digest") [$id]"
    else
      warn "The email wasn't sent: $id"
    fi
  else
    warn "The email couldn't be built (is $HEALTH_CONTAINER running?)."
  fi
  rm -f "$input" "$digest"
}

mnt_plan() { # when duration [message…]
  [[ $# -ge 2 ]] || die 'cx-pgsql maintenance plan "2026-11-10 02:00" 30m [public message]'
  local at minutes msg now old old_id old_at win kind=booked
  at=$(mnt_parse_when "$1") || exit 1
  minutes=$(mnt_minutes "$2") || exit 1
  shift 2
  msg=$(mnt_message "$*")
  now=$(date +%s)
  ((at > now + 60)) || die "That's not in the future — to start now:  cx-pgsql maintenance start $((minutes))m"
  mnt_lock
  old=$(mnt_find '.kind == "maintenance"')
  if [[ -n "$old" ]]; then
    old_id=$(jq -r .id <<<"$old")
    old_at=$(jq -r .starts_at <<<"$old")
    (($(jq -r '.starts_at | fromdateiso8601' <<<"$old") > now)) || die "Maintenance $old_id is under way: extend or end it first."
    mnt_update "$old_id" '.cancelled_at = $c' --arg c "$(mnt_iso "$now")"
    kind=moved
  fi
  win=$(mnt_window "$(mnt_id maint "$at")" maintenance manual "$at" $((at + minutes * 60)) "$minutes" "$msg")
  mnt_add "$win"
  ok "Maintenance $kind: $(TZ="${REPORT_TIMEZONE:-Europe/London}" date -d "@$at" '+%a %-d %b %Y, %H:%M %Z') for $minutes min${msg:+ — \"$msg\"}."
  if [[ -n "$msg" ]]; then info "The message is public: every app shows it."; fi
  mnt_notice "$kind" "$win" "${old_at:-}"
}

mnt_start() { # [duration] [message…]
  local minutes=30 msg now old old_id win
  if [[ -n "${1:-}" ]]; then
    minutes=$(mnt_minutes "$1") || exit 1
    shift
  fi
  msg=$(mnt_message "$*")
  now=$(date +%s)
  mnt_lock
  old=$(mnt_find 'true')
  if [[ -n "$old" ]]; then
    old_id=$(jq -r .id <<<"$old")
    (($(jq -r '.starts_at | fromdateiso8601' <<<"$old") > now)) || die "Maintenance $old_id is already under way: extend or end it."
    if [[ $(jq -r .kind <<<"$old") == maintenance ]]; then
      [[ -n "$msg" ]] || msg=$(jq -r '.message // ""' <<<"$old")
      mnt_update "$old_id" '.cancelled_at = $c' --arg c "$(mnt_iso "$now")"
      info "The planned window $old_id starts now instead."
    fi
  fi
  win=$(mnt_window "$(mnt_id maint "$now")" maintenance manual "$now" $((now + minutes * 60)) "$minutes" "$msg")
  mnt_add "$win"
  ok "Maintenance started: the apps show their maintenance page within about 15 s, for up to $minutes min. End it with  cx-pgsql maintenance end"
  mnt_notice booked "$win"
}

mnt_extend() { # duration
  local minutes win id ends now new
  minutes=$(mnt_minutes "${1:-}") || exit 1
  mnt_lock
  win=$(mnt_find 'started($now)')
  [[ -n "$win" ]] || win=$(mnt_find 'true')
  [[ -n "$win" ]] || die "No maintenance window is open."
  id=$(jq -r .id <<<"$win")
  ends=$(jq -r '.ends_by | fromdateiso8601' <<<"$win")
  now=$(date +%s)
  new=$(((ends > now ? ends : now) + minutes * 60))
  mnt_update "$id" '.ends_by = $e' --arg e "$(mnt_iso "$new")"
  ok "$id now runs until $(TZ="${REPORT_TIMEZONE:-Europe/London}" date -d "@$new" '+%H:%M %Z')."
  mnt_notice extended "$(mnt_read | jq -c --arg id "$id" '.windows[] | select(.id == $id)')" "" "$(jq -r .ends_by <<<"$win")"
}

mnt_end() {
  local win id now
  mnt_lock
  win=$(mnt_find 'started($now)')
  if [[ -z "$win" ]]; then
    [[ -n "$(mnt_find 'true')" ]] && die "The open window hasn't started: to call it off,  cx-pgsql maintenance cancel"
    die "No maintenance window is under way."
  fi
  id=$(jq -r .id <<<"$win")
  now=$(date +%s)
  mnt_update "$id" '.ended_at = $c' --arg c "$(mnt_iso "$now")"
  ok "$id ended: the apps come back within about 15 s."
}

mnt_cancel() {
  local win id now
  mnt_lock
  now=$(date +%s)
  win=$(mnt_find 'started($now) | not')
  [[ -n "$win" ]] || die "No planned window to cancel (one under way is ended with  cx-pgsql maintenance end)."
  [[ $(jq -r .kind <<<"$win") == reboot ]] && die "That's a booked reboot: cancel the reboot itself with  sudo shutdown -c  (its window follows)."
  id=$(jq -r .id <<<"$win")
  mnt_update "$id" '.cancelled_at = $c' --arg c "$(mnt_iso "$now")"
  ok "$id cancelled."
  mnt_notice cancelled "$win" "$(jq -r .starts_at <<<"$win")"
}

mnt_status() {
  local tz=${REPORT_TIMEZONE:-Europe/London}
  is_true "${MAINTENANCE_FEED:-true}" || warn "MAINTENANCE_FEED is off: windows are kept, but the apps aren't told."
  mnt_read | jq -r --argjson now "$(date +%s)" "$MNT_JQ"'
    def state: if .cancelled_at then "cancelled" elif .ended_at then "ended" elif (.ends_by | t) <= $now then "ran out"
               elif started($now) then "UNDER WAY" else "planned" end;
    if (.windows | length) == 0 then "No maintenance windows."
    else (.windows | sort_by(.starts_at)[] | "\(state | . + "          " | .[:10])  \(.id)  \(.starts_at) → \(.ended_at // .ends_by)  \(.message // "")") end'
  info "Published at https://$SERVER_FQDN/maintenance.json  (times above are UTC; the apps show $tz)"
}

mnt_feed() { curl -fsS --max-time 5 "http://127.0.0.1:$HEALTH_PORT/maintenance.json" || die "The health service didn't answer."; }
