# shellcheck shell=bash
# nginx + certbot: HTTPS for the health endpoint (and n8n), ACME challenges, and a default
# server that refuses names it doesn't serve.

NGINX_SITES=/etc/nginx/sites-available
NGINX_ENABLED=/etc/nginx/sites-enabled

nginx_describe() { echo "nginx: https://$SERVER_FQDN/healthz|status|metrics → health service$(is_true "$ENABLE_OBJECTS" && printf '; https://%s → object store' "$OBJECTS_FQDN")$(apps_any && printf '; %s → apps' "$(app_fqdns | tr '\n' ' ' | sed 's/ $//')"); certbot"; }

_nginx_common() {
  cat <<'EOF'
# Managed by CX_PGSQL_Node_1 setup (steps/60-nginx.sh).
# server_tokens and ssl_protocols are set per server: Debian's nginx.conf sets them in this (http)
# context on some releases (13 does both), and a second one here would be a duplicate.
# The health endpoint is polled, not browsed: 60 a minute per address is plenty.
limit_req_zone $binary_remote_addr zone=cx_health:10m rate=60r/m;
limit_req_zone $binary_remote_addr zone=cx_maintenance:10m rate=600r/m;
limit_req_status 429;
ssl_session_cache shared:cx_ssl:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
EOF
  # The object store's own limit (per address; Vercel's functions share theirs, so it's generous).
  if is_true "$ENABLE_OBJECTS"; then
    printf 'limit_req_zone $binary_remote_addr zone=cx_objects:10m rate=%s;\n' "$OBJECTS_RATE_LIMIT"
  fi
  # The apps in config/apps/: a request limit each, and the Connection header a WebSocket upgrade needs.
  if apps_any; then
    app_each _nginx_app_zone
    if apps_any_websocket; then
      printf 'map $http_upgrade $cx_connection_upgrade {\n\tdefault upgrade;\n\t"" close;\n}\n'
    fi
  fi
  return 0
}

_nginx_default() {
  cat <<EOF
# Managed by CX_PGSQL_Node_1 setup. Requests for any other name are dropped.
server {
	listen 80 default_server;
	listen [::]:80 default_server;
	server_name _;
	server_tokens off;
	location /.well-known/acme-challenge/ { root $WEBROOT; }
	location / { return 444; }
}
server {
	listen 443 ssl default_server;
	listen [::]:443 ssl default_server;
	server_name _;
	server_tokens off;
	ssl_reject_handshake on;
}
EOF
}

_nginx_tls_lines() {
  local dir
  dir=$(tls_dir_for "$1")
  printf '\tssl_certificate %s/fullchain.pem;\n\tssl_certificate_key %s/privkey.pem;\n' "$dir" "$dir"
  printf '\tssl_protocols TLSv1.2 TLSv1.3;\n\tserver_tokens off;\n'
  printf '\tadd_header Strict-Transport-Security "max-age=31536000" always;\n'
  printf '\tadd_header X-Content-Type-Options nosniff always;\n'
}

_nginx_http_block() {
  cat <<EOF
server {
	listen 80;
	listen [::]:80;
	server_name $1;
	server_tokens off;
	location /.well-known/acme-challenge/ { root $WEBROOT; }
	location / { return 301 https://\$host\$request_uri; }
}
EOF
}

_nginx_site() {
  printf '# Managed by CX_PGSQL_Node_1 setup (steps/60-nginx.sh).\n'
  _nginx_http_block "$SERVER_FQDN"
  cat <<EOF
server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name $SERVER_FQDN;
$(_nginx_tls_lines "$SERVER_FQDN")
	access_log /var/log/nginx/cx-health.access.log;

	# Every app on this server reads it, from shared egress addresses (Vercel's): a zone of its own.
	location = /maintenance.json {
		limit_req zone=cx_maintenance burst=120 nodelay;
		proxy_pass http://127.0.0.1:$HEALTH_PORT;
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_read_timeout 10s;
	}
	location ~ ^/(healthz|status|metrics)\$ {
		limit_req zone=cx_health burst=30 nodelay;
		proxy_pass http://127.0.0.1:$HEALTH_PORT;
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_read_timeout 30s;
	}
	location / { return 404; }
}
EOF
}

_nginx_n8n_site() {
  printf '# Managed by CX_PGSQL_Node_1 setup (steps/60-nginx.sh).\n'
  _nginx_http_block "$N8N_FQDN"
  cat <<EOF
server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name $N8N_FQDN;
$(_nginx_tls_lines "$N8N_FQDN")
	client_max_body_size 16m;

	location / {
		proxy_pass http://127.0.0.1:$N8N_PORT;
		proxy_http_version 1.1;
		proxy_set_header Upgrade \$http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_buffering off;
		proxy_read_timeout 300s;
	}
}
EOF
}

# The S3 API. The request goes to Garage exactly as it came (no URI in proxy_pass, the Host header
# kept): both are part of the signature it checks. Bodies stream through in both directions.
_nginx_objects_site() {
  printf '# Managed by CX_PGSQL_Node_1 setup (steps/60-nginx.sh).\n'
  _nginx_http_block "$OBJECTS_FQDN"
  cat <<EOF
server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name $OBJECTS_FQDN;
$(_nginx_tls_lines "$OBJECTS_FQDN")
	access_log /var/log/nginx/cx-objects.access.log;
	client_max_body_size $OBJECTS_MAX_BODY;

	location / {
		limit_req zone=cx_objects burst=$OBJECTS_RATE_BURST nodelay;
		proxy_pass http://127.0.0.1:$OBJECTS_S3_PORT;
		proxy_http_version 1.1;
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_set_header Connection "";
		proxy_request_buffering off;
		proxy_buffering off;
		proxy_read_timeout 300s;
		proxy_send_timeout 300s;
	}
}
EOF
}

# An app from config/apps/ (lib/apps.sh): TLS here, then its container on loopback. A WebSocket app
# keeps a connection up to an hour (a call through the voice relay lasts no longer).
_nginx_app_zone_name() { printf 'cx_app_%s' "${APP_NAME//-/_}"; }
_nginx_app_zone() { printf 'limit_req_zone $binary_remote_addr zone=%s:10m rate=%s;\n' "$(_nginx_app_zone_name)" "$APP_RATE_LIMIT"; }
_nginx_app_file() { printf 'cx-app-%s.conf' "$APP_NAME"; }
_nginx_app_site() {
  local timeout=60s
  app_websocket && timeout=3600s
  printf '# Managed by CX_PGSQL_Node_1 setup (steps/60-nginx.sh) from config/apps/%s.env.\n' "$APP_NAME"
  _nginx_http_block "$APP_FQDN"
  cat <<EOF
server {
	listen 443 ssl;
	listen [::]:443 ssl;
	server_name $APP_FQDN;
$(_nginx_tls_lines "$APP_FQDN")
	access_log /var/log/nginx/cx-app-$APP_NAME.access.log;
	client_max_body_size 1m;

EOF
  if app_has_static; then
    # Its static files first, straight from disk (they answer when the app is down), then the app.
    cat <<EOF
	root $(app_static_dir);
	location / {
		limit_req zone=$(_nginx_app_zone_name) burst=$APP_RATE_BURST nodelay;
		try_files \$uri @app;
		# A file answers a POST too (Twilio may ask either way): nginx's 405 becomes the file, fetched as GET.
		error_page 405 =200 \$uri;
	}
	# Reached from location / only, whose request limit has already counted the request.
	location @app {
EOF
  else
    printf '\tlocation / {\n\t\tlimit_req zone=%s burst=%s nodelay;\n' "$(_nginx_app_zone_name)" "$APP_RATE_BURST"
  fi
  cat <<EOF
		proxy_pass http://127.0.0.1:$APP_PORT;
		proxy_http_version 1.1;
EOF
  if app_websocket; then
    printf '\t\tproxy_set_header Upgrade $http_upgrade;\n\t\tproxy_set_header Connection $cx_connection_upgrade;\n\t\tproxy_buffering off;\n'
  else
    printf '\t\tproxy_set_header Connection "";\n'
  fi
  cat <<EOF
		proxy_set_header Host \$host;
		proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto https;
		proxy_read_timeout $timeout;
		proxy_send_timeout $timeout;
	}
}
EOF
}
# One app's items, counted from zero and handed back to the parent shell (app_each runs a subshell).
_nginx_app_check() {
  check_begin
  chk_render "site $APP_FQDN ($APP_NAME)" "$NGINX_SITES/$(_nginx_app_file)" _nginx_app_site
  chk "site $APP_FQDN enabled" _nginx_linked "$(_nginx_app_file)"
  printf '%s\t%s\t' "$CHECK_PASS" "$CHECK_FAIL"
  printf '%s\x1f' "${CHECK_LINES[@]}"
  printf '\n'
}
_nginx_apps_check() {
  local pass fail lines l IFS
  while IFS=$'\t' read -r pass fail lines; do
    CHECK_PASS=$((CHECK_PASS + pass))
    CHECK_FAIL=$((CHECK_FAIL + fail))
    IFS=$'\x1f'
    for l in $lines; do [[ -n "$l" ]] && CHECK_LINES+=("$l"); done
    unset IFS
  done < <(app_each _nginx_app_check)
}
_nginx_app_apply() {
  _nginx_app_site | write_if_changed "$NGINX_SITES/$(_nginx_app_file)" || true
  _nginx_enable "$(_nginx_app_file)"
}
# Sites of apps no longer in config/apps/.
_nginx_stale_app_sites() {
  local want f
  want=" $(app_names 2>/dev/null | sed 's/^/cx-app-/; s/$/.conf/' | tr '\n' ' ') "
  for f in "$NGINX_SITES"/cx-app-*.conf "$NGINX_ENABLED"/cx-app-*.conf; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "$want" == *" ${f##*/} "* ]] || printf '%s\n' "$f"
  done
}

_nginx_linked() { [[ "$(readlink -f "$NGINX_ENABLED/$1")" == "$NGINX_SITES/$1" ]]; }

nginx_check() {
  chk "nginx and certbot installed" pkgs_installed nginx certbot
  chk_render "conf.d/00-cx.conf" /etc/nginx/conf.d/00-cx.conf _nginx_common
  chk_render "default server (refuses unknown names)" "$NGINX_SITES/00-cx-default.conf" _nginx_default
  chk "default server enabled, Debian's default site off" sh -c "[ -L '$NGINX_ENABLED/00-cx-default.conf' ] && [ ! -e '$NGINX_ENABLED/default' ]"
  chk_render "site $SERVER_FQDN" "$NGINX_SITES/$SERVER_FQDN.conf" _nginx_site
  chk "site $SERVER_FQDN enabled" _nginx_linked "$SERVER_FQDN.conf"
  if is_true "$ENABLE_N8N"; then
    chk_render "site $N8N_FQDN (n8n)" "$NGINX_SITES/$N8N_FQDN.conf" _nginx_n8n_site
    chk "site $N8N_FQDN enabled" _nginx_linked "$N8N_FQDN.conf"
  fi
  if is_true "$ENABLE_OBJECTS"; then
    chk_render "site $OBJECTS_FQDN (object store)" "$NGINX_SITES/$OBJECTS_FQDN.conf" _nginx_objects_site
    chk "site $OBJECTS_FQDN enabled" _nginx_linked "$OBJECTS_FQDN.conf"
  fi
  apps_any && _nginx_apps_check
  chk "no site left for an app no longer in config/apps/" test -z "$(_nginx_stale_app_sites)"
  chk "nginx -t" nginx -t -q
  chk "nginx running and enabled" sh -c 'systemctl is-active --quiet nginx && systemctl is-enabled --quiet nginx'
}

_nginx_enable() {
  ln -sfn "$NGINX_SITES/$1" "$NGINX_ENABLED/$1"
}

nginx_apply() {
  ensure_pkgs nginx certbot
  install -d -m 0755 "$WEBROOT"
  local fqdn
  for fqdn in $(tls_domains); do tls_ensure_placeholder "$fqdn"; done

  _nginx_common | write_if_changed /etc/nginx/conf.d/00-cx.conf || true
  _nginx_default | write_if_changed "$NGINX_SITES/00-cx-default.conf" || true
  _nginx_enable 00-cx-default.conf
  rm -f "$NGINX_ENABLED/default"
  _nginx_site | write_if_changed "$NGINX_SITES/$SERVER_FQDN.conf" || true
  _nginx_enable "$SERVER_FQDN.conf"
  if is_true "$ENABLE_N8N"; then
    _nginx_n8n_site | write_if_changed "$NGINX_SITES/$N8N_FQDN.conf" || true
    _nginx_enable "$N8N_FQDN.conf"
  else
    rm -f "$NGINX_ENABLED/$N8N_FQDN.conf"
  fi
  if is_true "$ENABLE_OBJECTS"; then
    _nginx_objects_site | write_if_changed "$NGINX_SITES/$OBJECTS_FQDN.conf" || true
    _nginx_enable "$OBJECTS_FQDN.conf"
  else
    rm -f "$NGINX_ENABLED/$OBJECTS_FQDN.conf"
  fi

  if apps_any; then app_each _nginx_app_apply; fi
  _nginx_stale_app_sites | xargs -r rm -f

  # From the runbook: the apps group may edit nginx sites and read its logs.
  local d
  for d in /var/log/nginx /etc/nginx/conf.d /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/snippets; do
    [[ -d "$d" ]] || continue
    setfacl -R -m g:apps:rwX "$d" && setfacl -dR -m g:apps:rwX "$d"
  done

  nginx -t -q || die "nginx configuration test failed (see above)."
  systemctl enable nginx >/dev/null 2>&1
  if systemctl is-active --quiet nginx; then run systemctl reload nginx; else run systemctl start nginx; fi
}

nginx_teardown() {
  rm -f "$NGINX_ENABLED/$SERVER_FQDN.conf" "$NGINX_SITES/$SERVER_FQDN.conf" \
    "$NGINX_ENABLED/$N8N_FQDN.conf" "$NGINX_SITES/$N8N_FQDN.conf" \
    "$NGINX_ENABLED/$OBJECTS_FQDN.conf" "$NGINX_SITES/$OBJECTS_FQDN.conf" \
    "$NGINX_ENABLED/00-cx-default.conf" "$NGINX_SITES/00-cx-default.conf" /etc/nginx/conf.d/00-cx.conf \
    "$NGINX_ENABLED"/cx-app-*.conf "$NGINX_SITES"/cx-app-*.conf
  [[ -e "$NGINX_SITES/default" && ! -e "$NGINX_ENABLED/default" ]] && ln -s "$NGINX_SITES/default" "$NGINX_ENABLED/default"
  nginx -t -q 2>/dev/null && systemctl reload nginx 2>/dev/null || true
}
