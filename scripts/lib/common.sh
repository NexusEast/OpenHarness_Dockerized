# shellcheck shell=bash
# Common library for OpenHarness Dockerized scripts.
# Source this file from every script:  . "$(dirname "$0")/lib/common.sh"
#
# Security note (read SECURITY.md for the full picture):
#   The wrapper repo uses a SANDBOX isolation model. The container has NO
#   host filesystem access except through paths the user explicitly mounts.
#   This file therefore provides:
#     - a sensitive-paths blacklist (ohd_assert_mount_safe)
#     - host -> container path mapping (ohd_container_target_for)
#     - the helper that runs `oh ...` against a sandboxed instance,
#       optionally adding the host CWD as a one-off mount after a [y/N]
#       confirmation (ohd_exec_in_container).
#
# This file MUST NOT introduce any code path that bind-mounts $HOME
# wholesale, or that resurrects the old "transparency contract".

set -o pipefail

# ---------------- constants ----------------
OHD_HOME="${OHD_HOME:-$HOME/.openharness-docker}"
OHD_CONFIG="$OHD_HOME/config.json"
OHD_INSTANCES_DIR="$OHD_HOME/instances"
OHD_SHIM_BIN_DIR="${OHD_SHIM_BIN_DIR:-$HOME/.local/bin}"
OHD_IMAGE_TAG_DEFAULT="openharness-dockerized:latest"
OHD_CONTAINER_PREFIX="oh-"
OHD_LABEL="dev.openharness.dockerized=1"
OHD_LABEL_SANDBOX="dev.openharness.sandbox=1"
# Inside the container, every host-side mount lives under this prefix.
OHD_WORK_PREFIX="/work"
# Sandbox runs as this UID:GID. Must match Dockerfile ARG SANDBOX_UID/GID.
OHD_SANDBOX_UID="${OHD_SANDBOX_UID:-1000}"
OHD_SANDBOX_GID="${OHD_SANDBOX_GID:-1000}"

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
    ohd_ensure_docker
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable. Start Docker first."
}

# ---------------- path helpers ----------------
ohd_wrapper_repo_root() {
    # Echo the absolute path to the wrapper repo (the directory holding
    # deploy.sh / docker/ / scripts/). Resolves symlinks.
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    echo "$here"
}

# Canonicalise a path. realpath -m tolerates non-existent paths.
ohd_canonicalise() {
    local p="$1"
    [ -z "$p" ] && return 1
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$p"
    else
        # best-effort fallback (won't follow symlinks correctly without realpath)
        case "$p" in
            /*) printf '%s\n' "$p" ;;
            *)  printf '%s\n' "$(pwd -P)/$p" ;;
        esac
    fi
}

# Is path $1 inside path $2? (string-prefix; both must be absolute, no
# trailing /). Returns 0 if equal or descendant.
ohd_path_is_inside() {
    local child parent
    child="${1%/}"
    parent="${2%/}"
    [ -z "$parent" ] && parent="/"
    [ "$child" = "$parent" ] && return 0
    case "$child/" in
        "$parent"/*) return 0 ;;
        *)           return 1 ;;
    esac
}

# Build the array of host paths that must NEVER be exposed inside a
# sandbox. We use bash arrays so callers can `for s in "${OHD_SENSITIVE_PATHS[@]}"`.
# This is recomputed every call so $HOME changes are honored.
ohd_build_sensitive_paths() {
    OHD_SENSITIVE_PATHS=(
        # System-level
        "/"
        "/root"
        "/home"
        "/etc"
        "/var"
        "/usr"
        "/boot"
        "/sys"
        "/proc"
        "/dev"
        "/run"
        "/lib"
        "/lib64"
        "/sbin"
        "/bin"
        "/srv"
        "/opt"
        # Docker / container control planes (escape primitives)
        "/var/run/docker.sock"
        "/run/docker.sock"
        "/var/run/containerd"
        "/run/containerd"
        "/var/lib/docker"
        "/var/lib/containerd"
        "/var/lib/kubelet"
        # WSL plumbing
        "/mnt/wsl"
    )
    if [ -n "${HOME:-}" ]; then
        OHD_SENSITIVE_PATHS+=(
            "$HOME"
            "$HOME/.ssh"
            "$HOME/.aws"
            "$HOME/.azure"
            "$HOME/.gcp"
            "$HOME/.gcloud"
            "$HOME/.docker"
            "$HOME/.kube"
            "$HOME/.gnupg"
            "$HOME/.config"
            "$HOME/.netrc"
            "$HOME/.openharness"
            "$HOME/.openharness-docker"
            "$HOME/.openharness-instances"
            "$HOME/.bash_history"
            "$HOME/.zsh_history"
        )
    fi
    # Also add the wrapper repo itself: the agent must never modify the
    # scripts that run it.
    local wrapper; wrapper="$(ohd_wrapper_repo_root 2>/dev/null || true)"
    [ -n "$wrapper" ] && OHD_SENSITIVE_PATHS+=("$wrapper")
}

# Hard-fail if a host path requested for mount is unsafe.
# Rejects when:
#   * the path resolves to one of OHD_SENSITIVE_PATHS, OR
#   * it is inside one of them, OR
#   * one of them is inside it (to catch e.g. --mount /home which would
#     expose every user's $HOME).
# Also rejects symlinks (caller must pass the resolved real path).
ohd_assert_mount_safe() {
    local raw="$1"
    local cpath
    cpath="$(ohd_canonicalise "$raw")" || die "cannot canonicalise mount path: $raw"
    [ "$cpath" = "/" ] && die "refusing to mount '/' into the sandbox."

    if [ -L "$raw" ]; then
        die "mount '$raw' is a symlink (target='$(readlink -- "$raw" 2>/dev/null || true)'); pass the resolved target after re-checking it."
    fi

    if [ -e "$cpath" ] && [ ! -d "$cpath" ]; then
        die "mount '$raw' (canonical '$cpath') is not a directory; refusing."
    fi

    ohd_build_sensitive_paths
    local s
    for s in "${OHD_SENSITIVE_PATHS[@]}"; do
        if ohd_path_is_inside "$cpath" "$s"; then
            die "mount '$raw' (canonical '$cpath') is inside or equal to sensitive path '$s'; refusing. See SECURITY.md."
        fi
        if ohd_path_is_inside "$s" "$cpath"; then
            die "mount '$raw' (canonical '$cpath') would expose sensitive path '$s'; refusing. See SECURITY.md."
        fi
    done
    return 0
}

# Map a host path to its in-container target.
#   /data/proj      ->   /work/proj
#   /opt/code/foo   ->   /work/foo
# Multiple mounts with the same basename get suffixed (-2, -3, ...). The
# caller is responsible for tracking suffixes when assembling docker args.
ohd_container_target_for() {
    local host_path="$1"
    local suffix="${2:-}"
    local base
    base="$(basename -- "$host_path")"
    [ -z "$base" ] && base="root"
    base="${base//[^A-Za-z0-9._-]/_}"
    if [ -n "$suffix" ]; then
        printf '%s/%s-%s\n' "$OHD_WORK_PREFIX" "$base" "$suffix"
    else
        printf '%s/%s\n' "$OHD_WORK_PREFIX" "$base"
    fi
}

# Build a `--mount=type=bind,...` arg from a (host_path, ro?, target?) triple.
# Echoes the docker arg on stdout.
ohd_docker_mount_arg() {
    local host_path="$1"
    local ro="${2:-0}"
    local target="${3:-}"
    [ -z "$target" ] && target="$(ohd_container_target_for "$host_path")"
    if [ "$ro" -eq 1 ]; then
        printf -- '--mount=type=bind,source=%s,target=%s,readonly,bind-recursive=disabled\n' \
            "$host_path" "$target"
    else
        printf -- '--mount=type=bind,source=%s,target=%s,bind-recursive=disabled\n' \
            "$host_path" "$target"
    fi
}

# ---------------- dependency installer ----------------
ohd_detect_distro_id() {
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        echo darwin; return
    fi
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release; printf '%s\n' "${ID:-}" )
        return
    fi
    echo ""
}

ohd_detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf     >/dev/null 2>&1; then echo dnf
    elif command -v yum     >/dev/null 2>&1; then echo yum
    elif command -v apk     >/dev/null 2>&1; then echo apk
    elif command -v pacman  >/dev/null 2>&1; then echo pacman
    elif command -v zypper  >/dev/null 2>&1; then echo zypper
    elif command -v brew    >/dev/null 2>&1; then echo brew
    else echo ""
    fi
}

ohd_pkg_install_cmd() {
    local pm="$1" pkg="$2"
    case "$pm" in
        apt)    echo "apt-get update -qq && apt-get install -y $pkg" ;;
        dnf)    echo "dnf install -y $pkg" ;;
        yum)    echo "yum install -y $pkg" ;;
        apk)    echo "apk add --no-cache $pkg" ;;
        pacman) echo "pacman -Sy --noconfirm $pkg" ;;
        zypper) echo "zypper --non-interactive install $pkg" ;;
        brew)   echo "brew install $pkg" ;;
        *)      echo "" ;;
    esac
}

ohd_auto_install_allowed() {
    local pkg="$1"
    [ "${OH_DEPLOYER_NO_AUTO_INSTALL:-0}" = "1" ] && return 1
    [ "${OHD_NO_AUTO_INSTALL:-0}"          = "1" ] && return 1
    [ "${OHD_ASSUME_YES_ALL:-0}"           = "1" ] && {
        info "Auto-install '$pkg' (yes-for-all enabled)."
        return 0
    }
    if [ -t 0 ] && [ -t 1 ]; then
        local ans=""
        printf "? Install missing dependency '%s' now? [Y]es / [n]o / [a]ll (yes for the rest): " "$pkg"
        read -r ans || ans=""
        case "${ans:-Y}" in
            n|N|no|NO)         return 1 ;;
            a|A|all|ALL)
                export OHD_ASSUME_YES_ALL=1
                info "yes-for-all enabled: future missing deps will install without prompting."
                return 0 ;;
            *)                 return 0 ;;
        esac
    else
        info "Non-interactive shell; auto-accepting install of '$pkg'."
    fi
    return 0
}

ohd_run_privileged() {
    local cmd="$1"
    if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
        bash -c "$cmd"
    elif command -v sudo >/dev/null 2>&1; then
        info "Running: sudo $cmd"
        sudo bash -c "$cmd"
    else
        err "This step needs root, but neither root nor sudo is available."
        return 1
    fi
}

ohd_ensure_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    local pm cmd distro
    pm="$(ohd_detect_pkg_manager)"
    distro="$(ohd_detect_distro_id)"
    cmd="$(ohd_pkg_install_cmd "$pm" jq)"
    if [ -z "$cmd" ]; then
        err "'jq' is required but no supported package manager was found."
        info "Detected distro: ${distro:-unknown}"
        info "Install jq manually for your platform, then re-run ./deploy.sh."
        info "  See https://jqlang.org/download/"
        exit 1
    fi
    warn "'jq' is required but not installed."
    info "Detected distro: ${distro:-unknown}   package manager: $pm"
    info "Would run: $cmd"
    if ohd_auto_install_allowed jq; then
        if ohd_run_privileged "$cmd"; then
            command -v jq >/dev/null 2>&1 \
                && { ok "jq installed: $(jq --version 2>/dev/null || echo unknown)"; return 0; }
            die "jq install reported success but jq is still not on PATH."
        else
            die "Auto-install of jq failed. Run manually: $cmd"
        fi
    else
        info "Skipping auto-install. Install jq manually:"
        info "    $cmd"
        info "Then re-run ./deploy.sh."
        exit 1
    fi
}

ohd_ensure_docker() {
    command -v docker >/dev/null 2>&1 && return 0
    local pm distro
    pm="$(ohd_detect_pkg_manager)"
    distro="$(ohd_detect_distro_id)"
    warn "'docker' CLI is required but not installed."
    info "Detected distro: ${distro:-unknown}   package manager: ${pm:-unknown}"
    local steps=() post_hint=""
    case "$pm" in
        apt)
            steps=(
                "apt-get update -qq"
                "apt-get install -y ca-certificates curl gnupg"
                "install -m 0755 -d /etc/apt/keyrings"
                "curl -fsSL https://download.docker.com/linux/${distro:-debian}/gpg -o /etc/apt/keyrings/docker.asc || curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
                "chmod a+r /etc/apt/keyrings/docker.asc"
                "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro:-debian} \$(. /etc/os-release && echo \\\"\${VERSION_CODENAME:-bookworm}\\\") stable\" > /etc/apt/sources.list.d/docker.list"
                "apt-get update -qq"
                "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
                "systemctl enable --now docker 2>/dev/null || service docker start 2>/dev/null || true"
            )
            post_hint="If your user is not root, run:  sudo usermod -aG docker \"\$USER\"   and re-login."
            ;;
        dnf|yum)
            local family="centos"
            case "$distro" in
                fedora) family="fedora" ;;
                rhel|centos|rocky|almalinux|tencentos|ol|amzn) family="centos" ;;
            esac
            steps=(
                "$pm -y install ${pm}-plugins-core 2>/dev/null || $pm -y install yum-utils"
                "$pm config-manager --add-repo https://download.docker.com/linux/$family/docker-ce.repo"
                "$pm install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
                "systemctl enable --now docker"
            )
            post_hint="If your user is not root, run:  sudo usermod -aG docker \"\$USER\"   and re-login."
            ;;
        apk)
            steps=(
                "apk add --no-cache docker docker-cli docker-compose"
                "rc-update add docker default"
                "service docker start"
            )
            post_hint="If your user is not root, add it to the docker group:  addgroup \"\$USER\" docker   then re-login."
            ;;
        pacman)
            steps=(
                "pacman -Sy --noconfirm docker docker-compose"
                "systemctl enable --now docker"
            )
            post_hint="If your user is not root, run:  sudo usermod -aG docker \"\$USER\"   and re-login."
            ;;
        zypper)
            steps=(
                "zypper --non-interactive install docker docker-compose"
                "systemctl enable --now docker"
            )
            post_hint="If your user is not root, run:  sudo usermod -aG docker \"\$USER\"   and re-login."
            ;;
        brew)
            err "Docker Desktop must be installed manually on macOS."
            info "  brew install --cask docker"
            info "After install, launch Docker.app once so the engine starts, then re-run ./deploy.sh."
            exit 1
            ;;
        *)
            err "No supported package manager detected; cannot auto-install docker."
            info "Install Docker manually:  https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac
    echo
    info "Would run the following commands (as root) to install Docker:"
    for s in "${steps[@]}"; do
        info "    $s"
    done
    [ -n "$post_hint" ] && info "  Post-install: $post_hint"
    echo
    warn "Installing Docker touches systemd, repos and user groups; review the commands above."
    if ohd_auto_install_allowed docker; then
        local s rc=0
        for s in "${steps[@]}"; do
            if ! ohd_run_privileged "$s"; then
                rc=$?
                err "Step failed (exit $rc): $s"
                info "Aborting docker install. Fix the issue and re-run ./deploy.sh, or install docker manually."
                exit 1
            fi
        done
        if command -v docker >/dev/null 2>&1; then
            ok "Docker installed: $(docker --version 2>/dev/null || echo unknown)"
            [ -n "$post_hint" ] && warn "$post_hint"
            return 0
        else
            die "Docker install reported success but 'docker' is still not on PATH."
        fi
    else
        info "Skipping auto-install. Run the steps above manually, or use the official docs:"
        info "    https://docs.docker.com/engine/install/"
        exit 1
    fi
}

# Back-compat alias for older callers.
ohd_require_jq() { ohd_ensure_jq; }

# ---------------- config IO ----------------
ohd_init_config() {
    mkdir -p "$OHD_HOME" "$OHD_INSTANCES_DIR"
    if [ ! -f "$OHD_CONFIG" ]; then
        cat > "$OHD_CONFIG" <<'EOF'
{
  "version": 2,
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
    ohd_config_read | jq -r --arg n "$1" --arg f "$2" '.instances[$n][$f] // empty'
}

ohd_instance_upsert() {
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

# Append a mount entry to instance.<name>.mounts.
# Args: name, host_path, target, readonly(0|1).
ohd_instance_mount_add() {
    local name="$1" host="$2" target="$3" ro="${4:-0}"
    ohd_config_read \
        | jq --arg n "$name" --arg h "$host" --arg t "$target" --argjson r "$ro" '
            .instances[$n] |= ((. // {}) | (.mounts |= ((. // []) + [{host:$h, target:$t, readonly:($r==1)}])))
          ' \
        | ohd_config_write
}

ohd_instance_mounts_set() {
    # stdin: JSON array; replace .instances[name].mounts
    local name="$1"
    local arr; arr="$(cat)"
    ohd_config_read \
        | jq --arg n "$name" --argjson m "$arr" '.instances[$n].mounts = $m' \
        | ohd_config_write
}

ohd_instance_mounts_get() {
    ohd_config_read | jq -r --arg n "$1" '.instances[$n].mounts // [] | tojson'
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
ohd_home_volume_name() { echo "oh-${1}-home"; }

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

# Given an instance name and a host path, return the in-container path that
# the path is exposed at, or empty if the path is not in any of the
# instance's mounts. We honor multi-level matches (longest mount prefix wins).
ohd_resolve_host_path_to_container() {
    local instance="$1"
    local host_path="$2"
    [ -z "$host_path" ] && return 0
    local cpath; cpath="$(ohd_canonicalise "$host_path")" || return 0
    local mounts; mounts="$(ohd_instance_mounts_get "$instance")"
    [ -z "$mounts" ] && return 0
    local best_host="" best_target=""
    # Iterate via jq; for each {host,target,readonly}, see if cpath is inside host.
    while IFS=$'\t' read -r mhost mtarget; do
        [ -z "$mhost" ] && continue
        if ohd_path_is_inside "$cpath" "$mhost"; then
            # Prefer longer host prefix.
            if [ ${#mhost} -gt ${#best_host} ]; then
                best_host="$mhost"
                best_target="$mtarget"
            fi
        fi
    done < <(printf '%s\n' "$mounts" | jq -r '.[] | [.host, .target] | @tsv')
    if [ -n "$best_host" ]; then
        local rel="${cpath#$best_host}"
        rel="${rel#/}"
        if [ -z "$rel" ]; then
            printf '%s\n' "$best_target"
        else
            printf '%s/%s\n' "$best_target" "$rel"
        fi
        return 0
    fi
    return 0
}

# Prompt the user "Add this host path as a one-off sandbox mount? [y/N]".
# Returns 0 = yes, 1 = no. Honors:
#   - OH_AUTO_MOUNT_CWD=1   : auto-yes (CI / power user)
#   - OH_AUTO_MOUNT_CWD=0   : auto-no
#   - non-tty               : auto-no (safer default)
ohd_confirm_cwd_mount() {
    local host_path="$1"
    case "${OH_AUTO_MOUNT_CWD:-}" in
        1|y|Y|yes|YES) info "OH_AUTO_MOUNT_CWD=1 -> mounting $host_path"; return 0 ;;
        0|n|N|no|NO)   info "OH_AUTO_MOUNT_CWD=0 -> NOT mounting $host_path"; return 1 ;;
    esac
    if ! { [ -t 0 ] && [ -t 1 ]; }; then
        warn "Non-interactive shell; refusing to auto-mount '$host_path'."
        warn "Set OH_AUTO_MOUNT_CWD=1 to allow, or pre-add it via:  oh-ctl mount add $host_path"
        return 1
    fi
    echo                                                                       >&2
    warn "About to expose host path inside the sandbox:"                       >&2
    warn "    $host_path"                                                      >&2
    warn "The agent will be able to read AND WRITE everything under it."       >&2
    warn "If this contains secrets, credentials or anything you wouldn't paste"
    warn "into a public chat, answer 'n' and run from a different directory."
    local ans=""
    printf "? Mount it for this command? [y/N] " >&2
    read -r ans || ans=""
    case "${ans:-N}" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# Run a command inside an instance, with the host CWD optionally mounted.
# Strategy:
#   - If host cwd resolves into an existing mount, reuse it (just `docker exec
#     -w <container_path>`).
#   - Else, ask the user. If yes, spawn a one-off `docker run --rm` container
#     that shares the home volume with the long-lived idle container BUT
#     ADDITIONALLY mounts the host cwd at /work/<basename>. The long-lived
#     idle container is unaffected.
#   - Else, fall back to /oh-home and warn that the agent cannot see the
#     host cwd.
ohd_exec_in_container() {
    local instance="$1"; shift
    local cname; cname="$(ohd_container_name "$instance")"
    local home_vol; home_vol="$(ohd_home_volume_name "$instance")"
    local image; image="$(ohd_instance_get "$instance" image)"
    [ -z "$image" ] && image="$OHD_IMAGE_TAG_DEFAULT"

    if ! ohd_container_running "$cname"; then
        if ohd_container_exists "$cname"; then
            info "Instance '$instance' is stopped. Starting..."
            docker start "$cname" >/dev/null || die "Failed to start $cname"
        else
            die "Instance '$instance' has no container. Run ./deploy.sh"
        fi
    fi

    local tflags="-i"
    if [ -t 0 ] && [ -t 1 ]; then tflags="-it"; fi

    local host_cwd; host_cwd="$(pwd -P)"
    case "$host_cwd" in
        /private/*) host_cwd="${host_cwd#/private}" ;;  # macOS canonical
    esac

    local container_cwd
    container_cwd="$(ohd_resolve_host_path_to_container "$instance" "$host_cwd")"

    if [ -n "$container_cwd" ]; then
        # CWD already in scope -- use the long-lived container.
        docker exec $tflags \
            -e "OH_INSTANCE=$instance" \
            -e "TERM=${TERM:-xterm-256color}" \
            -e "COLORTERM=${COLORTERM:-truecolor}" \
            -w "$container_cwd" \
            "$cname" \
            oh-entrypoint exec -- "$@"
        return $?
    fi

    # CWD not in any existing mount. Ask whether to add it as an EPHEMERAL
    # mount.
    if ohd_assert_mount_safe "$host_cwd" 2>/dev/null && ohd_confirm_cwd_mount "$host_cwd"; then
        local target; target="$(ohd_container_target_for "$host_cwd")"
        local mount_arg; mount_arg="$(ohd_docker_mount_arg "$host_cwd" 0 "$target")"
        # One-off container: same home volume so config persists, same network
        # mode, same hardening, plus this single extra mount.
        docker run --rm $tflags \
            --label "$OHD_LABEL" \
            --label "$OHD_LABEL_SANDBOX" \
            --label "dev.openharness.instance=$instance" \
            --label "dev.openharness.ephemeral=1" \
            --user "$OHD_SANDBOX_UID:$OHD_SANDBOX_GID" \
            --read-only \
            --tmpfs "/tmp:size=512m,mode=1777,nosuid,nodev,noexec" \
            --tmpfs "/run:size=64m,mode=755,nosuid,nodev,noexec" \
            -v "${home_vol}:/oh-home" \
            --cap-drop=ALL \
            --security-opt=no-new-privileges:true \
            --pids-limit 512 \
            --memory 4g \
            --cpus 2 \
            --add-host "metadata.google.internal:127.0.0.1" \
            --add-host "metadata.tencentyun.com:127.0.0.1" \
            --add-host "metadata.aliyuncs.com:127.0.0.1" \
            --add-host "metadata.azure.com:127.0.0.1" \
            --add-host "169.254.169.254:127.0.0.1" \
            -e "HOME=/oh-home" \
            -e "OH_INSTANCE=$instance" \
            -e "TERM=${TERM:-xterm-256color}" \
            -e "COLORTERM=${COLORTERM:-truecolor}" \
            -w "$target" \
            "$mount_arg" \
            "$image" \
            oh-entrypoint exec -- "$@"
        return $?
    fi

    # User said no, or path was sensitive. Run inside the long-lived container
    # with cwd = /oh-home, and warn loudly.
    warn "Running '$1' from /oh-home; the agent cannot see your host cwd ($host_cwd)."
    warn "To make a host directory available, run:  oh-ctl mount add <host_path>"
    docker exec $tflags \
        -e "OH_INSTANCE=$instance" \
        -e "TERM=${TERM:-xterm-256color}" \
        -e "COLORTERM=${COLORTERM:-truecolor}" \
        -w "/oh-home" \
        "$cname" \
        oh-entrypoint exec -- "$@"
}
