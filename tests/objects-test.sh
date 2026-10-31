#!/usr/bin/env bash
# Object storage tests (steps/72-objects.sh), run as root inside the test VPS after a full apply with
# ENABLE_OBJECTS=true, OBJECTS_FQDN=s3-test.example.invalid and two apps in config/objects/:
#   alted.env  OBJ_BUCKETS="alted-uploads alted-listing"      other.env  OBJ_BUCKETS="other-files"
# Usage: tests/vps.sh exec bash -s < tests/objects-test.sh   (expects a fresh VPS: it counts objects)
set -uo pipefail
S=/etc/cx-pgsql/secrets
FQDN=s3-test.example.invalid
PASS=0 FAIL=0
t() { local name=$1; shift; if "$@" >/tmp/t.out 2>&1; then echo "PASS  $name"; PASS=$((PASS+1)); else echo "FAIL  $name"; sed 's/^/      /' /tmp/t.out | tail -8; FAIL=$((FAIL+1)); fi; }
not() { ! "$@"; }

grep -q "$FQDN" /etc/hosts || echo "127.0.0.1 $FQDN" >>/etc/hosts
# An S3 remote "app:" through nginx on the public name, as an app on Vercel would use it.
app() {
  export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_APP_TYPE=s3 RCLONE_CONFIG_APP_PROVIDER=Other \
    RCLONE_CONFIG_APP_ENDPOINT="https://$FQDN" RCLONE_CONFIG_APP_REGION=garage RCLONE_CONFIG_APP_FORCE_PATH_STYLE=true \
    RCLONE_CONFIG_APP_NO_CHECK_BUCKET=true RCLONE_CONFIG_APP_ACCESS_KEY_ID="$(cat $S/objects-key-$1-id)" \
    RCLONE_CONFIG_APP_SECRET_ACCESS_KEY="$(cat $S/objects-key-$1-secret)"
}
r() { rclone --no-check-certificate -q "$@"; }

echo "── key isolation, through nginx"
mkdir -p /tmp/src/u /tmp/src/l
for i in 1 2 3 4 5; do head -c $((i * 50000)) /dev/urandom >/tmp/src/u/obj$i; done
for i in 1 2; do head -c 80000 /dev/urandom >/tmp/src/l/pic$i; done
touch -d '-1 day' /tmp/src/u/* /tmp/src/l/*      # older than verify's two-hour window
app alted
t "alted writes its uploads bucket" r copy /tmp/src/u app:alted-uploads/u
t "alted writes its listing bucket" r copy /tmp/src/l app:alted-listing/l
t "alted reads back byte for byte" r check --download /tmp/src/u app:alted-uploads/u
t "alted can't list other's bucket" not r lsf app:other-files
t "alted can't write other's bucket" not r copyto /tmp/src/u/obj1 app:other-files/x
sig() { printf 'user = "%s:%s"\n' "$(cat $S/objects-key-$1-id)" "$(cat $S/objects-key-$1-secret)" | curl -sk -o /dev/null -w '%{http_code}' -K - --aws-sigv4 aws:amz:garage:s3 "${@:2}"; }
t "alted can't create a bucket (signed PUT → 403)" test "$(sig alted -X PUT https://$FQDN/alted-new-bucket)" = 403
t "alted can't delete its own bucket (not owner)" test "$(sig alted -X DELETE https://$FQDN/alted-listing)" = 403
t "alted can't set a lifecycle (not owner)" test "$(sig alted -X PUT --data-binary '<LifecycleConfiguration/>' "https://$FQDN/alted-uploads?lifecycle")" = 403
app other
t "other can't read alted's uploads" not r lsf app:alted-uploads
app cx-backup
t "backup key reads alted's uploads" r lsf app:alted-uploads
t "backup key can't write alted's uploads" not r copyto /tmp/src/u/obj1 app:alted-uploads/x
t "unsigned GET through nginx refused (403)" test "$(curl -sk -o /dev/null -w '%{http_code}' https://$FQDN/alted-uploads/u/obj1)" = 403
t "admin API not reachable through nginx" test "$(curl -sk -o /dev/null -w '%{http_code}' https://$FQDN/v2/GetClusterStatus)" = 403
t "HTTP redirects to HTTPS" test "$(curl -s -o /dev/null -w '%{http_code}' --resolve $FQDN:80:127.0.0.1 http://$FQDN/)" = 301
t "admin port only on loopback" not sh -c "ss -ltn | grep -E '0\.0\.0\.0:2849[01]|\[::\]:2849[01]'"

echo "── health"
TOKEN=$(cat $S/health-token)
st() { curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:28480/status; }
t "objects check ok in /status" sh -c "curl -s -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:28480/status | jq -e '.checks[] | select(.name==\"objects\") | .status == \"ok\"'"
t "/healthz lists objects checks" sh -c "curl -s http://127.0.0.1:28480/healthz | jq -e '.checks | has(\"objects\") and has(\"objects_capacity\") and has(\"backup_objects\")'"

echo "── off-site copy to the stand-in Dropbox"
install -d /srv/fake-dropbox
[ -s /etc/cx-pgsql/rclone.conf ] || { umask 077; printf '[dropbox]\ntype = local\n' >/etc/cx-pgsql/rclone.conf; }
t "backup objects runs" cx-pgsql backup objects
t "status: objects_backup succeeded" jq -e '.objects_backup.last_success and .objects_backup.last_error == null' /data/backups/status/status.json
t "status: 7 objects measured" jq -e '.objects.objects == 7' /data/backups/status/status.json
D=/srv/fake-dropbox/CX_PGSQL_Node_1/objects
t "copy holds 7 files" test "$(find $D -type f | wc -l)" = 7
t "no plain key or bucket name in the copy" not sh -c "find $D | grep -E 'obj[0-9]|pic[0-9]|alted|live|deleted'"
t "no plain bytes in the copy" not cmp -s /tmp/src/u/obj1 "$(find $D -type f -size 50040c | head -1)"
st | jq -c '[.checks[] | select(.name|test("objects")) | {name, status}]'

echo "── deletion goes to deleted/<date>"
app alted
r deletefile app:alted-uploads/u/obj5
t "backup objects after a delete" cx-pgsql backup objects
(source /opt/cx-pgsql/lib/core.sh; PROJECT_DIR=/opt/cx-pgsql; load_config
 for l in dbconf pg backup objects; do source /opt/cx-pgsql/lib/$l.sh; done
 obj_crypt_env; rclone --config /etc/cx-pgsql/rclone.conf lsf -R cxcrypt:) >/tmp/tree 2>&1
t "deleted/$(date -u +%F)/alted-uploads/u/obj5 exists" grep -qx "deleted/$(date -u +%F)/alted-uploads/u/obj5" /tmp/tree
t "live/ no longer has obj5" not grep -qx "live/alted-uploads/u/obj5" /tmp/tree

echo "── verify"
cx-pgsql backup physical >/dev/null 2>&1   # a fresh server has no base backup for verify to restore yet
t "backup verify passes" cx-pgsql backup verify
t "verify recorded both buckets ok" jq -e '.verify.objects["alted-uploads"].ok and .verify.objects["alted-uploads"].checked == 4 and .verify.objects["alted-listing"].ok' /data/backups/status/status.json
t "scratch bucket left empty" test "$(cx-pgsql objects list | awk '$1=="cx-verify"{print $2}')" = 0

echo "── restore"
r deletefile app:alted-uploads/u/obj1
t "restore one object from live" cx-pgsql objects restore alted-uploads u/obj1
t "obj1 back and identical" r check --download /tmp/src/u app:alted-uploads/u --include obj1
t "restore a deleted one" cx-pgsql objects restore alted-uploads --deleted "$(date -u +%F)" u/obj5
t "obj5 back and identical" r check --download /tmp/src/u app:alted-uploads/u --include obj5
t "backup key lost write again" sh -c "cd /opt/cx-pgsql && PROJECT_DIR=/opt/cx-pgsql bash -c 'source lib/core.sh; load_config; for l in tls dbconf pg backup objects; do source lib/\$l.sh; done; obj_key_grants cx-backup' | grep -qx 'alted-uploads r--'"
t "restore refuses an unknown bucket" not cx-pgsql objects restore nope-bucket

echo "── tampered copy fails verify"
lib() { cd /opt/cx-pgsql && PROJECT_DIR=/opt/cx-pgsql bash -c "source lib/core.sh; load_config; for l in tls dbconf pg backup objects; do source lib/\$l.sh; done; obj_crypt_env; $1"; }
encpath() { lib "rclone --config /etc/cx-pgsql/rclone.conf cryptdecode --reverse cxcrypt: '$1'" | awk '{print $NF}'; }
tamper() { cp -p "$1" /tmp/victim.bak; printf 'x' | dd of="$1" bs=1 seek=100 conv=notrunc status=none; }
victim="$D/$(encpath live/alted-uploads/u/obj2)"
t "found the live copy of obj2" test -f "$victim"
tamper "$victim"
t "verify fails on a tampered live copy" not cx-pgsql backup verify
t "health backup_verify fails" sh -c "sleep 16; curl -s -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:28480/status | jq -e '.checks[] | select(.name==\"backup_verify\") | .status == \"fail\"'"
cp /tmp/victim.bak "$victim"   # a plain cp: the copy's timestamp changes, which verify must not mind
t "verify passes again once repaired" cx-pgsql backup verify
dname=$(lib "rclone --config /etc/cx-pgsql/rclone.conf lsf -R --files-only cxcrypt:deleted" | head -1)
dvictim="$D/$(encpath "deleted/$dname")"
t "found a deleted/ copy ($dname)" test -f "$dvictim"
tamper "$dvictim"
t "verify fails on a tampered deleted/ copy" not cx-pgsql backup verify
t "status names the deleted objects" jq -e '.verify.objects["deleted/"].ok == false' /data/backups/status/status.json
cp -p /tmp/victim.bak "$dvictim"
t "verify passes once that's repaired" cx-pgsql backup verify

echo "── key rotation"
old=$(cat $S/objects-key-alted-id)
t "rotate" cx-pgsql objects key alted rotate
app alted
t "new key works" r lsf app:alted-uploads
RCLONE_CONFIG_APP_ACCESS_KEY_ID=$old RCLONE_CONFIG_APP_SECRET_ACCESS_KEY=$(cat $S/objects-key-alted-secret.previous) t "old key still works" r lsf app:alted-uploads
t "drop-previous" cx-pgsql objects key alted drop-previous
RCLONE_CONFIG_APP_ACCESS_KEY_ID=$old RCLONE_CONFIG_APP_SECRET_ACCESS_KEY=x t "old key refused" not r lsf app:alted-uploads
t "key show hides the secret" not sh -c "cx-pgsql objects key alted | grep -F '$(cat $S/objects-key-alted-secret)'"

echo "── drift and repair"
docker stop cx-pgsql-objects >/dev/null
t "status BROKEN with Garage stopped" not /opt/cx-pgsql/setup.sh status objects
t "health objects fails with Garage stopped" sh -c "sleep 16; curl -s -H 'Authorization: Bearer $TOKEN' http://127.0.0.1:28480/status | jq -e '.checks[] | select(.name==\"objects\") | .status == \"fail\"'"
t "apply repairs it" /opt/cx-pgsql/setup.sh apply objects
(cd /opt/cx-pgsql && PROJECT_DIR=/opt/cx-pgsql bash -c 'source lib/core.sh; load_config; for l in tls dbconf pg backup objects; do source lib/$l.sh; done; obj_key_set alted other-files rw-') >/dev/null 2>&1
t "an extra grant shows as BROKEN" not /opt/cx-pgsql/setup.sh status objects
t "apply takes it away again" /opt/cx-pgsql/setup.sh apply objects
app alted
t "alted can't read other-files after repair" not r lsf app:other-files
echo '# edited' >>/data/apps/cx-pgsql/objects/garage.toml
t "edited garage.toml is BROKEN" not /opt/cx-pgsql/setup.sh status objects
t "apply restores it" /opt/cx-pgsql/setup.sh apply objects

echo "── the stack's re-apply leaves Garage alone"
started=$(docker inspect -f '{{.State.StartedAt}}' cx-pgsql-objects)
/opt/cx-pgsql/setup.sh apply stack --force >/tmp/stack.log 2>&1
t "Garage not restarted by stack apply --force" test "$(docker inspect -f '{{.State.StartedAt}}' cx-pgsql-objects)" = "$started"
t "data intact" r check --download /tmp/src/l app:alted-listing/l

echo "── teardown and re-apply keep the data"
/opt/cx-pgsql/setup.sh teardown objects --yes >/dev/null 2>&1
t "database stack still running after objects teardown" sh -c "docker ps --format '{{.Names}}' | grep -qx cx-pgsql-postgres"
t "re-apply" /opt/cx-pgsql/setup.sh apply objects
t "objects still there" r check --download /tmp/src/l app:alted-listing/l

echo "── disaster: purge, rebuild, restore --all"
# (restore refreshes the off-site copy itself, so nothing to run here)
/opt/cx-pgsql/setup.sh teardown objects --purge --yes >/dev/null 2>&1
t "re-apply after purge" /opt/cx-pgsql/setup.sh apply objects
t "buckets empty after purge" test "$(cx-pgsql objects list | awk '$1=="alted-uploads"{print $2}')" = 0
t "restore --all" cx-pgsql objects restore --all
t "uploads back and identical" r check --download /tmp/src/u app:alted-uploads/u
t "listing back and identical" r check --download /tmp/src/l app:alted-listing/l

echo "── idempotent"
t "status all DONE" /opt/cx-pgsql/setup.sh status
echo
echo "passed $PASS, failed $FAIL"
