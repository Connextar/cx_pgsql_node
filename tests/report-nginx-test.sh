#!/usr/bin/env bash
# The nightly report's reading of an app's nginx access log (lib/report.sh, _rpt_app_nginx): needs only bash, awk
# and jq, so it runs anywhere. On the server's awk (Debian's mawk) as well as yours:
#   tests/report-nginx-test.sh
#   docker run --rm -v "$PWD:/p:ro" -w /p debian:trixie sh -c 'apt-get -qq update && apt-get -qq install -y jq >/dev/null && bash tests/report-nginx-test.sh'
set -uo pipefail
cd "$(dirname "$0")/.."
# lib/report.sh only defines functions; it needs nothing else to be loaded for this one.
# shellcheck source=../lib/report.sh
source lib/report.sh
PASS=0 FAIL=0
t() { local name=$1; shift; if "$@"; then echo "PASS  $name"; PASS=$((PASS + 1)); else echo "FAIL  $name"; FAIL=$((FAIL + 1)); fi; }

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
# Yesterday's file: one line before the period, then the format as it was (combined) and as it is (cx_app).
cat >"$dir/access.log.1" <<'EOF'
203.0.113.9 - - [17/Nov/2026:23:59:59 +0000] "GET /relay HTTP/1.1" 101 300 "-" "Twilio.TmeWs/1.0" 50.000 "websocket"
203.0.113.9 - - [18/Nov/2026:06:00:01 +0000] "GET /relay HTTP/1.1" 101 812 "-" "Twilio.TmeWs/1.0"
203.0.113.7 - - [18/Nov/2026:07:10:00 +0000] "HEAD /healthz HTTP/1.1" 502 0 "-" "Mozilla/5.0+(compatible; UptimeRobot/2.0)"
EOF
cat >"$dir/access.log" <<'EOF'
203.0.113.9 - - [18/Nov/2026:09:00:00 +0000] "GET /relay HTTP/1.1" 101 9120 "-" "Twilio.TmeWs/1.0" 84.512 "websocket"
203.0.113.9 - - [18/Nov/2026:09:30:00 +0000] "GET /relay?x=1 HTTP/1.1" 101 1200 "-" "Twilio.TmeWs/1.0" 12.000 "websocket"
203.0.113.9 - - [18/Nov/2026:10:00:00 +0000] "GET /relay HTTP/1.1" 101 99999 "-" "Twilio.TmeWs/1.0" 3599.100 "websocket"
198.51.100.4 - - [18/Nov/2026:11:00:00 +0000] "GET /relay HTTP/1.1" 403 9 "-" "python-requests/2.32 \x22quoted\x22 1.0" 0.002 "websocket"
198.51.100.4 - - [18/Nov/2026:11:00:01 +0000] "GET /relay HTTP/1.1" 502 157 "-" "Twilio.TmeWs/1.0" 0.001 "WebSocket"
198.51.100.4 - - [18/Nov/2026:11:05:00 +0000] "GET /gate.php HTTP/1.1" 404 5 "-" "Mozilla/5.0 Chrome/108.0.0.0 Safari/537.36" 0.001 "-"
198.51.100.4 - - [18/Nov/2026:11:05:01 +0000] "POST /fallback.xml HTTP/1.1" 200 410 "-" "TwilioProxy/1.1" 0.000 "-"
203.0.113.7 - - [18/Nov/2026:12:00:00 +0000] "HEAD /healthz HTTP/1.1" 200 0 "-" "Mozilla/5.0+(compatible; UptimeRobot/2.0)" 0.004 "-"
198.51.100.4 - - [18/Nov/2026:12:00:02 +0000] "-" 400 0 "-" "-" 0.000 "-"
EOF

out=$(_rpt_app_nginx "2026-11-18 06:00:00" /healthz 3600 "$dir/access.log.1" "$dir/access.log")
echo "$out" | jq -c .
q() { [[ "$(jq -cS "$1" <<<"$out")" == "$2" ]] || { echo "      $1 = $(jq -cS "$1" <<<"$out"), wanted $2"; return 1; }; }
valid() { jq -e . <<<"$out" >/dev/null; }

t "valid JSON" valid
t "lines before the period are left out" q .requests 11
t "statuses counted" q .status '{"101":4,"200":2,"400":1,"403":1,"404":1,"502":2}'
t "upgrades: by the Upgrade header, or a 101 in the old format" q .upgrades '{"status":{"101":4,"403":1,"502":1},"total":6}'
t "sessions: four, three of them timed" q '.sessions | [.count, .timed]' '[4,3]'
t "session lengths summed, longest kept" q '.sessions | [.total_s, .max_s] | map(. * 1000 | round)' '[3695612,3599100]'
t "one session at the one-hour limit" q .sessions.at_timeout 1
t "the health path: two requests, one 5xx" q '[.health_requests, .health_5xx]' '[2,1]'
t "no log: null" test "$(_rpt_app_nginx "2026-11-18 06:00:00" /healthz 0 "$dir/none.log")" = null
empty=$(_rpt_app_nginx "2027-01-01 00:00:00" /healthz 0 "$dir/access.log")
t "nothing in the period: zero counts and empty objects" test "$(jq -c '[.requests, .status, .upgrades, .sessions.count]' <<<"$empty")" = '[0,{},{"total":0,"status":{}},0]'

echo
echo "passed $PASS, failed $FAIL"
((FAIL == 0))
