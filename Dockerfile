# syntax=docker/dockerfile:1.7
#
# Self-hosted GitHub Actions runner with PHP, Composer, Node and Playwright
# system deps, for Laravel/PHP CI. The PHP version is a build arg:
#   docker build --build-arg PHP_VERSION=8.3 -t php-github-runner:8.3 .

ARG NODE_VERSION=24
ARG COMPOSER_VERSION=2

FROM composer:${COMPOSER_VERSION} AS composer
FROM node:${NODE_VERSION}-bookworm-slim AS node

FROM ubuntu:24.04

ARG RUNNER_VERSION=2.338.0
ARG PHP_VERSION=8.4
# Extensions without the "php<version>-" prefix. Packages that don't exist for
# the chosen PHP version (e.g. opcache, which is built in from 8.5) are skipped.
ARG PHP_EXTENSIONS="bcmath cli curl dev gd imagick intl mbstring mcrypt mongodb mysql opcache pcov readline redis soap sqlite3 uuid xml xsl yaml zip"
ARG RUNNER_UID=1001
ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="php-github-runner" \
      org.opencontainers.image.description="Ephemeral self-hosted GitHub Actions runner with PHP, Composer and Node" \
      org.opencontainers.image.authors="rasmus@huruphansen.dk"

ENV PHP_VERSION=${PHP_VERSION} \
    RUNNER_VERSION=${RUNNER_VERSION} \
    LANG=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# CI passes the date here so the apt layer is rebuilt (and picks up security
# updates) at least daily instead of being served from the build cache.
ARG APT_CACHE_BUST=""
# CI passes the lowest PHP patch release with all known security fixes; the
# build fails rather than publishing an image with an older, vulnerable PHP.
ARG PHP_MIN_VERSION=""

# Retry flaky mirrors, and fail instead of silently skipping the PHP packages
# when the PPA index can't be fetched.
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
 && apt-get update --error-on=any \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg software-properties-common \
 && add-apt-repository -y -n ppa:ondrej/php \
 && apt-get update --error-on=any \
 && apt-get upgrade -y \
 && pkgs=() \
 && for ext in ${PHP_EXTENSIONS}; do \
      if apt-cache show "php${PHP_VERSION}-${ext}" >/dev/null 2>&1; then pkgs+=("php${PHP_VERSION}-${ext}"); \
      else echo "WARNING: php${PHP_VERSION}-${ext} not available, skipping"; fi; \
    done \
 && apt-get install -y --no-install-recommends \
      git openssh-client jq rsync unzip zip xz-utils \
      build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
      "${pkgs[@]}" \
 && apt-get purge -y software-properties-common \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

RUN command -v php >/dev/null || { echo "ERROR: PHP was not installed"; exit 1; } \
 && echo "PHP $(php -r 'echo PHP_VERSION;')" \
 && if [ -n "${PHP_MIN_VERSION}" ] && ! php -r 'exit(version_compare(PHP_VERSION, getenv("PHP_MIN_VERSION"), ">=") ? 0 : 1);'; then \
      echo "ERROR: PHP $(php -r 'echo PHP_VERSION;') is older than ${PHP_MIN_VERSION} (missing security fixes)"; exit 1; \
    fi

COPY --from=composer /usr/bin/composer /usr/local/bin/composer
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && node --version && npm --version

# The runner is installed root-owned in /opt and copied fresh into the
# runner's home on every start, so a job can't tamper with it for later jobs.
RUN case "${TARGETARCH}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac \
 && mkdir -p /opt/actions-runner \
 && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz" \
    | tar xz --no-same-owner -C /opt/actions-runner \
 && chown -R root:root /opt/actions-runner \
 && /opt/actions-runner/bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/*

# System libraries for Playwright's Chromium. Browsers themselves are version
# specific, so jobs install them (npx playwright install chromium).
RUN npx -y playwright@latest install-deps chromium \
 && rm -rf /var/lib/apt/lists/* /root/.npm

RUN userdel -r ubuntu 2>/dev/null || true \
 && useradd -m -u "${RUNNER_UID}" -s /bin/bash docker

COPY --chmod=0755 start.sh /usr/local/bin/start-runner

# The entrypoint starts as root only to keep the GitHub PAT away from jobs;
# the runner and every job run as the unprivileged "docker" user.
ENTRYPOINT ["/usr/local/bin/start-runner"]
