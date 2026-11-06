#!/usr/bin/env bash
# Maintenance windows on a test VPS after `remote.sh apply` (see tests/README.md):
#   tests/vps.sh exec bash -s < tests/maintenance-test.sh
# Exercises the real units: a booked reboot through logind, the path unit, the feed through nginx, the
# commands, and the settle job. Emails are skipped (no Brevo key on a test VPS).
set -uo pipefail
pass=0 failed=0
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then echo "  ✓ $what"; pass=$((pass + 1)); else echo "  ✗ $what"; failed=$((failed + 1)); fi; }
# shellcheck disable=SC1091
set -a; source /opt/cx-pgsql/config/server.env.sample; source /opt/cx-pgsql/config/server.env; set +a
export FEED="https://$SERVER_FQDN/maintenance.json"
feed() { curl -sk --resolve "$SERVER_FQDN:443:127.0.0.1" "$FEED"; }
wait_for() { local i; for i in $(seq 1 30); do if eval "$1" >/dev/null 2>&1; then return 0; fi; sleep 1; done; return 1; }

echo "Published"
check "feed through nginx, version 1, CORS" bash -c "curl -sk -D- --resolve '$SERVER_FQDN:443:127.0.0.1' '$FEED' | grep -qi 'access-control-allow-origin: \*'"
check "feed names the server" bash -c "$(declare -f feed); feed | jq -e '.version == 1 and .server == \"$SERVER_HOSTNAME\"'"
check "units enabled" systemctl is-enabled --quiet cx-maintenance.path cx-maintenance-sync.timer cx-maintenance-settle.service
check "path unit watching" systemctl is-active --quiet cx-maintenance.path

echo "A booked reboot"
shutdown -r +180 "test booking" >/dev/null 2>&1
check "path unit writes the window" wait_for "feed | jq -e '[.windows[] | select(.kind == \"reboot\" and .state == \"planned\")] | length == 1'"
check "15-minute window, 2-ish expected" bash -c "$(declare -f feed); feed | jq -e '.windows[] | select(.state == \"planned\") | ((.ends_by | fromdateiso8601) - (.starts_at | fromdateiso8601)) >= 900'"
check "nothing internal published" bash -c "$(declare -f feed); ! feed | grep -qiE 'test booking|packages|source|created_at'"
shutdown -r +240 >/dev/null 2>&1
check "moved: old cancelled, new planned" wait_for "feed | jq -e '([.windows[] | select(.kind == \"reboot\") | .state] | sort) == [\"cancelled\", \"planned\"]'"
shutdown -c >/dev/null 2>&1
check "shutdown -c cancels it" wait_for "feed | jq -e '[.windows[] | select(.kind == \"reboot\" and .state == \"planned\")] | length == 0'"

echo "By hand"
cx-pgsql maintenance plan "$(TZ=Europe/London date -d '+2 days' '+%Y-%m-%d 02:00')" 30m "Upgrading the database" >/dev/null 2>&1
check "plan → planned with its message" bash -c "$(declare -f feed); feed | jq -e '[.windows[] | select(.kind == \"maintenance\" and .state == \"planned\" and .message == \"Upgrading the database\")] | length == 1'"
cx-pgsql maintenance start 20m >/dev/null 2>&1
check "start → active, the planned one replaced" bash -c "$(declare -f feed); feed | jq -e '[.windows[] | select(.kind == \"maintenance\" and .state != \"cancelled\") | .state] == [\"active\"]'"
cx-pgsql maintenance extend 10m >/dev/null 2>&1
check "extend → 30 min" bash -c "$(declare -f feed); feed | jq -e '.windows[] | select(.state == \"active\") | ((.ends_by | fromdateiso8601) - (.starts_at | fromdateiso8601)) == 1800'"
cx-pgsql maintenance end >/dev/null 2>&1
check "end → ended, ended_at set" bash -c "$(declare -f feed); feed | jq -e '([.windows[] | select(.state == \"active\")] | length == 0) and ([.windows[] | select(.kind == \"maintenance\" and .ended_at != null)] | length == 1)'"
check "status lists them" bash -c "cx-pgsql maintenance status | grep -q ended"

echo "Settle after a reboot"
f=/var/lib/cx-pgsql/maintenance/windows.json
s=$(date -u -d '-1 min' +%Y-%m-%dT%H:%M:%SZ) e=$(date -u -d '+14 min' +%Y-%m-%dT%H:%M:%SZ)
jq --arg s "$s" --arg e "$e" '.windows += [{id: "reboot-settle-test", kind: "reboot", source: "reboot", starts_at: $s, ends_by: $e, expected_minutes: 2, ended_at: null, cancelled_at: null, affects: ["postgres"], message: null}]' "$f" >"$f.t" && mv "$f.t" "$f"
check "an active reboot window" bash -c "$(declare -f feed); feed | jq -e '.windows[] | select(.id == \"reboot-settle-test\") | .state == \"active\"'"
systemctl start cx-maintenance-settle.service
check "settle ends it once healthy" bash -c "$(declare -f feed); feed | jq -e '.windows[] | select(.id == \"reboot-settle-test\") | .state == \"ended\" and .ended_at != null'"

echo "Unreadable file"
cp "$f" /tmp/w.json; echo '{broken' >"$f"
check "a 503, so the apps keep their copy" bash -c "[[ \$(curl -sk -o /dev/null -w '%{http_code}' --resolve '$SERVER_FQDN:443:127.0.0.1' '$FEED') == 503 ]]"
cp /tmp/w.json "$f"

echo "The nightly report"
t=$(mktemp -d)
mkdir -p "$t/logs/postgres" "$t/mnt"
printf '%s\n' \
  '2026-11-04 23:00:01.100 UTC [11] 10.0.0.2(5001) alted@alted FATAL:  terminating connection due to administrator command' \
  '2026-11-05 03:00:01.000 UTC [14] 10.0.0.3(5003) alted@alted FATAL:  terminating connection due to administrator command' \
  >"$t/logs/postgres/postgresql-Thu.log"
printf '%s\n' '{"version":1,"windows":[{"id":"r","kind":"reboot","starts_at":"2026-11-04T23:00:00Z","ends_by":"2026-11-04T23:15:00Z","ended_at":"2026-11-04T23:00:35Z","cancelled_at":null}]}' >"$t/mnt/windows.json"
pglog=$(STACK_LOGS_DIR="$t/logs" MAINTENANCE_DIR="$t/mnt" bash -c 'source /opt/cx-pgsql/lib/core.sh; source /opt/cx-pgsql/lib/report.sh; _rpt_pg_log "2026-11-04 00:00:00"' 2>/dev/null)
check "shutdown FATAL inside a window marked planned, the same outside one not" \
  jq -e '[.errors[] | select(.severity == "FATAL") | .planned] | sort == [false, true]' <<<"$pglog"
rm -rf "${t:?}"
updates=$(bash -c 'set -a; source /opt/cx-pgsql/config/server.env.sample; source /opt/cx-pgsql/config/server.env; set +a; source /opt/cx-pgsql/lib/core.sh; source /opt/cx-pgsql/lib/report.sh; _rpt_updates' 2>/dev/null)
check "updates: automatic security updates on, security packages listed by name" \
  jq -e '.auto.enabled == true and (.security_packages | type == "array") and (.security_packages | length) == .security' <<<"$updates"

echo "passed $pass, failed $failed"
((failed == 0))
