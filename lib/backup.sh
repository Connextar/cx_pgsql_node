# shellcheck shell=bash
# Backups, three layers:
#   physical  pgBackRest: full/differential base backups + continuous WAL archive (encrypted
#             repository) → restore the whole cluster to any moment (point in time).
#   logical   pg_dump of every database, nightly, kept grandfather-father-son, encrypted with
#             age to BACKUP_AGE_RECIPIENTS → restore or move one database on its own.
#   upload    rclone to BACKUP_REMOTE (Dropbox): the pgBackRest repository mirrored, the
#             encrypted dumps copied and pruned on their own (longer) schedule, and an
#             encrypted bundle of the server's secrets.
#   objects   rclone from the object store (Garage) to an rclone crypt remote on BACKUP_REMOTE:
#             one encrypted copy of every object, hourly; deleted ones kept for a while.
# `verify` proves all of it restores. Every job records its outcome in $BACKUP_STATUS_FILE,
# which the health endpoint reads and alerts on.

# Paths (BACKUP_STATUS_FILE, DUMPS_DIR, REPO_DIR) come from derive_config in lib/core.sh.
RCLONE_CONF=/etc/cx-pgsql/rclone.conf

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Merge into the status file: status_update '<jq filter>' [--arg k v]...  ($now is set)
status_update() {
  local filter=$1 tmp
  shift
  install -d -m 0755 "$(dirname "$BACKUP_STATUS_FILE")"
  [[ -s "$BACKUP_STATUS_FILE" ]] && jq -e . "$BACKUP_STATUS_FILE" >/dev/null 2>&1 || printf '{}\n' >"$BACKUP_STATUS_FILE"
  tmp=$(mktemp "$BACKUP_STATUS_FILE.XXXXXX")
  jq --arg now "$(now_iso)" "$@" "($filter) | .updated = \$now" "$BACKUP_STATUS_FILE" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$BACKUP_STATUS_FILE"
}

# One backup job at a time (a dump, a base backup, an upload or a verify).
backup_lock() {
  mkdir -p /run/cx-pgsql
  exec 8>/run/cx-pgsql/backup.lock
  flock -w 7200 8 || die "Another backup job has held the lock for two hours."
}

age_recipients_args() {
  local r args=()
  for r in $BACKUP_AGE_RECIPIENTS; do args+=(-r "$r"); done
  printf '%s\n' "${args[@]}"
}
encrypting() { [[ -n "${BACKUP_AGE_RECIPIENTS// /}" ]]; }

# ─── Retention ─────────────────────────────────────────────────────────────────────
# Reads names containing a YYYYmmddTHHMMZ stamp, NEWEST FIRST; prints the ones to keep:
# the newest of each of the last D days, W ISO weeks and M months.
gfs_keep() {
  local daily=$1 weekly=$2 monthly=$3 f stamp d w m keep nd=0 nw=0 nm=0
  local -A seen_d=() seen_w=() seen_m=()
  while read -r f; do
    stamp=$(grep -oE '[0-9]{8}T[0-9]{4}Z' <<<"$f") || continue
    d=${stamp:0:8}
    w=$(date -u -d "${d:0:4}-${d:4:2}-${d:6:2}" +%G-W%V)
    m=${d:0:6}
    keep=0
    if [[ -z "${seen_d[$d]:-}" ]] && ((nd < daily)); then seen_d[$d]=1 nd=$((nd + 1)) keep=1; fi
    if [[ -z "${seen_w[$w]:-}" ]] && ((nw < weekly)); then seen_w[$w]=1 nw=$((nw + 1)) keep=1; fi
    if [[ -z "${seen_m[$m]:-}" ]] && ((nm < monthly)); then seen_m[$m]=1 nm=$((nm + 1)) keep=1; fi
    if ((keep)); then printf '%s\n' "$f"; fi
  done
}

# Local: delete dumps (and their .sha256) that GFS doesn't keep, per database directory.
prune_local_dumps() {
  local dir files keep f removed=0
  for dir in "$DUMPS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    files=$(find "$dir" -maxdepth 1 -type f \( -name '*.dump' -o -name '*.dump.age' -o -name '*.sql.zst' -o -name '*.sql.zst.age' \) -printf '%f\n' | sort -r)
    keep=$(gfs_keep "$BACKUP_KEEP_DAILY" "$BACKUP_KEEP_WEEKLY" "$BACKUP_KEEP_MONTHLY" <<<"$files")
    while read -r f; do
      [[ -z "$f" ]] && continue
      grep -qxF "$f" <<<"$keep" && continue
      rm -f "$dir$f" "$dir$f.sha256"
      removed=$((removed + 1))
    done <<<"$files"
  done
  ((removed == 0)) || info "Removed $removed old dump(s) on the server."
}

# ─── Logical: pg_dump per database ─────────────────────────────────────────────────
_backup_names() { db_each sh -c 'case "$DB_BACKUP" in true|1|yes|on) printf "%s\n" "$DB_NAME";; esac'; }

# dump_one NAME STAMP → writes $DUMPS_DIR/NAME/NAME-STAMP.dump[.age] (+ .sha256), prints the file.
# Called from `if`, where bash ignores errexit: every step checks its own result.
dump_one() {
  local db=$1 stamp=$2 dir tmp final
  dir="$DUMPS_DIR/$db"
  install -d -m 0700 "$dir" || return 1
  tmp="$dir/.$db-$stamp.dump.partial"
  docker exec -u postgres "$PG_CONTAINER" pg_dump -Fc -Z zstd:3 -d "$db" >"$tmp" || return 1
  [[ -s "$tmp" ]] || return 1
  # The archive's table of contents must read back, or the dump is worthless.
  docker exec -i -u postgres "$PG_CONTAINER" pg_restore -l <"$tmp" >/dev/null || return 1
  if encrypting; then
    final="$dir/$db-$stamp.dump.age"
    # shellcheck disable=SC2046
    age $(age_recipients_args) -o "$final" "$tmp" || return 1
    rm -f "$tmp"
  else
    final="$dir/$db-$stamp.dump"
    mv "$tmp" "$final" || return 1
  fi
  chmod 0600 "$final"
  (cd "$dir" && sha256sum "$(basename "$final")" >"$(basename "$final").sha256") || return 1
  printf '%s\n' "$final"
}

dump_globals() {
  local stamp=$1 dir tmp final
  dir="$DUMPS_DIR/_globals"
  install -d -m 0700 "$dir"
  tmp="$dir/.globals-$stamp.sql.zst.partial"
  # Roles (with their password hashes) and tablespaces: needed to restore dumps elsewhere.
  docker exec -u postgres "$PG_CONTAINER" pg_dumpall --globals-only | zstd -q -3 >"$tmp" || { rm -f "$tmp"; return 1; }
  if encrypting; then
    final="$dir/globals-$stamp.sql.zst.age"
    # shellcheck disable=SC2046
    age $(age_recipients_args) -o "$final" "$tmp" || return 1
    rm -f "$tmp"
  else
    final="$dir/globals-$stamp.sql.zst"
    mv "$tmp" "$final" || return 1
  fi
  chmod 0600 "$final"
  (cd "$dir" && sha256sum "$(basename "$final")" >"$(basename "$final").sha256") || return 1
}

backup_logical() {
  local stamp db file failed=() summary='{}'
  stamp=$(date -u +%Y%m%dT%H%MZ)
  status_update '.logical.last_attempt = $now'
  pg_running || {
    status_update '.logical.last_error = "Postgres is not running"'
    die "Postgres is not running."
  }
  for db in $(_backup_names); do
    info "Dumping $db"
    if file=$(dump_one "$db" "$stamp"); then
      summary=$(jq --arg db "$db" --arg file "$(basename "$file")" --argjson bytes "$(stat -c %s "$file")" \
        --arg sha "$(cut -d' ' -f1 "$file.sha256")" \
        '.[$db] = {file: $file, bytes: $bytes, sha256: $sha, verified: true}' <<<"$summary")
      ok "$db → $(basename "$file") ($(numfmt --to=iec "$(stat -c %s "$file")"))"
    else
      failed+=("$db")
      rm -f "$DUMPS_DIR/$db/.$db-$stamp.dump.partial"
      err "Dump of $db failed"
    fi
  done
  dump_globals "$stamp" || failed+=(globals)
  prune_local_dumps
  if ((${#failed[@]})); then
    status_update '.logical.last_error = $e | .logical.databases = ($s | fromjson)' --arg e "failed: ${failed[*]}" --arg s "$summary"
    die "Dumps failed: ${failed[*]}"
  fi
  status_update '.logical.last_success = $now | .logical.last_error = null | .logical.encrypted = ($enc == "1") | .logical.databases = ($s | fromjson)' \
    --arg s "$summary" --arg enc "$(encrypting && echo 1 || echo 0)"
}

# ─── Physical: pgBackRest ──────────────────────────────────────────────────────────
pgbackrest() { docker exec -u postgres "$PG_CONTAINER" pgbackrest --stanza="$PGBACKREST_STANZA" "$@"; }

backup_physical() {
  local type=${1:-auto} info last_full age_days
  is_true "$BACKUP_PITR" || {
    info "BACKUP_PITR is off — no physical backups."
    status_update '.physical.enabled = false'
    return 0
  }
  status_update '.physical.enabled = true | .physical.last_attempt = $now'
  if [[ $type == auto ]]; then
    info=$(pgbackrest --output=json info)
    last_full=$(jq -r '[.[0].backup[]? | select(.type == "full") | .timestamp.stop] | max // 0' <<<"$info")
    age_days=$((($(date +%s) - last_full) / 86400))
    if ((last_full == 0 || age_days >= PGBACKREST_FULL_EVERY_DAYS)); then type="full"; else type="diff"; fi
  fi
  info "pgBackRest $type backup"
  if ! pgbackrest --type="$type" backup; then
    status_update '.physical.last_error = $e' --arg e "pgbackrest $type backup failed (see $STACK_LOGS_DIR/pgbackrest)"
    die "pgBackRest $type backup failed."
  fi
  info=$(pgbackrest --output=json info)
  status_update '.physical.last_success = $now | .physical.last_error = null | .physical.last_type = $t
    | .physical.last_full = ([($i | fromjson)[0].backup[]? | select(.type == "full") | .timestamp.stop] | max | if . then todate else null end)
    | .physical.backups = ([($i | fromjson)[0].backup[]?] | length)
    | .physical.repo_bytes = ($b | tonumber)' \
    --arg t "$type" --arg i "$info" --arg b "$(du -sb "$REPO_DIR" | cut -f1)"
  ok "pgBackRest $type backup done"
}

# ─── Upload: rclone to Dropbox (or any rclone remote) ──────────────────────────────
rclone_x() { rclone --config "$RCLONE_CONF" "$@"; }
remote_configured() { [[ -s "$RCLONE_CONF" ]] && rclone_x listremotes 2>/dev/null | grep_q -x "$BACKUP_REMOTE:"; }
remote_dest() { printf '%s:%s' "$BACKUP_REMOTE" "$BACKUP_REMOTE_PATH"; }
rclone_flags() {
  printf '%s\n' --transfers 4 --checkers 8 --tpslimit 12 --retries 5 --low-level-retries 10 --stats-one-line --stats 0
  [[ -n "$BACKUP_UPLOAD_BWLIMIT" ]] && printf '%s\n' --bwlimit "$BACKUP_UPLOAD_BWLIMIT"
  return 0
}

# Remote: same GFS rule, with the remote's (longer) counts.
prune_remote_dumps() {
  local dest db files keep f removed=0
  dest=$(remote_dest)/dumps
  for db in $(rclone_x lsf --dirs-only "$dest" 2>/dev/null | tr -d /); do
    files=$(rclone_x lsf --files-only "$dest/$db" | grep -vE '\.sha256$' | sort -r)
    keep=$(gfs_keep "$BACKUP_REMOTE_KEEP_DAILY" "$BACKUP_REMOTE_KEEP_WEEKLY" "$BACKUP_REMOTE_KEEP_MONTHLY" <<<"$files")
    while read -r f; do
      [[ -z "$f" ]] && continue
      grep -qxF "$f" <<<"$keep" && continue
      rclone_x deletefile "$dest/$db/$f" && rclone_x deletefile "$dest/$db/$f.sha256" 2>/dev/null || true
      removed=$((removed + 1))
    done <<<"$files"
  done
  ((removed == 0)) || info "Removed $removed old dump(s) from $(remote_dest)."
}

# The server's secrets, encrypted to the owner's age key: with this and the age private key,
# a new server can read the encrypted pgBackRest repository and keep every password.
secrets_bundle() {
  local items=("$(basename "$SECRETS_DIR")") recipients
  [[ -s "$RCLONE_CONF" ]] && items+=(rclone.conf)
  mapfile -t recipients < <(age_recipients_args)
  tar -C "$(dirname "$SECRETS_DIR")" -cf - "${items[@]}" | age "${recipients[@]}"
}

backup_upload() {
  local dest flags=() before after
  if ! is_true "$BACKUP_UPLOAD"; then
    status_update '.upload.enabled = false'
    info "BACKUP_UPLOAD is off."
    return 0
  fi
  dest=$(remote_dest)
  status_update '.upload.enabled = true | .upload.destination = $d | .upload.last_attempt = $now' --arg d "$dest"
  if ! remote_configured; then
    status_update '.upload.last_error = "rclone remote not configured (bin/remote.sh dropbox-auth)"'
    die "No rclone remote '$BACKUP_REMOTE' in $RCLONE_CONF — run bin/remote.sh dropbox-auth from your machine."
  fi
  mapfile -t flags < <(rclone_flags)
  before=$(rclone_x size --json "$dest" 2>/dev/null | jq -r '.bytes // 0' || echo 0)

  local errors=()
  if is_true "$BACKUP_PITR" && [[ -d "$REPO_DIR/backup" ]]; then
    info "Mirroring the pgBackRest repository (encrypted) to $dest/pgbackrest"
    # --skip-links: backup/<stanza>/latest is a convenience symlink pgBackRest doesn't need.
    rclone_x sync "${flags[@]}" --skip-links "$REPO_DIR" "$dest/pgbackrest" || errors+=("pgbackrest")
  fi
  if encrypting; then
    info "Copying encrypted dumps to $dest/dumps"
    rclone_x copy "${flags[@]}" --include '*.age' --include '*.age.sha256' "$DUMPS_DIR" "$dest/dumps" || errors+=("dumps")
    secrets_bundle | rclone_x rcat "$dest/secrets/secrets-$(hostname).tar.age" || errors+=("secrets")
  elif is_true "$BACKUP_UPLOAD_UNENCRYPTED_DUMPS"; then
    warn "Uploading UNENCRYPTED dumps (BACKUP_UPLOAD_UNENCRYPTED_DUMPS=true)."
    rclone_x copy "${flags[@]}" --exclude '.*' "$DUMPS_DIR" "$dest/dumps" || errors+=("dumps")
  else
    info "Dumps stay on the server: set BACKUP_AGE_RECIPIENTS to upload them encrypted."
  fi
  prune_remote_dumps || errors+=("prune")
  rclone_x copyto "$BACKUP_STATUS_FILE" "$dest/status.json" || true
  [[ -f "$PROJECT_DIR/docs/Restore.md" ]] && rclone_x copyto "$PROJECT_DIR/docs/Restore.md" "$dest/RESTORE.md" 2>/dev/null || true

  after=$(rclone_x size --json "$dest" 2>/dev/null | jq -r '.bytes // 0' || echo 0)
  if ((${#errors[@]})); then
    status_update '.upload.last_error = $e' --arg e "failed: ${errors[*]}"
    die "Upload failed: ${errors[*]}"
  fi
  status_update '.upload.last_success = $now | .upload.last_error = null | .upload.remote_bytes = ($a | tonumber) | .upload.bytes_transferred = (($a | tonumber) - ($b | tonumber) | if . < 0 then 0 else . end)' \
    --arg a "$after" --arg b "$before"
  ok "Uploaded to $dest ($(numfmt --to=iec "$after") held there)"
}

# ─── Objects: the object store's off-site copy ─────────────────────────────────────
# Sizes are measured every run (the health check's capacity warning reads them), even when there is
# nowhere to copy to. The copy is `rclone sync` into cxcrypt:live/<bucket>; whatever it would delete
# or overwrite there moves to cxcrypt:deleted/<today>/<bucket> instead, kept
# OBJECTS_BACKUP_KEEP_DELETED_DAYS days. Objects are never changed in place by the apps here, so in
# practice that folder holds deletions.
_objects_measure() {
  local b n bytes total=0 count=0 buckets='{}'
  for b in $(obj_buckets) "$OBJ_VERIFY_BUCKET"; do
    read -r n bytes < <(obj_bucket_usage "$b") || return 1
    total=$((total + bytes)) count=$((count + n))
    buckets=$(jq --arg b "$b" --argjson n "$n" --argjson s "$bytes" '.[$b] = {objects: $n, bytes: $s}' <<<"$buckets")
  done
  status_update '.objects = {measured: $now, capacity_bytes: ($c | tonumber), bytes: ($t | tonumber), objects: ($n | tonumber), buckets: ($b | fromjson)}' \
    --arg c "$(obj_capacity_bytes)" --arg t "$total" --arg n "$count" --arg b "$buckets"
  info "Object store: $count objects, $(numfmt --to=iec "$total") of $OBJECTS_CAPACITY"
}

_objects_prune_deleted() {
  local d cutoff removed=0
  cutoff=$(date -u -d "-$OBJECTS_BACKUP_KEEP_DELETED_DAYS days" +%F)
  # Nothing has been deleted yet on a new store: no deleted/ folder, which lsf calls an error.
  for d in $({ rclone_x lsf --dirs-only cxcrypt:deleted 2>/dev/null || true; } | tr -d /); do
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$d" < "$cutoff" ]] || continue
    rclone_x purge "cxcrypt:deleted/$d" && removed=$((removed + 1))
  done
  ((removed == 0)) || info "Removed $removed day(s) of deleted objects older than $OBJECTS_BACKUP_KEEP_DELETED_DAYS days from the off-site copy."
}

backup_objects() {
  if ! is_true "$ENABLE_OBJECTS"; then
    status_update '.objects_backup.enabled = false'
    info "ENABLE_OBJECTS is off."
    return 0
  fi
  obj_health_ok || {
    status_update '.objects_backup.last_attempt = $now | .objects_backup.last_error = "Garage is not healthy"'
    die "Garage is not healthy (cx-pgsql objects status)."
  }
  _objects_measure || warn "Couldn't measure the buckets."
  if ! is_true "$BACKUP_UPLOAD"; then
    status_update '.objects_backup.enabled = false'
    warn "BACKUP_UPLOAD is off: the objects have no off-site copy."
    return 0
  fi
  status_update '.objects_backup.enabled = true | .objects_backup.destination = $d | .objects_backup.last_attempt = $now' --arg d "$(remote_dest)/objects (rclone crypt)"
  if ! remote_configured; then
    status_update '.objects_backup.last_error = "rclone remote not configured (bin/remote.sh dropbox-auth)"'
    die "No rclone remote '$BACKUP_REMOTE' in $RCLONE_CONF — run bin/remote.sh dropbox-auth from your machine."
  fi
  obj_rclone_env "$OBJ_BACKUP_KEY"
  obj_crypt_env
  local flags=() b errors=() today
  mapfile -t flags < <(rclone_flags)
  today=$(date -u +%F)
  for b in $(obj_backup_buckets); do
    info "Copying bucket $b (encrypted) to $(remote_dest)/objects"
    rclone_x sync "${flags[@]}" --backup-dir "cxcrypt:deleted/$today/$b" "cxobj:$b" "cxcrypt:live/$b" || errors+=("$b")
  done
  _objects_prune_deleted || errors+=("prune")
  if ((${#errors[@]})); then
    status_update '.objects_backup.last_error = $e' --arg e "failed: ${errors[*]}"
    die "Objects copy failed: ${errors[*]}"
  fi
  status_update '.objects_backup.last_success = $now | .objects_backup.last_error = null'
  ok "Objects copied off-site to $(remote_dest)/objects"
}

# ─── Verify: prove it restores ─────────────────────────────────────────────────────
_verify_checksums() {
  local f bad=0
  while IFS= read -r -d '' f; do
    (cd "$(dirname "$f")" && sha256sum -c --quiet "$(basename "$f")") || { err "Checksum mismatch: $f"; bad=1; }
  done < <(find "$DUMPS_DIR" -name '*.sha256' -print0)
  return $bad
}

# Dump each database afresh and restore it into a scratch database: same tables come back.
_verify_logical() {
  local db scratch src_tables got_tables results='{}' bad=0
  for db in $(_backup_names); do
    scratch="cxverify_$db"
    pg_sql -d postgres <<<"DROP DATABASE IF EXISTS $scratch WITH (FORCE); CREATE DATABASE $scratch;"
    if docker exec -u postgres "$PG_CONTAINER" sh -c "pg_dump -Fc -d '$db' | pg_restore --no-owner --no-acl -d '$scratch'" 2>/tmp/cx-verify-$db.err; then
      src_tables=$(pg_value "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')" -d "$db")
      got_tables=$(pg_value "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')" -d "$scratch")
      if [[ "$src_tables" == "$got_tables" ]]; then
        ok "$db restores ($got_tables tables)"
        results=$(jq --arg db "$db" --argjson n "$got_tables" '.[$db] = {tables: $n, ok: true}' <<<"$results")
      else
        err "$db restored $got_tables of $src_tables tables"
        results=$(jq --arg db "$db" --argjson n "${got_tables:-0}" '.[$db] = {tables: $n, ok: false}' <<<"$results")
        bad=1
      fi
    else
      err "$db did not restore: $(tail -3 /tmp/cx-verify-$db.err)"
      results=$(jq --arg db "$db" '.[$db] = {ok: false}' <<<"$results")
      bad=1
    fi
    rm -f "/tmp/cx-verify-$db.err"
    pg_sql -d postgres <<<"DROP DATABASE IF EXISTS $scratch WITH (FORCE);"
  done
  VERIFY_RESULTS=$results
  return $bad
}

# Restore the newest pgBackRest backup into a throwaway container and query it.
_verify_physical() {
  is_true "$BACKUP_PITR" || return 0
  local dir name=${STACK_NAME}-verify dbs
  dir="$DATA_ROOT/verify-$(date -u +%Y%m%dT%H%M%S)"
  info "pgBackRest verify (repository checksums)"
  pgbackrest verify || return 1
  info "Restoring the newest backup into a throwaway container"
  install -d -m 0700 -o "$PG_UID" -g "$PG_GID" "$dir"
  docker rm -f "$name" >/dev/null 2>&1 || true
  _verify_cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$dir"; }
  if ! docker run --rm -u postgres --network none \
    -v "$dir:/var/lib/postgresql/data" -v "$STACK_DIR/config/pgbackrest:/etc/pgbackrest:ro" -v "$REPO_DIR:/backups/pgbackrest:ro" \
    "cx-pgsql/postgres:$PG_VERSION" pgbackrest --stanza="$PGBACKREST_STANZA" --type=immediate --target-action=promote \
    --log-path=/tmp restore; then
    _verify_cleanup
    return 1
  fi
  restored_pg_start "$name" "$dir" --network none
  restored_pg_wait "$name" || true
  dbs=$(docker exec -u postgres "$name" psql -qAtc "SELECT string_agg(datname, ' ' ORDER BY datname) FROM pg_database WHERE NOT datistemplate" 2>/dev/null || true)
  _verify_cleanup
  [[ -n "$dbs" ]] || { err "The restored cluster never came up."; return 1; }
  ok "Physical backup restores (databases: $dbs)"
}

# The objects' off-site copy, two ways. First every object older than two hours is compared with
# its encrypted copy (rclone cryptcheck: by hash, nothing downloaded) — two hours, because a newer
# one may not have had its hourly copy yet, and one way, because the copy may still hold objects
# deleted since. The list of names comes from the live side alone: an age filter given to the
# check itself would apply to the copy's timestamps too. Then a random sample per bucket is restored from the copy into the scratch
# bucket and compared byte for byte with the live objects.
_verify_objects() {
  is_true "$ENABLE_OBJECTS" && is_true "$BACKUP_UPLOAD" && remote_configured || return 0
  (
    obj_rclone_env "$OBJ_BACKUP_KEY"
    obj_crypt_env
    local b list results='{}' bad=0 failed checked sampled
    list=$(mktemp)
    for b in $(obj_backup_buckets); do
      info "Objects: checking bucket $b against its encrypted copy"
      failed=0 sampled=0
      checked=$(rclone_x lsf -R --files-only --min-age 2h "cxobj:$b" | tee "$list" | wc -l)
      if ((checked > 0)) && ! rclone_x cryptcheck --one-way --files-from "$list" "cxobj:$b" "cxcrypt:live/$b"; then
        err "Bucket $b: the off-site copy differs (cryptcheck above)"
        failed=1
      else
        shuf -n "$OBJECTS_VERIFY_SAMPLE" "$list" >"$list.sample" || true
        sampled=$(wc -l <"$list.sample")
        rclone_x delete "cxobj:$OBJ_VERIFY_BUCKET/$b" 2>/dev/null || true
        if ((sampled > 0)); then
          if ! rclone_x copy --files-from "$list.sample" "cxcrypt:live/$b" "cxobj:$OBJ_VERIFY_BUCKET/$b" ||
            ! rclone_x check --download --one-way --files-from "$list.sample" "cxobj:$b" "cxobj:$OBJ_VERIFY_BUCKET/$b"; then
            err "Bucket $b: objects restored from the off-site copy don't match"
            failed=1
          fi
          rclone_x delete "cxobj:$OBJ_VERIFY_BUCKET/$b" || true
        fi
      fi
      ((failed)) || ok "Bucket $b: $checked objects match their copy; $sampled restored and identical"
      ((failed)) && bad=1
      results=$(jq --arg b "$b" --argjson n "$checked" --argjson s "$sampled" --argjson ok "$( ((failed)) && echo false || echo true)" \
        '.[$b] = {checked: $n, restored: $s, ok: $ok}' <<<"$results")
    done
    # The deleted/ archive has nothing live to compare with, but rclone crypt authenticates every
    # block: reading a sample back in full proves those files are intact and decryptable.
    local f read=0 unreadable=0
    while read -r f; do
      [[ -n "$f" ]] || continue
      read=$((read + 1))
      rclone_x cat "cxcrypt:deleted/$f" >/dev/null 2>&1 || { err "Deleted object can't be read back: deleted/$f"; unreadable=$((unreadable + 1)); }
    done < <(rclone_x lsf -R --files-only cxcrypt:deleted 2>/dev/null | shuf -n "$OBJECTS_VERIFY_SAMPLE")
    ((unreadable)) && bad=1
    ((read == 0 || unreadable)) || ok "Deleted objects: $read read back and intact"
    results=$(jq --argjson n "$read" --argjson ok "$( ((unreadable)) && echo false || echo true)" \
      '.["deleted/"] = {read: $n, ok: $ok}' <<<"$results")
    rm -f "$list" "$list.sample"
    printf '%s\n' "$results" >"/run/cx-pgsql/verify-objects.json"
    exit $bad
  )
}

backup_verify() {
  local errors=()
  status_update '.verify.last_attempt = $now'
  _verify_checksums || errors+=("checksums")
  _verify_logical || errors+=("logical")
  if is_true "$BACKUP_VERIFY_PITR"; then _verify_physical || errors+=("physical"); fi
  rm -f /run/cx-pgsql/verify-objects.json
  _verify_objects || errors+=("objects")
  local results=${VERIFY_RESULTS:-} objects='null'
  [[ -n "$results" ]] || results='{}'
  [[ -s /run/cx-pgsql/verify-objects.json ]] && objects=$(cat /run/cx-pgsql/verify-objects.json)
  if ((${#errors[@]})); then
    status_update '.verify.last_error = $e | .verify.databases = ($r | fromjson) | .verify.objects = ($o | fromjson)' \
      --arg e "failed: ${errors[*]}" --arg r "$results" --arg o "$objects"
    die "Verify failed: ${errors[*]}"
  fi
  status_update '.verify.last_success = $now | .verify.last_error = null | .verify.databases = ($r | fromjson) | .verify.objects = ($o | fromjson)' \
    --arg r "$results" --arg o "$objects"
}
