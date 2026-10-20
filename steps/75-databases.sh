# shellcheck shell=bash
# One database and one owner login per file in config/databases/ (plus n8n's when enabled).
# Databases are never dropped here: one removed from config shows as "not in config" in
# `cx-pgsql db list`, and `cx-pgsql db drop` deletes it deliberately.

databases_describe() { echo "Databases and logins from config/databases/*.env ($(db_names | tr '\n' ' '))"; }

_dbs_sql() {
  local ext stmt_timeout=""
  [[ -n "$DB_STATEMENT_TIMEOUT" ]] && stmt_timeout="ALTER ROLE $DB_USER SET statement_timeout = '$DB_STATEMENT_TIMEOUT';"
  cat <<EOF
SELECT 'CREATE ROLE $DB_USER LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') \gexec
ALTER ROLE $DB_USER NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT $DB_CONNECTION_LIMIT;
$stmt_timeout
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING ''UTF8'' TEMPLATE template0' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME') \gexec
ALTER DATABASE $DB_NAME OWNER TO $DB_USER;
REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE $DB_NAME TO $DB_USER;
GRANT CONNECT ON DATABASE $DB_NAME TO cx_monitor;
EOF
  if [[ -n "$DB_READONLY_USER" ]]; then
    cat <<EOF
SELECT 'CREATE ROLE $DB_READONLY_USER LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_READONLY_USER') \gexec
GRANT CONNECT ON DATABASE $DB_NAME TO $DB_READONLY_USER;
EOF
  fi
  # Inside the database: the owner owns the public schema; extensions are created by the superuser.
  printf '\\connect %s\n' "$DB_NAME"
  printf 'ALTER SCHEMA public OWNER TO %s;\n' "$DB_USER"
  for ext in $DB_EXTENSIONS; do printf 'CREATE EXTENSION IF NOT EXISTS "%s";\n' "$ext"; done
  if [[ -n "$DB_READONLY_USER" ]]; then
    cat <<EOF
GRANT USAGE ON SCHEMA public TO $DB_READONLY_USER;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO $DB_READONLY_USER;
ALTER DEFAULT PRIVILEGES FOR ROLE $DB_USER IN SCHEMA public GRANT SELECT ON TABLES TO $DB_READONLY_USER;
EOF
  fi
}

_dbs_owner_ok() { [[ "$(pg_value "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$DB_NAME'")" == "$DB_USER" ]]; }
_dbs_public_revoked() {
  [[ "$(pg_value "SELECT has_database_privilege('public', '$DB_NAME', 'CONNECT')")" == f ]]
}
_dbs_extensions_ok() {
  local ext
  for ext in $DB_EXTENSIONS; do
    [[ "$(pg_value "SELECT 1 FROM pg_extension WHERE extname = '$ext'" -d "$DB_NAME")" == 1 ]] || return 1
  done
}
# Through PgBouncer with TLS, as an application would; n8n connects to Postgres directly.
_dbs_login_ok() {
  if is_true "$DB_PGBOUNCER"; then
    pg_login_ok "$DB_USER" "$DB_NAME" "$DB_SECRET" 127.0.0.1 "$PGBOUNCER_PUBLIC_PORT" require
  else
    pg_login_ok "$DB_USER" "$DB_NAME" "$DB_SECRET" 127.0.0.1 "$PG_DIRECT_PORT" require
  fi
}

_dbs_check_one() {
  check_begin
  chk "role $DB_USER" pg_role_exists "$DB_USER"
  chk "database $DB_NAME" pg_db_exists "$DB_NAME"
  chk "$DB_NAME owned by $DB_USER" _dbs_owner_ok
  chk "$DB_NAME closed to other roles" _dbs_public_revoked
  [[ -n "$DB_EXTENSIONS" ]] && chk "$DB_NAME extensions: $DB_EXTENSIONS" _dbs_extensions_ok
  chk "$DB_USER logs in to $DB_NAME$(is_true "$DB_PGBOUNCER" && printf ' through PgBouncer (TLS)')" _dbs_login_ok
  [[ -n "$DB_READONLY_USER" ]] && chk "read-only $DB_READONLY_USER logs in" pg_login_ok "$DB_READONLY_USER" "$DB_NAME" "db-$DB_READONLY_USER-password" 127.0.0.1 "$PG_DIRECT_PORT" require
  # Hand the results back to the parent shell (this runs in db_each's subshell).
  printf '%s\t%s\t' "$CHECK_PASS" "$CHECK_FAIL"
  printf '%s\x1f' "${CHECK_LINES[@]}"
  printf '\n'
}

databases_check() {
  if ! pg_running; then
    chk "Postgres is running (stack step)" false
    return 0
  fi
  local pass fail lines
  while IFS=$'\t' read -r pass fail lines; do
    CHECK_PASS=$((CHECK_PASS + pass))
    CHECK_FAIL=$((CHECK_FAIL + fail))
    local IFS=$'\x1f' l
    for l in $lines; do [[ -n "$l" ]] && CHECK_LINES+=("$l"); done
  done < <(db_each _dbs_check_one)
  ((CHECK_PASS + CHECK_FAIL > 0)) || chk_note "no databases configured (add config/databases/<name>.env)"
  return 0
}

_dbs_apply_one() {
  info "Database $DB_NAME (owner $DB_USER)"
  secret "$DB_SECRET" >/dev/null
  _dbs_sql | pg_sql -d postgres
  pg_login_ok "$DB_USER" "$DB_NAME" "$DB_SECRET" 127.0.0.1 "$PG_DIRECT_PORT" require || pg_set_password "$DB_USER" "$DB_SECRET"
  if [[ -n "$DB_READONLY_USER" ]]; then
    secret "db-$DB_READONLY_USER-password" >/dev/null
    pg_login_ok "$DB_READONLY_USER" "$DB_NAME" "db-$DB_READONLY_USER-password" 127.0.0.1 "$PG_DIRECT_PORT" require ||
      pg_set_password "$DB_READONLY_USER" "db-$DB_READONLY_USER-password"
  fi
}

databases_apply() {
  pg_running || die "Postgres isn't running — apply the stack step first."
  db_each _dbs_apply_one
  # PgBouncer re-reads its database list (the stack step wrote it) and forgets cached auth.
  docker kill -s HUP "$PGBOUNCER_CONTAINER" >/dev/null 2>&1 || true
  sleep 1
}

databases_teardown() {
  if ((PURGE)) && pg_running; then
    local name
    for name in $(db_names); do
      warn "Dropping database $name"
      pg_sql -d postgres <<<"DROP DATABASE IF EXISTS $name WITH (FORCE);"
    done
  else
    info "Databases kept (--purge drops every configured database)."
  fi
}
