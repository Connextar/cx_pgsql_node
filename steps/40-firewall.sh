# shellcheck shell=bash
# nftables: drop everything inbound except SSH (its new port), HTTP/S and the database port.
#
# Docker publishes container ports with DNAT, so that traffic never passes the INPUT hook:
# the published database port is therefore filtered in a prerouting chain that runs before
# Docker's NAT (banned addresses, optional allow-list). Only our own table is ever loaded or
# removed — never `flush ruleset`, which would wipe Docker's rules too.

FW_MAIN=/etc/nftables.conf
FW_FILE=/etc/nftables.d/10-cx-firewall.nft
FW_UNIT_DROPIN=/etc/systemd/system/nftables.service.d/10-cx.conf

firewall_describe() { echo "nftables: inbound SSH $SSH_PORT, 80, 443, PgBouncer $PGBOUNCER_PUBLIC_PORT; Docker-safe"; }

# Host ports that are published to the world (filtered before Docker's DNAT).
_fw_public_db_ports() {
  local ports=()
  [[ "$PGBOUNCER_BIND" != 127.0.0.1 ]] && ports+=("$PGBOUNCER_PUBLIC_PORT")
  [[ "$PG_DIRECT_BIND" != 127.0.0.1 ]] && ports+=("$PG_DIRECT_PORT")
  printf '%s' "${ports[*]}" | tr ' ' ','
}

_fw_main() {
  cat <<'EOF'
#!/usr/sbin/nft -f
# Managed by CX_PGSQL_Node_1 setup. Deliberately no "flush ruleset": Docker keeps its own
# tables, and every file below manages only its own table.
include "/etc/nftables.d/*.nft"
EOF
}

# The table carries a hash of its own rules as a comment, so the live ruleset can be checked
# against the file without parsing nft's output (fail2ban's ban entries come and go).
_fw_rules() {
  local body hash
  body=$(_fw_rules_body)
  hash=$(printf '%s\n' "$body" | sha256sum | cut -c1-16)
  printf '%s\n' "$body" | sed "s|^table inet cx_firewall {\$|table inet cx_firewall {\n\tcomment \"cx-rules $hash\"|"
}
_fw_rules_hash() { _fw_rules_body | sha256sum | cut -c1-16; }

_fw_rules_body() {
  local db_ports extra
  db_ports=$(_fw_public_db_ports)
  extra=$(printf '%s' "$FIREWALL_EXTRA_TCP_PORTS" | xargs | tr ' ' ',')
  cat <<EOF
#!/usr/sbin/nft -f
# Managed by CX_PGSQL_Node_1 setup (steps/40-firewall.sh). Changes here are overwritten.
# Create-then-delete makes reloading this file replace the table without touching others.
table inet cx_firewall
delete table inet cx_firewall

table inet cx_firewall {
	# Filled by fail2ban (action cx-nft-set), with a timeout per entry.
	set banned_v4 { type ipv4_addr; flags timeout; }
	set banned_v6 { type ipv6_addr; flags timeout; }
EOF
  if [[ -n "$PG_ALLOWED_CIDRS_V4" ]]; then
    printf '\tset db_allowed_v4 { type ipv4_addr; flags interval; elements = { %s } }\n' "$(printf '%s' "$PG_ALLOWED_CIDRS_V4" | xargs | tr ' ' ',')"
  fi
  if [[ -n "$PG_ALLOWED_CIDRS_V6" ]]; then
    printf '\tset db_allowed_v6 { type ipv6_addr; flags interval; elements = { %s } }\n' "$(printf '%s' "$PG_ALLOWED_CIDRS_V6" | xargs | tr ' ' ',')"
  fi
  cat <<EOF

	# Before Docker's DNAT (priority -100): applies to published container ports too.
	chain prerouting {
		type filter hook prerouting priority -150; policy accept;
		ip saddr @banned_v4 drop
		ip6 saddr @banned_v6 drop
EOF
  if [[ -n "$db_ports" ]]; then
    if [[ -n "$PG_ALLOWED_CIDRS_V4" ]]; then
      printf '\t\tmeta nfproto ipv4 tcp dport { %s } ip saddr != @db_allowed_v4 drop\n' "$db_ports"
    fi
    if [[ -n "$PG_ALLOWED_CIDRS_V6" ]]; then
      printf '\t\tmeta nfproto ipv6 tcp dport { %s } ip6 saddr != @db_allowed_v6 drop\n' "$db_ports"
    elif [[ -n "$PG_ALLOWED_CIDRS_V4" ]]; then
      # An IPv4 allow-list with no IPv6 one means: no IPv6 at all on the database ports.
      printf '\t\tmeta nfproto ipv6 tcp dport { %s } drop\n' "$db_ports"
    fi
  fi
  cat <<EOF
	}

	chain input {
		type filter hook input priority 0; policy drop;
		ct state invalid drop
		ct state { established, related } accept
		iif lo accept
		ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } limit rate 20/second accept
		ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
		tcp dport $SSH_PORT ct state new accept
		tcp dport { 80, 443 } accept
EOF
  [[ -n "$extra" ]] && printf '\t\ttcp dport { %s } accept\n' "$extra"
  cat <<EOF
		limit rate 5/minute log prefix "[nftables] drop: " level info
	}
}
EOF
}

_fw_unit_dropin() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup: stopping nftables removes only our table, not Docker's.
[Service]
ExecStop=
ExecStop=-/usr/sbin/nft delete table inet cx_firewall
EOF
}

_fw_loaded() { nft list table inet cx_firewall >/dev/null 2>&1; }
_fw_live_matches() { nft list table inet cx_firewall 2>/dev/null | grep_q -F "comment \"cx-rules $(_fw_rules_hash)\""; }

firewall_check() {
  chk "nftables installed" pkg_installed nftables
  chk_render "$FW_MAIN includes /etc/nftables.d (no flush ruleset)" "$FW_MAIN" _fw_main
  chk_render "$FW_FILE" "$FW_FILE" _fw_rules
  chk_render "stopping nftables leaves Docker's rules alone" "$FW_UNIT_DROPIN" _fw_unit_dropin
  chk "nftables enabled at boot" unit_enabled nftables
  chk "table inet cx_firewall loaded and current" _fw_live_matches
}

firewall_apply() {
  ensure_pkgs nftables
  if ! ss -Hltn "sport = :$SSH_PORT" | grep_q LISTEN && ((FORCE == 0)); then
    die "sshd isn't listening on $SSH_PORT — apply the ssh step first (or --force)."
  fi
  local tmp
  tmp=$(mktemp)
  _fw_rules >"$tmp"
  nft -c -f "$tmp" || die "Generated nftables rules don't parse (see above)."
  rm -f "$tmp"

  if ! _fw_main | same_content "$FW_MAIN" || ! _fw_rules | same_content "$FW_FILE" || ! _fw_live_matches; then
    rollback_save firewall "$FW_MAIN" "$FW_FILE" "$FW_UNIT_DROPIN"
    _fw_main | write_if_changed "$FW_MAIN" 0755 || true
    _fw_rules | write_if_changed "$FW_FILE" 0644 || true
    _fw_unit_dropin | write_if_changed "$FW_UNIT_DROPIN" || true
    systemctl daemon-reload
    rollback_schedule firewall
    # Re-adding bans that fail2ban holds: they live in the table we are about to replace.
    run nft -f "$FW_FILE"
    systemctl is-active --quiet fail2ban && fail2ban-client reload >/dev/null 2>&1 || true
  else
    _fw_unit_dropin | write_if_changed "$FW_UNIT_DROPIN" && systemctl daemon-reload || true
  fi
  systemctl enable nftables >/dev/null 2>&1
}

firewall_teardown() {
  rollback_save firewall "$FW_MAIN" "$FW_FILE" "$FW_UNIT_DROPIN"
  rm -f "$FW_FILE" "$FW_UNIT_DROPIN"
  systemctl daemon-reload
  nft delete table inet cx_firewall 2>/dev/null || true
  warn "Firewall table removed: the server accepts all inbound traffic now."
}
