#!/usr/bin/env bash
# Run from YOUR machine: ship this project to the server and drive it over SSH.
#
#   bin/remote.sh apply [step...] [--force]   sync, apply, then confirm SSH/firewall changes from a
#                                             fresh connection on the new port (else they revert)
#   bin/remote.sh status [step...]            what's DONE / MISSING / BROKEN
#   bin/remote.sh teardown <step...|all> [--purge]
#   bin/remote.sh sync                        copy the project to INSTALL_DIR only
#   bin/remote.sh cx <args>                   run cx-pgsql on the server (e.g. cx db url alted)
#   bin/remote.sh ssh                         interactive shell
#   bin/remote.sh tunnel [local-port] [remote-port]
#                                             forward localhost:<local> to the server's loopback
#                                             (default: the direct Postgres port)
#   bin/remote.sh dropbox-auth [--client-id ID --client-secret SECRET]
#                                             authorise Dropbox in your browser (needs rclone
#                                             here) and install the token on the server
#
# First run on a fresh VPS: connects as BOOTSTRAP_SSH_USER (root) on port 22 with your key;
# afterwards as ADMIN_USER on SSH_PORT. Settings come from config/server.env.
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case ${1:-} in -h | --help | help)
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 0
  ;;
esac
cd "$PROJECT_DIR"
[[ -f config/server.env ]] || { echo "Create config/server.env first (copy config/server.env.sample)." >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source config/server.env.sample
# shellcheck source=/dev/null
source config/server.env
set +a

HOST=${SERVER_IP:-$SERVER_FQDN}
BOOTSTRAP_SSH_USER=${BOOTSTRAP_SSH_USER:-root}
BOOTSTRAP_SSH_PORT=${BOOTSTRAP_SSH_PORT:-22}
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30)
[[ -n "${REMOTE_SSH_IDENTITY:-}" ]] && SSH_OPTS+=(-i "$REMOTE_SSH_IDENTITY" -o IdentitiesOnly=yes)

say() { printf '› %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# Pick the way in: the hardened one if it works, else the bootstrap one.
pick_target() {
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=6 -p "$SSH_PORT" "$ADMIN_USER@$HOST" true 2>/dev/null; then
    T_USER=$ADMIN_USER T_PORT=$SSH_PORT
  elif ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=6 -p "$BOOTSTRAP_SSH_PORT" "$BOOTSTRAP_SSH_USER@$HOST" true 2>/dev/null; then
    T_USER=$BOOTSTRAP_SSH_USER T_PORT=$BOOTSTRAP_SSH_PORT
    say "Using the bootstrap login $T_USER@$HOST:$T_PORT"
  else
    die "Can't log in to $HOST as $ADMIN_USER:$SSH_PORT or $BOOTSTRAP_SSH_USER:$BOOTSTRAP_SSH_PORT with your SSH key."
  fi
  SUDO=""
  [[ "$T_USER" == root ]] || SUDO="sudo"
}
rssh() { ssh "${SSH_OPTS[@]}" -p "$T_PORT" "$T_USER@$HOST" "$@"; }
rssh_t() { ssh -t "${SSH_OPTS[@]}" -p "$T_PORT" "$T_USER@$HOST" "$@"; }

cmd_sync() {
  pick_target
  say "Copying the project to $HOST:$INSTALL_DIR"
  # A fresh copy each time (so deleted files go too), swapped in at the end.
  # macOS tar would add AppleDouble "._*" files for extended attributes: none of those, please.
  COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.git --exclude=node_modules --exclude=.DS_Store \
    --exclude='._*' --exclude='tests/.cache' -czf - . |
    rssh "$SUDO bash -c 'set -e; rm -rf $INSTALL_DIR.new; mkdir -p $INSTALL_DIR.new; tar -xzf - -C $INSTALL_DIR.new 2>/dev/null; chown -R root:root $INSTALL_DIR.new; chmod 750 $INSTALL_DIR.new; chmod 600 $INSTALL_DIR.new/config/server.env; rm -rf $INSTALL_DIR.old; [ -d $INSTALL_DIR ] && mv $INSTALL_DIR $INSTALL_DIR.old; mv $INSTALL_DIR.new $INSTALL_DIR; rm -rf $INSTALL_DIR.old'"
}

remote_setup() { rssh_t "$SUDO $INSTALL_DIR/setup.sh $*"; }

# After a run, SSH/firewall changes wait for confirmation from a NEW connection on the new path
# (ADMIN_USER on SSH_PORT): reaching it that way is the proof the change didn't lock us out.
confirm_from_new_connection() {
  local new=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" "$ADMIN_USER@$HOST")
  local old=(ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=8 -p "$BOOTSTRAP_SSH_PORT" "$BOOTSTRAP_SSH_USER@$HOST")
  local probe="test -s /run/cx-pgsql/rollback-pending" rc=0
  # ssh exits 255 when it can't connect; otherwise with the command's status (1 = nothing pending).
  "${new[@]}" "$probe" 2>/dev/null || rc=$?
  if ((rc == 1)); then return 0; fi
  if ((rc != 0)); then
    rc=0
    "${old[@]}" "$probe" 2>/dev/null || rc=$?
    if ((rc == 1)); then return 0; fi
    if ((rc != 0)); then
      say "Couldn't reach $HOST on port $SSH_PORT or $BOOTSTRAP_SSH_PORT to check: any pending change reverts within ${ROLLBACK_SECONDS}s."
      return 1
    fi
    say "Changes are pending, but $ADMIN_USER@$HOST:$SSH_PORT doesn't answer yet — retrying"
  fi
  say "Confirming SSH/firewall changes from a new connection ($ADMIN_USER@$HOST:$SSH_PORT)"
  local _
  for _ in 1 2 3 4 5; do
    if "${new[@]}" "sudo $INSTALL_DIR/setup.sh confirm"; then
      return 0
    fi
    sleep 5
  done
  die "Couldn't log in as $ADMIN_USER on port $SSH_PORT — the changes revert by themselves within ${ROLLBACK_SECONDS}s. Check config/authorized_keys and SSH_PORT."
}

cmd_apply() {
  local rc=0
  cmd_sync
  remote_setup apply "$@" || rc=$?
  # Whatever happened, SSH/firewall changes already made must be confirmed on the new path
  # (the run may have used the bootstrap login), or they revert by themselves.
  confirm_from_new_connection || rc=1
  if ((rc != 0)); then
    die "The apply stopped with an error (above). Fix it and run bin/remote.sh apply again: finished steps are skipped."
  fi
  pick_target
  remote_setup status || true
}

cmd_dropbox_auth() {
  command -v rclone >/dev/null || die "rclone isn't installed here: brew install rclone"
  local args=(dropbox) client_args=() out token
  while (($#)); do
    case $1 in
      --client-id) args+=("$2"); client_args+=(--client-id "$2"); shift ;;
      --client-secret) args+=("$2"); client_args+=(--client-secret "$2"); shift ;;
      *) die "Unknown option $1" ;;
    esac
    shift
  done
  say "A browser window opens: sign in to the Dropbox account that should hold the backups."
  out=$(rclone authorize "${args[@]}")
  token=$(printf '%s\n' "$out" | sed -n '/^{/,/^}/p' | tr -d '\n')
  [[ -n "$token" ]] || token=$(printf '%s\n' "$out" | grep -E '^\{.*access_token' | tail -1)
  [[ -n "$token" ]] || die "No token in rclone's output."
  pick_target
  printf '%s' "$token" | rssh "$SUDO $INSTALL_DIR/bin/cx-pgsql backup dropbox-configure ${client_args[*]}"
}

CMD=${1:-status}
[[ $# -gt 0 ]] && shift
case $CMD in
  apply | setup | repair) cmd_apply "$@" ;;
  status) pick_target; remote_setup status "$@" ;;
  teardown) cmd_sync; remote_setup teardown "$@" ;;
  confirm) confirm_from_new_connection ;;
  sync) cmd_sync ;;
  cx) pick_target; rssh_t "$SUDO $INSTALL_DIR/bin/cx-pgsql $*" ;;
  ssh) pick_target; rssh_t ;;
  tunnel)
    pick_target
    lp=${1:-$PG_DIRECT_PORT} rp=${2:-$PG_DIRECT_PORT}
    say "localhost:$lp → $HOST 127.0.0.1:$rp (Ctrl-C to close)"
    ssh "${SSH_OPTS[@]}" -N -L "$lp:127.0.0.1:$rp" -p "$T_PORT" "$T_USER@$HOST"
    ;;
  dropbox-auth) cmd_dropbox_auth "$@" ;;
  -h | --help | help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" ;;
  *) die "Unknown command $CMD (see bin/remote.sh --help)" ;;
esac
