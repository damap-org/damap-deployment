# syntax=docker/dockerfile:1

# ===== Stage 1: Build ===== #
# Create a first stage container to build the application, this container image will be dropped once
# the runner is built
FROM maven:3.9.5-eclipse-temurin-17-alpine AS builder

ARG BUILD_HOME=/home/app
ARG DAMAP_BE_VERSION

# Extra step from upstream: Install git for cloning the repository
RUN apk update && apk add git

WORKDIR ${BUILD_HOME}

# Extra step from upstream: Clone repository manually
RUN git clone -b ${DAMAP_BE_VERSION} --single-branch --depth 1 https://github.com/damap-org/damap-backend.git .

RUN mkdir -p ${BUILD_HOME}/.m2/repository && chown -R 1000:0 ${BUILD_HOME}

USER 1000

# Extra step from upstream: Copy custom configuration
COPY ./application.yml ${BUILD_HOME}/src/main/resources/application.yaml

RUN mvn \
    -Duser.home="${BUILD_HOME}" \
    -B package \
    -DskipTests \
    -Dquarkus.package.jar.type=mutable-jar

# ===== Stage 2: Runtime ===== #
# This stage will only contain the runtime binaries without build dependencies.
FROM rockylinux:8.5

ARG JAVA_PACKAGE=java-17-openjdk-headless

ENV JAVA_OPTIONS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager -Duser.home=/deployments" \ 
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en"

# Extra step from upstream: Copy entrypoint script
COPY --from=builder /home/app/docker/docker-entrypoint.sh /docker-entrypoint.sh

WORKDIR /quarkus-app

COPY --from=builder /home/app/target/quarkus-app/ ./

RUN dnf install -y openssl tzdata-java curl ca-certificates ${JAVA_PACKAGE} \
    && dnf clean all -y \
    && chown 1001:root -R ./

EXPOSE 8080

USER 1001

ENTRYPOINT [ "/docker-entrypoint.sh" ]
