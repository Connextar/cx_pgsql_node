# shellcheck shell=bash
# From the Contabo runbook (steps 8–9): nvm + Node for ADMIN_USER and a PM2 daemon shared by
# everyone in group pm2 (PM2_HOME=/etc/pm2daemon), started at boot. Off unless ENABLE_NODE_STACK.

PM2_HOME_DIR=/etc/pm2daemon
NVM_VERSION=v0.40.3

node_describe() { echo "nvm + Node ($NODE_VERSION) + shared PM2 daemon for app servers"; }
node_enabled() { is_true "$ENABLE_NODE_STACK"; }

_node_home() { getent passwd "$ADMIN_USER" | cut -d: -f6; }
_node_as_admin() { runuser -u "$ADMIN_USER" -- bash -lc "export NVM_DIR=\$HOME/.nvm; . \$NVM_DIR/nvm.sh; export PM2_HOME=$PM2_HOME_DIR; $*"; }
# The boot service must run the SHARED daemon (PM2_HOME=/etc/pm2daemon), not one in ~/.pm2.
_node_unit_ok() {
  local unit="/etc/systemd/system/pm2-$ADMIN_USER.service"
  grep -qx "Environment=PM2_HOME=$PM2_HOME_DIR" "$unit" 2>/dev/null && unit_enabled "pm2-$ADMIN_USER"
}
_node_profile() { printf '# Managed by CX_PGSQL_Node_1 setup: one PM2 daemon shared by group pm2.\nexport PM2_HOME=%s\n' "$PM2_HOME_DIR"; }

node_check() {
  chk "build tools" pkgs_installed build-essential libssl-dev
  chk "nvm for $ADMIN_USER" test -s "$(_node_home)/.nvm/nvm.sh"
  chk "node $NODE_VERSION installed" _node_as_admin "node --version"
  chk "pm2 installed" _node_as_admin "command -v pm2"
  chk "group pm2 with $ADMIN_USER" sh -c "id -nG '$ADMIN_USER' | tr ' ' '\n' | grep -qx pm2"
  chk "$PM2_HOME_DIR shared (setgid, group pm2)" sh -c "[ \"\$(stat -c %G:%a '$PM2_HOME_DIR')\" = 'pm2:2770' ]"
  chk_render "PM2_HOME for every login" /etc/profile.d/cx-pm2.sh _node_profile
  chk "pm2 starts at boot with PM2_HOME=$PM2_HOME_DIR" _node_unit_ok
  chk "pm2 daemon running under systemd" unit_active "pm2-$ADMIN_USER"
}

node_apply() {
  ensure_pkgs build-essential libssl-dev curl
  local home
  home=$(_node_home) || die "Apply the users step first."
  if [[ ! -s "$home/.nvm/nvm.sh" ]]; then
    run runuser -u "$ADMIN_USER" -- bash -c "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash"
  fi
  _node_as_admin "nvm install '$NODE_VERSION' --latest-npm && nvm alias default '$NODE_VERSION'"
  getent group pm2 >/dev/null || groupadd --system pm2
  usermod -aG pm2 "$ADMIN_USER"
  install -d -m 2770 -o "$ADMIN_USER" -g pm2 "$PM2_HOME_DIR"
  _node_profile | write_if_changed /etc/profile.d/cx-pm2.sh || true
  _node_as_admin "command -v pm2 >/dev/null || npm install -g pm2@latest"
  if ! _node_unit_ok; then
    local node_bin
    node_bin=$(_node_as_admin 'dirname "$(command -v node)"')
    # Without --hp, pm2 takes PM2_HOME from the environment (with --hp it would be <home>/.pm2).
    # From /, because it switches to ADMIN_USER, who can't enter root's working directory.
    (cd / && run env "PATH=$PATH:$node_bin" "PM2_HOME=$PM2_HOME_DIR" "$node_bin/pm2" startup systemd -u "$ADMIN_USER" >/dev/null)
    systemctl daemon-reload
  fi
  if ! unit_active "pm2-$ADMIN_USER"; then
    # Hand the daemon to systemd: stop one started by hand, then start the service.
    _node_as_admin "pm2 kill >/dev/null 2>&1 || true"
    run systemctl start "pm2-$ADMIN_USER"
  fi
  _node_as_admin "pm2 describe pm2-logrotate >/dev/null 2>&1 || { pm2 install pm2-logrotate >/dev/null && pm2 set pm2-logrotate:max_size 5M >/dev/null; }; pm2 save >/dev/null"
}

node_teardown() {
  systemctl disable --now "pm2-$ADMIN_USER" 2>/dev/null || true
  rm -f /etc/profile.d/cx-pm2.sh "/etc/systemd/system/pm2-$ADMIN_USER.service"
  systemctl daemon-reload
  ((PURGE)) && rm -rf "$PM2_HOME_DIR" "$(_node_home)/.nvm"
  return 0
}
