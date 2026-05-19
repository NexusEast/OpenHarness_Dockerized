#!/usr/bin/env bash
# status.sh - show all OH instances and their container status.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$HERE/scripts/oh-ctl.sh" status "$@"
