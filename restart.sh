#!/usr/bin/env bash
# restart.sh - restart an OH instance (default if none given).
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/scripts/oh-ctl.sh" restart "$@"
