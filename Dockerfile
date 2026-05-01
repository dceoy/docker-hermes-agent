FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source
FROM tianon/gosu:1.19-trixie AS gosu_source
FROM debian:13.4

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    TERM=xterm-256color \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_HOME=/home/${USER_NAME:-agent}/.hermes \
    HERMES_APP_DIR=/opt/hermes

ARG USER_NAME=agent
ARG USER_UID=1001
ARG USER_GID=1001

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,id=hermes-apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=hermes-apt-lib,target=/var/lib/apt,sharing=locked \
    apt-get -yqq update \
    && apt-get -yqq install --no-install-recommends --no-install-suggests \
      build-essential ca-certificates curl ffmpeg gcc git libffi-dev nodejs npm \
      openssh-client procps python3 python3-dev ripgrep tini \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

WORKDIR ${HERMES_APP_DIR}

# Install Hermes Agent
RUN uv venv \
    && uv pip install --no-cache-dir hermes-agent[all]

# Create runtime user and writable home/config/workspace dirs
RUN groupadd --gid "${USER_GID}" "${USER_NAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --home-dir "/home/${USER_NAME}" --shell /bin/bash "${USER_NAME}" \
    && install -d -m 0755 -o "${USER_UID}" -g "${USER_GID}" "${HERMES_HOME}" "${HERMES_HOME}/workspace" \
    && chown -R "${USER_UID}:${USER_GID}" "/home/${USER_NAME}" "${HERMES_APP_DIR}"

ENV PATH="${HERMES_APP_DIR}/.venv/bin:/home/${USER_NAME}/.local/bin:${PATH}"

USER ${USER_NAME}
WORKDIR ${HERMES_HOME}/workspace

VOLUME ["/home/${USER_NAME}/.hermes"]

ENTRYPOINT ["/usr/bin/tini", "--", "hermes"]
CMD ["gateway", "run"]
