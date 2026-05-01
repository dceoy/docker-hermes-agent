# syntax=docker/dockerfile:1.10
ARG HERMES_PYTHON_VERSION=3.13
ARG HERMES_DEBIAN_RELEASE=trixie
ARG UV_VERSION=0.11.6
ARG GOSU_VERSION=1.19

FROM ghcr.io/astral-sh/uv:${UV_VERSION}-python${HERMES_PYTHON_VERSION}-${HERMES_DEBIAN_RELEASE} AS uv_source
FROM tianon/gosu:${GOSU_VERSION}-${HERMES_DEBIAN_RELEASE} AS gosu_source

FROM debian:${HERMES_DEBIAN_RELEASE}-slim AS runtime

ARG HERMES_GIT_URL=https://github.com/NousResearch/hermes-agent.git
ARG HERMES_GIT_REF=main
ARG HERMES_EXTRAS=all
ARG USER_NAME=hermes
ARG USER_UID=10000
ARG USER_GID=10000

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV \
  DEBIAN_FRONTEND=noninteractive \
  TERM=xterm-256color \
  PYTHONUNBUFFERED=1 \
  HERMES_INSTALL_DIR=/opt/hermes \
  HERMES_HOME=/opt/data \
  PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
  PATH=/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}

RUN \
      rm -f /etc/apt/apt.conf.d/docker-clean \
      && printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' \
        > /etc/apt/apt.conf.d/keep-cache

# hadolint ignore=DL3008
RUN \
      --mount=type=cache,id=hermes-apt-cache,target=/var/cache/apt,sharing=locked \
      --mount=type=cache,id=hermes-apt-lib,target=/var/lib/apt,sharing=locked \
      apt-get -yqq update \
      && apt-get -yqq install --no-install-recommends --no-install-suggests \
        build-essential ca-certificates curl docker-cli ffmpeg gcc git \
        libffi-dev nodejs npm openssh-client procps python3 python3-dev \
        ripgrep tini

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/gosu
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

RUN \
      groupadd --gid "${USER_GID}" "${USER_NAME}" \
      && useradd --uid "${USER_UID}" --gid "${USER_GID}" \
        --home-dir "${HERMES_HOME}" --shell /bin/bash "${USER_NAME}"

WORKDIR ${HERMES_INSTALL_DIR}

# Clone hermes-agent at the requested ref. ADD invalidates the cache when
# the ref's commit changes, so rebuilds pick up upstream updates without
# requiring --no-cache.
ADD ${HERMES_GIT_URL}#${HERMES_GIT_REF} ${HERMES_INSTALL_DIR}

ENV npm_config_install_links=false

# hadolint ignore=DL3016
RUN \
      --mount=type=cache,id=hermes-npm-cache,target=/root/.npm,sharing=locked \
      npm install --prefer-offline --no-audit \
      && npx playwright install --with-deps chromium --only-shell \
      && (cd web && npm install --prefer-offline --no-audit) \
      && (cd ui-tui && npm install --prefer-offline --no-audit) \
      && (cd web && npm run build) \
      && (cd ui-tui && npm run build) \
      && npm cache clean --force

RUN \
      --mount=type=cache,id=hermes-uv-cache,target=/root/.cache/uv,sharing=locked \
      uv venv \
      && uv pip install -e ".[${HERMES_EXTRAS}]"

RUN \
      install -d -m 0755 -o "${USER_UID}" -g "${USER_GID}" "${HERMES_HOME}" \
      && chmod -R a+rX "${HERMES_INSTALL_DIR}" \
      && ln -sf "${HERMES_INSTALL_DIR}/.venv/bin/hermes" /usr/local/bin/hermes

ENV HERMES_WEB_DIST=${HERMES_INSTALL_DIR}/hermes_cli/web_dist

VOLUME ["/opt/data"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD hermes --version >/dev/null \
    || exit 1

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh"]
