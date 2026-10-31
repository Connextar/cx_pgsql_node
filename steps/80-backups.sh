# shellcheck shell=bash
# Backup schedules (systemd timers), tools (rclone, age), log rotation and the cx-pgsql command.
# The jobs themselves are in lib/backup.sh; their outcomes feed the health endpoint.

SYSTEMD_DIR=/etc/systemd/system

backups_describe() { echo "Backup timers: dumps, pgBackRest, upload to $BACKUP_REMOTE:$BACKUP_REMOTE_PATH$(is_true "$ENABLE_OBJECTS" && printf ', objects'), weekly verify"; }

# job|schedule|enabled
_bk_jobs() {
  printf 'logical|%s|true\n' "$BACKUP_LOGICAL_SCHEDULE"
  printf 'physical|%s|%s\n' "$BACKUP_PHYSICAL_SCHEDULE" "$(is_true "$BACKUP_PITR" && echo true || echo false)"
  printf 'upload|%s|%s\n' "$BACKUP_UPLOAD_SCHEDULE" "$(is_true "$BACKUP_UPLOAD" && echo true || echo false)"
  printf 'verify|%s|true\n' "$BACKUP_VERIFY_SCHEDULE"
  printf 'objects|%s|%s\n' "$OBJECTS_BACKUP_SCHEDULE" "$(is_true "$ENABLE_OBJECTS" && echo true || echo false)"
}

_bk_service() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/80-backups.sh).
[Unit]
Description=CX PGSQL backup job: %i
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/cx-pgsql backup %i
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=6h
EOF
}

_bk_timer() { # job schedule
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup (steps/80-backups.sh).
[Unit]
Description=CX PGSQL backup schedule: $1

[Timer]
OnCalendar=$2
Persistent=true
RandomizedDelaySec=60
Unit=cx-backup@$1.service

[Install]
WantedBy=timers.target
EOF
}

_bk_logrotate() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup. Postgres rotates its own log files (a weekday ring).
$STACK_LOGS_DIR/pgbouncer/*.log $STACK_LOGS_DIR/pgbackrest/*.log /var/log/cx-pgsql.log /var/log/cx-pgsql-setup.log {
	weekly
	rotate 8
	compress
	delaycompress
	missingok
	notifempty
	copytruncate
}
EOF
}

_bk_timer_ok() { unit_enabled "cx-backup-$1.timer" && unit_active "cx-backup-$1.timer"; }

backups_check() {
  local job schedule enabled
  chk "rclone, age, zstd installed" pkgs_installed rclone age zstd
  chk "cx-pgsql on the PATH" test "$(readlink -f /usr/local/bin/cx-pgsql)" = "$INSTALL_DIR/bin/cx-pgsql"
  chk "backup directories" test -d "$BACKUP_ROOT/dumps" -a -d "$BACKUP_ROOT/status"
  chk_render "cx-backup@.service" "$SYSTEMD_DIR/cx-backup@.service" _bk_service
  while IFS='|' read -r job schedule enabled; do
    if [[ $enabled == true ]]; then
      chk_render "timer $job ($schedule)" "$SYSTEMD_DIR/cx-backup-$job.timer" _bk_timer "$job" "$schedule"
      chk "timer $job enabled" _bk_timer_ok "$job"
    fi
  done < <(_bk_jobs)
  chk_render "log rotation" /etc/logrotate.d/cx-pgsql _bk_logrotate
  if is_true "$BACKUP_UPLOAD"; then
    chk_soft "rclone remote '$BACKUP_REMOTE' configured (bin/remote.sh dropbox-auth)" remote_configured
  fi
  chk_soft "dumps encrypted to an age key (BACKUP_AGE_RECIPIENTS) — needed to upload them" encrypting
}

backups_apply() {
  ensure_pkgs rclone age zstd jq
  ln -sfn "$INSTALL_DIR/bin/cx-pgsql" /usr/local/bin/cx-pgsql
  install -d -m 0755 "$BACKUP_ROOT" "$BACKUP_ROOT/status"
  install -d -m 0700 "$BACKUP_ROOT/dumps"
  [[ -s "$BACKUP_ROOT/status/status.json" ]] || printf '{}\n' >"$BACKUP_ROOT/status/status.json"
  chmod 0644 "$BACKUP_ROOT/status/status.json"

  local job schedule enabled reload=0
  _bk_service | write_if_changed "$SYSTEMD_DIR/cx-backup@.service" && reload=1
  while IFS='|' read -r job schedule enabled; do
    if [[ $enabled == true ]]; then
      _bk_timer "$job" "$schedule" | write_if_changed "$SYSTEMD_DIR/cx-backup-$job.timer" && reload=1
    elif [[ -f "$SYSTEMD_DIR/cx-backup-$job.timer" ]]; then
      systemctl disable --now "cx-backup-$job.timer" >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/cx-backup-$job.timer"
      reload=1
    fi
  done < <(_bk_jobs)
  ((reload)) && systemctl daemon-reload
  while IFS='|' read -r job schedule enabled; do
    [[ $enabled == true ]] && run systemctl enable --now "cx-backup-$job.timer" >/dev/null 2>&1
  done < <(_bk_jobs)
  _bk_logrotate | write_if_changed /etc/logrotate.d/cx-pgsql || true
  # Record whether uploads are on, so the health check knows to expect them.
  status_update '.upload.enabled = ($u == "1") | .physical.enabled = ($p == "1") | .objects_backup.enabled = ($o == "1")' \
    --arg u "$(is_true "$BACKUP_UPLOAD" && echo 1 || echo 0)" --arg p "$(is_true "$BACKUP_PITR" && echo 1 || echo 0)" \
    --arg o "$(is_true "$ENABLE_OBJECTS" && is_true "$BACKUP_UPLOAD" && echo 1 || echo 0)"

  is_true "$BACKUP_UPLOAD" && ! remote_configured &&
    warn "Uploads are on but no rclone remote is configured: from your machine run  bin/remote.sh dropbox-auth"
  encrypting || warn "BACKUP_AGE_RECIPIENTS is empty: dumps stay on this server (the pgBackRest repository, encrypted, still uploads)."
  return 0
}

backups_teardown() {
  local job
  for job in logical physical upload verify objects; do
    systemctl disable --now "cx-backup-$job.timer" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/cx-backup-$job.timer"
  done
  rm -f "$SYSTEMD_DIR/cx-backup@.service" /etc/logrotate.d/cx-pgsql /usr/local/bin/cx-pgsql
  systemctl daemon-reload
  info "Backup files in $BACKUP_ROOT and the remote copy are kept."
}
