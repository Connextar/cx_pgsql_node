# shellcheck shell=bash
# Object storage (Garage): the apps declared in config/objects/, Garage's admin API, and rclone
# remotes for the local S3 API and the encrypted off-site copy. Used by steps/72-objects.sh,
# lib/backup.sh (the objects backup and its verify) and bin/cx-pgsql (objects …).
#
# obj_each CALLBACK [ARGS...] runs CALLBACK once per app, in a subshell, with these set:
#   OBJ_NAME, OBJ_BUCKETS (space-separated), OBJ_BACKUP (true = in the off-site copy), OBJ_FILE
#
# Keys are named, and their two halves kept as secrets objects-key-<name>-id / -secret. Besides
# one per app there is the server's own, cx-backup: read on every bucket, write only on cx-verify
# (the weekly restore test's scratch bucket) — and on an app's bucket only during a restore.

OBJ_BACKUP_KEY=cx-backup
OBJ_VERIFY_BUCKET=cx-verify

_obj_defaults() { OBJ_NAME='' OBJ_BUCKETS='' OBJ_BACKUP=true; }

_obj_finalize() {
  OBJ_FILE=$1
  [[ -n "$OBJ_NAME" ]] || OBJ_NAME=$(basename "$OBJ_FILE" .env)
  [[ "$OBJ_NAME" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || die "$OBJ_FILE: name '$OBJ_NAME' must be 2–31 lowercase letters, digits and dashes."
  [[ "$OBJ_NAME" == "$OBJ_BACKUP_KEY" ]] && die "$OBJ_FILE: '$OBJ_NAME' is reserved."
  [[ -n "${OBJ_BUCKETS// /}" ]] || die "$OBJ_FILE: OBJ_BUCKETS is empty."
  local b
  for b in $OBJ_BUCKETS; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || die "$OBJ_FILE: bucket '$b' must be 3–63 lowercase letters, digits and dashes."
    [[ "$b" == "$OBJ_VERIFY_BUCKET" ]] && die "$OBJ_FILE: bucket '$b' is reserved."
  done
  export OBJ_NAME OBJ_BUCKETS OBJ_BACKUP OBJ_FILE
}

obj_each() {
  local f
  for f in "$PROJECT_DIR"/config/objects/*.env; do
    [[ -e "$f" ]] || continue
    (
      _obj_defaults
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
      _obj_finalize "$f"
      "$@"
    ) || return 1
  done
}

obj_names() { obj_each sh -c 'printf "%s\n" "$OBJ_NAME"'; }
# Every app's buckets, one per line.
obj_buckets() { obj_each sh -c 'printf "%s\n" $OBJ_BUCKETS'; }
# The buckets in the off-site copy.
obj_backup_buckets() { obj_each sh -c 'case "$OBJ_BACKUP" in true|1|yes|on) printf "%s\n" $OBJ_BUCKETS;; esac'; }
# The app that owns a bucket (empty when none does).
obj_owner_of() { obj_each sh -c 'for b in $OBJ_BUCKETS; do [ "$b" = "$1" ] && printf "%s\n" "$OBJ_NAME"; done; true' sh "$1"; }

# OBJECTS_CAPACITY in bytes, decimal as Garage counts them (40G = 40 000 000 000).
obj_capacity_bytes() {
  local v=${OBJECTS_CAPACITY^^}
  numfmt --from=si "${v%B}"
}

# ─── Garage's admin API (loopback only) ────────────────────────────────────────────
obj_admin_url() { printf 'http://127.0.0.1:%s' "$OBJECTS_ADMIN_PORT"; }

# obj_api METHOD ENDPOINT [JSON] — prints the response body; fails on an HTTP error. The token goes
# to curl on stdin and the body through a root-only file, so neither shows up in `ps` (ImportKey's
# body carries a secret key).
obj_api() {
  local method=$1 endpoint=$2 body=${3:-} tmp="" rc=0
  local args=(-sS --fail-with-body --max-time 30 -K - -X "$method")
  if [[ -n "$body" ]]; then
    tmp=$(mktemp)
    printf '%s' "$body" >"$tmp"
    args+=(-H 'Content-Type: application/json' --data-binary "@$tmp")
  fi
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$(secret_path objects-admin-token)")" |
    curl "${args[@]}" "$(obj_admin_url)/v2/$endpoint" || rc=$?
  [[ -n "$tmp" ]] && rm -f "$tmp"
  return $rc
}

# Garage's own verdict: 200 once the layout is applied and every partition is available.
obj_health_ok() { curl -fsS --max-time 5 -o /dev/null "$(obj_admin_url)/health"; }

obj_node_id() { obj_api GET GetClusterStatus | jq -er '.nodes[0].id'; }

# This node holds the layout's only role, at OBJECTS_CAPACITY, with nothing staged.
obj_layout_ok() {
  obj_api GET GetClusterLayout | jq -e --arg id "$(obj_node_id)" --argjson cap "$(obj_capacity_bytes)" \
    '(.roles | length) == 1 and .roles[0].id == $id and .roles[0].capacity == $cap and (.stagedRoleChanges | length) == 0' >/dev/null
}

obj_layout_apply() {
  local id version
  id=$(obj_node_id)
  obj_api POST UpdateClusterLayout "$(jq -nc --arg id "$id" --argjson cap "$(obj_capacity_bytes)" \
    '{roles: [{id: $id, zone: "dc1", capacity: $cap, tags: []}]}')" >/dev/null
  version=$(obj_api GET GetClusterLayout | jq -er '.version + 1')
  obj_api POST ApplyClusterLayout "$(jq -nc --argjson v "$version" '{version: $v}')" >/dev/null
  info "Garage layout version $version: this node, $OBJECTS_CAPACITY"
}

obj_bucket_id() { obj_api GET "GetBucketInfo?globalAlias=$1" 2>/dev/null | jq -er .id; }
obj_bucket_exists() { obj_bucket_id "$1" >/dev/null; }
obj_bucket_create() {
  obj_bucket_exists "$1" && return 0
  obj_api POST CreateBucket "$(jq -nc --arg b "$1" '{globalAlias: $b}')" >/dev/null
  info "Created bucket $1"
}
# "objects bytes" of one bucket.
obj_bucket_usage() { obj_api GET "GetBucketInfo?globalAlias=$1" | jq -er '"\(.objects // 0) \(.bytes // 0)"'; }

# ─── Keys ──────────────────────────────────────────────────────────────────────────
obj_key_id_secret() { printf 'objects-key-%s-id' "$1"; }
obj_key_secret_secret() { printf 'objects-key-%s-secret' "$1"; }
obj_key_id() { cat "$(secret_path "$(obj_key_id_secret "$1")")"; }

# The key's half secrets are made on this server (Garage's own format: GK + 24 hex, 64 hex) and
# imported, so nothing has to be read back out of Garage's output.
obj_key_exists() {
  secret_exists "$(obj_key_id_secret "$1")" &&
    obj_api GET "GetKeyInfo?id=$(obj_key_id "$1")" 2>/dev/null | jq -e --arg n "$1" '.name == $n and .expired == false' >/dev/null
}
obj_key_ensure() {
  local name=$1 id sk
  id=$(secret_hex "$(obj_key_id_secret "$name")" 12 GK)
  sk=$(secret_hex "$(obj_key_secret_secret "$name")" 32)
  obj_api GET "GetKeyInfo?id=$id" >/dev/null 2>&1 && return 0
  obj_api POST ImportKey "$(jq -nc --arg id "$id" --arg sk "$sk" --arg n "$name" \
    '{accessKeyId: $id, secretAccessKey: $sk, name: $n}')" >/dev/null
  info "Access key for $name imported"
}

# What a key may do, one line per bucket: "<bucket> <r|-><w|-><o|->", sorted.
obj_key_grants() {
  obj_api GET "GetKeyInfo?id=$(obj_key_id "$1")" | jq -r '.buckets[]
    | "\(.globalAliases[0] // .id) \(if .permissions.read then "r" else "-" end)\(if .permissions.write then "w" else "-" end)\(if .permissions.owner then "o" else "-" end)"' | sort
}
# obj_key_set KEY BUCKET r|w|o letters wanted ("rw-", "r--", "---")
obj_key_set() {
  local key=$1 bucket=$2 want=$3 bid kid allow deny
  bid=$(obj_bucket_id "$bucket")
  kid=$(obj_key_id "$key")
  allow=$(jq -nc --arg w "$want" '{read: ($w[0:1] == "r"), write: ($w[1:2] == "w"), owner: ($w[2:3] == "o")}')
  deny=$(jq -nc --arg w "$want" '{read: ($w[0:1] != "r"), write: ($w[1:2] != "w"), owner: ($w[2:3] != "o")}')
  if [[ "$want" != "---" ]]; then
    obj_api POST AllowBucketKey "$(jq -nc --arg b "$bid" --arg k "$kid" --argjson p "$allow" '{bucketId: $b, accessKeyId: $k, permissions: $p}')" >/dev/null
  fi
  obj_api POST DenyBucketKey "$(jq -nc --arg b "$bid" --arg k "$kid" --argjson p "$deny" '{bucketId: $b, accessKeyId: $k, permissions: $p}')" >/dev/null
}
# Bring a key's grants to exactly WANT ("<bucket> <perms>" lines): every other bucket is denied.
obj_key_converge() {
  local key=$1 want=$2 bucket perms
  while read -r bucket perms; do
    [[ -n "$bucket" ]] || continue
    grep_q -E "^$bucket " <<<"$want" || obj_key_set "$key" "$bucket" "---"
  done < <(obj_key_grants "$key")
  while read -r bucket perms; do
    [[ -n "$bucket" ]] && obj_key_set "$key" "$bucket" "$perms"
  done <<<"$want"
}

# What each key should hold. An app: read and write on its own buckets (never owner, which would
# let it change bucket settings). cx-backup: read everywhere, write on its scratch bucket.
obj_app_grants() { local b; for b in $OBJ_BUCKETS; do printf '%s rw-\n' "$b"; done | sort; }
obj_backup_grants() {
  { obj_buckets | sed 's/$/ r--/'; printf '%s rw-\n' "$OBJ_VERIFY_BUCKET"; } | sort
}

# ─── rclone remotes, defined in this shell's environment only ──────────────────────
# "cxobj:" — the local S3 API, as key NAME. Nothing is written to a config file.
obj_rclone_env() {
  local name=$1
  export RCLONE_CONFIG_CXOBJ_TYPE=s3 RCLONE_CONFIG_CXOBJ_PROVIDER=Other \
    RCLONE_CONFIG_CXOBJ_ENDPOINT="http://127.0.0.1:$OBJECTS_S3_PORT" RCLONE_CONFIG_CXOBJ_REGION=garage \
    RCLONE_CONFIG_CXOBJ_FORCE_PATH_STYLE=true RCLONE_CONFIG_CXOBJ_NO_CHECK_BUCKET=true
  RCLONE_CONFIG_CXOBJ_ACCESS_KEY_ID=$(obj_key_id "$name")
  RCLONE_CONFIG_CXOBJ_SECRET_ACCESS_KEY=$(cat "$(secret_path "$(obj_key_secret_secret "$name")")")
  export RCLONE_CONFIG_CXOBJ_ACCESS_KEY_ID RCLONE_CONFIG_CXOBJ_SECRET_ACCESS_KEY
}

# "cxcrypt:" — the encrypted off-site copy, under BACKUP_REMOTE:BACKUP_REMOTE_PATH/objects. File and
# folder names and contents are encrypted with the two server secrets objects-crypt-pass and
# objects-crypt-salt (in the age-encrypted secrets bundle; keep a second copy yourself).
#   live/<bucket>/<key>                    the current objects
#   deleted/<YYYY-MM-DD>/<bucket>/<key>    what was deleted or replaced that day
obj_crypt_env() {
  RCLONE_CONFIG_CXCRYPT_REMOTE="$(remote_dest)/objects"
  export RCLONE_CONFIG_CXCRYPT_TYPE=crypt RCLONE_CONFIG_CXCRYPT_REMOTE \
    RCLONE_CONFIG_CXCRYPT_FILENAME_ENCRYPTION=standard RCLONE_CONFIG_CXCRYPT_DIRECTORY_NAME_ENCRYPTION=true
  RCLONE_CONFIG_CXCRYPT_PASSWORD=$(secret objects-crypt-pass 48 | rclone obscure -)
  RCLONE_CONFIG_CXCRYPT_PASSWORD2=$(secret objects-crypt-salt 48 | rclone obscure -)
  export RCLONE_CONFIG_CXCRYPT_PASSWORD RCLONE_CONFIG_CXCRYPT_PASSWORD2
}

# ─── Restore from the off-site copy ────────────────────────────────────────────────
# obj_restore <bucket> [--deleted YYYY-MM-DD] [key...]   named objects (all of them when none)
# obj_restore --all                                      every backed-up bucket, from live/
# Copies only what is missing or different; never deletes. cx-backup is given write on the bucket
# for the duration and loses it again afterwards, whatever happens.
obj_restore() {
  local all=0 bucket="" date="" keys=()
  while (($#)); do
    case $1 in
      --all) all=1 ;;
      --deleted) date=${2:?--deleted needs a date (YYYY-MM-DD)}; shift ;;
      -*) die "Unknown option $1" ;;
      *) if [[ -z "$bucket" && $all == 0 ]]; then bucket=$1; else keys+=("$1"); fi ;;
    esac
    shift
  done
  ((all)) || [[ -n "$bucket" ]] || die "objects restore <bucket> [--deleted YYYY-MM-DD] [key...] | --all"
  [[ -z "$date" || "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--deleted takes a date: YYYY-MM-DD"
  remote_configured || die "No rclone remote '$BACKUP_REMOTE' configured — nothing to restore from."
  local buckets=()
  if ((all)); then
    mapfile -t buckets < <(obj_backup_buckets)
  else
    [[ -n "$(obj_owner_of "$bucket")" ]] || die "No app in config/objects/ has a bucket '$bucket'."
    buckets=("$bucket")
  fi
  (
    obj_rclone_env "$OBJ_BACKUP_KEY"
    obj_crypt_env
    local b src list
    list=$(mktemp)
    # shellcheck disable=SC2064 # the bucket list is fixed now
    trap "for b in ${buckets[*]}; do obj_key_set '$OBJ_BACKUP_KEY' \"\$b\" r-- || true; done; rm -f '$list'" EXIT
    for b in "${buckets[@]}"; do
      obj_bucket_exists "$b" || obj_bucket_create "$b"
      obj_key_set "$OBJ_BACKUP_KEY" "$b" rw-
      src="cxcrypt:live/$b"
      [[ -n "$date" ]] && src="cxcrypt:deleted/$date/$b"
      # An empty bucket has no folder in the copy.
      if ! rclone_x lsf --max-depth 1 "$src" >/dev/null 2>&1; then
        info "Nothing for $b in ${src#cxcrypt:}"
        continue
      fi
      if ((${#keys[@]})); then
        printf '%s\n' "${keys[@]}" >"$list"
        info "Restoring ${#keys[@]} object(s) into $b from ${src#cxcrypt:}"
        rclone_x copy --files-from "$list" "$src" "cxobj:$b"
      else
        info "Restoring bucket $b from ${src#cxcrypt:}"
        rclone_x copy --stats-one-line --stats 30s "$src" "cxobj:$b"
      fi
      ok "Bucket $b restored ($(obj_bucket_usage "$b" | awk '{print $1}') objects now)"
    done
  ) || return 1
  # What came back from deleted/ is live again, so the off-site copy is brought up to date now
  # rather than at the next hourly run (until then the weekly verify would find it missing there).
  info "Refreshing the off-site copy"
  (backup_objects) || warn "The off-site copy wasn't refreshed (cx-pgsql backup objects to retry)."
}
