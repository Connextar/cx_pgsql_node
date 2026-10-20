#!/usr/bin/env bash
# Undo an unconfirmed SSH or firewall change. Run by a transient systemd timer that
# `rollback_schedule` (lib/core.sh) starts before the change; `setup.sh confirm` stops it.
# It restores the files saved before the change and reloads the service, so a change that
# locked us out reverts itself.
set -uo pipefail

name=${1:?usage: rollback.sh ssh|firewall}
dir=/var/lib/cx-pgsql/rollback/$name
log() { printf '%s rollback(%s): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$name" "$*" | tee -a /var/log/cx-pgsql-setup.log; }

[[ -d "$dir" ]] || {
  log "nothing saved — nothing to undo"
  exit 0
}

# Put back every saved file; delete the ones that didn't exist before.
if [[ -d "$dir/files" ]]; then
  (cd "$dir/files" && find . -type f -print0) | while IFS= read -r -d '' f; do
    target=${f#.}
    mkdir -p "$(dirname "$target")"
    cp -a "$dir/files$target" "$target"
    log "restored $target"
  done
fi
if [[ -f "$dir/absent" ]]; then
  while read -r f; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f" && log "removed $f"
  done <"$dir/absent"
fi

case $name in
  ssh)
    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket; then
      systemctl restart ssh.socket
    fi
    if sshd -t; then
      systemctl reload ssh || systemctl restart ssh
      log "sshd reloaded with the previous configuration"
    else
      log "previous sshd configuration does not validate; sshd left running as is"
    fi
    ;;
  firewall)
    systemctl daemon-reload
    # Dropping our table reopens the box; Docker's own tables are untouched.
    nft delete table inet cx_firewall 2>/dev/null && log "removed table inet cx_firewall"
    if [[ -f /etc/nftables.conf ]] && ! grep -q 'flush ruleset' /etc/nftables.conf; then
      nft -f /etc/nftables.conf && log "reloaded the previous /etc/nftables.conf"
    fi
    ;;
esac

rm -rf "$dir"
sed -i "/^$name\$/d" /run/cx-pgsql/rollback-pending 2>/dev/null || true
log "done"
