# shellcheck shell=bash
# Core of the setup: logging, configuration, templates, secrets and the step runner.
#
# A step is a file steps/NN-<id>.sh defining, with <id> as the prefix:
#   <id>_describe   one line for `setup.sh list`
#   <id>_enabled    optional; non-zero return = switched off in config (shown, never run)
#   <id>_check      inspects the live system; each item is reported with `chk`
#   <id>_apply      brings the system to the checked state. Idempotent: it is also the repair
#   <id>_teardown   optional; reverses apply
#
# A step's state is derived from its check items, never from a stamp file, so a step that
# was applied and later broken (a file edited, a service stopped) shows as BROKEN and is
# repaired by the next apply:
#   DONE     every item holds
#   MISSING  no item holds (never applied, or fully removed)
#   BROKEN   some items hold and some don't (partly applied, or drifted since)
# Items checked with `chk_soft` only warn: a step whose hard items all hold is DONE even
# when a soft one fails (e.g. a self-signed certificate while DNS isn't pointing here yet).

# ─── Output ────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_DIM='' C_BOLD='' C_OFF=''
fi

LOG_FILE=${LOG_FILE:-/var/log/cx-pgsql-setup.log}

_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  if [[ -w "$(dirname "$LOG_FILE")" ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
info() { printf '%s\n' "${C_BLUE}›${C_OFF} $*"; _log "INFO $*"; }
ok() { printf '%s\n' "${C_GREEN}✓${C_OFF} $*"; _log "OK $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_OFF} $*" >&2; _log "WARN $*"; }
err() { printf '%s\n' "${C_RED}✗${C_OFF} $*" >&2; _log "ERROR $*"; }
die() {
  err "$*"
  exit 1
}
section() { printf '\n%s\n' "${C_BOLD}$*${C_OFF}"; }

# Run a command, echoing it in verbose mode. Output goes to the terminal and the log.
run() {
  [[ "${VERBOSE:-0}" == 1 ]] && printf '%s\n' "${C_DIM}\$ $*${C_OFF}"
  _log "RUN $*"
  "$@"
}

# `cmd | grep -q` under pipefail fails when grep exits early and cmd dies of SIGPIPE on its
# remaining output (sshd -T, nft list …). grep_q reads everything and discards the output.
grep_q() { grep "$@" >/dev/null; }

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)."; }

# ─── Configuration ─────────────────────────────────────────────────────────────────
# PROJECT_DIR is set by the entry script. Values come from config/server.env.sample
# (every default), overlaid by config/server.env (this server's choices).
load_config() {
  local sample="$PROJECT_DIR/config/server.env.sample" local_cfg="$PROJECT_DIR/config/server.env"
  [[ -f "$sample" ]] || die "Missing $sample."
  set -a
  # shellcheck source=/dev/null
  source "$sample"
  if [[ -f "$local_cfg" ]]; then
    # shellcheck source=/dev/null
    source "$local_cfg"
  elif [[ "${CX_ALLOW_SAMPLE_CONFIG:-0}" != 1 ]]; then
    set +a
    die "No config/server.env. Copy config/server.env.sample to config/server.env and edit it."
  fi
  set +a
  derive_config
}

# Values computed from the configuration, exported for templates.
derive_config() {
  export PG_MAJOR="${PG_VERSION%%.*}"
  export PG_DATA_DIR="$DATA_ROOT/$PG_MAJOR/data"
  export STACK_CERTS_DIR="$STACK_DIR/certs"
  export STACK_LOGS_DIR="$STACK_DIR/logs"
  export TLS_DIR="/etc/cx-pgsql/tls/$SERVER_FQDN"
  export COMPOSE_PROJECT_NAME="$STACK_NAME"
  export PG_CONTAINER="${STACK_NAME}-postgres"
  export PGBOUNCER_CONTAINER="${STACK_NAME}-pgbouncer"
  export HEALTH_CONTAINER="${STACK_NAME}-health"
  export N8N_CONTAINER="${STACK_NAME}-n8n"
  # The uid/gid the postgres user has in the official image (and in our PgBouncer image).
  export PG_UID=999 PG_GID=999
  export WEBROOT=/var/www/letsencrypt
  # Backups (lib/backup.sh, lib/restore.sh).
  export BACKUP_STATUS_FILE="$BACKUP_ROOT/status/status.json"
  export DUMPS_DIR="$BACKUP_ROOT/dumps"
  export REPO_DIR="$BACKUP_ROOT/pgbackrest"
  export PITR_CONTAINER="${STACK_NAME}-pitr"
  # Object storage (steps/72-objects.sh, lib/objects.sh).
  export OBJECTS_DIR="$STACK_DIR/objects"
  export OBJECTS_CONTAINER="${STACK_NAME}-objects"
}

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

# ─── Files and templates ───────────────────────────────────────────────────────────
# Templates use ${UPPER_CASE} for our values; anything else (nginx's $host, Postgres' %p)
# passes through. Every ${VAR} a template names must be set, or rendering fails loudly.
render_template() {
  local src=$1 vars name missing=()
  [[ -f "$src" ]] || die "Template not found: $src"
  vars=$(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$src" | sort -u | tr '\n' ' ' || true)
  for name in $(grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$src" | sort -u | tr -d '${}' || true); do
    [[ -v "$name" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "Template $src uses unset variable(s): ${missing[*]}"
  envsubst "$vars" <"$src"
}

# Write stdin to DEST if its content differs. Returns 0 when the file changed, 1 when it
# was already identical. Mode and owner are always enforced.
write_if_changed() {
  local dest=$1 mode=${2:-0644} owner=${3:-root:root} tmp changed=1
  tmp=$(mktemp)
  cat >"$tmp"
  mkdir -p "$(dirname "$dest")"
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dest"
    _log "WROTE $dest"
    changed=0
  else
    chmod "$mode" "$dest"
    chown "$owner" "$dest"
  fi
  rm -f "$tmp"
  return $changed
}

# Whether DEST already holds exactly what stdin would write.
same_content() {
  local dest=$1
  [[ -f "$dest" ]] && cmp -s - "$dest"
}

# ─── Packages ──────────────────────────────────────────────────────────────────────
_APT_UPDATED=0
# Wait for the dpkg lock rather than fail: on a fresh server unattended-upgrades often holds it.
APT_LOCK_WAIT=(-o DPkg::Lock::Timeout=600)
apt_update_once() {
  if ((_APT_UPDATED == 0)); then
    env DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_WAIT[@]}" update -qq >>"$LOG_FILE" 2>&1 || die "apt-get update failed (see $LOG_FILE)."
    _APT_UPDATED=1
  fi
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep_q 'install ok installed'; }
pkgs_installed() {
  local p
  for p in "$@"; do pkg_installed "$p" || return 1; done
}
ensure_pkgs() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]} == 0)) && return 0
  apt_update_once
  info "Installing: ${missing[*]}"
  # dpkg's progress goes to the log; it's shown only if the install fails.
  if ! env DEBIAN_FRONTEND=noninteractive apt-get "${APT_LOCK_WAIT[@]}" install -y -qq --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}" >>"$LOG_FILE" 2>&1; then
    tail -30 "$LOG_FILE" >&2
    die "apt-get install failed: ${missing[*]}"
  fi
}

# ─── Secrets ───────────────────────────────────────────────────────────────────────
# A secret is a root-only file under SECRETS_DIR, generated once and never overwritten.
# Values are URL-safe so they can go into connection strings unescaped.
secret_path() { printf '%s/%s' "$SECRETS_DIR" "$1"; }
secret() {
  local name=$1 len=${2:-40} path
  path=$(secret_path "$name")
  if [[ ! -s "$path" ]]; then
    install -d -m 0700 "$SECRETS_DIR"
    (umask 077 && openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c "$len" >"$path")
    _log "SECRET generated $name"
  fi
  cat "$path"
}
secret_exists() { [[ -s "$(secret_path "$1")" ]]; }
# The same, as hex (what Garage's RPC secret and access keys must be): secret_hex <name> <bytes> [prefix]
secret_hex() {
  local name=$1 bytes=$2 prefix=${3:-} path
  path=$(secret_path "$name")
  if [[ ! -s "$path" ]]; then
    install -d -m 0700 "$SECRETS_DIR"
    (umask 077 && printf '%s%s' "$prefix" "$(openssl rand -hex "$bytes")" >"$path")
    _log "SECRET generated $name"
  fi
  cat "$path"
}

# ─── Services ──────────────────────────────────────────────────────────────────────
unit_active() { systemctl is-active --quiet "$1"; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# ─── Rollback timers (SSH and firewall) ────────────────────────────────────────────
# Before a change that could lock us out, save what it replaces and schedule its undo.
# `setup.sh confirm`, run from a NEW connection, cancels the undo.
ROLLBACK_DIR=${ROLLBACK_DIR:-/var/lib/cx-pgsql/rollback}

rollback_save() { # rollback_save <name> <file>...  (missing files are recorded as absent)
  local name=$1 f
  shift
  local dir="$ROLLBACK_DIR/$name"
  rm -rf "$dir"
  mkdir -p "$dir/files"
  for f in "$@"; do
    if [[ -e "$f" ]]; then
      mkdir -p "$dir/files$(dirname "$f")"
      cp -a "$f" "$dir/files$f"
    else
      printf '%s\n' "$f" >>"$dir/absent"
    fi
  done
}

rollback_schedule() { # rollback_schedule <name>
  local name=$1 unit="cx-rollback-$1"
  if [[ "${CX_NO_ROLLBACK:-0}" == 1 ]]; then
    warn "Rollback timer for $name skipped (--no-rollback)."
    return 0
  fi
  systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
  systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null || true
  run systemd-run --quiet --unit="$unit" --on-active="${ROLLBACK_SECONDS}s" \
    --timer-property=AccuracySec=1s "$PROJECT_DIR/lib/rollback.sh" "$name"
  mkdir -p /run/cx-pgsql
  printf '%s\n' "$name" >>/run/cx-pgsql/rollback-pending
  warn "$name: change applied with an automatic undo in ${ROLLBACK_SECONDS}s."
  warn "Confirm from a NEW connection: ssh -p $SSH_PORT $ADMIN_USER@${SERVER_IP:-$SERVER_FQDN} sudo $INSTALL_DIR/setup.sh confirm"
}

rollback_pending() { [[ -s /run/cx-pgsql/rollback-pending ]]; }

rollback_confirm() {
  local name unit any=0
  if [[ -s /run/cx-pgsql/rollback-pending ]]; then
    while read -r name; do
      [[ -n "$name" ]] || continue
      unit="cx-rollback-$name"
      systemctl stop "$unit.timer" 2>/dev/null || true
      systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null || true
      rm -rf "${ROLLBACK_DIR:?}/$name"
      ok "Confirmed $name: its automatic undo is cancelled."
      any=1
    done < <(sort -u /run/cx-pgsql/rollback-pending)
    rm -f /run/cx-pgsql/rollback-pending
  fi
  ((any)) || info "Nothing waiting for confirmation."
}

# ─── Checks ────────────────────────────────────────────────────────────────────────
# Inside <id>_check, report each item with `chk "label" command...`. The command's
# success means the item holds.
check_begin() {
  CHECK_PASS=0
  CHECK_FAIL=0
  CHECK_WARN=0
  CHECK_LINES=()
}
chk() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    CHECK_PASS=$((CHECK_PASS + 1))
    CHECK_LINES+=("  ${C_GREEN}✓${C_OFF} $label")
  else
    CHECK_FAIL=$((CHECK_FAIL + 1))
    CHECK_LINES+=("  ${C_RED}✗${C_OFF} $label")
  fi
}
# An item that warns but never makes the step MISSING or BROKEN.
chk_soft() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    CHECK_LINES+=("  ${C_GREEN}✓${C_OFF} $label")
  else
    CHECK_WARN=$((CHECK_WARN + 1))
    CHECK_LINES+=("  ${C_YELLOW}!${C_OFF} $label")
  fi
}
# A line that only informs.
chk_note() { CHECK_LINES+=("  ${C_DIM}•${C_OFF} $1"); }
# A file that must hold what a generator prints: chk_render "label" dest generator args...
chk_render() {
  local label=$1 dest=$2
  shift 2
  if [[ -f "$dest" ]] && "$@" 2>/dev/null | cmp -s - "$dest"; then
    CHECK_PASS=$((CHECK_PASS + 1))
    CHECK_LINES+=("  ${C_GREEN}✓${C_OFF} $label")
  else
    CHECK_FAIL=$((CHECK_FAIL + 1))
    if [[ -f "$dest" ]]; then
      CHECK_LINES+=("  ${C_RED}✗${C_OFF} $label ${C_DIM}(differs from the template)${C_OFF}")
    else
      CHECK_LINES+=("  ${C_RED}✗${C_OFF} $label ${C_DIM}(missing)${C_OFF}")
    fi
  fi
}
# 0 DONE, 1 MISSING, 2 BROKEN
check_state() {
  if ((CHECK_FAIL == 0)); then
    return 0
  elif ((CHECK_PASS == 0)); then
    return 1
  else
    return 2
  fi
}

# ─── Step runner ───────────────────────────────────────────────────────────────────
STEP_IDS=()
load_steps() {
  local f id
  for f in "$PROJECT_DIR"/steps/[0-9][0-9]-*.sh; do
    # shellcheck source=/dev/null
    source "$f"
    id=$(basename "$f" .sh)
    id=${id#[0-9][0-9]-}
    STEP_IDS+=("$id")
  done
}

step_enabled() {
  local id=$1
  if declare -F "${id}_enabled" >/dev/null; then "${id}_enabled"; else return 0; fi
}

# Resolve user-given step names (or "all") to known ids, in run order.
resolve_steps() {
  local want=("$@") id w found
  if ((${#want[@]} == 0)) || [[ " ${want[*]} " == *" all "* ]]; then
    printf '%s\n' "${STEP_IDS[@]}"
    return
  fi
  for w in "${want[@]}"; do
    found=0
    for id in "${STEP_IDS[@]}"; do
      if [[ "$id" == "$w" ]]; then found=1; fi
    done
    ((found)) || die "Unknown step '$w'. Steps: ${STEP_IDS[*]}"
  done
  for id in "${STEP_IDS[@]}"; do
    for w in "${want[@]}"; do
      if [[ "$id" == "$w" ]]; then printf '%s\n' "$id"; fi
    done
  done
  return 0
}

# shellcheck disable=SC2034 # STEP_STATE is read by setup.sh
# Runs <id>_check and sets STEP_STATE (DONE/MISSING/BROKEN/DISABLED) and CHECK_LINES.
step_state() {
  local id=$1 rc=0
  if ! step_enabled "$id"; then
    STEP_STATE=DISABLED
    CHECK_LINES=()
    CHECK_WARN=0
    return
  fi
  check_begin
  "${id}_check" || true
  check_state || rc=$?
  case $rc in
    0) STEP_STATE=DONE ;;
    1) STEP_STATE=MISSING ;;
    *) STEP_STATE=BROKEN ;;
  esac
}

state_label() {
  case $1 in
    DONE)
      if ((${CHECK_WARN:-0} > 0)); then
        printf '%s' "${C_GREEN}DONE${C_OFF} ${C_YELLOW}(${CHECK_WARN} warning$( ((CHECK_WARN > 1)) && printf s))${C_OFF}"
      else
        printf '%s' "${C_GREEN}DONE${C_OFF}"
      fi
      ;;
    MISSING) printf '%s' "${C_YELLOW}MISSING${C_OFF}" ;;
    BROKEN) printf '%s' "${C_RED}BROKEN${C_OFF}" ;;
    DISABLED) printf '%s' "${C_DIM}DISABLED${C_OFF}" ;;
  esac
}
