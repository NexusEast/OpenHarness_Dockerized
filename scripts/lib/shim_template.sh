#!/usr/bin/env bash
# OpenHarness sandbox shim. Auto-generated; do not edit by hand.
#
# This file is installed as ~/.local/bin/oh, ohmo, openh, openharness.
# It detects which name it was invoked as and forwards to the right binary
# inside the chosen sandbox container.
#
# Selection rules (first match wins):
#   1. OH_INSTANCE env var
#   2. --oh-instance NAME (consumed and removed before forwarding)
#   3. config default_instance
#   4. single instance
# If none match -> friendly error.
#
# Sandbox semantics:
#   The container has NO host filesystem access except paths the user has
#   added via `oh-ctl mount add`. If your current host CWD is not inside
#   any sandbox mount, this shim will:
#     - run the command from /oh-home (with a warning), OR
#     - if you set OH_AUTO_MOUNT_CWD=1, ask whether to mount the cwd
#       ephemerally (a one-shot --rm container with the same hardening).
#   Set OH_AUTO_MOUNT_CWD=1 to skip the [y/N] prompt.

# Sentinel for install-shims.sh / deploy.sh -- DO NOT REMOVE.
OHD_SHIM_TEMPLATE_VERSION=2

set -euo pipefail

OHD_REPO="${OHD_REPO:-__OHD_REPO__}"
. "$OHD_REPO/scripts/lib/common.sh"

prog="$(basename "$0")"
case "$prog" in
    oh|openh|openharness) target_cli="oh" ;;
    ohmo)                 target_cli="ohmo" ;;
    *)                    target_cli="$prog" ;;
esac

explicit_instance=""
new_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --oh-instance)
            shift; explicit_instance="${1:-}"; shift || true ;;
        --oh-instance=*)
            explicit_instance="${1#*=}"; shift ;;
        *)
            new_args+=("$1"); shift ;;
    esac
done

if ! instance="$(ohd_resolve_instance "$explicit_instance")"; then
    exit 1
fi

if [ ${#new_args[@]} -eq 0 ]; then
    ohd_exec_in_container "$instance" "$target_cli"
else
    ohd_exec_in_container "$instance" "$target_cli" "${new_args[@]}"
fi
