# shellcheck shell=bash
# The nightly report email (lib/report.sh): a systemd timer that runs `cx-pgsql report run`. With
# REBOOT_NOTICE, also the planned-downtime notice: a path unit on /run/systemd/shutdown (where a booked
# reboot is recorded) and a half-hourly safety-net timer, both running `cx-pgsql report reboot-notice`.
# Sending needs a Brevo API key on the server — from your machine: bin/remote.sh brevo-auth.

report_describe() { echo "Nightly report email to $REPORT_TO ($REPORT_SCHEDULE UTC, through Brevo)"; }
report_enabled() { is_true "$REPORT_ENABLED"; }

_report_service() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/85-report.sh).
[Unit]
Description=CX PGSQL nightly report email
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/cx-pgsql report run
Nice=10
TimeoutStartSec=15min
EOF
}

_report_timer() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/85-report.sh).
[Unit]
Description=CX PGSQL nightly report email: schedule

[Timer]
OnCalendar=$REPORT_SCHEDULE
Persistent=true
RandomizedDelaySec=120
Unit=cx-report.service

[Install]
WantedBy=timers.target
EOF
}

_report_timer_ok() { unit_enabled cx-report.timer && unit_active cx-report.timer; }

_notice_service() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/85-report.sh).
[Unit]
Description=CX PGSQL planned-reboot notice email
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/cx-pgsql report reboot-notice
TimeoutStartSec=5min
EOF
}

# logind writes the booking into this directory (and deletes it on shutdown -c): any change runs the notice.
_notice_path() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/85-report.sh).
[Unit]
Description=CX PGSQL planned-reboot notice: watch for a booked reboot

[Path]
PathChanged=/run/systemd/shutdown
Unit=cx-reboot-notice.service

[Install]
WantedBy=paths.target
EOF
}

_notice_timer() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/85-report.sh). A safety net for the path unit, and a retry
# when a send failed: the notice itself sends nothing twice.
[Unit]
Description=CX PGSQL planned-reboot notice: half-hourly check

[Timer]
OnCalendar=*:05,35
Unit=cx-reboot-notice.service

[Install]
WantedBy=timers.target
EOF
}

_notice_on() { unit_enabled cx-reboot-notice.path && unit_active cx-reboot-notice.path && unit_enabled cx-reboot-notice.timer && unit_active cx-reboot-notice.timer; }

report_check() {
  chk "a recipient (REPORT_TO) and a sender (REPORT_FROM)" test -n "$REPORT_TO" -a -n "$REPORT_FROM"
  chk_render "cx-report.service" "$SYSTEMD_DIR/cx-report.service" _report_service
  chk_render "timer ($REPORT_SCHEDULE UTC)" "$SYSTEMD_DIR/cx-report.timer" _report_timer
  chk "timer enabled" _report_timer_ok
  if is_true "$REBOOT_NOTICE"; then
    chk_render "cx-reboot-notice.service" "$SYSTEMD_DIR/cx-reboot-notice.service" _notice_service
    chk_render "reboot notice: watch /run/systemd/shutdown" "$SYSTEMD_DIR/cx-reboot-notice.path" _notice_path
    chk_render "reboot notice: half-hourly check" "$SYSTEMD_DIR/cx-reboot-notice.timer" _notice_timer
    chk "reboot notice watching" _notice_on
  fi
  chk_soft "Brevo API key installed (bin/remote.sh brevo-auth)" secret_exists brevo-api-key
}

report_apply() {
  [[ -n "$REPORT_TO" && -n "$REPORT_FROM" ]] || die "Set REPORT_TO and REPORT_FROM in config/server.env."
  install -d -m 0700 /var/lib/cx-pgsql/report
  local reload=0
  _report_service | write_if_changed "$SYSTEMD_DIR/cx-report.service" && reload=1
  _report_timer | write_if_changed "$SYSTEMD_DIR/cx-report.timer" && reload=1
  if is_true "$REBOOT_NOTICE"; then
    _notice_service | write_if_changed "$SYSTEMD_DIR/cx-reboot-notice.service" && reload=1
    _notice_path | write_if_changed "$SYSTEMD_DIR/cx-reboot-notice.path" && reload=1
    _notice_timer | write_if_changed "$SYSTEMD_DIR/cx-reboot-notice.timer" && reload=1
  elif [[ -f "$SYSTEMD_DIR/cx-reboot-notice.path" ]]; then
    systemctl disable --now cx-reboot-notice.path cx-reboot-notice.timer >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR"/cx-reboot-notice.{service,path,timer}
    reload=1
  fi
  ((reload)) && systemctl daemon-reload
  run systemctl enable --now cx-report.timer >/dev/null 2>&1
  # Enabling the path unit runs the notice once if a reboot is already booked (PathChanged only sees changes).
  if is_true "$REBOOT_NOTICE"; then
    run systemctl enable --now cx-reboot-notice.path cx-reboot-notice.timer >/dev/null 2>&1
    secret_exists brevo-api-key && { systemctl start --no-block cx-reboot-notice.service || true; }
  fi
  # Once it's on, the health service warns when an email fails or stops (the report_email check).
  status_update '.report.enabled = true'
  secret_exists brevo-api-key || warn "No Brevo API key yet: from your machine run  bin/remote.sh brevo-auth"
  return 0
}

report_teardown() {
  systemctl disable --now cx-report.timer cx-reboot-notice.path cx-reboot-notice.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/cx-report.timer" "$SYSTEMD_DIR/cx-report.service" "$SYSTEMD_DIR"/cx-reboot-notice.{service,path,timer}
  systemctl daemon-reload
  status_update '.report.enabled = false'
  info "The Brevo key ($(secret_path brevo-api-key)) and the last report in /var/lib/cx-pgsql/report are kept."
}
