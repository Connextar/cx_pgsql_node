# A disposable stand-in for a fresh Debian VPS (13 by default; DEBIAN_RELEASE=bookworm for 12):
# systemd as PID 1, sshd on 22, root logs in with the test key. Everything else is setup.sh's job.
ARG DEBIAN_RELEASE=trixie
FROM debian:${DEBIAN_RELEASE}
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server ca-certificates iproute2 procps \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/systemd/system/*.wants/* /lib/systemd/system/multi-user.target.wants/getty* \
    && systemctl enable ssh \
    && mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY root_authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
