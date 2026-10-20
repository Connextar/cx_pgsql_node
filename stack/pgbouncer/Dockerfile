# PgBouncer from the PGDG repository, built on the official Postgres image so it runs as
# the same `postgres` user (uid 999) that owns the certificate files, with no third-party image.
ARG PG_VERSION=17
ARG PG_IMAGE_VARIANT=trixie
FROM postgres:${PG_VERSION}-${PG_IMAGE_VARIANT}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbouncer ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -o postgres -g postgres -m 0750 /var/log/pgbouncer /var/run/pgbouncer

USER postgres
EXPOSE 6432
STOPSIGNAL SIGINT
ENTRYPOINT ["pgbouncer"]
CMD ["/etc/pgbouncer/pgbouncer.ini"]

LABEL org.opencontainers.image.title="cx-pgsql pgbouncer" \
      org.opencontainers.image.description="PgBouncer for CX_PGSQL_Node_1"
