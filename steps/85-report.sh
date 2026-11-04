# shellcheck shell=bash
# The nightly report email (lib/report.sh): a systemd timer that runs `cx-pgsql report run`. Sending needs a
# Brevo API key on the server — from your machine: bin/remote.sh brevo-auth.

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

report_check() {
  chk "a recipient (REPORT_TO) and a sender (REPORT_FROM)" test -n "$REPORT_TO" -a -n "$REPORT_FROM"
  chk_render "cx-report.service" "$SYSTEMD_DIR/cx-report.service" _report_service
  chk_render "timer ($REPORT_SCHEDULE UTC)" "$SYSTEMD_DIR/cx-report.timer" _report_timer
  chk "timer enabled" _report_timer_ok
  chk_soft "Brevo API key installed (bin/remote.sh brevo-auth)" secret_exists brevo-api-key
}

report_apply() {
  [[ -n "$REPORT_TO" && -n "$REPORT_FROM" ]] || die "Set REPORT_TO and REPORT_FROM in config/server.env."
  install -d -m 0700 /var/lib/cx-pgsql/report
  local reload=0
  _report_service | write_if_changed "$SYSTEMD_DIR/cx-report.service" && reload=1
  _report_timer | write_if_changed "$SYSTEMD_DIR/cx-report.timer" && reload=1
  ((reload)) && systemctl daemon-reload
  run systemctl enable --now cx-report.timer >/dev/null 2>&1
  # Once it's on, the health service warns when an email fails or stops (the report_email check).
  status_update '.report.enabled = true'
  secret_exists brevo-api-key || warn "No Brevo API key yet: from your machine run  bin/remote.sh brevo-auth"
  return 0
}

report_teardown() {
  systemctl disable --now cx-report.timer >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/cx-report.timer" "$SYSTEMD_DIR/cx-report.service"
  systemctl daemon-reload
  status_update '.report.enabled = false'
  info "The Brevo key ($(secret_path brevo-api-key)) and the last report in /var/lib/cx-pgsql/report are kept."
}
