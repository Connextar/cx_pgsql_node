# shellcheck shell=bash
# The admin user, groups, SSH keys, sudo, git identity and the shared app directories.

users_describe() { echo "Admin user ($ADMIN_USER), groups, SSH keys, sudo, git, /data/apps"; }

_users_keys_source() {
  local f="$PROJECT_DIR/$AUTHORIZED_KEYS_FILE"
  [[ "$AUTHORIZED_KEYS_FILE" == /* ]] && f=$AUTHORIZED_KEYS_FILE
  printf '%s' "$f"
}
# The public keys ADMIN_USER should accept: the configured file, or (first run only) root's.
_users_wanted_keys() {
  local src
  src=$(_users_keys_source)
  if [[ -s "$src" ]]; then
    grep -E '^(ssh-|ecdsa-|sk-)' "$src" || true
  elif [[ -s /root/.ssh/authorized_keys ]]; then
    grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true
  fi
}
_users_home() { getent passwd "$ADMIN_USER" | cut -d: -f6; }
_users_keys_ok() {
  local home key
  home=$(_users_home) || return 1
  [[ -s "$home/.ssh/authorized_keys" ]] || return 1
  [[ "$(stat -c %a "$home/.ssh")" == 700 && "$(stat -c %a "$home/.ssh/authorized_keys")" == 600 ]] || return 1
  [[ "$(stat -c %U "$home/.ssh/authorized_keys")" == "$ADMIN_USER" ]] || return 1
  while read -r key; do
    [[ -z "$key" ]] && continue
    grep -qxF "$key" "$home/.ssh/authorized_keys" || return 1
  done < <(_users_wanted_keys)
}
_users_in_groups() {
  local g have
  have=" $(id -nG "$ADMIN_USER" 2>/dev/null) "
  for g in $ADMIN_GROUPS; do [[ "$have" == *" $g "* ]] || return 1; done
}
_users_sudoers() {
  if is_true "$ADMIN_SUDO_NOPASSWD"; then
    printf '# Managed by CX_PGSQL_Node_1 setup.\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN_USER"
  else
    printf '# Managed by CX_PGSQL_Node_1 setup.\n%s ALL=(ALL:ALL) ALL\n' "$ADMIN_USER"
  fi
}
_users_password_set() { [[ "$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')" == P ]]; }
_users_acl_ok() { getfacl -p "$1" 2>/dev/null | grep_q '^default:group:apps:rwx'; }

users_check() {
  local g
  for g in apps ssh-users docker; do chk "group $g" getent group "$g"; done
  chk "user $ADMIN_USER" id "$ADMIN_USER"
  chk "$ADMIN_USER in: $ADMIN_GROUPS" _users_in_groups
  chk "$ADMIN_USER authorized_keys (from $AUTHORIZED_KEYS_FILE)" _users_keys_ok
  chk_render "sudo rule for $ADMIN_USER" /etc/sudoers.d/90-cx-admin _users_sudoers
  is_true "$ADMIN_SUDO_NOPASSWD" || chk "$ADMIN_USER has a sudo password" _users_password_set
  chk "git identity ($GIT_USER_NAME)" test "$(git config --system user.name 2>/dev/null)" = "$GIT_USER_NAME"
  chk "/data/apps shared with group apps" _users_acl_ok /data/apps
  chk "/logs shared with group apps" _users_acl_ok /logs
  is_true "$ADMIN_DEPLOY_KEY" && chk "$ADMIN_USER deploy key" test -s "$(_users_home)/.ssh/id_ed25519.pub"
}

users_apply() {
  local g home keys
  for g in apps ssh-users docker; do getent group "$g" >/dev/null || run groupadd --system "$g"; done

  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    run useradd --create-home --shell /bin/bash "$ADMIN_USER"
  fi
  for g in $ADMIN_GROUPS; do
    getent group "$g" >/dev/null || run groupadd --system "$g"
    id -nG "$ADMIN_USER" | tr ' ' '\n' | grep_q -x "$g" || run usermod -aG "$g" "$ADMIN_USER"
  done

  keys=$(_users_wanted_keys)
  if [[ -z "$keys" ]]; then
    die "No SSH public keys: put yours in $AUTHORIZED_KEYS_FILE. Without one, SSH hardening would lock everyone out."
  fi
  [[ -s "$(_users_keys_source)" ]] || warn "$AUTHORIZED_KEYS_FILE is empty — copied root's keys for $ADMIN_USER instead."
  home=$(_users_home)
  install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  while read -r key; do
    [[ -z "$key" ]] && continue
    grep -qxF "$key" "$home/.ssh/authorized_keys" || printf '%s\n' "$key" >>"$home/.ssh/authorized_keys"
  done <<<"$keys"
  chmod 600 "$home/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh/authorized_keys"

  local tmp
  tmp=$(mktemp)
  _users_sudoers >"$tmp"
  visudo -cqf "$tmp" || die "Generated sudoers rule does not validate."
  rm -f "$tmp"
  _users_sudoers | write_if_changed /etc/sudoers.d/90-cx-admin 0440 || true
  if ! is_true "$ADMIN_SUDO_NOPASSWD" && ! _users_password_set; then
    printf '%s:%s\n' "$ADMIN_USER" "$(secret admin-password 24)" | chpasswd
    warn "$ADMIN_USER's sudo password is in $(secret_path admin-password) (root only)."
  fi

  git config --system user.name "$GIT_USER_NAME"
  git config --system user.email "$GIT_USER_EMAIL"

  # From the runbook: shared app and log directories the apps group can write.
  install -d -m 2775 -o "$ADMIN_USER" -g apps /data/apps
  install -d -m 0755 /logs
  for d in /data/apps /logs; do
    setfacl -R -m g:apps:rwX "$d"
    setfacl -dR -m g:apps:rwX "$d"
  done

  if is_true "$ADMIN_DEPLOY_KEY" && [[ ! -s "$home/.ssh/id_ed25519.pub" ]]; then
    run runuser -u "$ADMIN_USER" -- ssh-keygen -q -t ed25519 -N '' -C "$ADMIN_USER@$SERVER_HOSTNAME" -f "$home/.ssh/id_ed25519"
    info "Deploy key for GitHub/Bitbucket: $(cat "$home/.ssh/id_ed25519.pub")"
  fi
}

users_teardown() {
  rm -f /etc/sudoers.d/90-cx-admin
  if ((PURGE)); then
    warn "Removing user $ADMIN_USER and its home directory."
    userdel -r "$ADMIN_USER" 2>/dev/null || true
  else
    info "User $ADMIN_USER kept (its sudo rule is removed). Use --purge to delete the user."
  fi
}
