#!/usr/bin/env bash
# deploy.sh - interactive wizard to deploy a new OpenHarness sandbox instance,
# or to (re)deploy an existing one.
#
# This is the SANDBOX deploy. There is no "share-home" mode. The container
# created here has no host filesystem access except through paths passed
# via --mount. See SECURITY.md for the threat model and isolation contract.
#
# Usage:
#   ./deploy.sh                         # full interactive wizard
#   ./deploy.sh --name default          # non-interactive (reuses saved settings if any)
#   ./deploy.sh --mount /data/proj      # add a sandbox mount (repeatable)
#   ./deploy.sh --mount /data/docs:ro   # read-only mount
#   ./deploy.sh --rebuild-image         # force image rebuild
#   ./deploy.sh --no-network            # cut the container off from the network entirely
#   ./deploy.sh --no-self-update        # skip wrapper-repo self-update
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

# ---------------- self-update check (wrapper repo) ----------------
ORIG_ARGV=("$@")
NO_SELF_UPDATE=0
if [ "${OH_DEPLOYER_NO_SELF_UPDATE:-0}" = "1" ]; then NO_SELF_UPDATE=1; fi
if [ "${OH_DEPLOYER_NO_AUTO_INSTALL:-0}" = "1" ]; then export OHD_NO_AUTO_INSTALL=1; fi
filtered=()
for a in "$@"; do
    case "$a" in
        --no-self-update)  NO_SELF_UPDATE=1 ;;
        --no-auto-install) export OHD_NO_AUTO_INSTALL=1 ;;
        *) filtered+=("$a") ;;
    esac
done
set -- ${filtered[@]+"${filtered[@]}"}

ohd_self_update_check() {
    [ "${OH_DEPLOYER_SELF_UPDATE_DONE:-0}" = "1" ] && return 0
    [ "$NO_SELF_UPDATE" -eq 1 ] && return 0
    _skip() {
        local level="$1" reason="$2" hint="${3:-}"
        case "$level" in warn) warn "$reason" ;; *) info "$reason" ;; esac
        [ -n "$hint" ] && info "$hint"
        if [ -t 0 ] && [ -t 1 ]; then
            local ans=""
            printf "? Continue deploy without self-update? [Y/n] "
            read -r ans || ans=""
            case "${ans:-Y}" in n|N|no|NO) err "Aborted by user."; exit 1 ;; esac
        else
            info "Non-interactive shell; continuing without self-update."
        fi
    }
    command -v git >/dev/null 2>&1 || { _skip info "git not found; cannot self-update."; return 0; }
    [ -d "$HERE/.git" ] || { _skip info "Not a git checkout; cannot self-update."; return 0; }
    local branch
    branch="$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    [ "$branch" = "HEAD" ] && { _skip info "Detached HEAD; cannot self-update."; return 0; }
    if ! git -C "$HERE" diff --quiet || ! git -C "$HERE" diff --cached --quiet; then
        _skip warn "Wrapper repo has uncommitted changes; cannot self-update." "Run './update-deployer.sh' manually after committing/stashing."
        return 0
    fi
    info "Checking wrapper repo for updates (origin/$branch)..."
    git -C "$HERE" fetch --quiet --prune origin 2>/dev/null || { _skip info "git fetch failed (offline?); cannot self-update."; return 0; }
    local local_sha remote_sha base
    local_sha="$(git -C "$HERE" rev-parse HEAD)"
    remote_sha="$(git -C "$HERE" rev-parse "origin/$branch" 2>/dev/null || echo "$local_sha")"
    [ "$local_sha" = "$remote_sha" ] && { ok "Wrapper repo is up to date."; return 0; }
    base="$(git -C "$HERE" merge-base HEAD "origin/$branch" 2>/dev/null || echo "")"
    if [ -n "$base" ] && [ "$base" != "$local_sha" ]; then
        _skip warn "Local branch has commits not on origin/$branch; cannot fast-forward." \
            "Run './update-deployer.sh --rebase' manually if you want to integrate."
        return 0
    fi
    local n_behind
    n_behind="$(git -C "$HERE" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "?")"
    info "Wrapper repo is $n_behind commit(s) behind origin/$branch."
    git -C "$HERE" log --oneline --no-decorate "HEAD..origin/$branch" | head -n 10 | sed 's/^/    /'
    local ans=""
    if [ -t 0 ] && [ -t 1 ]; then
        printf "? Pull latest wrapper code and restart deploy? [Y/n] "
        read -r ans || ans=""
    else
        info "Non-interactive shell; auto-accepting self-update."; ans="y"
    fi
    case "${ans:-Y}" in n|N|no|NO) _skip warn "Self-update declined by user."; return 0 ;; esac
    info "Pulling..."
    if ! git -C "$HERE" pull --ff-only --quiet origin "$branch"; then
        _skip warn "git pull --ff-only failed." "Run './update-deployer.sh' manually."
        return 0
    fi
    if command -v chmod >/dev/null 2>&1; then
        while IFS= read -r f; do
            [ -f "$HERE/$f" ] && chmod +x "$HERE/$f" 2>/dev/null || true
        done < <(git -C "$HERE" ls-files '*.sh')
    fi
    ok "Wrapper repo updated to $(git -C "$HERE" rev-parse --short HEAD). Restarting deploy..."
    export OH_DEPLOYER_SELF_UPDATE_DONE=1
    exec "$HERE/deploy.sh" ${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}
}
ohd_self_update_check

ohd_require_supported_platform
ohd_require_jq
ohd_require_docker
ohd_init_config

# ---------------- arg parsing ----------------
INSTANCE_NAME=""
OPENROUTER_KEY=""
DEFAULT_MODEL=""
MOUNTS=()           # each entry: HOST_PATH or HOST_PATH:ro
NETWORK_MODE="bridge"
REBUILD_IMAGE=0
NONINTERACTIVE=0
SET_AS_DEFAULT_FLAG=""
IMAGE_TAG="$OHD_IMAGE_TAG_DEFAULT"
OPENHARNESS_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name)               INSTANCE_NAME="$2"; shift 2 ;;
        --openrouter-key)     OPENROUTER_KEY="$2"; shift 2 ;;
        --model)              DEFAULT_MODEL="$2"; shift 2 ;;
        --mount)              MOUNTS+=("$2"); shift 2 ;;
        --no-network)         NETWORK_MODE="none"; shift ;;
        --rebuild-image)      REBUILD_IMAGE=1; shift ;;
        --image)              IMAGE_TAG="$2"; shift 2 ;;
        --openharness-version) OPENHARNESS_VERSION="$2"; shift 2 ;;
        --yes|-y)             NONINTERACTIVE=1; shift ;;
        --set-default)        SET_AS_DEFAULT_FLAG="yes"; shift ;;
        --no-default)         SET_AS_DEFAULT_FLAG="no"; shift ;;
        -h|--help)
            cat <<EOF
deploy.sh - OpenHarness sandbox deployment wizard

Options:
  --name NAME              Instance name (default: prompt; first instance auto-named "default")
  --openrouter-key KEY     OpenRouter API key (default: prompt)
  --model MODEL            Default OpenRouter model id
  --mount HOST_PATH[:ro]   Add a sandbox bind-mount (repeatable). The path
                           appears inside the container at /work/<basename>.
                           Append :ro for read-only. The agent has access ONLY
                           to paths added this way -- nothing else under your
                           host \$HOME is reachable.
  --no-network             Run with --network=none (no egress).
  --rebuild-image          Rebuild the docker image even if it exists
  --image TAG              Custom image tag (default: $OHD_IMAGE_TAG_DEFAULT)
  --openharness-version V  Pin openharness-ai version (default: latest)
  --set-default            Force this instance as the default
  --no-default             Don't make this the default
  --yes / -y               Non-interactive: accept reasonable defaults
  --no-self-update         Skip the wrapper-repo self-update check
                           (also: env OH_DEPLOYER_NO_SELF_UPDATE=1)
  --no-auto-install        Do not auto-install missing host dependencies
                           (jq, docker).
                           (also: env OH_DEPLOYER_NO_AUTO_INSTALL=1)
  -h / --help              This help

Environment overrides:
  OPENROUTER_API_KEY       Same as --openrouter-key (preferred: avoids
                           leaking the key into the process table via ps).
  OH_AUTO_MOUNT_CWD=1      Allow ad-hoc cwd mounting at \`oh\` time without
                           interactive [y/N] confirmation. Off by default.

Security:
  See SECURITY.md for the threat model and a list of host paths that
  --mount will refuse to expose (\$HOME, ~/.ssh, /var/run/docker.sock, ...).
EOF
            exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

prompt() {
    local ans
    if [ "$NONINTERACTIVE" -eq 1 ]; then echo "${2:-}"; return; fi
    if [ -n "${2:-}" ]; then
        printf '%b? %s [%s]: %b' "$C_BLU" "$1" "$2" "$C_RST" >&2
    else
        printf '%b? %s: %b' "$C_BLU" "$1" "$C_RST" >&2
    fi
    IFS= read -r ans || true
    [ -z "$ans" ] && ans="${2:-}"
    echo "$ans"
}

prompt_secret() {
    local ans
    if [ "$NONINTERACTIVE" -eq 1 ]; then echo ""; return; fi
    printf '%b? %s: %b' "$C_BLU" "$1" "$C_RST" >&2
    IFS= read -rs ans || true
    echo >&2
    echo "$ans"
}

confirm() {
    if [ "$NONINTERACTIVE" -eq 1 ]; then [ "$2" = "yes" ]; return; fi
    local def="${2:-no}"; local hint="[y/N]"
    [ "$def" = "yes" ] && hint="[Y/n]"
    local ans
    printf '%b? %s %s %b' "$C_BLU" "$1" "$hint" "$C_RST" >&2
    IFS= read -r ans || true
    [ -z "$ans" ] && ans="$def"
    case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

cat <<BANNER
${C_BLD}
╔══════════════════════════════════════════════════════╗
║          OpenHarness Sandbox — Deploy                ║
╚══════════════════════════════════════════════════════╝
${C_RST}
This wizard will:
  1) ask for an instance name
  2) ask for your OpenRouter API key + default model
  3) build the docker image (first time only)
  4) create a hardened sandbox container (NO host \$HOME access)
  5) configure the OpenRouter provider profile inside the container
  6) install \`oh\`, \`ohmo\`, \`openh\`, \`oh-ctl\` shims to ${C_BLD}$OHD_SHIM_BIN_DIR${C_RST}

${C_YLW}Security model:${C_RST} the agent inside the container can read/write ONLY
the host paths you pass via --mount. See SECURITY.md.

BANNER

# ---------------- 1. instance name ----------------
existing="$(ohd_list_instance_names || true)"
existing_count="$(printf '%s\n' "$existing" | grep -c . || true)"
if [ -z "$INSTANCE_NAME" ]; then
    if [ "$existing_count" -eq 0 ]; then
        INSTANCE_NAME="$(prompt "Instance name" "default")"
    else
        info "Existing instances:"; printf '%s\n' "$existing" | sed 's/^/    - /' >&2
        INSTANCE_NAME="$(prompt "New (or existing to redeploy) instance name" "")"
    fi
fi
[ -z "$INSTANCE_NAME" ] && die "Instance name is required."
case "$INSTANCE_NAME" in *[!a-zA-Z0-9_.-]*) die "Invalid instance name: '$INSTANCE_NAME' (allowed: a-z A-Z 0-9 . _ -)";; esac

CONTAINER_NAME="$(ohd_container_name "$INSTANCE_NAME")"
HOME_VOLUME="$(ohd_home_volume_name "$INSTANCE_NAME")"
INSTANCE_DIR="$OHD_INSTANCES_DIR/$INSTANCE_NAME"
mkdir -p "$INSTANCE_DIR"

# ---------------- 2. credentials ----------------
# Allow OPENROUTER_API_KEY env var as an alternative to --openrouter-key.
if [ -z "$OPENROUTER_KEY" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
    OPENROUTER_KEY="$OPENROUTER_API_KEY"
fi

existing_key="$(ohd_instance_get "$INSTANCE_NAME" openrouter_key_set 2>/dev/null || true)"
if [ -z "$OPENROUTER_KEY" ]; then
    if [ "$existing_key" = "yes" ] && confirm "Reuse existing OpenRouter API key for '$INSTANCE_NAME'?" yes; then
        OPENROUTER_KEY="__KEEP__"
    else
        info "Get a key at: https://openrouter.ai/keys"
        info "Tip: create a sub-key with a budget cap; the agent inside the sandbox CAN read this key."
        OPENROUTER_KEY="$(prompt_secret "OpenRouter API key (input hidden)")"
        [ -z "$OPENROUTER_KEY" ] && die "OpenRouter API key is required."
    fi
fi

if [ -z "$DEFAULT_MODEL" ]; then
    suggested="$(ohd_instance_get "$INSTANCE_NAME" model 2>/dev/null || true)"
    [ -z "$suggested" ] && suggested="anthropic/claude-3.5-sonnet"
    DEFAULT_MODEL="$(prompt "Default OpenRouter model id" "$suggested")"
fi

# ---------------- 3. mounts (validate BEFORE we build/start anything) -------
declare -a DOCKER_MOUNT_ARGS=()
declare -a MOUNT_DESCRIPTIONS=()  # for the banner + JSON metadata
declare -a MOUNT_RECORDS=()       # parallel array of "host\ttarget\treadonly"

# Detect duplicate basenames so /work/<base> doesn't collide.
# NOTE: macOS still ships bash 3.2 (no associative arrays), so we use
# two parallel indexed arrays as a tiny key->value lookup table instead
# of `declare -A`. Works on bash 3.2+ and bash 4/5.
USED_BASENAME_KEYS=()
USED_BASENAME_VALS=()

for raw in "${MOUNTS[@]}"; do
    ro=0
    spec="$raw"
    case "$spec" in
        *:ro) ro=1; spec="${spec%:ro}" ;;
    esac

    ohd_assert_mount_safe "$spec"
    canonical="$(ohd_canonicalise "$spec")"
    [ -d "$canonical" ] || die "mount '$spec' canonical '$canonical' does not exist or is not a directory."

    base="$(basename -- "$canonical")"
    base="${base//[^A-Za-z0-9._-]/_}"
    [ -z "$base" ] && base="root"
    suffix=""
    found_idx=-1
    for i in "${!USED_BASENAME_KEYS[@]}"; do
        if [ "${USED_BASENAME_KEYS[$i]}" = "$base" ]; then
            found_idx=$i
            break
        fi
    done
    if [ "$found_idx" -ge 0 ]; then
        suffix="${USED_BASENAME_VALS[$found_idx]}"
        USED_BASENAME_VALS[$found_idx]=$((suffix + 1))
    else
        USED_BASENAME_KEYS+=("$base")
        USED_BASENAME_VALS+=("2")
    fi
    target="$(ohd_container_target_for "$canonical" "$suffix")"

    DOCKER_MOUNT_ARGS+=("$(ohd_docker_mount_arg "$canonical" "$ro" "$target")")
    rolabel=""; [ "$ro" -eq 1 ] && rolabel=" :ro"
    MOUNT_DESCRIPTIONS+=("${canonical} -> ${target}${rolabel}")
    MOUNT_RECORDS+=("${canonical}\t${target}\t${ro}")

    # If we are root and the mount is rw, chown to UID 1000 so the in-container
    # user can write. (Non-root host users must do this themselves.)
    if [ "$(id -u)" = "0" ] && [ "$ro" -eq 0 ]; then
        chown -R "${OHD_SANDBOX_UID}:${OHD_SANDBOX_GID}" "$canonical" 2>/dev/null || true
    fi
done

# ---------------- 4. image ----------------
need_build=0
if [ "$REBUILD_IMAGE" -eq 1 ]; then need_build=1; fi
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then need_build=1; fi
if [ "$need_build" -eq 1 ]; then
    info "Building image $IMAGE_TAG ..."
    build_args=(
        --build-arg "SANDBOX_UID=${OHD_SANDBOX_UID}"
        --build-arg "SANDBOX_GID=${OHD_SANDBOX_GID}"
    )
    [ -n "$OPENHARNESS_VERSION" ] && build_args+=(--build-arg "OPENHARNESS_VERSION=$OPENHARNESS_VERSION")
    docker build "${build_args[@]}" -t "$IMAGE_TAG" "$HERE/docker"
    ok "Image built: $IMAGE_TAG"
else
    info "Reusing existing image $IMAGE_TAG (use --rebuild-image to force rebuild)"
fi

# ---------------- 5. (re)create container ----------------
if ohd_container_exists "$CONTAINER_NAME"; then
    if confirm "Container '$CONTAINER_NAME' already exists. Recreate it?" yes; then
        docker rm -f "$CONTAINER_NAME" >/dev/null
    else
        info "Keeping existing container; will only update provider config inside it."
    fi
fi

# Ensure the per-instance home volume exists.
if ! docker volume inspect "$HOME_VOLUME" >/dev/null 2>&1; then
    info "Creating named volume $HOME_VOLUME ..."
    docker volume create "$HOME_VOLUME" >/dev/null
fi

run_args=(
    -d --restart unless-stopped
    --name "$CONTAINER_NAME"
    --label "$OHD_LABEL"
    --label "$OHD_LABEL_SANDBOX"
    --label "dev.openharness.instance=$INSTANCE_NAME"
    --hostname "$CONTAINER_NAME"

    # identity: non-root, fixed
    --user "${OHD_SANDBOX_UID}:${OHD_SANDBOX_GID}"

    # filesystem: read-only rootfs + tmpfs scratch + named volume HOME
    --read-only
    --tmpfs "/tmp:size=512m,mode=1777,nosuid,nodev,noexec"
    --tmpfs "/run:size=64m,mode=755,nosuid,nodev,noexec"
    -v "${HOME_VOLUME}:/oh-home"

    # capabilities: drop everything; deny privilege re-acquisition
    --cap-drop=ALL
    --security-opt=no-new-privileges:true

    # resource limits
    --pids-limit 512
    --memory 4g
    --cpus 2

    # env
    -e "HOME=/oh-home"
    -e "OH_INSTANCE=$INSTANCE_NAME"
    -e "OH_DEFAULT_MODEL=$DEFAULT_MODEL"

    # blackhole well-known cloud metadata endpoints
    --add-host "metadata.google.internal:127.0.0.1"
    --add-host "metadata.tencentyun.com:127.0.0.1"
    --add-host "metadata.aliyuncs.com:127.0.0.1"
    --add-host "metadata.azure.com:127.0.0.1"
    --add-host "169.254.169.254:127.0.0.1"
)

case "$NETWORK_MODE" in
    none)   run_args+=(--network=none) ;;
    bridge) ;; # default
    *) die "unsupported network mode: $NETWORK_MODE" ;;
esac

# Append validated mounts.
for m in "${DOCKER_MOUNT_ARGS[@]}"; do
    run_args+=("$m")
done

if ! ohd_container_exists "$CONTAINER_NAME"; then
    info "Creating sandbox container $CONTAINER_NAME ..."
    docker run "${run_args[@]}" "$IMAGE_TAG" idle >/dev/null
    ok "Container started: $CONTAINER_NAME"
fi

if ! ohd_container_running "$CONTAINER_NAME"; then
    docker start "$CONTAINER_NAME" >/dev/null
fi

# ---------------- 6. inject secrets + configure provider ------------------
# Secrets file lives inside the named volume HOME, owned by UID 1000, mode
# 0400. The agent CAN read it (it has to call the LLM), but it never lives
# on host persistent storage as a chown'd-by-root file.
inject_secrets() {
    local key="$1" model="$2"
    local sf; sf="$(mktemp)"
    chmod 600 "$sf"
    {
        printf 'OPENAI_API_KEY=%s\n'        "$key"
        printf 'OPENROUTER_API_KEY=%s\n'    "$key"
        printf 'OPENAI_BASE_URL=%s\n'       "https://openrouter.ai/api/v1"
        printf 'OPENHARNESS_API_FORMAT=%s\n' "openai"
        printf 'OH_DEFAULT_MODEL=%s\n'      "$model"
    } > "$sf"
    docker exec "$CONTAINER_NAME" mkdir -p /oh-home/.oh-runtime
    # Pipe through `cat > FILE` inside the container so the file is owned
    # by the in-container UID 1000 (cap-drop=ALL prevents post-hoc chown).
    docker exec -i "$CONTAINER_NAME" sh -c \
        'cat > /oh-home/.oh-runtime/secrets.env && chmod 0400 /oh-home/.oh-runtime/secrets.env' \
        < "$sf"
    if command -v shred >/dev/null 2>&1; then shred -u "$sf"; else rm -f "$sf"; fi
}

if [ "$OPENROUTER_KEY" != "__KEEP__" ]; then
    info "Injecting OpenRouter secrets into the sandbox ..."
    inject_secrets "$OPENROUTER_KEY" "$DEFAULT_MODEL"
fi

info "Configuring OpenRouter provider inside the sandbox ..."
# Stage a tiny configurator script INSIDE the container's named volume
# (writable from inside). Then exec it.
docker exec -i "$CONTAINER_NAME" sh -c '
    cat > /oh-home/.oh-runtime/configure.sh <<CFG_EOF
#!/usr/bin/env bash
set -e
mkdir -p "$HOME/.openharness"
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model "${OH_DEFAULT_MODEL}" 2>/dev/null || true
oh provider use openrouter >/dev/null 2>&1 || true
oh config set default_model "${OH_DEFAULT_MODEL}" 2>/dev/null || true
CFG_EOF
    chmod 0500 /oh-home/.oh-runtime/configure.sh
'
docker exec \
    -e "OH_DEFAULT_MODEL=$DEFAULT_MODEL" \
    "$CONTAINER_NAME" \
    bash -c '. /oh-home/.oh-runtime/secrets.env 2>/dev/null; bash /oh-home/.oh-runtime/configure.sh' \
    || warn "Provider configuration returned non-zero; check 'oh provider list' inside the container."

# ---------------- 7. persist instance metadata --------------------------------
# Build a JSON array of mounts from MOUNT_RECORDS.
mounts_json='[]'
for rec in "${MOUNT_RECORDS[@]}"; do
    IFS=$'\t' read -r mhost mtarget mro <<< "$(printf '%b' "$rec")"
    mounts_json="$(jq --arg h "$mhost" --arg t "$mtarget" --argjson r "$mro" \
        '. + [{host:$h, target:$t, readonly:($r==1)}]' <<< "$mounts_json")"
done

ohd_instance_upsert "$INSTANCE_NAME" \
    "image=$IMAGE_TAG" \
    "container=$CONTAINER_NAME" \
    "home_volume=$HOME_VOLUME" \
    "model=$DEFAULT_MODEL" \
    "network=$NETWORK_MODE" \
    "openrouter_key_set=yes" \
    "wrapper_repo=$(ohd_wrapper_repo_root)" \
    "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# mounts is a JSON array, so set it via the dedicated helper.
ohd_instance_mounts_set "$INSTANCE_NAME" <<< "$mounts_json"

# ---------------- 8. default-instance handling ----------------
current_default="$(ohd_default_instance)"
if [ -z "$current_default" ]; then
    if [ "$SET_AS_DEFAULT_FLAG" = "no" ]; then
        warn "No default instance set. Run:  oh-ctl set-default $INSTANCE_NAME"
    else
        ohd_set_default_instance "$INSTANCE_NAME"
        ok "Marked '$INSTANCE_NAME' as default (first instance)."
    fi
else
    if [ "$current_default" = "$INSTANCE_NAME" ]; then
        info "'$INSTANCE_NAME' is already the default."
    else
        case "$SET_AS_DEFAULT_FLAG" in
            yes) ohd_set_default_instance "$INSTANCE_NAME"
                ok "Default instance changed to '$INSTANCE_NAME' (was '$current_default')." ;;
            no)  info "Keeping default as '$current_default'." ;;
            *)
                if confirm "Make '$INSTANCE_NAME' the default OH instance? (current: $current_default)" no; then
                    ohd_set_default_instance "$INSTANCE_NAME"
                    ok "Default instance changed to '$INSTANCE_NAME'."
                else
                    info "Keeping default as '$current_default'."
                fi
                ;;
        esac
    fi
fi

# ---------------- 9. install shims ----------------
# Skip if shim template hasn't been migrated yet (during the migration the
# legacy template still expects the old transparent-mount layout). The
# install-shims script will gate itself on a sentinel.
if [ -x "$HERE/scripts/install-shims.sh" ] && \
   grep -q 'OHD_SHIM_TEMPLATE_VERSION=2' "$HERE/scripts/lib/shim_template.sh" 2>/dev/null; then
    "$HERE/scripts/install-shims.sh" --repo "$HERE" --bin "$OHD_SHIM_BIN_DIR"
else
    warn "install-shims.sh skipped (shim template v2 not yet present)."
    info "Run it manually once shims are upgraded: $HERE/scripts/install-shims.sh --repo \"$HERE\""
fi

# ---------------- 10. summary ----------------
cat <<EOF

${C_GRN}${C_BLD}✓ Done.${C_RST}

Instance:    ${C_BLD}$INSTANCE_NAME${C_RST}
Container:   $CONTAINER_NAME
Image:       $IMAGE_TAG
Home volume: $HOME_VOLUME    (Docker named volume; not on your host \$HOME)
Model:       $DEFAULT_MODEL
Network:     $NETWORK_MODE
Default:     $(ohd_default_instance)

Sandbox mounts (the ONLY host paths the agent can see):
EOF
if [ ${#MOUNT_DESCRIPTIONS[@]} -eq 0 ]; then
    echo "  (none)  -- the agent has no host filesystem access."
    echo "  Add one with:  oh-ctl mount add <host_path>"
else
    for d in "${MOUNT_DESCRIPTIONS[@]}"; do
        echo "  $d"
    done
fi
cat <<EOF

Try it now:
    ${C_BLD}oh-ctl mount add /path/to/your/project${C_RST}    # expose a host dir
    ${C_BLD}cd /path/to/your/project && oh -p "Summarize"${C_RST}
    ${C_BLD}oh-ctl list${C_RST}

If \`oh\` is not found, restart your shell or:
    export PATH="$OHD_SHIM_BIN_DIR:\$PATH"

Read SECURITY.md for the full threat model and isolation contract.
EOF
