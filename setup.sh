#!/usr/bin/env bash
# CX_PGSQL_Node_1 — provision, check, repair and tear down the server.
#
#   setup.sh status   [step...]          what is DONE / MISSING / BROKEN, item by item
#   setup.sh apply    [step...] [--force] run every step that isn't DONE (all steps by default)
#   setup.sh repair   [step...]          same as apply; reads better when something broke
#   setup.sh teardown <step...|all> [--purge] [--yes]
#                                         undo steps in reverse order; --purge also deletes data
#   setup.sh confirm                      keep SSH/firewall changes (cancels their automatic undo)
#   setup.sh list                         the steps, in order
#
# Options: --force (re-apply DONE steps too), --no-rollback (no automatic undo timers),
#          --verbose, --yes (no questions for teardown).
# Runs on the server as root. From your machine, bin/remote.sh syncs this project and runs it.
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_DIR
# shellcheck source=lib/core.sh
source "$PROJECT_DIR/lib/core.sh"
for _lib in tls dbconf pg backup; do
  # shellcheck source=/dev/null
  source "$PROJECT_DIR/lib/$_lib.sh"
done

trap 'err "Failed at ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND}"' ERR

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

CMD=${1:-status}
[[ $# -gt 0 ]] && shift
FORCE=0 PURGE=0 YES=0
ARGS=()
for a in "$@"; do
  case $a in
    --force) FORCE=1 ;;
    --purge) PURGE=1 ;;
    --yes | -y) YES=1 ;;
    --no-rollback) export CX_NO_ROLLBACK=1 ;;
    --verbose | -v) export VERBOSE=1 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "Unknown option $a" ;;
    *) ARGS+=("$a") ;;
  esac
done
export FORCE PURGE YES

case $CMD in
  -h | --help | help) usage; exit 0 ;;
esac

need_root "$CMD"
mkdir -p "$(dirname "$LOG_FILE")" /var/lib/cx-pgsql
load_config
[[ "$PROJECT_DIR" == "$INSTALL_DIR" ]] ||
  warn "Running from $PROJECT_DIR, but hooks and timers call $INSTALL_DIR — install there (bin/remote.sh sync does)."
load_steps

cmd_list() {
  local id i=0
  for id in "${STEP_IDS[@]}"; do
    i=$((i + 1))
    printf '%2d. %-10s %s\n' "$i" "$id" "$("${id}_describe")"
  done
}

cmd_status() {
  local id
  STATUS_RC=0
  section "$SERVER_HOSTNAME — $(date -u '+%Y-%m-%d %H:%M UTC')"
  while read -r -u 9 id; do
    step_state "$id"
    printf '%-10s %s\n' "$id" "$(state_label "$STEP_STATE")"
    if [[ $STEP_STATE != DONE && $STEP_STATE != DISABLED ]] || ((CHECK_WARN > 0)) || [[ "${VERBOSE:-0}" == 1 ]]; then
      ((${#CHECK_LINES[@]})) && printf '%s\n' "${CHECK_LINES[@]}"
    fi
    case $STEP_STATE in MISSING | BROKEN) STATUS_RC=1 ;; esac
  done 9< <(resolve_steps "${ARGS[@]}")
  if rollback_pending; then
    echo
    warn "Changes waiting for confirmation: $(sort -u /run/cx-pgsql/rollback-pending | tr '\n' ' ')— run: setup.sh confirm"
  fi
}

cmd_apply() {
  local id applied=0
  while read -r -u 9 id; do
    step_state "$id"
    if [[ $STEP_STATE == DISABLED ]]; then
      info "$id: disabled in config — skipped"
      continue
    fi
    # A step with warnings is re-applied too: a warning is something a re-run may fix
    # (e.g. the certificate once DNS points here). Still warning afterwards is not a failure.
    if [[ $STEP_STATE == DONE && $FORCE == 0 && ${CHECK_WARN:-0} == 0 ]]; then
      ok "$id: already done"
      continue
    fi
    section "$id — $("${id}_describe") ($(state_label "$STEP_STATE"))"
    ((${#CHECK_LINES[@]})) && printf '%s\n' "${CHECK_LINES[@]}"
    "${id}_apply"
    applied=$((applied + 1))
    step_state "$id"
    if [[ $STEP_STATE == DONE ]]; then
      ok "$id: done"
    else
      printf '%s\n' "${CHECK_LINES[@]}"
      die "$id is still $(state_label "$STEP_STATE") after applying it — see the items above."
    fi
  done 9< <(resolve_steps "${ARGS[@]}")
  echo
  ok "Applied $applied step(s)."
  if rollback_pending; then
    warn "SSH/firewall changes revert in ${ROLLBACK_SECONDS}s unless confirmed from a NEW connection:"
    warn "  ssh -p $SSH_PORT $ADMIN_USER@${SERVER_IP:-$SERVER_FQDN} sudo $INSTALL_DIR/setup.sh confirm"
  fi
}

cmd_teardown() {
  ((${#ARGS[@]})) || die "Name the steps to tear down (or 'all')."
  local ids=() id
  mapfile -t ids < <(resolve_steps "${ARGS[@]}")
  # Reverse order: the stack goes before Docker, the firewall after the stack, and so on.
  local reversed=()
  for ((i = ${#ids[@]} - 1; i >= 0; i--)); do reversed+=("${ids[i]}"); done
  section "Tear down: ${reversed[*]}$( ((PURGE)) && printf ' (with --purge: DATA IS DELETED)')"
  if ((YES == 0)); then
    read -r -p "Type the hostname ($SERVER_HOSTNAME) to continue: " answer
    [[ "$answer" == "$SERVER_HOSTNAME" ]] || die "Cancelled."
  fi
  for id in "${reversed[@]}"; do
    if declare -F "${id}_teardown" >/dev/null; then
      section "$id — tearing down"
      "${id}_teardown"
      ok "$id: torn down"
    else
      info "$id: nothing to tear down"
    fi
  done
}

case $CMD in
  list) cmd_list ;;
  status)
    cmd_status
    exit "$STATUS_RC"
    ;;
  apply | setup | repair) cmd_apply ;;
  teardown) cmd_teardown ;;
  confirm) rollback_confirm ;;
  *) usage; die "Unknown command '$CMD'." ;;
esac
