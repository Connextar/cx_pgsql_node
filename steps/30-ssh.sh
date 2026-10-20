# shellcheck shell=bash
# SSH on its own port, keys only, no root, only members of SSH_ALLOW_GROUPS.
# Applied with an automatic undo (ROLLBACK_SECONDS) unless confirmed from a new connection.

SSH_DROPIN=/etc/ssh/sshd_config.d/00-cx-hardening.conf
SSH_SOCKET_DROPIN=/etc/systemd/system/ssh.socket.d/00-cx-port.conf

ssh_describe() { echo "sshd on port $SSH_PORT: keys only, no root login, AllowGroups $SSH_ALLOW_GROUPS"; }

_ssh_conf() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/30-ssh.sh). Changes here are overwritten.
# Named 00-… so it is read first: for sshd the first value of a keyword wins.
Port $SSH_PORT
PermitRootLogin $SSH_PERMIT_ROOT_LOGIN
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowGroups $SSH_ALLOW_GROUPS
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
# Local forwarding stays on for SSH tunnels to the loopback-only database port.
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
}
_ssh_socket_conf() { printf '[Socket]\nListenStream=\nListenStream=%s\n' "$SSH_PORT"; }
_ssh_socket_activated() { systemctl is-enabled --quiet ssh.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; }
_ssh_effective() { sshd -T 2>/dev/null | grep_q -ix "$1"; }
_ssh_listening() { ss -Hltn "sport = :$SSH_PORT" | grep_q LISTEN; }
# `Port` lines add up rather than override, so any other one (in sshd_config or another
# drop-in) would keep that port open as well.
_ssh_only_port() { [[ "$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ')" == "$SSH_PORT " ]]; }
_ssh_stray_port_files() { grep -lE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -vxF "$SSH_DROPIN" || true; }

ssh_check() {
  chk "openssh-server installed" pkg_installed openssh-server
  chk_render "$SSH_DROPIN" "$SSH_DROPIN" _ssh_conf
  chk "sshd_config reads sshd_config.d/" grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config
  _ssh_socket_activated && chk_render "ssh.socket listens on $SSH_PORT" "$SSH_SOCKET_DROPIN" _ssh_socket_conf
  chk "effective: port $SSH_PORT only" _ssh_only_port
  chk "effective: password authentication off" _ssh_effective "passwordauthentication no"
  chk "effective: root login $SSH_PERMIT_ROOT_LOGIN" _ssh_effective "permitrootlogin $SSH_PERMIT_ROOT_LOGIN"
  chk "listening on $SSH_PORT" _ssh_listening
}

ssh_apply() {
  ensure_pkgs openssh-server
  # Never take away the way in: someone who can log in afterwards must exist.
  local home
  home=$(getent passwd "$ADMIN_USER" | cut -d: -f6) || die "Apply the users step first: $ADMIN_USER doesn't exist."
  [[ -s "$home/.ssh/authorized_keys" ]] || die "$ADMIN_USER has no authorized_keys — refusing to disable password and root login."
  local g ok_group=0
  for g in $SSH_ALLOW_GROUPS; do id -nG "$ADMIN_USER" | tr ' ' '\n' | grep_q -x "$g" && ok_group=1; done
  ((ok_group)) || die "$ADMIN_USER is in none of SSH_ALLOW_GROUPS ($SSH_ALLOW_GROUPS) — it couldn't log in."
  grep -qE '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config ||
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

  local changed=0 stray
  stray=$(_ssh_stray_port_files)
  [[ -n "$stray" ]] && changed=1
  if ! _ssh_conf | same_content "$SSH_DROPIN" ||
    { _ssh_socket_activated && ! _ssh_socket_conf | same_content "$SSH_SOCKET_DROPIN"; }; then
    changed=1
  fi

  if ((changed)); then
    # shellcheck disable=SC2086 # one path per line
    rollback_save ssh "$SSH_DROPIN" "$SSH_SOCKET_DROPIN" $stray
    local f
    for f in $stray; do
      sed -i -E 's/^([[:space:]]*Port[[:space:]])/# disabled by CX_PGSQL_Node_1 setup: \1/' "$f"
      info "Commented out the Port line in $f"
    done
    _ssh_conf | write_if_changed "$SSH_DROPIN" 0644 || true
    if ! sshd -t; then
      rm -f "$SSH_DROPIN"
      [[ -f "$ROLLBACK_DIR/ssh/files$SSH_DROPIN" ]] && cp -a "$ROLLBACK_DIR/ssh/files$SSH_DROPIN" "$SSH_DROPIN"
      die "The new sshd configuration does not validate; the previous one is back."
    fi
    rollback_schedule ssh
    if _ssh_socket_activated; then
      _ssh_socket_conf | write_if_changed "$SSH_SOCKET_DROPIN" || true
      systemctl daemon-reload
      run systemctl restart ssh.socket
    fi
    run systemctl reload ssh 2>/dev/null || run systemctl restart ssh
    # Established sessions survive a reload; new ones must use the new port from here on.
    info "sshd now listens on $SSH_PORT. Keep this session open until you've confirmed from a new one."
  fi
  systemctl enable ssh >/dev/null 2>&1 || true
}

ssh_teardown() {
  rollback_save ssh "$SSH_DROPIN" "$SSH_SOCKET_DROPIN"
  rm -f "$SSH_DROPIN" "$SSH_SOCKET_DROPIN"
  systemctl daemon-reload
  sshd -t || die "sshd configuration without our drop-in does not validate."
  rollback_schedule ssh
  _ssh_socket_activated && systemctl restart ssh.socket
  systemctl reload ssh || systemctl restart ssh
  warn "sshd is back on its distribution defaults (port 22 unless configured elsewhere)."
}
