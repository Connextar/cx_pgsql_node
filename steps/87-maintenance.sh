# shellcheck shell=bash
# Maintenance windows (lib/maintenance.sh), published by the health service as /maintenance.json for the apps
# on this server. Systemd keeps them in step with reboots:
#   cx-maintenance.path            a booked reboot (/run/systemd/shutdown changes) → cx-pgsql maintenance sync
#   cx-maintenance-sync.timer      the same every five minutes, a safety net
#   cx-maintenance-settle.service  at boot: ends the reboot's window once everything is healthy again

maintenance_describe() { echo "Maintenance windows for the apps (https://$SERVER_FQDN/maintenance.json), kept in step with reboots"; }
maintenance_enabled() { is_true "${MAINTENANCE_FEED:-true}"; }

_mnt_unit_head() { printf '# Managed by CX_PGSQL_Node_1 setup (steps/87-maintenance.sh).\n'; }

_mnt_sync_service() {
  _mnt_unit_head
  cat <<EOF
[Unit]
Description=CX PGSQL maintenance windows: follow a booked reboot

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/cx-pgsql maintenance sync
TimeoutStartSec=2min
EOF
}

_mnt_path() {
  _mnt_unit_head
  cat <<EOF
[Unit]
Description=CX PGSQL maintenance windows: watch for a booked reboot

[Path]
PathChanged=/run/systemd/shutdown
Unit=cx-maintenance-sync.service

[Install]
WantedBy=paths.target
EOF
}

_mnt_sync_timer() {
  _mnt_unit_head
  cat <<EOF
[Unit]
Description=CX PGSQL maintenance windows: five-minutely check

[Timer]
OnBootSec=1min
OnCalendar=*:0/5
Unit=cx-maintenance-sync.service

[Install]
WantedBy=timers.target
EOF
}

# Waits (up to MAINTENANCE_SETTLE_SECONDS) for the stack after a reboot; only then is the window ended.
_mnt_settle_service() {
  _mnt_unit_head
  cat <<EOF
[Unit]
Description=CX PGSQL maintenance windows: end the reboot's window once healthy
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/cx-pgsql maintenance settle
TimeoutStartSec=$(( ${MAINTENANCE_SETTLE_SECONDS:-600} + 120 ))

[Install]
WantedBy=multi-user.target
EOF
}

_mnt_units_on() {
  unit_enabled cx-maintenance.path && unit_active cx-maintenance.path &&
    unit_enabled cx-maintenance-sync.timer && unit_active cx-maintenance-sync.timer &&
    unit_enabled cx-maintenance-settle.service
}

_mnt_file_ok() { [[ -f "$MAINTENANCE_DIR/windows.json" ]] && jq -e '.windows | type == "array"' "$MAINTENANCE_DIR/windows.json" >/dev/null 2>&1; }

_mnt_published() {
  curl -fsS --max-time 5 "http://127.0.0.1:$HEALTH_PORT/maintenance.json" 2>/dev/null | jq -e '.version == 1' >/dev/null 2>&1
}

maintenance_check() {
  chk "windows file $MAINTENANCE_DIR/windows.json" _mnt_file_ok
  chk_render "cx-maintenance-sync.service" "$SYSTEMD_DIR/cx-maintenance-sync.service" _mnt_sync_service
  chk_render "watch /run/systemd/shutdown" "$SYSTEMD_DIR/cx-maintenance.path" _mnt_path
  chk_render "five-minutely check" "$SYSTEMD_DIR/cx-maintenance-sync.timer" _mnt_sync_timer
  chk_render "settle at boot" "$SYSTEMD_DIR/cx-maintenance-settle.service" _mnt_settle_service
  chk "units enabled" _mnt_units_on
  chk_soft "published by the health service (/maintenance.json)" _mnt_published
}

maintenance_apply() {
  install -d -m 0755 "$MAINTENANCE_DIR"
  if ! _mnt_file_ok; then
    printf '{"version":1,"windows":[]}\n' >"$MAINTENANCE_DIR/windows.json"
    chmod 0644 "$MAINTENANCE_DIR/windows.json"
  fi
  local reload=0
  _mnt_sync_service | write_if_changed "$SYSTEMD_DIR/cx-maintenance-sync.service" && reload=1
  _mnt_path | write_if_changed "$SYSTEMD_DIR/cx-maintenance.path" && reload=1
  _mnt_sync_timer | write_if_changed "$SYSTEMD_DIR/cx-maintenance-sync.timer" && reload=1
  _mnt_settle_service | write_if_changed "$SYSTEMD_DIR/cx-maintenance-settle.service" && reload=1
  ((reload)) && systemctl daemon-reload
  run systemctl enable --now cx-maintenance.path cx-maintenance-sync.timer >/dev/null 2>&1
  run systemctl enable cx-maintenance-settle.service >/dev/null 2>&1
  # A reboot booked before this step existed: write its window now (PathChanged only sees changes).
  systemctl start --no-block cx-maintenance-sync.service || true
  _mnt_published || warn "The health service doesn't publish /maintenance.json yet: apply the stack step (it mounts $MAINTENANCE_DIR)."
  return 0
}

maintenance_teardown() {
  systemctl disable --now cx-maintenance.path cx-maintenance-sync.timer >/dev/null 2>&1 || true
  systemctl disable cx-maintenance-settle.service >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR"/cx-maintenance{.path,-sync.service,-sync.timer,-settle.service}
  systemctl daemon-reload
  info "The windows ($MAINTENANCE_DIR/windows.json) are kept; the health service still publishes them until it's restarted without the mount."
}
