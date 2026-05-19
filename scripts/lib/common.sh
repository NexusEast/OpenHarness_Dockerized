# shellcheck shell=bash
# Common library for OpenHarness Dockerized scripts.
# Source this file from every script:  . "$(dirname "$0")/lib/common.sh"

set -o pipefail

# ---------------- constants ----------------
OHD_HOME="${OHD_HOME:-$HOME/.openharness-docker}"
OHD_CONFIG="$OHD_HOME/config.json"
OHD_INSTANCES_DIR="$OHD_HOME/instances"
OHD_SHIM_BIN_DIR="${OHD_SHIM_BIN_DIR:-$HOME/.local/bin}"
OHD_IMAGE_TAG_DEFAULT="openharness-dockerized:latest"
OHD_CONTAINER_PREFIX="oh-"
OHD_LABEL="dev.openharness.dockerized=1"

# ---------------- isolation helpers ----------------
# The "wrapper repo" is THIS git repository (the one containing deploy.sh, the
# Dockerfile, etc).  It must stay fully isolated from any container we spawn:
#   * containers must not be able to read or modify its files,
#   * pulling/pushing this repo must not affect a running container,
#   * the agent inside a container must not pretend it can edit our scripts.
#
# We enforce this with a "shadow" mount: when the wrapper repo path happens to
# fall inside a bind-mount we're about to attach (typical case: someone clones
# this repo under their $HOME), we add a second `-v` that overlays a tmpfs (or
# anonymous volume) at the same in-container path. The container sees an empty
# directory there; any writes go into the throwaway overlay.
ohd_wrapper_repo_root() {
    # Echo the absolute path to the wrapper repo (the directory holding
    # deploy.sh / Dockerfile / scripts/).  Resolves symlinks.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    echo "$here"
}

# Is path $1 inside path $2? (string-prefix; both must be absolute, no trailing /).
ohd_path_is_inside() {
    local child parent
    child="${1%/}"
    parent="${2%/}"
    [ "$child" = "$parent" ] && return 0
    case "$child/" in
        "$parent"/*) return 0 ;;
        *)           return 1 ;;
    esac
}

# ---------------- colored logging ----------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_DIM=''; C_BLD=''; C_RST=''
fi

log()    { printf '%s\n' "$*" >&2; }
info()   { printf '%s[i]%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
ok()     { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn()   { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()    { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()    { err "$*"; exit 1; }

# ---------------- platform check ----------------
ohd_detect_platform() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$uname_s" in
        Linux*)   echo linux ;;
        Darwin*)  echo macos ;;
        MINGW*|MSYS*|CYGWIN*) echo "unsupported:$uname_s" ;;
        *)        echo "unsupported:$uname_s" ;;
    esac
}

ohd_require_supported_platform() {
    local p; p="$(ohd_detect_platform)"
    case "$p" in
        linux|macos) ;;
        *) die "Unsupported host: $p. Use macOS / Linux / WSL." ;;
    esac
}

ohd_require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "Required command not found: $c"
    done
}

ohd_require_docker() {
    ohd_require_cmd docker
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start Docker first."
}

# ---------------- jq helper (with fallback) ----------------
# We require jq for clarity. If absent, error early.
ohd_require_jq() {
    command -v jq >/dev/null 2>&1 || die "'jq' is required. Install with: brew install jq / apt-get install jq"
}

# ---------------- config IO ----------------
ohd_init_config() {
    mkdir -p "$OHD_HOME" "$OHD_INSTANCES_DIR"
    if [ ! -f "$OHD_CONFIG" ]; then
        cat > "$OHD_CONFIG" <<'EOF'
{
  "version": 1,
  "default_instance": null,
  "instances": {}
}
EOF
    fi
}

ohd_config_read() {
    ohd_require_jq
    [ -f "$OHD_CONFIG" ] || ohd_init_config
    cat "$OHD_CONFIG"
}

ohd_config_write() {
    # stdin: full JSON
    ohd_require_jq
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    jq . "$tmp" >/dev/null || { rm -f "$tmp"; die "Invalid JSON written to config"; }
    mv "$tmp" "$OHD_CONFIG"
}

ohd_default_instance() {
    ohd_config_read | jq -r '.default_instance // empty'
}

ohd_set_default_instance() {
    local name="$1"
    ohd_config_read | jq --arg n "$name" '.default_instance = $n' | ohd_config_write
}

ohd_list_instance_names() {
    ohd_config_read | jq -r '.instances | keys[]' 2>/dev/null || true
}

ohd_instance_exists() {
    local name="$1"
    [ -n "$(ohd_config_read | jq -r --arg n "$name" '.instances[$n] // empty')" ]
}

ohd_instance_get() {
    # $1=name $2=field
    ohd_config_read | jq -r --arg n "$1" --arg f "$2" '.instances[$n][$f] // empty'
}

ohd_instance_upsert() {
    # $1=name; rest are k=v pairs (strings only)
    local name="$1"; shift
    local payload='{}'
    while [ $# -gt 0 ]; do
        local kv="$1"; shift
        local k="${kv%%=*}"; local v="${kv#*=}"
        payload="$(jq --arg k "$k" --arg v "$v" '. + {($k): $v}' <<< "$payload")"
    done
    ohd_config_read \
        | jq --arg n "$name" --argjson p "$payload" \
            '.instances[$n] = ((.instances[$n] // {}) + $p)' \
        | ohd_config_write
}

ohd_instance_delete() {
    local name="$1"
    ohd_config_read \
      | jq --arg n "$name" '
          del(.instances[$n])
          | if .default_instance == $n then .default_instance = null else . end
        ' \
      | ohd_config_write
}

# ---------------- container naming ----------------
ohd_container_name() { echo "${OHD_CONTAINER_PREFIX}$1"; }

ohd_container_running() {
    local cname="$1"
    [ -n "$(docker ps -q --filter "name=^${cname}$" --filter "label=${OHD_LABEL}")" ]
}

ohd_container_exists() {
    local cname="$1"
    [ -n "$(docker ps -aq --filter "name=^${cname}$" --filter "label=${OHD_LABEL}")" ]
}

# Pretty print one instance row.
ohd_print_instance_row() {
    local name="$1"; local default="$2"
    local cname; cname="$(ohd_container_name "$name")"
    local mark="  "; [ "$name" = "$default" ] && mark="${C_GRN}* ${C_RST}"
    local state="stopped"; ohd_container_running "$cname" && state="running"
    local image; image="$(ohd_instance_get "$name" image)"
    local model; model="$(ohd_instance_get "$name" model)"
    printf '%b%-14s %-9s %-32s %s\n' "$mark" "$name" "$state" "${image:-?}" "${model:-?}"
}

# ---------------- helpers for transparent invocation ----------------
# Pick the target instance name based on:
#   - $OH_INSTANCE override (env)
#   - --name argument (handled by caller before calling this)
#   - default_instance from config
#   - if exactly one instance exists, use it
#   - if multiple, error and prompt user
ohd_resolve_instance() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        echo "$explicit"; return 0
    fi
    if [ -n "${OH_INSTANCE:-}" ]; then
        echo "$OH_INSTANCE"; return 0
    fi
    local d
    d="$(ohd_default_instance)"
    if [ -n "$d" ] && ohd_instance_exists "$d"; then
        echo "$d"; return 0
    fi
    # No default — pick if only one exists
    local names; names="$(ohd_list_instance_names)"
    local count; count="$(printf '%s\n' "$names" | grep -c .)" || true
    if [ "$count" = "1" ]; then
        echo "$names"; return 0
    fi
    if [ "$count" = "0" ]; then
        err "No OH instance is deployed. Run: $(basename "$0") deploy   or   ./deploy.sh"
        return 2
    fi
    err "Multiple OH instances and no default set. Available:"
    while read -r n; do [ -n "$n" ] && err "    - $n"; done <<< "$names"
    err "Either set a default with:  oh-ctl set-default <name>"
    err "Or pick one explicitly:     OH_INSTANCE=<name> oh ...   (or)   oh-ctl exec <name> -- oh ..."
    return 3
}

# Run a command inside a container with proper TTY/stdin handling and cwd-preservation.
ohd_exec_in_container() {
    local instance="$1"; shift
    local cname; cname="$(ohd_container_name "$instance")"
    if ! ohd_container_running "$cname"; then
        if ohd_container_exists "$cname"; then
            info "Instance '$instance' is stopped. Starting..."
            docker start "$cname" >/dev/null || die "Failed to start $cname"
        else
            die "Instance '$instance' has no container. Run ./deploy.sh"
        fi
    fi
    # Decide TTY flags
    local tflags="-i"
    if [ -t 0 ] && [ -t 1 ]; then tflags="-it"; fi

    # cwd: container path equals host path because we mount $HOME identically
    local host_cwd; host_cwd="$(pwd)"
    # Make sure we don't lose path on macOS where /tmp -> /private/tmp etc.
    case "$host_cwd" in
        /private/*) host_cwd_in="${host_cwd#/private}" ;;
        *)          host_cwd_in="$host_cwd" ;;
    esac

    # Probe: is this path visible inside the container?
    # If not, fall back to the instance's host_home with a friendly warning.
    if ! docker exec "$cname" test -d "$host_cwd_in" 2>/dev/null; then
        local fallback
        fallback="$(ohd_instance_get "$instance" host_home)"
        [ -z "$fallback" ] && fallback="/"
        warn "Path not visible inside container '$instance':"
        warn "    host cwd : $host_cwd"
        warn "    expected : $host_cwd_in"
        warn "Falling back to: $fallback"
        warn "Tip: redeploy with  --extra-mount '$host_cwd'  to add this path to the container."
        host_cwd_in="$fallback"
    fi

    docker exec $tflags \
        -e "OH_INSTANCE=$instance" \
        -e "TERM=${TERM:-xterm-256color}" \
        -e "COLORTERM=${COLORTERM:-truecolor}" \
        -w "$host_cwd_in" \
        "$cname" \
        oh-entrypoint exec -- "$@"
}
