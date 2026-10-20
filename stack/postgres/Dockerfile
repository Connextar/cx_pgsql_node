# PostgreSQL with pgBackRest, for WAL archiving and point-in-time recovery.
# The official image already carries the PGDG apt repository, so pgBackRest comes from
# the same source as Postgres itself.
ARG PG_VERSION=17
ARG PG_IMAGE_VARIANT=trixie
FROM postgres:${PG_VERSION}-${PG_IMAGE_VARIANT}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest ca-certificates; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -o postgres -g postgres -m 0750 /var/log/pgbackrest /var/spool/pgbackrest /var/lib/pgbackrest /backups

LABEL org.opencontainers.image.title="cx-pgsql postgres" \
      org.opencontainers.image.description="PostgreSQL + pgBackRest for CX_PGSQL_Node_1"
