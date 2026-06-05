#!/usr/bin/env bash
# uninstall.sh - remove OpenHarness sandbox containers, named volumes, image, and host shims.
#
# Usage:
#   ./uninstall.sh                # remove containers + shims, KEEP named volumes (state) and image
#   ./uninstall.sh --image        # also remove the docker image
#   ./uninstall.sh --volumes      # also remove the per-instance home volumes (DELETES openharness state)
#   ./uninstall.sh --purge-config # also wipe ~/.openharness-docker (instance metadata only)
#   ./uninstall.sh --all          # everything: containers + volumes + image + metadata + shims
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

REMOVE_IMAGE=0
REMOVE_VOLUMES=0
PURGE_CONFIG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image)         REMOVE_IMAGE=1; shift ;;
        --volumes)       REMOVE_VOLUMES=1; shift ;;
        --purge-config)  PURGE_CONFIG=1; shift ;;
        --all)           REMOVE_IMAGE=1; REMOVE_VOLUMES=1; PURGE_CONFIG=1; shift ;;
        -h|--help)
            echo "Usage: uninstall.sh [--image] [--volumes] [--purge-config] [--all]"; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

ohd_require_docker

# Stop & remove all containers with our label.
# NOTE: avoid `mapfile`/`readarray` — both are bash 4+ and macOS still
# ships bash 3.2. The while-read idiom below works on every bash >= 3.0.
ctns=()
while IFS= read -r _line; do
    [ -n "$_line" ] && ctns+=("$_line")
done < <(docker ps -aq --filter "label=$OHD_LABEL" 2>/dev/null || true)
if [ "${#ctns[@]}" -gt 0 ]; then
    info "Removing ${#ctns[@]} OH container(s)..."
    docker rm -f "${ctns[@]}" >/dev/null || true
    ok "Containers removed."
else
    info "No OH containers found."
fi

if [ "$REMOVE_VOLUMES" -eq 1 ]; then
    vols=()
    while IFS= read -r _line; do
        [ -n "$_line" ] && vols+=("$_line")
    done < <(docker volume ls -q | grep -E '^oh-.*-home$' 2>/dev/null || true)
    if [ "${#vols[@]}" -gt 0 ]; then
        info "Removing ${#vols[@]} OH home volume(s)..."
        docker volume rm "${vols[@]}" >/dev/null || true
        ok "Home volumes removed (per-instance OpenHarness state is gone)."
    fi
fi

if [ "$REMOVE_IMAGE" -eq 1 ]; then
    imgs=()
    while IFS= read -r _line; do
        [ -n "$_line" ] && imgs+=("$_line")
    done < <(docker images -q "openharness-dockerized" 2>/dev/null | sort -u || true)
    if [ "${#imgs[@]}" -gt 0 ]; then
        info "Removing image(s)..."
        docker rmi -f "${imgs[@]}" >/dev/null || true
        ok "Image(s) removed."
    fi
fi

# Shims (sh side).
for f in oh ohmo openh openharness oh-ctl; do
    [ -f "$OHD_SHIM_BIN_DIR/$f" ] && rm -f "$OHD_SHIM_BIN_DIR/$f" && ok "Removed $OHD_SHIM_BIN_DIR/$f"
done

if [ "$PURGE_CONFIG" -eq 1 ]; then
    info "Purging $OHD_HOME (instance metadata only; volumes and openharness state already handled separately)"
    rm -rf "$OHD_HOME"
    ok "Done."
fi

cat <<EOF

${C_GRN}Uninstall complete.${C_RST}

NOTE: Per-instance OpenHarness state lives in Docker named volumes
(\`oh-<instance>-home\`). It is NOT stored in your host \$HOME. If you
did not pass --volumes, that state is preserved. List remaining volumes:

    docker volume ls --filter name=^oh-

Remove a single instance's state:    docker volume rm oh-<name>-home
EOF
