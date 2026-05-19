#!/usr/bin/env bash
# uninstall.sh - remove OpenHarness Docker containers, image, and host shims.
# Persistent user data in ~/.openharness, ~/.ohmo is KEPT by default.
#
# Usage:
#   ./uninstall.sh                # remove containers + shims, keep image and data
#   ./uninstall.sh --image        # also remove the docker image
#   ./uninstall.sh --purge-config # also wipe ~/.openharness-docker (instance metadata only)
#   ./uninstall.sh --all          # everything except ~/.openharness, ~/.ohmo (still kept)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

REMOVE_IMAGE=0
PURGE_CONFIG=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image)         REMOVE_IMAGE=1; shift ;;
        --purge-config)  PURGE_CONFIG=1; shift ;;
        --all)           REMOVE_IMAGE=1; PURGE_CONFIG=1; shift ;;
        -h|--help)
            echo "Usage: uninstall.sh [--image] [--purge-config] [--all]"; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

ohd_require_docker

# Stop & remove all containers with our label
mapfile -t ctns < <(docker ps -aq --filter "label=$OHD_LABEL" 2>/dev/null || true)
if [ "${#ctns[@]}" -gt 0 ]; then
    info "Removing ${#ctns[@]} OH container(s)..."
    docker rm -f "${ctns[@]}" >/dev/null || true
    ok "Containers removed."
else
    info "No OH containers found."
fi

if [ "$REMOVE_IMAGE" -eq 1 ]; then
    mapfile -t imgs < <(docker images -q "openharness-dockerized" 2>/dev/null | sort -u || true)
    if [ "${#imgs[@]}" -gt 0 ]; then
        info "Removing image(s)..."
        docker rmi -f "${imgs[@]}" >/dev/null || true
        ok "Image(s) removed."
    fi
fi

# Shims
for f in oh ohmo openh openharness oh-ctl; do
    [ -f "$OHD_SHIM_BIN_DIR/$f" ] && rm -f "$OHD_SHIM_BIN_DIR/$f" && ok "Removed $OHD_SHIM_BIN_DIR/$f"
done

if [ "$PURGE_CONFIG" -eq 1 ]; then
    info "Purging $OHD_HOME (instance metadata)"
    rm -rf "$OHD_HOME"
    ok "Done."
fi

cat <<EOF

${C_GRN}Uninstall complete.${C_RST}

Kept on disk (your user data, NOT touched):
    \$HOME/.openharness/   (skills, plugins, provider profiles, credentials)
    \$HOME/.ohmo/          (ohmo workspace, memory, soul)
    \$HOME/.claude/, \$HOME/.codex/  (subscription credentials)

If you also want to wipe those, do it manually with: rm -rf ~/.openharness ~/.ohmo
EOF
