#!/usr/bin/env bash
# OpenHarness Dockerized shim. Auto-generated; do not edit by hand.
#
# This file is installed as ~/.local/bin/oh, ohmo, openh, openharness.
# It detects which name it was invoked as and forwards to the right binary
# inside the chosen OH container.
#
# Selection rules (first match wins):
#   1. OH_INSTANCE env var
#   2. --oh-instance NAME (consumed and removed before forwarding)
#   3. config default_instance
#   4. single instance
# If none match → friendly error.

set -euo pipefail

# Locate this repo's lib (the shim is a copy, not a symlink, so rely on env).
OHD_REPO="${OHD_REPO:-__OHD_REPO__}"
. "$OHD_REPO/scripts/lib/common.sh"

# Determine which CLI to invoke based on argv[0]
prog="$(basename "$0")"
case "$prog" in
    oh|openh|openharness) target_cli="oh" ;;
    ohmo)                 target_cli="ohmo" ;;
    *)                    target_cli="$prog" ;;
esac

# Pull --oh-instance out of args
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

# Resolve which instance
if ! instance="$(ohd_resolve_instance "$explicit_instance")"; then
    exit 1
fi

# Forward
if [ ${#new_args[@]} -eq 0 ]; then
    ohd_exec_in_container "$instance" "$target_cli"
else
    ohd_exec_in_container "$instance" "$target_cli" "${new_args[@]}"
fi
