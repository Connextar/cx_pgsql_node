# shellcheck shell=bash
# Docker Engine and the compose plugin from Docker's own apt repository (docs.docker.com/engine/install/debian/).

DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
# deb822 format: what Docker documents now, and read by Debian 12 and 13 alike.
DOCKER_LIST=/etc/apt/sources.list.d/docker.sources
DOCKER_LIST_LEGACY=/etc/apt/sources.list.d/docker.list

docker_describe() { echo "Docker Engine + compose plugin, log rotation, live-restore"; }

_docker_list() {
  local codename arch
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && printf '%s' "$VERSION_CODENAME")
  arch=$(dpkg --print-architecture)
  printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' \
    "$codename" "$arch" "$DOCKER_KEYRING"
}

_docker_daemon_json() {
  cat <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true
}
EOF
}

docker_check() {
  chk "Docker apt repository" test -s "$DOCKER_KEYRING"
  chk_render "$DOCKER_LIST" "$DOCKER_LIST" _docker_list
  chk "no second (legacy) Docker source" test ! -e "$DOCKER_LIST_LEGACY"
  chk "packages: ${DOCKER_PKGS[*]}" pkgs_installed "${DOCKER_PKGS[@]}"
  chk_render "/etc/docker/daemon.json (log rotation, live-restore)" /etc/docker/daemon.json _docker_daemon_json
  chk "docker running and enabled" sh -c 'systemctl is-active --quiet docker && systemctl is-enabled --quiet docker'
  chk "docker compose works" docker compose version
}

docker_apply() {
  ensure_pkgs ca-certificates curl
  if [[ ! -s "$DOCKER_KEYRING" ]]; then
    install -d -m 0755 /etc/apt/keyrings
    run curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_KEYRING"
    chmod a+r "$DOCKER_KEYRING"
  fi
  if _docker_list | write_if_changed "$DOCKER_LIST"; then _APT_UPDATED=0; fi
  if [[ -e "$DOCKER_LIST_LEGACY" ]]; then
    rm -f "$DOCKER_LIST_LEGACY"
    _APT_UPDATED=0
  fi
  # Debian's own docker.io conflicts with docker-ce.
  local p
  for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
    pkg_installed "$p" && run apt-get "${APT_LOCK_WAIT[@]}" remove -y -qq "$p"
  done
  ensure_pkgs "${DOCKER_PKGS[@]}"
  if _docker_daemon_json | write_if_changed /etc/docker/daemon.json; then
    # live-restore keeps containers running across this restart once it is on.
    systemctl is-active --quiet docker && run systemctl restart docker
  fi
  run systemctl enable --now docker containerd >/dev/null 2>&1
}

docker_teardown() {
  if ((PURGE)); then
    warn "Removing Docker and ALL its images, containers and volumes."
    apt-get "${APT_LOCK_WAIT[@]}" purge -y -qq "${DOCKER_PKGS[@]}" || true
    rm -rf /var/lib/docker /var/lib/containerd "$DOCKER_LIST" "$DOCKER_KEYRING"
  else
    info "Docker left installed (use --purge to remove it with every image and volume)."
  fi
}
