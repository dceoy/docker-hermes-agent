# syntax=docker/dockerfile:1.10
ARG NIX_VERSION=2.30.3
ARG HERMES_DEBIAN_RELEASE=trixie

FROM nixos/nix:${NIX_VERSION} AS builder

ARG HERMES_FLAKE_REF=github:NousResearch/hermes-agent

SHELL ["/bin/sh", "-eu", "-c"]

RUN mkdir -p /etc/nix \
      && printf 'experimental-features = nix-command flakes\n' \
        > /etc/nix/nix.conf

# Build the hermes-agent flake into the Nix store, then materialize the
# runtime closure into /closure so the next stage can drop it under
# /nix/store without dragging in build-time-only paths.
RUN nix build --out-link /tmp/hermes-result "${HERMES_FLAKE_REF}" \
      && mkdir /closure \
      && cp -a $(nix-store --query --requisites /tmp/hermes-result) /closure/ \
      && readlink -f /tmp/hermes-result > /tmp/hermes-store-path

FROM debian:${HERMES_DEBIAN_RELEASE}-slim AS runtime

ARG USER_NAME=hermes
ARG USER_UID=10000
ARG USER_GID=10000

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV \
  DEBIAN_FRONTEND=noninteractive \
  TERM=xterm-256color \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/opt/data \
  PATH=/usr/local/bin:/usr/bin:/bin

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
        ca-certificates tini

# Bring the materialized closure under /nix/store. The Nix-built wrapper
# scripts hard-code their interpreter paths against /nix/store entries,
# so this layout is non-negotiable.
COPY --from=builder /closure /nix/store
COPY --from=builder /tmp/hermes-store-path /opt/hermes-store-path

RUN \
      groupadd --gid "${USER_GID}" "${USER_NAME}" \
      && useradd --uid "${USER_UID}" --gid "${USER_GID}" \
        --home-dir "${HERMES_HOME}" --shell /bin/bash "${USER_NAME}" \
      && install -d -m 0755 -o "${USER_UID}" -g "${USER_GID}" "${HERMES_HOME}" \
      && hermes_path="$(cat /opt/hermes-store-path)" \
      && for cmd in hermes hermes-agent hermes-acp; do \
           if [[ -x "${hermes_path}/bin/${cmd}" ]]; then \
             ln -sf "${hermes_path}/bin/${cmd}" "/usr/local/bin/${cmd}"; \
           fi; \
         done

USER ${USER_NAME}
WORKDIR ${HERMES_HOME}

VOLUME ["/opt/data"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD hermes --version >/dev/null \
    || exit 1

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/hermes"]
