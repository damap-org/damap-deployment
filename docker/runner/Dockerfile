FROM docker:29.8.1-cli AS docker-cli
FROM ghcr.io/actions/actions-runner:2.337.0

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && mv /home/runner /opt/actions-runner

COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose
COPY entrypoint.sh /usr/local/bin/damap-runner

RUN chmod 755 /usr/local/bin/damap-runner

ENV RUNNER_IMAGE_VERSION=2.337.0

USER 1001:1001

WORKDIR /tmp

ENTRYPOINT ["/usr/local/bin/damap-runner"]

CMD ["start"]
