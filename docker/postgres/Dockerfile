ARG POSTGRES_VERSION

FROM postgres:${POSTGRES_VERSION}

COPY --chmod=0755 docker-entrypoint-initdb.d /docker-entrypoint-initdb.d
COPY --chmod=0755 healthcheck.sh /usr/local/bin/healthcheck.sh

USER ${POSTGRES_USER}
