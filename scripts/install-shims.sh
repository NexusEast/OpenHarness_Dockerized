#!/usr/bin/env bash
# install-shims.sh - install oh/ohmo/openh/openharness/oh-ctl shims to a bin dir.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/common.sh"

REPO=""
BIN="$OHD_SHIM_BIN_DIR"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --bin)  BIN="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: install-shims.sh --repo <path> [--bin <dir>]"; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

[ -z "$REPO" ] && REPO="$(cd "$HERE/.." && pwd)"
[ -d "$REPO/scripts" ] || die "Invalid --repo: $REPO (no scripts/ dir)"
mkdir -p "$BIN"

template="$REPO/scripts/lib/shim_template.sh"
[ -f "$template" ] || die "Missing template: $template"

# Generate concrete shim with the repo path baked in
gen_shim() {
    local name="$1"
    local out="$BIN/$name"
    sed "s|__OHD_REPO__|$REPO|g" "$template" > "$out"
    chmod +x "$out"
    ok "Installed shim: $out"
}

gen_shim oh
gen_shim ohmo
gen_shim openh
gen_shim openharness

# oh-ctl is a thin wrapper around scripts/oh-ctl.sh, no shim template
ctl_target="$BIN/oh-ctl"
cat > "$ctl_target" <<EOF
#!/usr/bin/env bash
exec "$REPO/scripts/oh-ctl.sh" "\$@"
EOF
chmod +x "$ctl_target"
ok "Installed: $ctl_target"

# PATH hint
case ":$PATH:" in
    *":$BIN:"*) info "PATH already includes $BIN" ;;
    *) warn "Add $BIN to PATH. For example, append to your shell rc:"
       printf '    export PATH=\"%s:$PATH\"\n' "$BIN" >&2 ;;
esac
