#!/usr/bin/env bash
# Run once after cloning to mark all scripts executable.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
find "$HERE" -type f -name "*.sh" -exec chmod +x {} +
chmod +x "$HERE/docker/entrypoint.sh"
echo "[+] All .sh scripts marked executable."
