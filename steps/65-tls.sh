# shellcheck shell=bash
# Let's Encrypt certificates for SERVER_FQDN (and N8N_FQDN), renewed by certbot's timer.
# Until DNS points at this server the self-signed placeholder stays in use: that is a
# warning, not a failure, so the rest of the setup can go ahead.

TLS_HOOK=/etc/letsencrypt/renewal-hooks/deploy/cx-pgsql.sh

tls_describe() { echo "Let's Encrypt for $SERVER_FQDN (webroot), deploy hook → nginx, Postgres, PgBouncer"; }

_tls_public_ip() {
  if [[ -n "${SERVER_IP:-}" ]]; then
    printf '%s' "$SERVER_IP"
  else
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p'
  fi
}
_tls_dns_ok() {
  local ip
  ip=$(_tls_public_ip)
  [[ -n "$ip" ]] && dig +short A "$1" @1.1.1.1 2>/dev/null | grep_q -xF "$ip"
}
_tls_hook() {
  printf '#!/bin/sh\n# Managed by CX_PGSQL_Node_1 setup.\nexec %s/lib/tls-deploy-hook.sh "$@"\n' "$INSTALL_DIR"
}
_tls_le_installed() {
  local fqdn=$1 dir
  dir=$(tls_dir_for "$fqdn")
  tls_has_le "$fqdn" && ! tls_is_self_signed "$fqdn" && cmp -s "$(tls_le_live "$fqdn")/fullchain.pem" "$dir/fullchain.pem"
}
_tls_days_ok() {
  local d
  d=$(tls_days_left "$1") && ((d > 14))
}

tls_check() {
  local fqdn
  chk "certbot installed" pkg_installed certbot
  chk_render "deploy hook $TLS_HOOK" "$TLS_HOOK" _tls_hook
  chk "certbot renewal timer enabled" unit_enabled certbot.timer
  for fqdn in $(tls_domains); do
    chk "certificate files for $fqdn" test -s "$(tls_dir_for "$fqdn")/privkey.pem"
    if _tls_dns_ok "$fqdn"; then
      chk_note "DNS: $fqdn → $(_tls_public_ip)"
    else
      chk_note "DNS: $fqdn does not point at $(_tls_public_ip) yet"
    fi
    chk_soft "Let's Encrypt certificate in use for $fqdn" _tls_le_installed "$fqdn"
    chk_soft "$fqdn valid for more than 14 days ($(tls_days_left "$fqdn" 2>/dev/null || echo '?') left)" _tls_days_ok "$fqdn"
  done
  [[ -d "$STACK_DIR" ]] && chk "Postgres/PgBouncer hold the current certificate" tls_stack_in_sync
}

tls_apply() {
  ensure_pkgs certbot
  _tls_hook | write_if_changed "$TLS_HOOK" 0755 || true
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  local fqdn
  for fqdn in $(tls_domains); do
    tls_ensure_placeholder "$fqdn"
    if tls_has_le "$fqdn"; then continue; fi
    if ! _tls_dns_ok "$fqdn"; then
      warn "$fqdn doesn't resolve to $(_tls_public_ip) yet — keeping the self-signed certificate. Point its A record here and re-run."
      continue
    fi
    info "Requesting a Let's Encrypt certificate for $fqdn"
    run certbot certonly --webroot -w "$WEBROOT" -d "$fqdn" --email "$ADMIN_EMAIL" \
      --agree-tos --no-eff-email --non-interactive --keep-until-expiring ||
      warn "certbot failed for $fqdn — the self-signed certificate stays in use."
  done
  # Covers the first issue (certbot runs the hook too) and repairs any copy that drifted.
  if tls_sync; then tls_reload_services; fi
}

tls_teardown() {
  rm -f "$TLS_HOOK"
  if ((PURGE)); then
    local fqdn
    for fqdn in $(tls_domains); do
      certbot delete --non-interactive --cert-name "$fqdn" 2>/dev/null || true
      rm -rf "$(tls_dir_for "$fqdn")"
    done
  fi
}
