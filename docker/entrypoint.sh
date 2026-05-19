#!/usr/bin/env bash
# OpenHarness sandbox entrypoint.
#
# Differences from a "share host home" wrapper:
#   - We are NOT root. We were started as UID 1000:1000 by Docker's --user.
#   - We do NOT usermod / chown anything. The image has no privileges to do
#     so (cap-drop=ALL is enforced at run time) and trying would give a
#     misleading impression that the container can affect host file
#     ownership.
#   - $HOME is a Docker-managed named volume (/oh-home) that the host
#     cannot reach via bind-mount semantics; only `docker exec` / `docker
#     cp` can read it. This is the agent's only persistent state.
#   - No sudo, no su, no privilege drop — there's nothing to drop to.
#
# Usage (the host shim drives this):
#   oh-entrypoint idle           # keep the container alive (PID 1 = sleep)
#   oh-entrypoint exec -- <cmd>  # run a one-shot command as UID 1000

set -euo pipefail

# Sanity: refuse to run as root. If we ever do, something on the host side
# has misconfigured --user; better to fail loud than silently grant root
# inside the agent's reach.
if [ "$(id -u)" = "0" ]; then
    echo "[oh-entrypoint] FATAL: running as root inside the sandbox." >&2
    echo "[oh-entrypoint]   The host deploy script must pass --user <non-zero>:<gid>." >&2
    exit 97
fi

RUNTIME_HOME="${HOME:-/oh-home}"
export HOME="$RUNTIME_HOME"
export USER="ohuser"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

mkdir -p "$HOME/.openharness" "$HOME/.ohmo" "$HOME/.cache" 2>/dev/null || true

# Load instance secrets if present. The file is written by inject-secrets.sh
# (driven by deploy.sh) into the named-volume HOME, owned by UID 1000, mode
# 0400. It contains the OpenRouter API key and default model -- the agent
# CAN read it (it has to, to call the LLM), and that's an accepted risk
# documented in SECURITY.md ("agent can exfiltrate the OpenRouter key it
# was given"; mitigation: use a dedicated sub-key with budget caps).
OH_SECRETS_FILE="${OH_SECRETS_FILE:-/oh-home/.oh-runtime/secrets.env}"
if [ -r "$OH_SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$OH_SECRETS_FILE"; set +a
fi

cmd="${1:-idle}"
shift || true

case "$cmd" in
    idle)
        echo "[oh-entrypoint] sandbox ready; instance=${OH_INSTANCE:-unknown}; home=$HOME; uid=$(id -u) gid=$(id -g)"
        exec sleep infinity
        ;;
    exec)
        if [ "${1:-}" = "--" ]; then shift; fi
        exec "$@"
        ;;
    ohmo-gateway)
        # ohmo gateway is a long-running process the user can opt into.
        exec ohmo gateway run
        ;;
    *)
        # Treat everything else as a program to run.
        exec "$cmd" "$@"
        ;;
esac
