#!/usr/bin/env bash
# OpenHarness container entrypoint.
#
# Usage (inside the container):
#   oh-entrypoint idle           # default: keep the container alive; host drives it via docker exec
#   oh-entrypoint ohmo gateway   # also supports running ohmo gateway in the foreground
#   oh-entrypoint exec -- oh ... # explicitly run a one-shot command (typically oh ...)
#
set -euo pipefail

# Inside the image we always have a baked-in user 'ohuser' (uid/gid set at build time).
# At run time we (a) resync ohuser's UID/GID to the host's (HOST_UID/HOST_GID),
# and (b) point its $HOME at the bind-mounted directory.
HOST_USER="ohuser"
HOST_HOME="${HOST_HOME:-/home/ohuser}"
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# ---- (a) resync ohuser to host UID/GID, idempotent on container restart ----
current_uid="$(id -u "$HOST_USER" 2>/dev/null || echo 1000)"
current_gid="$(id -g "$HOST_USER" 2>/dev/null || echo 1000)"
if [ "$current_gid" != "$HOST_GID" ]; then
    # Re-use existing group with that GID if any; otherwise change ohuser's group.
    existing_group="$(getent group "$HOST_GID" | cut -d: -f1 || true)"
    if [ -n "$existing_group" ]; then
        usermod -g "$existing_group" "$HOST_USER" 2>/dev/null || true
    else
        groupmod -g "$HOST_GID" "$HOST_USER" 2>/dev/null || true
    fi
fi
if [ "$current_uid" != "$HOST_UID" ]; then
    # If a user with that UID already exists (e.g. root with UID 0), just delete
    # ohuser so we run as that existing user instead.
    existing_user="$(getent passwd "$HOST_UID" | cut -d: -f1 || true)"
    if [ -n "$existing_user" ] && [ "$existing_user" != "$HOST_USER" ]; then
        HOST_USER="$existing_user"
    else
        usermod -u "$HOST_UID" "$HOST_USER" 2>/dev/null || true
    fi
fi

# If the bind-mounted $HOME differs from the baked-in HOST_HOME (for example
# when the host home is /Users/foo on macOS), rewrite this user's home so that
# tools resolving ~ end up on the bind-mounted directory.
RUNTIME_HOME="${OH_RUNTIME_HOME:-$HOST_HOME}"
if [ "$RUNTIME_HOME" != "$HOST_HOME" ]; then
    # Make sure the parent directory exists.
    mkdir -p "$(dirname "$RUNTIME_HOME")"
    if [ ! -e "$RUNTIME_HOME" ]; then
        # Nothing mounted at this path; create an empty directory so $HOME resolves.
        mkdir -p "$RUNTIME_HOME"
        chown -R "$HOST_UID:$HOST_GID" "$RUNTIME_HOME"
    fi
    # Rewrite the home field in /etc/passwd.
    sed -i "s|^${HOST_USER}:\(.*\):\(.*\):\(.*\):\(.*\):${HOST_HOME}:|${HOST_USER}:\1:\2:\3:\4:${RUNTIME_HOME}:|" /etc/passwd || true
fi

export HOME="$RUNTIME_HOME"
export USER="$HOST_USER"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

# Load instance secrets if present (written by deploy.* into a file private to
# the container, NOT bind-mounted from the host). This is where the OpenRouter
# API key lives so 'oh -p' can actually call the model.
OH_SECRETS_FILE="${OH_SECRETS_FILE:-/etc/oh-runtime/secrets.env}"
if [ -f "$OH_SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$OH_SECRETS_FILE"; set +a
fi

# Make sure the key config directories exist and are owned by the target user.
for d in "$HOME/.openharness" "$HOME/.ohmo" "$HOME/.cache"; do
    if [ ! -e "$d" ]; then
        mkdir -p "$d"
        chown "$HOST_UID:$HOST_GID" "$d" 2>/dev/null || true
    fi
done

# Drop to the target user before running the requested command.
run_as_user() {
    if [ "$(id -u)" = "0" ] && [ "$HOST_USER" != "root" ]; then
        # Use sudo to drop privileges; explicitly forward the auth-related env
        # vars (sudo's default policy strips them otherwise).
        exec sudo -E -u "$HOST_USER" \
            HOME="$HOME" \
            PATH="$PATH" \
            OH_INSTANCE="${OH_INSTANCE:-}" \
            OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
            OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
            OPENAI_BASE_URL="${OPENAI_BASE_URL:-}" \
            OPENHARNESS_API_FORMAT="${OPENHARNESS_API_FORMAT:-}" \
            "$@"
    else
        # Already running as the target user (e.g. UID 0 host).
        exec "$@"
    fi
}

cmd="${1:-idle}"
shift || true

case "$cmd" in
    idle)
        # Minimal placeholder process: keep the container alive; host drives it via docker exec.
        echo "[oh-entrypoint] container ready; instance=${OH_INSTANCE:-unknown}; home=$HOME"
        # tini forwards PID 1 signals to sleep correctly, so docker stop terminates cleanly.
        exec sleep infinity
        ;;
    exec)
        # exec -- some-command args...
        if [ "${1:-}" = "--" ]; then shift; fi
        run_as_user "$@"
        ;;
    ohmo-gateway)
        run_as_user ohmo gateway run
        ;;
    *)
        # Treat the whole command line as an external program and pass it through.
        run_as_user "$cmd" "$@"
        ;;
esac
