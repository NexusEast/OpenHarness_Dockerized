# OpenHarness runtime image
# - Ships no OpenHarness source; installs the published package via pip
#   (pip install openharness-ai).
# - Creates a placeholder user whose UID/GID get realigned with the host's at
#   runtime so files written through bind mounts get the right ownership.
#
# (Intentionally no `# syntax=` directive: keep this Dockerfile usable in
# air-gapped or DNS-restricted environments where pulling the BuildKit frontend
# image would time out.)
ARG PYTHON_VERSION=3.12
FROM python:${PYTHON_VERSION}-slim-bookworm

# ---- Base tools: oh's internal tooling expects git/ripgrep/fd/curl/jq/bash ----
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash git curl ca-certificates ripgrep jq tini sudo \
        build-essential nodejs npm fd-find less openssh-client procps \
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
    oh --version || true; \
    ohmo --help >/dev/null 2>&1 || true

# ---- Host-aligned user: only create a placeholder at build time. ----
# The real UID/GID realignment happens inside entrypoint.sh at container start
# (driven by HOST_UID/HOST_GID env vars), so the same image is reusable by any
# host user, including root (UID=0).
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_USER=ohuser
ARG HOST_HOME=/home/ohuser
RUN set -eux; \
    groupadd -g 1000 ohuser 2>/dev/null || true; \
    useradd -m -u 1000 -g 1000 -s /bin/bash -d /home/ohuser ohuser 2>/dev/null || true; \
    echo "%sudo ALL=(ALL) NOPASSWD:ALL"   >> /etc/sudoers.d/oh-runtime; \
    echo "ohuser ALL=(ALL) NOPASSWD:ALL"  >> /etc/sudoers.d/oh-runtime; \
    echo "root ALL=(ALL) NOPASSWD:ALL"    >> /etc/sudoers.d/oh-runtime; \
    chmod 0440 /etc/sudoers.d/oh-runtime

# ---- entrypoint ----
COPY entrypoint.sh /usr/local/bin/oh-entrypoint
RUN chmod +x /usr/local/bin/oh-entrypoint

# By default the container stays idle; the host drives it via `docker exec`.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/oh-entrypoint"]
CMD ["idle"]
