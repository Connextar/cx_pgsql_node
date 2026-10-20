# shellcheck shell=bash
# Base system: packages, hostname, time zone, locale, security updates, swap, kernel settings.

BASE_PKGS=(sudo curl ca-certificates gnupg acl git sysstat htop vim less jq unattended-upgrades
  apt-listchanges gettext-base openssl rsync cron logrotate locales bind9-dnsutils net-tools zstd lsof tzdata)

base_describe() { echo "Packages, hostname, time zone, locale, security updates, swap, sysctl"; }

_base_hosts_line() { printf '127.0.1.1\t%s %s\n' "$SERVER_FQDN" "$SERVER_HOSTNAME"; }

_base_sysctl() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup (steps/10-base.sh).
# Keep the database's pages in RAM; swap only under real pressure.
vm.swappiness = 10
# Serverless clients open and drop many connections.
net.core.somaxconn = 4096
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
# Hardening.
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
EOF
}

_base_auto_upgrades() {
  if is_true "$AUTO_SECURITY_UPDATES"; then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n'
  else
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n'
  fi
}

_base_unattended_local() {
  cat <<'EOF'
// Managed by CX_PGSQL_Node_1 setup. Debian's own 50unattended-upgrades picks the origins
// (security updates); this only says what happens afterwards.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
}

_base_journald() { printf '[Journal]\nSystemMaxUse=%s\n' "$JOURNAL_MAX_USE"; }

_base_cloud_init() {
  printf '# Managed by CX_PGSQL_Node_1 setup: keep the hostname and /etc/hosts we set.\npreserve_hostname: true\nmanage_etc_hosts: false\n'
}

_base_swap_ok() {
  ((SWAP_SIZE_MB == 0)) && return 0
  local size
  size=$(swapon --show=NAME,SIZE --bytes --noheadings 2>/dev/null | awk '$1=="/swapfile"{print $2}')
  [[ -n "$size" ]] && ((size >= (SWAP_SIZE_MB - 1) * 1024 * 1024)) && grep -q '^/swapfile ' /etc/fstab
}

# zoneinfo/UTC is itself a link (to Etc/UTC), so compare where both ends lead.
_base_tz_ok() { [[ "$(readlink -f /etc/localtime)" == "$(readlink -f "/usr/share/zoneinfo/$TIMEZONE")" ]]; }

# Debian 12 gates collection on ENABLED= in /etc/default/sysstat; Debian 13 runs it from timers.
_base_sysstat_ok() {
  unit_enabled sysstat || return 1
  [[ ! -f /etc/default/sysstat ]] || grep -q '^ENABLED="true"' /etc/default/sysstat
}

_base_locale_ok() {
  local want=${LOCALE%%.*}
  locale -a 2>/dev/null | grep_q -i "^${want}\.utf-\?8$" && grep -q "^LANG=$LOCALE" /etc/default/locale
}

base_check() {
  chk "packages: ${BASE_PKGS[*]}" pkgs_installed "${BASE_PKGS[@]}"
  chk "hostname is $SERVER_HOSTNAME" test "$(hostname)" = "$SERVER_HOSTNAME"
  chk "/etc/hosts names $SERVER_FQDN" grep -qxF "$(_base_hosts_line)" /etc/hosts
  [[ -d /etc/cloud ]] && chk_render "cloud-init keeps the hostname" /etc/cloud/cloud.cfg.d/99-cx-hostname.cfg _base_cloud_init
  chk "time zone is $TIMEZONE" _base_tz_ok
  chk "locale $LOCALE" _base_locale_ok
  chk "sysstat collecting" _base_sysstat_ok
  chk_render "unattended-upgrades schedule" /etc/apt/apt.conf.d/20auto-upgrades _base_auto_upgrades
  chk_render "unattended-upgrades never reboots" /etc/apt/apt.conf.d/52cx-unattended-upgrades _base_unattended_local
  chk_render "sysctl settings" /etc/sysctl.d/90-cx.conf _base_sysctl
  chk "swappiness applied" test "$(cat /proc/sys/vm/swappiness)" = 10
  chk_render "journal capped at $JOURNAL_MAX_USE" /etc/systemd/journald.conf.d/90-cx.conf _base_journald
  if ((SWAP_SIZE_MB > 0)); then chk "swap file of ${SWAP_SIZE_MB} MB" _base_swap_ok; fi
}

base_apply() {
  ensure_pkgs "${BASE_PKGS[@]}"

  if [[ "$(hostname)" != "$SERVER_HOSTNAME" ]]; then
    run hostnamectl set-hostname "$SERVER_HOSTNAME" 2>/dev/null || {
      printf '%s\n' "$SERVER_HOSTNAME" >/etc/hostname
      hostname "$SERVER_HOSTNAME"
    }
  fi
  if ! grep -qxF "$(_base_hosts_line)" /etc/hosts; then
    # Replace any existing 127.0.1.1 line (cloud images put the provider's name there).
    # Rewritten in place, not renamed: /etc/hosts is a bind mount in containers.
    local hosts
    hosts=$(grep -v '^127\.0\.1\.1[[:space:]]' /etc/hosts; _base_hosts_line)
    printf '%s\n' "$hosts" >/etc/hosts
  fi
  [[ -d /etc/cloud ]] && _base_cloud_init | write_if_changed /etc/cloud/cloud.cfg.d/99-cx-hostname.cfg || true

  if ! _base_tz_ok; then
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown time zone $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sfn "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    printf '%s\n' "$TIMEZONE" >/etc/timezone
  fi

  if ! _base_locale_ok; then
    sed -i "s/^# *\($LOCALE .*\)/\1/" /etc/locale.gen
    grep -q "^$LOCALE " /etc/locale.gen || printf '%s UTF-8\n' "$LOCALE" >>/etc/locale.gen
    run locale-gen >/dev/null
    run update-locale "LANG=$LOCALE"
  fi

  [[ -f /etc/default/sysstat ]] && sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
  systemctl enable --now sysstat >/dev/null 2>&1 || true

  _base_auto_upgrades | write_if_changed /etc/apt/apt.conf.d/20auto-upgrades || true
  _base_unattended_local | write_if_changed /etc/apt/apt.conf.d/52cx-unattended-upgrades || true

  _base_sysctl | write_if_changed /etc/sysctl.d/90-cx.conf || true
  run sysctl -q --load=/etc/sysctl.d/90-cx.conf || warn "Some kernel settings could not be applied here (a container?)."

  if _base_journald | write_if_changed /etc/systemd/journald.conf.d/90-cx.conf; then
    systemctl restart systemd-journald || true
  fi

  if ((SWAP_SIZE_MB > 0)) && ! _base_swap_ok; then
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    info "Creating a ${SWAP_SIZE_MB} MB swap file"
    run fallocate -l "${SWAP_SIZE_MB}M" /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
    chmod 600 /swapfile
    run mkswap /swapfile >/dev/null
    grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    run swapon /swapfile || warn "swapon failed (swap is not supported in some containers)."
  fi
}

base_teardown() {
  rm -f /etc/sysctl.d/90-cx.conf /etc/systemd/journald.conf.d/90-cx.conf \
    /etc/apt/apt.conf.d/52cx-unattended-upgrades /etc/cloud/cloud.cfg.d/99-cx-hostname.cfg
  if ((PURGE)) && grep -q '^/swapfile ' /etc/fstab; then
    swapoff /swapfile 2>/dev/null || true
    sed -i '\#^/swapfile #d' /etc/fstab
    rm -f /swapfile
  fi
  info "Packages, hostname, time zone and locale are left as they are."
}
