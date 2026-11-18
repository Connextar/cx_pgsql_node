# shellcheck shell=bash
# App containers from config/apps/*.env (lib/apps.sh): each built from its repository and run beside
# the database stack, behind nginx on its own host name (steps/60-nginx.sh, lib/tls.sh). Off when
# config/apps/ holds no app. Last on purpose: an app waiting for its secrets or its deploy key never
# holds up the steps the database needs.

apps_describe() { echo "app containers from config/apps/ ($(app_names 2>/dev/null | tr '\n' ' ')) behind nginx"; }
apps_enabled() { apps_any; }

# ─── Checks ────────────────────────────────────────────────────────────────────────
_apps_check_one() {
  check_begin
  local v missing
  chk "$APP_NAME: $APP_REPO at $APP_REF checked out" app_checked_out
  if app_repo_is_ssh && ! secret_exists "$(app_key_secret "$APP_NAME")"; then
    chk "$APP_NAME: deploy key for $APP_REPO" false
  fi
  missing=$(app_missing_secrets | tr '\n' ' ')
  for v in $APP_SECRETS; do chk "$APP_NAME: secret $v" secret_exists "$(app_secret_name "$APP_NAME" "$v")"; done
  [[ -n "${missing// /}" ]] && chk_note "set with: bin/remote.sh app-secrets $APP_NAME   (from your machine)"
  if app_checked_out; then
    chk_note "$APP_NAME: commit $(app_short) — $(git -C "$(app_src)" log -1 --format='%s' 2>/dev/null | cut -c1-60)"
    local file mode gen
    while IFS='|' read -r file mode gen; do
      chk_render "$APP_NAME: $file" "$APP_DIR/$file" "$gen"
    done < <(_app_files)
    app_has_static && chk "$APP_NAME: static files from $APP_STATIC published in $(app_static_dir)" app_static_ok
    chk "$APP_NAME: image $(app_image) built" app_image_built
    chk "$APP_NAME: container running and healthy" app_running
    chk "$APP_NAME: container matches its configuration" app_up_to_date
    chk "$APP_NAME: answers on 127.0.0.1:$APP_PORT$APP_HEALTH_PATH" app_loopback_ok
    chk "$APP_NAME: answers on https://$APP_FQDN$APP_HEALTH_PATH (nginx)" app_public_ok
    chk_soft "$APP_NAME: the newest commit on $APP_REF (else: bin/remote.sh app-deploy $APP_NAME)" app_at_upstream
  fi
  # Hand the results back to the parent shell (this runs in app_each's subshell).
  printf '%s\t%s\t%s\t' "$CHECK_PASS" "$CHECK_FAIL" "$CHECK_WARN"
  printf '%s\x1f' "${CHECK_LINES[@]}"
  printf '\n'
}

_apps_check_all() {
  local pass fail warn lines l IFS
  while IFS=$'\t' read -r pass fail warn lines; do
    CHECK_PASS=$((CHECK_PASS + pass))
    CHECK_FAIL=$((CHECK_FAIL + fail))
    CHECK_WARN=$((CHECK_WARN + warn))
    IFS=$'\x1f'
    for l in $lines; do [[ -n "$l" ]] && CHECK_LINES+=("$l"); done
    unset IFS
  done < <(app_each _apps_check_one)
}

apps_check() {
  local clashes orphan
  clashes=$(apps_conflicts)
  chk "no app's port or host name clashes${clashes:+: $(printf '%s' "$clashes" | tr '\n' ';')}" test -z "$clashes"
  chk "docker available" command -v docker
  _apps_check_all
  for orphan in $(apps_orphans); do
    chk_note "container cx-app-$orphan has no config/apps/$orphan.env any more: cx-pgsql app remove $orphan --yes"
  done
  return 0
}

# ─── Apply ─────────────────────────────────────────────────────────────────────────
# One app. Problems that only the owner can fix (no deploy key on the repository yet, a secret not
# set) are reported and the app left as it is: the step stays unfinished and says why.
_apps_apply_one() {
  local missing
  if ! app_checked_out; then
    app_fetch || return 0
  elif [[ ! -f "$(app_src)/$APP_DOCKERFILE" ]] && ! app_image_built; then
    # A checkout that can't be built (made before the Dockerfile reached APP_REF) is no deploy to keep: fetch again.
    info "$APP_NAME: $(app_short) has no $APP_DOCKERFILE — fetching $APP_REF again"
    app_fetch || return 0
  fi
  # Before the secrets: the static files need none (the fallback answers even before the app first runs),
  # and none goes into the image, so setting them then only starts it.
  if app_has_static && ! app_static_ok; then app_static_publish; fi
  app_image_built || app_build || return 0
  missing=$(app_missing_secrets | tr '\n' ' ')
  if [[ -n "${missing// /}" ]]; then
    warn "$APP_NAME: waiting for secret(s) ${missing% } — from your machine: bin/remote.sh app-secrets $APP_NAME"
    return 0
  fi
  app_write_files
  app_running && app_up_to_date && return 0
  app_start || return 0
}

apps_apply() {
  ensure_pkgs git curl
  command -v docker >/dev/null || die "Apply the docker step first."
  local clashes
  clashes=$(apps_conflicts)
  [[ -z "$clashes" ]] || die "config/apps/: $(printf '%s' "$clashes" | tr '\n' ';')"
  install -d -m 0750 "$APPS_DIR"
  app_each _apps_apply_one
}

_apps_teardown_one() {
  [[ -f "$APP_DIR/compose.yml" ]] && { app_compose down --remove-orphans || true; }
  docker image ls "$APP_IMAGE_REPO" --format '{{.Repository}}:{{.Tag}}' | xargs -r docker image rm >/dev/null 2>&1 || true
  if ((PURGE)); then
    rm -rf "${APP_DIR:?}" "$(app_static_dir)"
    info "$APP_NAME: removed, with its checkout. Its secrets stay under $SECRETS_DIR (app-$APP_NAME-*)."
  else
    info "$APP_NAME: stopped and removed. The checkout in $APP_DIR is kept (--purge deletes it)."
  fi
}
apps_teardown() { app_each _apps_teardown_one; }
