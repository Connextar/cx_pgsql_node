#!/usr/bin/env bash
# App container tests (steps/95-apps.sh, lib/apps.sh), run as root inside the test VPS after a full
# apply with one app, config/apps/cx-support-relay.env from example.env.sample, but:
#   APP_FQDN=relay-test.example.invalid   APP_REPO=/srv/git/cx-support.git (a bare copy of cx-support,
#   APP_STATIC=services/voice-relay/static holding fallback.xml)
#   VOICE_RELAY_URL=wss://relay-test.example.invalid/relay
# and its secrets set with TWILIO_AUTH_TOKEN=test-token-123 (bin/remote.sh app-secrets … --from <file>).
# Usage: tests/vps.sh exec bash -s < tests/apps-test.sh
set -uo pipefail
APP=cx-support-relay
FQDN=relay-test.example.invalid
TOKEN=test-token-123
DIR=/data/apps/cx-apps/$APP
C=cx-app-$APP
SETUP=/opt/cx-pgsql/setup.sh
PASS=0 FAIL=0
t() { local name=$1; shift; if "$@" >/tmp/t.out 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; sed 's/^/      /' /tmp/t.out | tail -8; FAIL=$((FAIL+1)); fi; }
not() { ! "$@"; }
has() { grep -q -- "$1" /tmp/t.out; }

health() { curl -sk --max-time 5 --resolve "$FQDN:443:127.0.0.1" "https://$FQDN/healthz"; }
serves() { health | grep -qE "$1"; }
serves_file() { curl -sk --max-time 5 --resolve "$FQDN:443:127.0.0.1" "https://$FQDN$1" | grep -q "$2"; }
# A WebSocket upgrade through nginx; prints the status code (101 = upgraded). $1: the signature, or empty.
upgrade() {
  local sig=()
  [[ -n "$1" ]] && sig=(-H "X-Twilio-Signature: $1")
  curl -sk --max-time 3 -o /dev/null -w '%{http_code}' --http1.1 --resolve "$FQDN:443:127.0.0.1" \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${sig[@]}" "https://$FQDN/relay" || true
}
# Twilio's signature for a WebSocket URL: HMAC-SHA1 of the URL (no parameters), base64.
twilio_sig() { printf '%s' "wss://$FQDN/relay" | openssl dgst -sha1 -hmac "$TOKEN" -binary | base64; }
started() { docker inspect -f '{{.State.StartedAt}}' "$C"; }
commit() { git -C "$DIR/src" rev-parse --short=7 HEAD; }

echo "── served through nginx"
t "https://$FQDN/healthz → ok <version> <commit>" serves "^ok [0-9.]+ $(commit)\$"
t "unsigned WebSocket upgrade refused by the relay (403)" test "$(upgrade '')" = 403
t "a wrong signature refused (403)" test "$(upgrade 'bm90IGEgc2lnbmF0dXJl')" = 403
t "Twilio-signed upgrade passes nginx and the relay (101)" test "$(upgrade "$(twilio_sig)")" = 101
t "plain HTTP redirects to HTTPS" sh -c "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $FQDN' http://127.0.0.1/healthz | grep -qx 301"
t "nginx: an hour for a WebSocket" grep -q 'proxy_read_timeout 3600s' /etc/nginx/sites-available/$C.conf

echo "── static files (APP_STATIC): the 0800 number's fallback TwiML"
t "GET /fallback.xml → 200 text/xml" sh -c "test \"\$(curl -sk --resolve $FQDN:443:127.0.0.1 -o /tmp/body -w '%{http_code} %{content_type}' https://$FQDN/fallback.xml)\" = '200 text/xml'"
t "it is the TwiML: Say, then Hangup" sh -c "grep -q '<Say language=\"en-GB\" voice=\"Polly.Arthur-Neural\">Sorry, this line' /tmp/body && grep -q '<Hangup/>' /tmp/body"
t "POST /fallback.xml (as Twilio may) → 200 and the same file" sh -c "test \"\$(curl -sk --resolve $FQDN:443:127.0.0.1 -X POST -d CallSid=CA1 -o /tmp/body2 -w '%{http_code}' https://$FQDN/fallback.xml)\" = 200 && cmp -s /tmp/body /tmp/body2"
t "published read-only to nginx: root-owned 0644" test "$(stat -c %U:%a /var/www/cx-apps/$APP/fallback.xml)" = root:644
docker stop "$C" >/dev/null
t "still answers with the relay stopped" sh -c "test \"\$(curl -sk --resolve $FQDN:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://$FQDN/fallback.xml)\" = 200"
t "while /healthz goes to the (stopped) app: 502" test "$(curl -sk --resolve "$FQDN:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$FQDN/healthz")" = 502
docker start "$C" >/dev/null
for _ in $(seq 1 30); do [[ "$(docker inspect -f '{{.State.Health.Status}}' "$C")" == healthy ]] && break; sleep 1; done
t "relay back: /healthz and the signed upgrade still reach it" sh -c "curl -sk --resolve $FQDN:443:127.0.0.1 https://$FQDN/healthz | grep -q '^ok' && test \"\$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' --http1.1 --resolve $FQDN:443:127.0.0.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'X-Twilio-Signature: $(twilio_sig)' https://$FQDN/relay)\" = 101"

echo "── locked down"
insp() { docker inspect -f "$1" "$C"; }
t "read-only root filesystem" test "$(insp '{{.HostConfig.ReadonlyRootfs}}')" = true
t "every capability dropped" sh -c "docker inspect -f '{{json .HostConfig.CapDrop}}' $C | grep -q ALL"
t "no-new-privileges" sh -c "docker inspect -f '{{json .HostConfig.SecurityOpt}}' $C | grep -q no-new-privileges"
t "runs as uid 10010" test "$(insp '{{.Config.User}}')" = 10010:10010
t "memory limited to 512 MB" test "$(insp '{{.HostConfig.Memory}}')" = 536870912
t "process cap 256" test "$(insp '{{.HostConfig.PidsLimit}}')" = 256
t "published on loopback only" sh -c "ss -Hltn 'sport = :28510' | awk '{print \$4}' | grep -qx '127.0.0.1:28510'"
t "on its own network only" test "$(insp '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')" = "$C "
PGIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cx-pgsql-postgres)
conn() { docker exec "$C" node -e "const s=require('net').connect({host:'$1',port:$2,timeout:3000});s.on('connect',()=>process.exit(0));s.on('timeout',()=>process.exit(1));s.on('error',()=>process.exit(1))"; }
t "no route to Postgres by its network address ($PGIP:5432)" not conn "$PGIP" 5432
t "the name 'postgres' doesn't resolve" not conn postgres 5432
t "the health service's loopback port isn't reachable" not conn 127.0.0.1 28480
t "the internet is (Anthropic's API, 443)" conn api.anthropic.com 443
t "can't write outside /tmp" not docker exec "$C" sh -c 'echo x > /app/x'
t "can write /tmp" docker exec "$C" sh -c 'echo x > /tmp/x'

echo "── secrets"
t "secrets.env is root-only (600)" test "$(stat -c %a:%U "$DIR/secrets.env")" = 600:root
t "each secret a root-only file" sh -c "stat -c %a /etc/cx-pgsql/secrets/app-$APP-* | grep -vx 600 | grep -q . && exit 1 || exit 0"
t "values single-quoted for Compose" grep -qx "TWILIO_AUTH_TOKEN='$TOKEN'" "$DIR/secrets.env"
t "no secret in app.env or compose.yml" not grep -q "$TOKEN" "$DIR/app.env" "$DIR/compose.yml"
t "the container got the token" sh -c "docker exec $C node -e 'process.exit(process.env.TWILIO_AUTH_TOKEN===\"$TOKEN\"?0:1)'"
t "cx-pgsql app secrets lists names, not values" sh -c "cx-pgsql app secrets $APP > /tmp/s && grep -q 'TWILIO_AUTH_TOKEN *set' /tmp/s && ! grep -q '$TOKEN' /tmp/s"
t "a secret with a quote is refused" not sh -c "printf \"a'b\n\" | cx-pgsql app secret $APP ANTHROPIC_API_KEY"
t "an unknown secret name is refused" not sh -c "printf 'x\n' | cx-pgsql app secret $APP NOT_ONE_OF_THEM"
t "two lines are refused" not sh -c "printf 'a\nb\n' | cx-pgsql app secret $APP ANTHROPIC_API_KEY"

echo "── idempotent: an apply leaves a running app alone"
before=$(started)
t "status: apps DONE" sh -c "$SETUP status apps"
t "apply apps changes nothing" sh -c "$SETUP apply apps | grep -q 'apps: already done'"
t "not restarted" test "$(started)" = "$before"

echo "── a new commit: a warning, then a deploy"
old=$(commit)
EXTRA="extra-$(date +%s).txt"
rm -rf /tmp/w && git clone -q /srv/git/cx-support.git /tmp/w
(cd /tmp/w && echo "// test $(date +%s)" >>services/voice-relay/main.ts && echo extra >"services/voice-relay/static/$EXTRA" &&
  echo hidden >services/voice-relay/static/.hidden && ln -sf /etc/passwd services/voice-relay/static/passwd &&
  git add -A && git -c user.name=t -c user.email=t@t commit -qm 'test: a change, with static files' && git push -q origin main)
new=$(git -C /tmp/w rev-parse --short=7 HEAD)
t "status warns that main has moved on" sh -c "$SETUP status apps | grep -q '! $APP: the newest commit'"
t "still running the old commit" serves " $old\$"
t "cx-pgsql app deploy" cx-pgsql app deploy $APP
t "now running the new commit" serves " $new\$"
t "the new static file is served" serves_file "/$EXTRA" extra
t "a symlink in the folder isn't published" test ! -e /var/www/cx-apps/$APP/passwd
t "nor a dot-file" test ! -e /var/www/cx-apps/$APP/.hidden
t "/passwd doesn't give /etc/passwd" not serves_file /passwd root:
t "the previous image is kept" test -s "$DIR/.previous-image"
t "two images, no more" test "$(docker image ls cx-app/$APP -q | wc -l)" = 2
t "cx-pgsql app rollback" cx-pgsql app rollback $APP
t "back on the old commit" serves " $old\$"
t "and its static files with it ($EXTRA gone)" test ! -e "/var/www/cx-apps/$APP/$EXTRA"
t "status after rollback: DONE (with the newer-commit warning)" sh -c "$SETUP status apps"
t "deploy again" cx-pgsql app deploy $APP
t "on the new commit again" serves " $new\$"

echo "── drift is repaired"
docker stop "$C" >/dev/null
t "stopped → BROKEN" not $SETUP status apps
echo '# edited' >>/etc/nginx/sites-available/$C.conf
t "edited site → nginx BROKEN" not $SETUP status nginx
t "apply repairs both" $SETUP apply nginx apps
t "serving again" serves "^ok "

echo "── config checks"
cp /opt/cx-pgsql/config/apps/$APP.env /opt/cx-pgsql/config/apps/clash.env
sed -i 's/^APP_NAME=.*/APP_NAME=clash/' /opt/cx-pgsql/config/apps/clash.env
t "a second app on the same port and name: status fails" sh -c "! $SETUP status apps > /tmp/t2 && grep -q 'two apps' /tmp/t2"
t "and apply refuses" not $SETUP apply apps
sed -i -e 's/^APP_PORT=.*/APP_PORT=28511/' -e 's/^APP_FQDN=.*/APP_FQDN=clash-test.example.invalid/' \
  -e 's#^APP_REPO=.*#APP_REPO=git@github.com:Connextar/cx-support.git#' /opt/cx-pgsql/config/apps/clash.env
t "an SSH repo without its deploy key: apply says how to add it" sh -c "$SETUP apply nginx tls >/dev/null; $SETUP apply apps 2>&1 | tee /tmp/t3; grep -q 'Deploy keys' /tmp/t3 && grep -q 'ssh-ed25519 ' /tmp/t3"
t "GitHub's pinned host key was accepted (the refusal is the key, not the host)" sh -c "grep -qi 'permission denied' $(dirname $DIR)/clash/fetch.log && ! grep -qi 'host key verification' $(dirname $DIR)/clash/fetch.log"
t "cx-pgsql app key prints it" sh -c "cx-pgsql app key clash | grep -q '^ssh-ed25519 '"
t "the first app is untouched" serves " $new\$"
rm /opt/cx-pgsql/config/apps/clash.env
t "apply removes the second app's nginx site" sh -c "$SETUP apply nginx >/dev/null; test ! -e /etc/nginx/sites-enabled/cx-app-clash.conf"
t "cx-pgsql app list" sh -c "cx-pgsql app list | grep -q '^$APP .*running'"
t "certbot's deploy hook still runs" /opt/cx-pgsql/lib/tls-deploy-hook.sh

echo "── teardown"
t "teardown apps" $SETUP teardown apps --yes
t "container gone" not docker inspect "$C"
t "images gone" test -z "$(docker image ls cx-app/$APP -q)"
t "checkout kept (no --purge)" test -d "$DIR/src"
t "apply brings it back" $SETUP apply apps
t "serving again" serves "^ok "

echo
echo "passed $PASS, failed $FAIL"
