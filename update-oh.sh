#!/usr/bin/env bash
# update-oh.sh - rebuild the openharness-ai image and recreate containers.
#
# Updates the OpenHarness runtime inside the sandbox by reinstalling
# 'openharness-ai' from PyPI and re-creating each instance's container with
# the same mounts. Per-instance state (named volume HOME) is preserved.
#
# Usage:
#   ./update-oh.sh                    # rebuild image, recreate every instance
#   ./update-oh.sh --name default     # only update one instance
#   ./update-oh.sh --version 0.1.9    # pin a specific openharness-ai version
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

ohd_require_supported_platform
ohd_require_jq
ohd_require_docker
ohd_init_config

ONLY=""
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name)    ONLY="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) echo "Usage: update-oh.sh [--name NAME] [--version VER]"; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

names="$(ohd_list_instance_names)"
[ -z "$names" ] && die "No instances to update. Run ./deploy.sh first."

# We just delegate to deploy.sh; it knows how to (re)build the image and
# recreate the container with the saved mount list. The named-volume HOME
# is preserved, so the openharness profile + agent state survive.
while read -r name; do
    [ -z "$name" ] && continue
    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

    info "Updating instance: $name"
    args=(--name "$name" --no-self-update --yes --no-default --rebuild-image)
    [ -n "$VERSION" ] && args+=(--openharness-version "$VERSION")

    # Re-pass the saved mounts.
    mounts="$(ohd_instance_mounts_get "$name")"
    while IFS=$'\t' read -r mhost mtarget mro; do
        [ -z "$mhost" ] && continue
        if [ "$mro" = "true" ]; then
            args+=(--mount "${mhost}:ro")
        else
            args+=(--mount "$mhost")
        fi
    done < <(printf '%s\n' "$mounts" | jq -r '.[] | [.host, .target, .readonly] | @tsv')

    "$HERE/deploy.sh" "${args[@]}"
    ok "Updated $name"
done <<< "$names"

ok "All requested instances updated."
info "Run 'oh-ctl exec <name> -- oh provider list' to confirm OpenRouter is still configured."
