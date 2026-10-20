#!/usr/bin/env bash
# Disposable test VPS for this project (see tests/README.md).
#   tests/vps.sh up       build and start it (fresh)
#   tests/vps.sh down     remove it and its Docker volume
#   tests/vps.sh exec …   run a command inside as root
set -Eeuo pipefail
cd "$(dirname "$0")"
NAME=cxvps-test
CACHE=.cache
# Debian release of the stand-in VPS: trixie (13, default) or bookworm (12).
DEBIAN_RELEASE=${DEBIAN_RELEASE:-trixie}
case ${1:-} in
  up)
    mkdir -p "$CACHE"
    [[ -f "$CACHE/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C cxvps-test -f "$CACHE/id_ed25519"
    cp "$CACHE/id_ed25519.pub" vps/root_authorized_keys
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-docker" "$NAME-containerd" >/dev/null 2>&1 || true
    docker build -q --build-arg "DEBIAN_RELEASE=$DEBIAN_RELEASE" -t "cxvps-test:$DEBIAN_RELEASE" vps >/dev/null
    # Ports: 2222→22 (bootstrap SSH), 19225 (hardened SSH), 28433 (PgBouncer), 8443→443, 8080→80.
    docker run -d --name "$NAME" --hostname vmi-test --privileged --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
      -v "$NAME-docker:/var/lib/docker" -v "$NAME-containerd:/var/lib/containerd" \
      -p 127.0.0.1:2222:22 -p 127.0.0.1:19225:19225 -p 127.0.0.1:28433:28433 \
      -p 127.0.0.1:8443:443 -p 127.0.0.1:8080:80 \
      "cxvps-test:$DEBIAN_RELEASE" >/dev/null
    for _ in $(seq 1 30); do
      ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CACHE/id_ed25519" -p 2222 root@127.0.0.1 true 2>/dev/null && break
      sleep 1
    done
    echo "up: ssh -i tests/.cache/id_ed25519 -p 2222 root@127.0.0.1"
    ;;
  down)
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$NAME-docker" "$NAME-containerd" >/dev/null 2>&1 || true
    echo down
    ;;
  exec) shift; docker exec -i "$NAME" "$@" ;;
  *) echo "usage: tests/vps.sh up|down|exec …" >&2; exit 1 ;;
esac
