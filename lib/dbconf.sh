# shellcheck shell=bash
# The databases this server hosts: one file per database in config/databases/<name>.env
# (see config/databases/example.env.sample), plus n8n's own when ENABLE_N8N is on.
#
# db_each CALLBACK [ARGS...] runs CALLBACK once per database, in a subshell, with these set:
#   DB_NAME, DB_USER, DB_SECRET (name of its password secret), DB_EXTENSIONS,
#   DB_POOL_SIZE, DB_SESSION_POOL_SIZE, DB_CONNECTION_LIMIT, DB_STATEMENT_TIMEOUT,
#   DB_PGBOUNCER (true = reachable through PgBouncer), DB_BACKUP (true = in nightly dumps),
#   DB_READONLY_USER (optional read-only login), DB_FILE (the file it came from)

_db_defaults() {
  DB_NAME='' DB_USER='' DB_SECRET='' DB_EXTENSIONS='' DB_READONLY_USER=''
  DB_POOL_SIZE=$PGBOUNCER_DEFAULT_POOL_SIZE DB_SESSION_POOL_SIZE=5
  DB_CONNECTION_LIMIT=-1 DB_STATEMENT_TIMEOUT='' DB_PGBOUNCER=true DB_BACKUP=true
}

_db_finalize() {
  DB_FILE=$1
  [[ -n "$DB_NAME" ]] || DB_NAME=$(basename "$DB_FILE" .env)
  [[ -n "$DB_USER" ]] || DB_USER=$DB_NAME
  [[ -n "$DB_SECRET" ]] || DB_SECRET="db-$DB_USER-password"
  local n
  for n in "$DB_NAME" "$DB_USER" ${DB_READONLY_USER:+"$DB_READONLY_USER"}; do
    [[ "$n" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "$DB_FILE: '$n' must be lowercase letters, digits and underscores."
  done
  case $DB_NAME in postgres | template0 | template1 | pgbouncer) die "$DB_FILE: '$DB_NAME' is reserved." ;; esac
  case $DB_USER in postgres | cx_monitor | pgbouncer_auth) die "$DB_FILE: user '$DB_USER' is reserved." ;; esac
  export DB_NAME DB_USER DB_SECRET DB_EXTENSIONS DB_READONLY_USER DB_POOL_SIZE DB_SESSION_POOL_SIZE \
    DB_CONNECTION_LIMIT DB_STATEMENT_TIMEOUT DB_PGBOUNCER DB_BACKUP DB_FILE
}

db_each() {
  local f
  for f in "$PROJECT_DIR"/config/databases/*.env; do
    [[ -e "$f" ]] || continue
    (
      _db_defaults
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
      _db_finalize "$f"
      "$@"
    ) || return 1
  done
  if is_true "$ENABLE_N8N"; then
    (
      _db_defaults
      DB_NAME=n8n DB_USER=n8n DB_SECRET=n8n-db-password DB_PGBOUNCER=false
      _db_finalize n8n
      "$@"
    ) || return 1
  fi
}

db_names() { db_each sh -c 'printf "%s\n" "$DB_NAME"'; }
