FROM debian:trixie-slim

ARG TARGETARCH
ARG RESTIC_VERSION=0.19.1
ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z
ARG SUPERCRONIC_VERSION=0.2.49
ARG RESTIC_SHA256_AMD64=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c
ARG RESTIC_SHA256_ARM64=a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465
ARG MC_SHA256_AMD64=01f866e9c5f9b87c2b09116fa5d7c06695b106242d829a8bb32990c00312e891
ARG MC_SHA256_ARM64=14c8c9616cfce4636add161304353244e8de383b2e2752c0e9dad01d4c27c12c
ARG SUPERCRONIC_SHA256_AMD64=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
ARG SUPERCRONIC_SHA256_ARM64=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        bzip2 \
        ca-certificates \
        curl \
        postgresql-client-17 \
        procps \
        tar \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN set -e; \
    arch="${TARGETARCH:-amd64}"; \
    case "$arch" in \
      amd64) restic_sha="$RESTIC_SHA256_AMD64"; mc_sha="$MC_SHA256_AMD64"; cron_sha="$SUPERCRONIC_SHA256_AMD64"; restic_arch=linux_amd64; mc_arch=amd64; cron_arch=amd64 ;; \
      arm64) restic_sha="$RESTIC_SHA256_ARM64"; mc_sha="$MC_SHA256_ARM64"; cron_sha="$SUPERCRONIC_SHA256_ARM64"; restic_arch=linux_arm64; mc_arch=arm64; cron_arch=arm64 ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_${restic_arch}.bz2"; \
    echo "${restic_sha}  /tmp/restic.bz2" | sha256sum -c -; \
    bunzip2 -c /tmp/restic.bz2 > /usr/local/bin/restic; \
    chmod 0755 /usr/local/bin/restic; \
    curl -fsSL -o /usr/local/bin/mc "https://dl.min.io/client/mc/release/linux-${mc_arch}/archive/mc.${MC_VERSION}"; \
    echo "${mc_sha}  /usr/local/bin/mc" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/mc; \
    curl -fsSL -o /usr/local/bin/supercronic "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${cron_arch}"; \
    echo "${cron_sha}  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/supercronic; \
    rm -f /tmp/restic.bz2; \
    rm -rf /var/lib/apt/lists/*

COPY lib.sh /usr/local/lib/backup/lib.sh
COPY entrypoint.sh backup.sh app-backup.sh maintenance.sh healthcheck.sh restore.sh init-repo.sh /usr/local/bin/

RUN sed -i 's/\r$//' /usr/local/lib/backup/lib.sh /usr/local/bin/*.sh \
    && chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/backup.sh \
        /usr/local/bin/app-backup.sh \
        /usr/local/bin/maintenance.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/restore.sh \
        /usr/local/bin/init-repo.sh

WORKDIR /staging
VOLUME ["/staging"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
