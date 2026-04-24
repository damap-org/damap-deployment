# syntax=docker/dockerfile:1

# ===== Stage 1: Build ===== #
# Create a first stage container to build the application.
# Uses Maven with Eclipse Temurin JDK (Ubuntu Noble 24.04 LTS).
# This container image will be dropped once the runner is built.
# NOTE: It's recommended to keep the Ubuntu version in sync with the runtime image.
FROM maven:3.9-eclipse-temurin-17-noble AS builder

ARG BUILD_HOME=/home/app
ARG DAMAP_BE_VERSION

# Metadata annotations as defined by the Open Container Initiative:
# https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="DAMAP-backend" \
    org.opencontainers.image.description="DAMAP is a tool that aims to facilitate the creation of data management plans (DMPs) for researchers." \
    org.opencontainers.image.url="https://github.com/damap-org/damap-backend" \
    org.opencontainers.image.source="https://github.com/damap-org/damap-backend" \
    org.opencontainers.image.documentation="https://github.com/damap-org/damap-backend/blob/next/README.md" \
    org.opencontainers.image.vendor="Technische Universität Wien" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.authors="DAMAP Development Team" \
    org.opencontainers.image.base.name="eclipse-temurin:17-jre-noble"

# Extra step from upstream: Install git for cloning the repository
RUN apt update && \
    apt install -y git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR "${BUILD_HOME}"

# Extra step from upstream: Clone repository manually
RUN git clone -b ${DAMAP_BE_VERSION} --single-branch --depth 1 https://github.com/damap-org/damap-backend.git .

RUN mkdir -p "${BUILD_HOME}/.m2/repository" && chown -R 1000:0 "${BUILD_HOME}"

USER 1000

# Extra step from upstream: Copy custom configuration
COPY ./application.yml ${BUILD_HOME}/src/main/resources/application.yaml

RUN mvn \
    -Duser.home="${BUILD_HOME}" \
    -B dependency:go-offline

RUN mvn \
    -Duser.home="${BUILD_HOME}" \
    -B package \
    -DskipTests \
    -Dquarkus.package.jar.type=mutable-jar

# ===== Stage 2: Runtime ===== #
# Minimal runtime container using Eclipse Temurin JRE for Quarkus (Ubuntu Noble 24.04 LTS).
FROM eclipse-temurin:17-jre-noble AS runner

# Configure the JAVA_OPTIONS, you can add -XshowSettings:vm to also display the heap size.
ENV JAVA_OPTIONS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en"

WORKDIR /quarkus-app
# Extra step from upstream: Copy entrypoint script
COPY --from=builder /home/app/docker/docker-entrypoint.sh /docker-entrypoint.sh

COPY --from=builder /home/app/target/quarkus-app/ ./

# Ensure Quarkus can write generated metadata when running as a random UID.
RUN chown 1001:0 -R ./ && \
    chmod g+rwX ./quarkus

EXPOSE 8080

# Non-root user for OpenShift.
USER 1001

ENTRYPOINT [ "/docker-entrypoint.sh" ]
