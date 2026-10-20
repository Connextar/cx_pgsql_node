# shellcheck shell=bash
# Restores. Nothing here overwrites live data without --yes, and an in-place restore keeps
# the data directory it replaces until you delete it.

# Bring backups down from the remote (a new server after a disaster, or an older copy).
restore_fetch() {
  local what=${1:-all} dest flags=()
  remote_configured || die "No rclone remote '$BACKUP_REMOTE' — run bin/remote.sh dropbox-auth first."
  dest=$(remote_dest)
  mapfile -t flags < <(rclone_flags)
  if [[ $what == all || $what == repo ]]; then
    install -d -m 0750 -o "$PG_UID" -g "$PG_GID" "$REPO_DIR"
    info "Fetching the pgBackRest repository from $dest/pgbackrest"
    rclone_x sync "${flags[@]}" "$dest/pgbackrest" "$REPO_DIR"
    chown -R "$PG_UID:$PG_GID" "$REPO_DIR"
  fi
  if [[ $what == all || $what == dumps ]]; then
    install -d -m 0700 "$DUMPS_DIR"
    info "Fetching dumps from $dest/dumps"
    rclone_x copy "${flags[@]}" "$dest/dumps" "$DUMPS_DIR"
  fi
  ok "Fetched. Next: cx-pgsql restore in-place (whole cluster) or cx-pgsql restore dump (one database)."
}

# The newest dump file for a database.
latest_dump() { find "$DUMPS_DIR/$1" -maxdepth 1 -type f \( -name '*.dump' -o -name '*.dump.age' \) -printf '%f\n' 2>/dev/null | sort -r | head -1; }

# restore dump DB [FILE|latest] [--into NAME] [--replace --yes] [--identity AGE_KEY_FILE] [--no-owner]
restore_dump() {
  local db=${1:?database name} file=${2:-latest} into="" replace=0 identity="" no_owner=0
  shift 2 || shift $#
  while (($#)); do
    case $1 in
      --into) into=$2; shift ;;
      --replace) replace=1 ;;
      --identity) identity=$2; shift ;;
      --no-owner) no_owner=1 ;;
      --yes) YES=1 ;;
      *) die "Unknown option $1" ;;
    esac
    shift
  done
  [[ $file == latest ]] && file=$(latest_dump "$db")
  [[ -n "$file" ]] || die "No dump of $db in $DUMPS_DIR/$db."
  [[ "$file" == */* ]] || file="$DUMPS_DIR/$db/$file"
  [[ -f "$file" ]] || die "No such file: $file"
  if [[ -f "$file.sha256" ]]; then
    (cd "$(dirname "$file")" && sha256sum -c --quiet "$(basename "$file").sha256") || die "Checksum mismatch: $file"
  fi

  local plain=$file tmp=""
  if [[ $file == *.age ]]; then
    [[ -n "$identity" && -f "$identity" ]] || die "$file is encrypted: pass --identity <your age private key file> (copy it up for this, then delete it)."
    tmp=$(mktemp /root/cx-restore.XXXXXX)
    age -d -i "$identity" -o "$tmp" "$file" || { rm -f "$tmp"; die "Could not decrypt $file with that key."; }
    plain=$tmp
  fi

  local target
  if ((replace)); then
    target=$db
    ((${YES:-0})) || die "--replace drops and recreates $db from the dump: add --yes to confirm."
  else
    target=${into:-${db}_restored_$(date -u +%Y%m%d%H%M)}
  fi
  pg_db_exists "$target" && ((replace == 0)) && die "Database $target already exists."
  local owner
  owner=$(pg_value "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'" || true)
  [[ -n "$owner" ]] || owner=postgres

  info "Restoring $(basename "$file") into $target (owner $owner)"
  if ((replace)); then
    pg_sql -d postgres <<<"DROP DATABASE IF EXISTS $target WITH (FORCE);"
  fi
  pg_sql -d postgres <<<"CREATE DATABASE $target OWNER $owner;"
  local args=(--exit-on-error -d "$target")
  ((no_owner)) && args+=(--no-owner --role="$owner")
  if ! docker exec -i -u postgres "$PG_CONTAINER" pg_restore "${args[@]}" <"$plain"; then
    [[ -n "$tmp" ]] && rm -f "$tmp"
    die "pg_restore failed; $target is incomplete (drop it with: cx-pgsql db drop $target --yes)."
  fi
  [[ -n "$tmp" ]] && rm -f "$tmp"
  ok "Restored into $target."
  ((replace)) || info "When it looks right: rename with ALTER DATABASE, or copy what you need out of it."
}

# Run pgBackRest restore into an empty directory, in a one-off container of our image.
_pgbr_restore_into() { # DIR [pgbackrest restore options...]
  local dir=$1
  shift
  install -d -m 0700 -o "$PG_UID" -g "$PG_GID" "$dir"
  docker run --rm -u postgres --network none \
    -v "$dir:/var/lib/postgresql/data" \
    -v "$STACK_DIR/config/pgbackrest:/etc/pgbackrest:ro" \
    -v "$REPO_DIR:/backups/pgbackrest" \
    "cx-pgsql/postgres:$PG_VERSION" \
    pgbackrest --stanza="$PGBACKREST_STANZA" --log-path=/tmp "$@" restore
}

# Start a container on a restored data directory with the live cluster's own configuration:
# recovery refuses to start when max_connections and its siblings are lower than the original
# server's, and the data directory only carries initdb's defaults. No archiving, no log files,
# a small buffer pool. restored_pg_start NAME DIR [docker run options…]
restored_pg_start() {
  local name=$1 dir=$2
  shift 2
  docker run -d --name "$name" -u postgres "$@" \
    -v "$dir:/var/lib/postgresql/data" \
    -v "$STACK_DIR/config/postgres/postgresql.conf:/etc/postgresql/postgresql.conf:ro" \
    -v "$STACK_DIR/config/postgres/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro" \
    -v "$STACK_DIR/config/postgres/conf.d:/etc/postgresql/conf.d:ro" \
    -v "$STACK_CERTS_DIR:/etc/cx-certs:ro" \
    -v "$STACK_DIR/config/pgbackrest:/etc/pgbackrest:ro" \
    -v "$REPO_DIR:/backups/pgbackrest:ro" \
    "cx-pgsql/postgres:$PG_VERSION" postgres \
    -c config_file=/etc/postgresql/postgresql.conf -c hba_file=/etc/postgresql/pg_hba.conf \
    -c archive_mode=off -c logging_collector=off -c shared_buffers=128MB >/dev/null
}

# Wait until a restored copy has finished recovery and accepts queries.
restored_pg_wait() {
  local name=$1 _
  for _ in $(seq 1 150); do
    [[ "$(docker exec -u postgres "$name" psql -qAtc 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" == t ]] && return 0
    docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep_q true || break
    sleep 2
  done
  docker logs --tail 15 "$name" >&2 2>&1 || true
  return 1
}

_pitr_target_args() {
  if [[ -n "${1:-}" ]]; then
    printf '%s\n' --type=time "--target=$1" --target-action=promote
  else
    # No time: replay everything archived (the latest moment there is).
    printf '%s\n' --target-action=promote
  fi
}

# A copy of the cluster at a moment, on 127.0.0.1:PORT, to look at or copy data out of.
# restore pitr [--time "2026-10-20 09:30:00+00"] [--port 28439]
restore_pitr() {
  local time="" port=28439 dir targs=()
  while (($#)); do
    case $1 in
      --time) time=$2; shift ;;
      --port) port=$2; shift ;;
      *) die "Unknown option $1" ;;
    esac
    shift
  done
  docker inspect "$PITR_CONTAINER" >/dev/null 2>&1 && die "$PITR_CONTAINER exists — run cx-pgsql restore cleanup first."
  dir="$DATA_ROOT/pitr-$(date -u +%Y%m%dT%H%M%S)"
  mapfile -t targs < <(_pitr_target_args "$time")
  info "Restoring ${time:-the latest moment} into $dir"
  _pgbr_restore_into "$dir" "${targs[@]}" || die "pgBackRest restore failed."
  restored_pg_start "$PITR_CONTAINER" "$dir" -p "127.0.0.1:$port:5432" --label cx-pgsql.pitr-dir="$dir"
  restored_pg_wait "$PITR_CONTAINER" || die "The restored copy didn't come up (log above). Clean up with: cx-pgsql restore cleanup"
  ok "Point-in-time copy running: docker exec -it -u postgres $PITR_CONTAINER psql"
  info "Or from your machine: bin/remote.sh tunnel $port, then connect to localhost:$port with an app login (sslmode=require)"
  info "Remove it with: cx-pgsql restore cleanup"
}

restore_cleanup() {
  local dir
  dir=$(docker inspect -f '{{index .Config.Labels "cx-pgsql.pitr-dir"}}' "$PITR_CONTAINER" 2>/dev/null || true)
  docker rm -f "$PITR_CONTAINER" >/dev/null 2>&1 && ok "Removed $PITR_CONTAINER"
  [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir" && ok "Removed $dir"
  find "$DATA_ROOT" -maxdepth 1 -name 'verify-*' -type d -exec rm -rf {} + 2>/dev/null || true
  return 0
}

# Replace the live cluster with a restore (disaster recovery, or undoing a bad change).
# restore in-place [--time "…"] --yes
restore_in_place() {
  local time="" stamp old targs=()
  while (($#)); do
    case $1 in
      --time) time=$2; shift ;;
      --yes) YES=1 ;;
      *) die "Unknown option $1" ;;
    esac
    shift
  done
  ((${YES:-0})) || die "This replaces the live database cluster with ${time:-the latest restorable moment}. Add --yes to go ahead."
  [[ -d "$REPO_DIR/backup/$PGBACKREST_STANZA" ]] || die "No pgBackRest repository in $REPO_DIR (cx-pgsql restore fetch brings it down)."
  stamp=$(date -u +%Y%m%dT%H%M%S)
  old="$PG_DATA_DIR.before-$stamp"
  info "Stopping the stack"
  (cd "$STACK_DIR" && docker compose stop)
  mv "$PG_DATA_DIR" "$old"
  mapfile -t targs < <(_pitr_target_args "$time")
  info "Restoring ${time:-the latest moment} into $PG_DATA_DIR"
  if ! _pgbr_restore_into "$PG_DATA_DIR" "${targs[@]}"; then
    rm -rf "$PG_DATA_DIR"
    mv "$old" "$PG_DATA_DIR"
    (cd "$STACK_DIR" && docker compose up -d --wait)
    die "Restore failed; the previous data is back in place and running."
  fi
  info "Starting the stack (recovery replays WAL first)"
  (cd "$STACK_DIR" && docker compose up -d --wait --wait-timeout 900)
  local _
  for _ in $(seq 1 300); do
    [[ "$(pg_value 'SELECT NOT pg_is_in_recovery()' 2>/dev/null)" == t ]] && break
    sleep 2
  done
  ok "Restored. The data it replaced is in $old — delete it once you're satisfied."
  info "Taking a full backup on the new timeline"
  backup_physical full || warn "Full backup failed — run: cx-pgsql backup physical full"
}
