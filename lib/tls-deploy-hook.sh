#!/usr/bin/env bash
# certbot deploy hook (installed as /etc/letsencrypt/renewal-hooks/deploy/cx-pgsql.sh):
# after every issue or renewal, copy the certificate to where nginx, Postgres and
# PgBouncer read it, and tell them to reload.
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export PROJECT_DIR
# shellcheck source=lib/core.sh
source "$PROJECT_DIR/lib/core.sh"
# shellcheck source=lib/tls.sh
source "$PROJECT_DIR/lib/tls.sh"
load_config
tls_sync || true
tls_reload_services
