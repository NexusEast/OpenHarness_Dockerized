# OpenHarness sandbox image.
# ---------------------------------------------------------------------------
# Hardened runtime for openharness-ai. The container that this image produces
# is treated as ACTIVELY HOSTILE: the agent inside has no host filesystem
# access, no privileged capabilities, no path back to root, and no network
# control plane (no docker.sock, no cloud metadata).
#
# Threat model is documented in SECURITY.md at the repo root. Read that
# before changing anything in this file.
#
# (Intentionally no `# syntax=` directive: keep this Dockerfile usable in
# air-gapped or DNS-restricted environments where pulling the BuildKit
# frontend image would time out.)

ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm

# ---- Base tooling expected by openharness-ai (git/ripgrep/fd/curl/jq/...) ---
# Kept deliberately small. Excluded on purpose:
#   - sudo                  : no privilege-escalation path inside the image
#   - openssh-client        : no host-key-based egress from inside the box
#   - nodejs / npm          : not required by `oh` proper
#   - build-essential       : no toolchain to compile exploits in-place
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash git curl ca-certificates ripgrep jq tini \
        fd-find less procps \
    ; \
    ln -s /usr/bin/fdfind /usr/local/bin/fd || true; \
    rm -rf /var/lib/apt/lists/*

# ---- Install openharness-ai ----
ARG OPENHARNESS_VERSION=
RUN set -eux; \
    pip install --no-cache-dir --upgrade pip; \
    if [ -n "$OPENHARNESS_VERSION" ]; then \
        pip install --no-cache-dir "openharness-ai==${OPENHARNESS_VERSION}"; \
    else \
        pip install --no-cache-dir "openharness-ai"; \
    fi; \
    oh --version || true

# ---- Non-root user, no sudoers entry, no privilege re-acquisition path -----
# UID/GID are fixed at build time. The runtime container is started with
# --user 1000:1000. The image carries:
#   - no sudo binary
#   - no /etc/sudoers.d/oh-runtime
#   - no setuid binaries beyond the debian defaults (and those are blocked
#     at runtime by --security-opt=no-new-privileges)
ARG SANDBOX_UID=1000
ARG SANDBOX_GID=1000
RUN set -eux; \
    groupadd -g "${SANDBOX_GID}" ohuser; \
    useradd -m -u "${SANDBOX_UID}" -g "${SANDBOX_GID}" -s /bin/bash -d /home/ohuser ohuser; \
    # Build-time assertions: catch regressions if anyone ever re-adds these.
    ! command -v sudo >/dev/null 2>&1; \
    ! test -e /etc/sudoers.d/oh-runtime

# ---- entrypoint ----
COPY entrypoint.sh /usr/local/bin/oh-entrypoint
RUN chmod 0555 /usr/local/bin/oh-entrypoint

# Default HOME points at the named-volume mountpoint chosen by deploy.sh.
ENV HOME=/oh-home

USER 1000:1000
WORKDIR /oh-home

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/oh-entrypoint"]
CMD ["idle"]
