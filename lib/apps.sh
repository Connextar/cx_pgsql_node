# shellcheck shell=bash
# App containers: small services (first: cx-support's voice relay) that run beside the database
# stack, each built from its own git repository and served by nginx on a name of its own, with a
# Let's Encrypt certificate. One file per app in config/apps/ (see config/apps/example.env.sample).
# Used by steps/95-apps.sh, steps/60-nginx.sh, lib/tls.sh and bin/cx-pgsql (app …).
#
# app_each CALLBACK [ARGS...] runs CALLBACK once per app, in a subshell, with APP_* set (below).
#
# What each app gets on the server:
#   $APPS_DIR/<name>/src           a shallow checkout of APP_REF (root only), and .cx-source naming it
#   $APPS_DIR/<name>/compose.yml   its container: read-only, no capabilities, its own network (not the
#                                  database's), its port on loopback only
#   $APPS_DIR/<name>/app.env       APP_ENV's plain settings
#   $APPS_DIR/<name>/secrets.env   APP_SECRETS' values (0600), from secrets app-<name>-<VAR>
#   secret app-<name>-deploy-key   a read-only deploy key for the repository, when it is reached over SSH
#
# Nothing here deploys by itself: `setup.sh apply` builds the commit already checked out (and checks
# out APP_REF only when there is none, or APP_REF/APP_REPO changed). A new commit goes live with
# `cx-pgsql app deploy <name>`, so a server apply never restarts an app (and drops its calls) unasked.

# Every app runs as this uid (none mounts anything from the host).
APP_UID=10010
# GitHub's SSH host key (https://api.github.com/meta), pinned: other hosts are trusted on first use.
APP_GITHUB_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'

_app_defaults() {
  APP_NAME='' APP_FQDN='' APP_REPO='' APP_REF=main APP_DOCKERFILE=Dockerfile APP_CONTEXT=.
  APP_PORT='' APP_CONTAINER_PORT='' APP_HEALTH_PATH=/healthz APP_WEBSOCKET=false
  APP_MEMORY_LIMIT=512m APP_CPUS=1.0 APP_SECRETS='' APP_ENV='' APP_RATE_LIMIT=10r/s APP_RATE_BURST=40
}

_app_finalize() {
  APP_FILE=$1
  [[ -n "$APP_NAME" ]] || APP_NAME=$(basename "$APP_FILE" .env)
  [[ "$APP_NAME" =~ ^[a-z0-9][a-z0-9-]{1,30}$ ]] || die "$APP_FILE: name '$APP_NAME' must be 2–31 lowercase letters, digits and dashes."
  [[ "$APP_FQDN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$APP_FQDN" == *.* ]] || die "$APP_FILE: APP_FQDN '$APP_FQDN' isn't a host name."
  [[ -n "$APP_REPO" ]] || die "$APP_FILE: APP_REPO is empty."
  [[ "$APP_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "$APP_FILE: APP_REF '$APP_REF' isn't a branch or tag name."
  local p
  for p in APP_PORT APP_CONTAINER_PORT; do
    [[ "${!p}" =~ ^[0-9]+$ ]] && ((${!p} >= 1024 && ${!p} <= 65535)) || die "$APP_FILE: $p must be a port from 1024 to 65535."
  done
  [[ "$APP_HEALTH_PATH" == /* ]] || die "$APP_FILE: APP_HEALTH_PATH must start with /."
  [[ "$APP_DOCKERFILE" != /* && "$APP_DOCKERFILE" != *..* && "$APP_CONTEXT" != /* && "$APP_CONTEXT" != *..* ]] ||
    die "$APP_FILE: APP_DOCKERFILE and APP_CONTEXT are paths inside the repository."
  for p in $APP_SECRETS; do
    [[ "$p" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$APP_FILE: secret name '$p' must be UPPER_CASE."
  done
  APP_DIR="$APPS_DIR/$APP_NAME"
  APP_CONTAINER="cx-app-$APP_NAME"
  APP_PROJECT="cx-app-$APP_NAME"
  APP_IMAGE_REPO="cx-app/$APP_NAME"
  export APP_NAME APP_FQDN APP_REPO APP_REF APP_DOCKERFILE APP_CONTEXT APP_PORT APP_CONTAINER_PORT \
    APP_HEALTH_PATH APP_WEBSOCKET APP_MEMORY_LIMIT APP_CPUS APP_SECRETS APP_ENV APP_RATE_LIMIT APP_RATE_BURST \
    APP_FILE APP_DIR APP_CONTAINER APP_PROJECT APP_IMAGE_REPO
}

app_each() {
  local f
  for f in "$PROJECT_DIR"/config/apps/*.env; do
    [[ -e "$f" ]] || continue
    (
      _app_defaults
      set -a
      # shellcheck source=/dev/null
      source "$f"
      set +a
      _app_finalize "$f"
      "$@"
    ) || return 1
  done
}

# Run CALLBACK for one app, by name.
app_one() {
  local name=$1
  shift
  [[ " $(app_names | tr '\n' ' ') " == *" $name "* ]] || die "No app '$name' in config/apps/ (have: $(app_names | tr '\n' ' '))."
  app_each _app_if_named "$name" "$@"
}
_app_if_named() {
  local name=$1
  shift
  [[ "$APP_NAME" == "$name" ]] || return 0
  "$@"
}

app_names() { app_each sh -c 'printf "%s\n" "$APP_NAME"'; }
app_fqdns() { app_each sh -c 'printf "%s\n" "$APP_FQDN"'; }
apps_any() { [[ -n "$(app_names 2>/dev/null)" ]]; }
apps_any_websocket() { [[ -n "$(app_each sh -c 'case "$APP_WEBSOCKET" in true|1|yes|on) echo y;; esac')" ]]; }

# Names, host names and ports must be unique, and clear of everything else this server serves.
_app_claims() { printf 'port %s\nhost name %s\n' "$APP_PORT" "$APP_FQDN"; }
_app_clashes_with_server() {
  local ports=" $SSH_PORT $PGBOUNCER_PUBLIC_PORT $PG_DIRECT_PORT $HEALTH_PORT $N8N_PORT $OBJECTS_S3_PORT $OBJECTS_ADMIN_PORT "
  local names=" $SERVER_FQDN $N8N_FQDN $OBJECTS_FQDN "
  [[ "$ports" == *" $APP_PORT "* ]] && printf 'port %s (%s; the server uses it)\n' "$APP_PORT" "$APP_NAME"
  [[ "$names" == *" $APP_FQDN "* ]] && printf 'host name %s (%s; the server uses it)\n' "$APP_FQDN" "$APP_NAME"
  return 0
}
# One line per clash; nothing when there is none.
apps_conflicts() {
  app_each _app_claims | sort | uniq -d | sed 's/$/ (two apps)/'
  app_each _app_clashes_with_server
}

# ─── Secrets and the deploy key ────────────────────────────────────────────────────
app_secret_name() { printf 'app-%s-%s' "$1" "$2"; }
app_key_secret() { printf 'app-%s-deploy-key' "$1"; }
app_known_hosts() { printf '%s/app-known-hosts' "$SECRETS_DIR"; }

# SSH (git@host:owner/repo, ssh://…) needs the deploy key; https:// and local paths don't.
app_repo_is_ssh() { [[ "$APP_REPO" == ssh://* || "$APP_REPO" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+: ]]; }

app_key_ensure() {
  local path
  path=$(secret_path "$(app_key_secret "$APP_NAME")")
  if [[ ! -s "$path" ]]; then
    install -d -m 0700 "$SECRETS_DIR"
    ssh-keygen -q -t ed25519 -N '' -C "$SERVER_HOSTNAME $APP_NAME (read-only deploy key)" -f "$path"
    _log "SECRET generated $(app_key_secret "$APP_NAME")"
  fi
  chmod 0600 "$path"
  grep_q -xF "$APP_GITHUB_HOST_KEY" "$(app_known_hosts)" 2>/dev/null || {
    install -d -m 0700 "$SECRETS_DIR"
    printf '%s\n' "$APP_GITHUB_HOST_KEY" >>"$(app_known_hosts)"
    chmod 0600 "$(app_known_hosts)"
  }
}
app_key_public() { cat "$(secret_path "$(app_key_secret "$APP_NAME")").pub"; }

# git, with the app's deploy key when the repository is reached over SSH.
app_git() {
  if app_repo_is_ssh; then
    GIT_SSH_COMMAND="ssh -i $(secret_path "$(app_key_secret "$APP_NAME")") -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$(app_known_hosts) -o StrictHostKeyChecking=accept-new" \
      GIT_TERMINAL_PROMPT=0 git "$@"
  else
    GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

app_missing_secrets() {
  local v
  for v in $APP_SECRETS; do secret_exists "$(app_secret_name "$APP_NAME" "$v")" || printf '%s\n' "$v"; done
}

# One secret's value, from stdin: one line, not empty.
app_secret_set() {
  local var=$1 value rest=""
  [[ " $APP_SECRETS " == *" $var "* ]] || die "$var isn't one of $APP_NAME's secrets (APP_SECRETS: $APP_SECRETS)."
  IFS= read -r value || true
  IFS= read -r -d '' rest || true
  value=${value%$'\r'}
  [[ -n "$value" ]] || die "No value for $var on stdin."
  [[ -z "${rest//[$'\r\n']/}" ]] || die "$var must be one line."
  # secrets.env quotes each value in single quotes, so Compose takes it literally ($ included).
  [[ "$value" != *"'"* ]] || die "$var can't contain a single quote (')."
  install -d -m 0700 "$SECRETS_DIR"
  (umask 077 && printf '%s' "$value" >"$(secret_path "$(app_secret_name "$APP_NAME" "$var")")")
  _log "SECRET set $(app_secret_name "$APP_NAME" "$var")"
}

# ─── The checkout ──────────────────────────────────────────────────────────────────
app_src() { printf '%s/src' "$APP_DIR"; }
# What the checkout was made from: "<repo> <ref>". A change in either means a new checkout.
app_source_line() { printf '%s %s\n' "$APP_REPO" "$APP_REF"; }
app_checked_out() {
  [[ -d "$(app_src)/.git" ]] && [[ "$(cat "$APP_DIR/.cx-source" 2>/dev/null)" == "$(app_source_line)" ]]
}
app_commit() { git -C "$(app_src)" rev-parse HEAD 2>/dev/null; }
app_short() { local c; c=$(app_commit) && printf '%s' "${c:0:12}"; }
app_image() { printf '%s:%s' "$APP_IMAGE_REPO" "$(app_short)"; }
# The newest commit of APP_REF upstream (empty when the repository can't be reached).
app_remote_commit() {
  app_git ls-remote "$APP_REPO" "refs/heads/$APP_REF" "refs/tags/$APP_REF^{}" "refs/tags/$APP_REF" 2>/dev/null |
    awk 'NR == 1 || /\^\{\}$/ { c = $1 } END { print c }'
}
app_at_upstream() {
  local remote
  remote=$(app_remote_commit)
  [[ -n "$remote" && "$remote" == "$(app_commit)" ]]
}

# A fresh shallow checkout of APP_REF, swapped in when complete.
app_fetch() {
  local src new
  src=$(app_src)
  new="$APP_DIR/src.new"
  rm -rf "$new"
  install -d -m 0750 "$APP_DIR"
  app_repo_is_ssh && app_key_ensure
  info "$APP_NAME: fetching $APP_REF from $APP_REPO"
  if ! app_git clone --quiet --depth 1 --branch "$APP_REF" --no-tags "$APP_REPO" "$new" 2>"$APP_DIR/fetch.log"; then
    sed 's/^/    /' "$APP_DIR/fetch.log" >&2
    rm -rf "$new"
    if app_repo_is_ssh && grep_q -iE 'permission denied|could not read from remote|repository not found' "$APP_DIR/fetch.log"; then
      warn "$APP_NAME: the server can't read $APP_REPO. Add its deploy key there, read-only (GitHub: the repository's"
      warn "  Settings → Deploy keys), or from your machine: bin/remote.sh app-key $APP_NAME --github"
      warn "  $(app_key_public)"
    fi
    return 1
  fi
  rm -rf "$src"
  mv "$new" "$src"
  app_source_line >"$APP_DIR/.cx-source"
  # Modes as committed: the build copies them into the image, where the app runs as another uid.
  # APP_DIR (0750, root) is what keeps the checkout private.
  info "$APP_NAME: checked out $(app_short) ($(git -C "$src" log -1 --format='%s' | cut -c1-70))"
}

# ─── Generated files ───────────────────────────────────────────────────────────────
app_websocket() { is_true "$APP_WEBSOCKET"; }

_app_compose() {
  cat <<EOF
# Generated by CX_PGSQL_Node_1 setup from config/apps/$APP_NAME.env — do not edit.
name: $APP_PROJECT
services:
  app:
    image: $(app_image)
    container_name: $APP_CONTAINER
    restart: unless-stopped
    # tini as PID 1: a stop reaches the app at once rather than after the grace period.
    init: true
    user: "$APP_UID:$APP_UID"
    read_only: true
    tmpfs:
      - /tmp:size=64m
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    env_file: [app.env, secrets.env]
    environment:
      GIT_COMMIT: "$(app_commit)"
    ports:
      - "127.0.0.1:$APP_PORT:$APP_CONTAINER_PORT"
    stop_grace_period: 20s
    deploy:
      resources:
        limits:
          memory: $APP_MEMORY_LIMIT
          cpus: "$APP_CPUS"
          pids: 256
    networks: [app]
# Its own network: no route to Postgres, PgBouncer or the health service inside Docker.
networks:
  app:
    name: $APP_PROJECT
EOF
}

_app_env_file() {
  printf '# Generated by CX_PGSQL_Node_1 setup from config/apps/%s.env (APP_ENV) — do not edit.\n' "$APP_NAME"
  printf '%s\n' "$APP_ENV" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true
}

_app_secrets_file() {
  local v
  printf '# Generated by CX_PGSQL_Node_1 setup from secrets app-%s-* — do not edit.\n' "$APP_NAME"
  for v in $APP_SECRETS; do
    secret_exists "$(app_secret_name "$APP_NAME" "$v")" || continue
    printf "%s='%s'\n" "$v" "$(cat "$(secret_path "$(app_secret_name "$APP_NAME" "$v")")")"
  done
}

# "file|mode|generator"
_app_files() {
  cat <<EOF
compose.yml|0644|_app_compose
app.env|0644|_app_env_file
secrets.env|0600|_app_secrets_file
EOF
}

app_write_files() {
  local file mode gen
  install -d -m 0750 "$APP_DIR"
  while IFS='|' read -r file mode gen; do
    "$gen" | write_if_changed "$APP_DIR/$file" "$mode" && info "$APP_NAME: wrote $file"
  done < <(_app_files)
  return 0
}

# ─── The container ─────────────────────────────────────────────────────────────────
app_compose() { (cd "$APP_DIR" && docker compose -p "$APP_PROJECT" "$@"); }

app_image_built() { docker image inspect "$(app_image)" >/dev/null 2>&1; }

app_build() {
  local src
  src=$(app_src)
  [[ -f "$src/$APP_DOCKERFILE" ]] || { err "$APP_NAME: no $APP_DOCKERFILE in $APP_REPO at $APP_REF."; return 1; }
  info "$APP_NAME: building $(app_image) (the log: $APP_DIR/build.log)"
  if ! docker build --pull -q -t "$(app_image)" --build-arg "GIT_COMMIT=$(app_commit)" --label "cx.commit=$(app_commit)" \
    -f "$src/$APP_DOCKERFILE" "$src/$APP_CONTEXT" >"$APP_DIR/build.log" 2>&1; then
    tail -30 "$APP_DIR/build.log" >&2
    err "$APP_NAME: the image didn't build (above)."
    return 1
  fi
}

app_running() { _apps_container_healthy "$APP_CONTAINER"; }
_apps_container_healthy() {
  local state
  state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null) || return 1
  [[ "$state" == "running healthy" || "$state" == "running none" ]]
}
app_up_to_date() {
  local want have
  [[ -f "$APP_DIR/compose.yml" ]] || return 1
  want=$(app_compose config --hash app 2>/dev/null | awk '{print $2}') || return 1
  have=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$APP_CONTAINER" 2>/dev/null) || return 1
  [[ -n "$want" && "$have" == "$want" ]]
}

# The whole public path, as a client would use it: TLS at nginx on APP_FQDN, then the app. Resolved to
# this machine, so it works before DNS does (and skips verification while the certificate is self-signed).
app_public_ok() {
  local insecure=()
  tls_is_self_signed "$APP_FQDN" && insecure=(-k)
  curl -fsS -o /dev/null --max-time 10 "${insecure[@]}" --resolve "$APP_FQDN:443:127.0.0.1" "https://$APP_FQDN$APP_HEALTH_PATH"
}
app_loopback_ok() { curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$APP_PORT$APP_HEALTH_PATH"; }

app_start() {
  local previous
  previous=$(docker inspect -f '{{.Config.Image}}' "$APP_CONTAINER" 2>/dev/null || true)
  info "$APP_NAME: starting $(app_image)"
  if ! app_compose up -d --wait --wait-timeout 120 --remove-orphans; then
    app_compose logs --tail 40 >&2 || true
    err "$APP_NAME didn't become healthy (logs above)."
    return 1
  fi
  [[ -n "$previous" && "$previous" != "$(app_image)" ]] && printf '%s\n' "$previous" >"$APP_DIR/.previous-image"
  app_prune_images
}

# Keep the running image and the one before it (for a quick way back); delete older builds.
app_prune_images() {
  local keep img
  keep=" $(app_image) $(cat "$APP_DIR/.previous-image" 2>/dev/null) "
  for img in $(docker image ls "$APP_IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}'); do
    [[ "$keep" == *" $img "* ]] || docker image rm "$img" >/dev/null 2>&1 || true
  done
  docker image prune -f >/dev/null 2>&1 || true
}

# Containers of apps no longer in config/apps/.
apps_orphans() {
  local configured c
  configured=" $(app_names 2>/dev/null | sed 's/^/cx-app-/' | tr '\n' ' ') "
  for c in $(docker ps -a --format '{{.Names}}' --filter 'name=^cx-app-' 2>/dev/null); do
    [[ "$configured" == *" $c "* ]] || printf '%s\n' "${c#cx-app-}"
  done
}
