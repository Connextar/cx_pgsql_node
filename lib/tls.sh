# shellcheck shell=bash
# Certificates. Everything that serves TLS reads one stable place per name,
#   /etc/cx-pgsql/tls/<fqdn>/{fullchain,privkey}.pem   (nginx)
#   $STACK_CERTS_DIR/server.{crt,key}                  (Postgres, PgBouncer; uid 999)
# filled first with a self-signed placeholder and then, once DNS points here, with the
# Let's Encrypt certificate (certbot's deploy hook copies each renewal in).

tls_domains() {
  printf '%s\n' "$SERVER_FQDN"
  is_true "$ENABLE_N8N" && printf '%s\n' "$N8N_FQDN"
  is_true "$ENABLE_OBJECTS" && printf '%s\n' "$OBJECTS_FQDN"
  return 0
}

tls_dir_for() { printf '/etc/cx-pgsql/tls/%s' "$1"; }

# A self-signed certificate so nginx and Postgres can start before Let's Encrypt has issued one.
tls_ensure_placeholder() {
  local fqdn=$1 dir
  dir=$(tls_dir_for "$fqdn")
  [[ -s "$dir/fullchain.pem" && -s "$dir/privkey.pem" ]] && return 0
  install -d -m 0755 "$dir"
  (umask 077 && openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=$fqdn" \
    -addext "subjectAltName=DNS:$fqdn" -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" 2>/dev/null)
  chmod 0644 "$dir/fullchain.pem"
  touch "$dir/.self-signed"
  info "Self-signed placeholder certificate for $fqdn (replaced once Let's Encrypt issues one)."
}

tls_is_self_signed() { [[ -e "$(tls_dir_for "$1")/.self-signed" ]]; }
tls_le_live() { printf '/etc/letsencrypt/live/%s' "$1"; }
tls_has_le() { [[ -s "$(tls_le_live "$1")/fullchain.pem" ]]; }

# Days until the installed certificate for <fqdn> expires (negative when expired).
tls_days_left() {
  local end
  end=$(openssl x509 -enddate -noout -in "$(tls_dir_for "$1")/fullchain.pem" 2>/dev/null | cut -d= -f2) || return 1
  echo $((($(date -d "$end" +%s) - $(date +%s)) / 86400))
}

# Copy Let's Encrypt's current files into the stable places. Prints what changed;
# returns 0 when anything changed.
tls_sync() {
  local fqdn dir live changed=1
  for fqdn in $(tls_domains); do
    dir=$(tls_dir_for "$fqdn")
    live=$(tls_le_live "$fqdn")
    tls_has_le "$fqdn" || continue
    install -d -m 0755 "$dir"
    if ! cmp -s "$live/fullchain.pem" "$dir/fullchain.pem" || ! cmp -s "$live/privkey.pem" "$dir/privkey.pem"; then
      install -m 0644 "$live/fullchain.pem" "$dir/fullchain.pem"
      install -m 0600 "$live/privkey.pem" "$dir/privkey.pem"
      rm -f "$dir/.self-signed"
      info "Installed the Let's Encrypt certificate for $fqdn"
      changed=0
    fi
  done
  tls_sync_stack && changed=0
  return $changed
}

# The database name's certificate, owned by the postgres uid inside the containers.
tls_sync_stack() {
  local dir changed=1
  dir=$(tls_dir_for "$SERVER_FQDN")
  [[ -d "$STACK_DIR" && -s "$dir/fullchain.pem" ]] || return 1
  install -d -m 0755 "$STACK_CERTS_DIR"
  if ! cmp -s "$dir/fullchain.pem" "$STACK_CERTS_DIR/server.crt" || ! cmp -s "$dir/privkey.pem" "$STACK_CERTS_DIR/server.key"; then
    install -m 0644 -o "$PG_UID" -g "$PG_GID" "$dir/fullchain.pem" "$STACK_CERTS_DIR/server.crt"
    install -m 0600 -o "$PG_UID" -g "$PG_GID" "$dir/privkey.pem" "$STACK_CERTS_DIR/server.key"
    changed=0
  fi
  return $changed
}

tls_stack_in_sync() {
  local dir
  dir=$(tls_dir_for "$SERVER_FQDN")
  cmp -s "$dir/fullchain.pem" "$STACK_CERTS_DIR/server.crt" && cmp -s "$dir/privkey.pem" "$STACK_CERTS_DIR/server.key"
}

# Tell everything holding the certificate to read it again.
tls_reload_services() {
  systemctl is-active --quiet nginx && nginx -t -q 2>/dev/null && systemctl reload nginx
  if docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep_q true; then
    docker exec -u postgres "$PG_CONTAINER" psql -qAtc 'SELECT pg_reload_conf()' >/dev/null && info "Postgres re-read its certificate"
  fi
  if docker inspect -f '{{.State.Running}}' "$PGBOUNCER_CONTAINER" 2>/dev/null | grep_q true; then
    pgbouncer_reload >/dev/null && info "PgBouncer re-read its certificate"
  fi
  return 0
}
