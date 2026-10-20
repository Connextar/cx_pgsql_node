# shellcheck shell=bash
# Talking to the cluster. SQL runs inside the Postgres container as the `postgres` OS user
# over the local socket (peer auth: no password). Passwords never appear on a command line:
# logins are tested with the host's psql and PGPASSWORD in the child's environment only.

pg_running() { [[ "$(docker inspect -f '{{.State.Health.Status}}' "$PG_CONTAINER" 2>/dev/null)" == healthy ]]; }

# psql as superuser over the socket. SQL from stdin; extra args go to psql (e.g. -d dbname).
pg_sql() { docker exec -i -u postgres "$PG_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# One value (first column of the first row): pg_value "SELECT …" [-d db]
pg_value() {
  local sql=$1
  shift
  docker exec -u postgres "$PG_CONTAINER" psql -X -qAt -v ON_ERROR_STOP=1 "$@" -c "$sql"
}

# A session that leaves no copy of what it runs in logs or pg_stat_statements (for passwords).
pg_quiet_preamble() {
  cat <<'EOF'
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET pg_stat_statements.track_utility = off;
EOF
}

# Can USER log in to DB with the password in secret SECRET, through host:port?
# pg_login_ok USER DB SECRET HOST PORT [SSLMODE]
pg_login_ok() {
  local user=$1 db=$2 secret_name=$3 host=$4 port=$5 sslmode=${6:-prefer} pw
  pw=$(cat "$(secret_path "$secret_name")" 2>/dev/null) || return 1
  PGPASSWORD=$pw PGCONNECT_TIMEOUT=5 psql -X -qAt \
    "host=$host port=$port dbname=$db user=$user sslmode=$sslmode" -c 'SELECT 1' 2>/dev/null | grep_q -x 1
}

# Set a role's password from its secret, without logging it.
pg_set_password() {
  local role=$1 secret_name=$2 pw
  pw=$(secret "$secret_name")
  { pg_quiet_preamble; printf "ALTER ROLE %s WITH LOGIN PASSWORD '%s';\n" "$role" "$pw"; } | pg_sql -d postgres
}

pg_role_exists() { [[ "$(pg_value "SELECT 1 FROM pg_roles WHERE rolname = '$1'")" == 1 ]]; }
pg_db_exists() { [[ "$(pg_value "SELECT 1 FROM pg_database WHERE datname = '$1'")" == 1 ]]; }
