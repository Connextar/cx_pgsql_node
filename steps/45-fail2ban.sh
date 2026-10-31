# shellcheck shell=bash
# fail2ban: bans repeated SSH, Postgres and PgBouncer authentication failures.
# Bans go into the firewall's own sets (banned_v4/banned_v6), which are checked before
# Docker's NAT, so they also cover the published database port.

F2B_DIR=/etc/fail2ban

fail2ban_describe() { echo "fail2ban: sshd, postgres and pgbouncer jails banning into nftables"; }

_f2b_action() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup. Adds/removes the address in the firewall's ban set;
# the set lives in table inet cx_firewall (steps/40-firewall.sh).
[Definition]
actionstart =
actionstop =
actioncheck = nft list set inet cx_firewall <set> >/dev/null
actionban = nft add element inet cx_firewall <set> { <ip> timeout <bantime>s }
actionunban = nft delete element inet cx_firewall <set> { <ip> }

[Init]
set = banned_v4

[Init?family=inet6]
set = banned_v6
EOF
}

# log_line_prefix in stack/postgres/postgresql.conf.tmpl is '%m [%p] %r %q%u@%d ':
# "2026-10-20 10:00:00.123 UTC [123] 203.0.113.5(53422) alted@alted FATAL:  …"
_f2b_filter_postgres() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup.
[Definition]
# fail2ban finds and cuts out the timestamp itself, so the expression isn't anchored on it.
failregex = ^.*\[\d+\] <HOST>\(\d+\) \S* *FATAL:  (?:password authentication failed for user|no pg_hba\.conf entry for host|role "[^"]*" does not exist|database "[^"]*" does not exist)
ignoreregex =
EOF
}

# PgBouncer: "… WARNING C-0x…: alted/alted@203.0.113.5:53422 pooler error: password authentication failed"
_f2b_filter_pgbouncer() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup.
[Definition]
failregex = ^.* C-0x[0-9a-f]+: \S*@<HOST>:\d+ (?:pooler error: (?:password authentication failed|SASL authentication failed|no such user|SSL required)|closing because: (?:password authentication failed|SASL authentication failed|no such user|SSL required))
ignoreregex =
EOF
}

# nginx's access log for the object store: 203.0.113.5 - - [31/Oct/2026:12:00:00 +0000] "GET /b/k HTTP/1.1" 403 …
_f2b_filter_objects() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup.
[Definition]
failregex = ^<HOST> \S+ \S+ \[[^\]]*\] "[^"]*" 403\s
ignoreregex =
EOF
}
# Off by default (OBJECTS_FAIL2BAN): see config/server.env.sample for why.
_f2b_objects_jail() { is_true "$ENABLE_OBJECTS" && is_true "$OBJECTS_FAIL2BAN"; }

# Debian 12's fail2ban.conf doesn't declare allowipv6, so every run warns about it.
_f2b_server() { printf '# Managed by CX_PGSQL_Node_1 setup.\n[Definition]\nallowipv6 = auto\n'; }

_f2b_jails() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/45-fail2ban.sh).
[DEFAULT]
banaction = cx-nft-set
banaction_allports = cx-nft-set
bantime = $F2B_BANTIME
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = $F2B_MAXRETRY
ignoreip = 127.0.0.1/8 ::1 $DOCKER_SUBNET $F2B_IGNORE_IPS

[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
mode = aggressive

[cx-postgres]
enabled = true
filter = cx-postgres
port = $PG_DIRECT_PORT
backend = polling
# Postgres and PgBouncer write UTC whatever the server's time zone.
logtimezone = UTC
logpath = $STACK_LOGS_DIR/postgres/postgresql-*.log

[cx-pgbouncer]
enabled = true
filter = cx-pgbouncer
port = $PGBOUNCER_PUBLIC_PORT
backend = polling
logtimezone = UTC
logpath = $STACK_LOGS_DIR/pgbouncer/pgbouncer.log
EOF
  if _f2b_objects_jail; then
    cat <<EOF

[cx-objects]
enabled = true
filter = cx-objects
port = https
backend = polling
maxretry = $OBJECTS_F2B_MAXRETRY
logpath = /var/log/nginx/cx-objects.access.log
EOF
  fi
  return 0
}

# fail2ban refuses to start a jail whose log file doesn't exist yet.
_f2b_log_files() {
  local d
  install -d -m 0750 -o "$PG_UID" -g "$PG_GID" "$STACK_LOGS_DIR/postgres" "$STACK_LOGS_DIR/pgbouncer"
  for d in Mon Tue Wed Thu Fri Sat Sun; do
    [[ -e "$STACK_LOGS_DIR/postgres/postgresql-$d.log" ]] || install -m 0640 -o "$PG_UID" -g "$PG_GID" /dev/null "$STACK_LOGS_DIR/postgres/postgresql-$d.log"
  done
  [[ -e "$STACK_LOGS_DIR/pgbouncer/pgbouncer.log" ]] || install -m 0640 -o "$PG_UID" -g "$PG_GID" /dev/null "$STACK_LOGS_DIR/pgbouncer/pgbouncer.log"
  if _f2b_objects_jail && [[ ! -e /var/log/nginx/cx-objects.access.log ]]; then
    install -d -m 0755 /var/log/nginx
    install -m 0640 /dev/null /var/log/nginx/cx-objects.access.log
  fi
  return 0
}

_f2b_jail_running() { fail2ban-client status "$1" >/dev/null 2>&1; }

fail2ban_check() {
  chk "fail2ban installed" pkgs_installed fail2ban python3-systemd
  chk_render "action cx-nft-set" "$F2B_DIR/action.d/cx-nft-set.conf" _f2b_action
  chk_render "filter cx-postgres" "$F2B_DIR/filter.d/cx-postgres.conf" _f2b_filter_postgres
  chk_render "filter cx-pgbouncer" "$F2B_DIR/filter.d/cx-pgbouncer.conf" _f2b_filter_pgbouncer
  chk_render "jails" "$F2B_DIR/jail.d/cx.local" _f2b_jails
  chk_render "server settings" "$F2B_DIR/fail2ban.d/cx.local" _f2b_server
  chk "fail2ban running" unit_active fail2ban
  chk "jail sshd" _f2b_jail_running sshd
  chk "jail cx-postgres" _f2b_jail_running cx-postgres
  chk "jail cx-pgbouncer" _f2b_jail_running cx-pgbouncer
  if _f2b_objects_jail; then
    chk_render "filter cx-objects" "$F2B_DIR/filter.d/cx-objects.conf" _f2b_filter_objects
    chk "jail cx-objects" _f2b_jail_running cx-objects
  fi
  return 0
}

fail2ban_apply() {
  ensure_pkgs fail2ban python3-systemd
  _fw_loaded || warn "The firewall table isn't loaded yet: bans will fail until the firewall step runs."
  _f2b_log_files
  local changed=0
  _f2b_action | write_if_changed "$F2B_DIR/action.d/cx-nft-set.conf" && changed=1
  _f2b_filter_postgres | write_if_changed "$F2B_DIR/filter.d/cx-postgres.conf" && changed=1
  _f2b_filter_pgbouncer | write_if_changed "$F2B_DIR/filter.d/cx-pgbouncer.conf" && changed=1
  if _f2b_objects_jail; then
    _f2b_filter_objects | write_if_changed "$F2B_DIR/filter.d/cx-objects.conf" && changed=1
  fi
  _f2b_jails | write_if_changed "$F2B_DIR/jail.d/cx.local" && changed=1
  _f2b_server | write_if_changed "$F2B_DIR/fail2ban.d/cx.local" && changed=1
  # Debian's own defaults enable sshd with a log file that doesn't exist on journald-only systems.
  if [[ -f "$F2B_DIR/jail.d/defaults-debian.conf" ]]; then
    mv "$F2B_DIR/jail.d/defaults-debian.conf" "$F2B_DIR/jail.d/defaults-debian.conf.disabled"
    changed=1
  fi
  run fail2ban-client -t >/dev/null || die "fail2ban configuration test failed (see above)."
  systemctl enable fail2ban >/dev/null 2>&1
  if ! unit_active fail2ban; then
    run systemctl restart fail2ban
  elif ((changed)); then
    run fail2ban-client reload >/dev/null
  fi
  # The server needs a moment to start its jails.
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    _f2b_jail_running cx-pgbouncer && break
    sleep 1
  done
}

fail2ban_teardown() {
  rm -f "$F2B_DIR/jail.d/cx.local" "$F2B_DIR/fail2ban.d/cx.local" "$F2B_DIR/action.d/cx-nft-set.conf" \
    "$F2B_DIR/filter.d/cx-postgres.conf" "$F2B_DIR/filter.d/cx-pgbouncer.conf" "$F2B_DIR/filter.d/cx-objects.conf"
  [[ -f "$F2B_DIR/jail.d/defaults-debian.conf.disabled" ]] &&
    mv "$F2B_DIR/jail.d/defaults-debian.conf.disabled" "$F2B_DIR/jail.d/defaults-debian.conf"
  systemctl restart fail2ban 2>/dev/null || true
}
