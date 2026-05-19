#!/usr/bin/env bash
# deploy.sh - interactive wizard to deploy a new OpenHarness Docker instance,
# or to (re)deploy an existing one.
#
# Usage:
#   ./deploy.sh                       # full interactive wizard
#   ./deploy.sh --name oh-default     # non-interactive (reuses saved settings if any)
#   ./deploy.sh --extra-mount /data   # add extra bind mounts (repeatable)
#   ./deploy.sh --rebuild-image       # force rebuild of the image
#   ./deploy.sh --no-self-update      # skip the wrapper-repo self-update check
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

# ---------------- self-update check (wrapper repo) ----------------
# Save the original argv so we can re-exec ourselves with the same call after a
# pull. Strip out --no-self-update so users don't have to repeat it; honor the
# OH_DEPLOYER_NO_SELF_UPDATE env var as an alternative way to disable.
ORIG_ARGV=("$@")
NO_SELF_UPDATE=0
if [ "${OH_DEPLOYER_NO_SELF_UPDATE:-0}" = "1" ]; then NO_SELF_UPDATE=1; fi
filtered=()
for a in "$@"; do
    case "$a" in
        --no-self-update) NO_SELF_UPDATE=1 ;;
        *) filtered+=("$a") ;;
    esac
done
# Reset $@ so the rest of the script sees argv without --no-self-update.
set -- ${filtered[@]+"${filtered[@]}"}

ohd_self_update_check() {
    # Guard against infinite re-exec loops.
    [ "${OH_DEPLOYER_SELF_UPDATE_DONE:-0}" = "1" ] && return 0
    [ "$NO_SELF_UPDATE" -eq 1 ] && return 0

    # Helper: the self-update was skipped for some reason; ask the user whether
    # to continue running deploy anyway, or abort. Non-interactive shells
    # auto-continue (so CI / piped invocations don't hang).
    _ohd_self_update_skip() {
        local level="$1"     # "info" | "warn"
        local reason="$2"
        local hint="${3:-}"
        case "$level" in
            warn) warn "$reason" ;;
            *)    info "$reason" ;;
        esac
        [ -n "$hint" ] && info "$hint"
        if [ -t 0 ] && [ -t 1 ]; then
            local ans=""
            printf "? Continue deploy without self-update? [Y/n] "
            read -r ans || ans=""
            case "${ans:-Y}" in
                n|N|no|NO)
                    err "Aborted by user."
                    exit 1 ;;
            esac
        else
            info "Non-interactive shell; continuing without self-update."
        fi
        return 0
    }

    if ! command -v git >/dev/null 2>&1; then
        _ohd_self_update_skip info "git not found; cannot self-update the wrapper repo."
        return 0
    fi
    if [ ! -d "$HERE/.git" ]; then
        _ohd_self_update_skip info "Not a git checkout; cannot self-update the wrapper repo."
        return 0
    fi

    local branch
    branch="$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    if [ "$branch" = "HEAD" ]; then
        _ohd_self_update_skip info "Detached HEAD; cannot self-update."
        return 0
    fi

    # Skip on dirty tree (warn). Don't auto-stash; user data safety > convenience.
    if ! git -C "$HERE" diff --quiet || ! git -C "$HERE" diff --cached --quiet; then
        _ohd_self_update_skip warn \
            "Wrapper repo has uncommitted changes; cannot self-update." \
            "Run './update-deployer.sh' manually after committing/stashing."
        return 0
    fi

    info "Checking wrapper repo for updates (origin/$branch)..."
    if ! git -C "$HERE" fetch --quiet --prune origin 2>/dev/null; then
        _ohd_self_update_skip info "git fetch failed (offline?); cannot self-update."
        return 0
    fi

    local local_sha remote_sha base
    local_sha="$(git -C "$HERE" rev-parse HEAD)"
    remote_sha="$(git -C "$HERE" rev-parse "origin/$branch" 2>/dev/null || echo "$local_sha")"
    if [ "$local_sha" = "$remote_sha" ]; then
        ok "Wrapper repo is up to date."
        return 0
    fi
    base="$(git -C "$HERE" merge-base HEAD "origin/$branch" 2>/dev/null || echo "")"
    if [ -n "$base" ] && [ "$base" != "$local_sha" ]; then
        # Local has commits remote doesn't -> non-fast-forward; treat as skip.
        _ohd_self_update_skip warn \
            "Local branch has commits not on origin/$branch; cannot fast-forward." \
            "Run './update-deployer.sh --rebase' manually if you want to integrate."
        return 0
    fi

    local n_behind
    n_behind="$(git -C "$HERE" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "?")"
    echo
    info "Wrapper repo is $n_behind commit(s) behind origin/$branch."
    info "Recent upstream commits:"
    git -C "$HERE" log --oneline --no-decorate "HEAD..origin/$branch" | head -n 10 | sed 's/^/    /'
    echo

    local ans=""
    if [ -t 0 ] && [ -t 1 ]; then
        printf "? Pull latest wrapper code and restart deploy? [Y/n] "
        read -r ans || ans=""
    else
        info "Non-interactive shell; auto-accepting self-update."
        ans="y"
    fi
    case "${ans:-Y}" in
        n|N|no|NO)
            _ohd_self_update_skip warn "Self-update declined by user."
            return 0 ;;
    esac

    info "Pulling..."
    if ! git -C "$HERE" pull --ff-only --quiet origin "$branch"; then
        _ohd_self_update_skip warn \
            "git pull --ff-only failed." \
            "Run './update-deployer.sh' manually to investigate."
        return 0
    fi
    # Re-apply +x on shell scripts (Windows checkouts often drop it).
    if command -v chmod >/dev/null 2>&1; then
        while IFS= read -r f; do
            [ -f "$HERE/$f" ] && chmod +x "$HERE/$f" 2>/dev/null || true
        done < <(git -C "$HERE" ls-files '*.sh')
    fi
    ok "Wrapper repo updated to $(git -C "$HERE" rev-parse --short HEAD). Restarting deploy..."
    echo
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
EXTRA_MOUNTS=()
REBUILD_IMAGE=0
NONINTERACTIVE=0
SET_AS_DEFAULT_FLAG=""    # "yes"|"no"|""
IMAGE_TAG="$OHD_IMAGE_TAG_DEFAULT"
OPENHARNESS_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --name)               INSTANCE_NAME="$2"; shift 2 ;;
        --openrouter-key)     OPENROUTER_KEY="$2"; shift 2 ;;
        --model)              DEFAULT_MODEL="$2"; shift 2 ;;
        --extra-mount)        EXTRA_MOUNTS+=("$2"); shift 2 ;;
        --rebuild-image)      REBUILD_IMAGE=1; shift ;;
        --image)              IMAGE_TAG="$2"; shift 2 ;;
        --openharness-version) OPENHARNESS_VERSION="$2"; shift 2 ;;
        --yes|-y)             NONINTERACTIVE=1; shift ;;
        --set-default)        SET_AS_DEFAULT_FLAG="yes"; shift ;;
        --no-default)         SET_AS_DEFAULT_FLAG="no"; shift ;;
        -h|--help)
            cat <<EOF
deploy.sh - OpenHarness Docker deployment wizard

Options:
  --name NAME              Instance name (default: prompt; first instance auto-named "default")
  --openrouter-key KEY     OpenRouter API key (default: prompt)
  --model MODEL            Default OpenRouter model id (default: prompt; e.g. anthropic/claude-3.5-sonnet)
  --extra-mount HOST_PATH  Add extra bind mount (repeatable, mounts at same path inside container)
  --rebuild-image          Rebuild the docker image even if it exists
  --image TAG              Custom image tag (default: $OHD_IMAGE_TAG_DEFAULT)
  --openharness-version V  Pin openharness-ai version (default: latest)
  --set-default            Force this instance as the default
  --no-default             Don't make this the default
  --yes / -y               Non-interactive: accept reasonable defaults
  --no-self-update         Skip the wrapper-repo self-update check
                           (also: env OH_DEPLOYER_NO_SELF_UPDATE=1)
  -h / --help              This help
EOF
            exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

prompt() {
    # $1=msg $2=default
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
    # $1=msg $2=default(yes|no)
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
║          OpenHarness Dockerized — Deploy             ║
╚══════════════════════════════════════════════════════╝
${C_RST}
This wizard will:
  1) ask for an instance name
  2) ask for your OpenRouter API key + default model
  3) build the docker image (first time only)
  4) create the container with bind-mounts to your \$HOME
  5) configure the OpenRouter provider profile inside the container
  6) install \`oh\`, \`ohmo\`, \`openh\`, \`oh-ctl\` shims to ${C_BLD}$OHD_SHIM_BIN_DIR${C_RST}

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
INSTANCE_DIR="$OHD_INSTANCES_DIR/$INSTANCE_NAME"
mkdir -p "$INSTANCE_DIR"

# ---------------- 2. credentials ----------------
existing_key="$(ohd_instance_get "$INSTANCE_NAME" openrouter_key_set 2>/dev/null || true)"
if [ -z "$OPENROUTER_KEY" ]; then
    if [ "$existing_key" = "yes" ] && confirm "Reuse existing OpenRouter API key for '$INSTANCE_NAME'?" yes; then
        OPENROUTER_KEY="__KEEP__"
    else
        info "Get a key at: https://openrouter.ai/keys"
        OPENROUTER_KEY="$(prompt_secret "OpenRouter API key (input hidden)")"
        [ -z "$OPENROUTER_KEY" ] && die "OpenRouter API key is required."
    fi
fi

if [ -z "$DEFAULT_MODEL" ]; then
    suggested="$(ohd_instance_get "$INSTANCE_NAME" model 2>/dev/null || true)"
    [ -z "$suggested" ] && suggested="anthropic/claude-3.5-sonnet"
    DEFAULT_MODEL="$(prompt "Default OpenRouter model id" "$suggested")"
fi

# ---------------- 3. mounts ----------------
HOST_HOME="$HOME"
HOST_USER_NAME="$(id -un)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
info "Will bind-mount your home directory (\$HOME=$HOST_HOME) to the same path inside the container."
info "Container UID/GID will match yours: $HOST_UID:$HOST_GID."

# ---------------- 4. image ----------------
need_build=0
if [ "$REBUILD_IMAGE" -eq 1 ]; then need_build=1; fi
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then need_build=1; fi
if [ "$need_build" -eq 1 ]; then
    info "Building image $IMAGE_TAG ..."
    build_args=(
        --build-arg "HOST_UID=$HOST_UID"
        --build-arg "HOST_GID=$HOST_GID"
        --build-arg "HOST_USER=$HOST_USER_NAME"
        --build-arg "HOST_HOME=$HOST_HOME"
    )
    [ -n "$OPENHARNESS_VERSION" ] && build_args+=(--build-arg "OPENHARNESS_VERSION=$OPENHARNESS_VERSION")
    docker build "${build_args[@]}" -t "$IMAGE_TAG" "$HERE/docker"
    ok "Image built: $IMAGE_TAG"
else
    info "Reusing existing image $IMAGE_TAG (use --rebuild-image to force rebuild)"
fi

# ---------------- 5. container ----------------
if ohd_container_exists "$CONTAINER_NAME"; then
    if confirm "Container '$CONTAINER_NAME' already exists. Recreate it?" yes; then
        docker rm -f "$CONTAINER_NAME" >/dev/null
    else
        info "Keeping existing container; will only update provider config inside it."
    fi
fi

run_args=(
    -d --restart unless-stopped
    --name "$CONTAINER_NAME"
    --label "$OHD_LABEL"
    --label "dev.openharness.instance=$INSTANCE_NAME"
    --hostname "$CONTAINER_NAME"
    -e "HOST_UID=$HOST_UID"
    -e "HOST_GID=$HOST_GID"
    -e "HOST_USER=$HOST_USER_NAME"
    -e "HOST_HOME=$HOST_HOME"
    -e "OH_RUNTIME_HOME=$HOST_HOME"
    -e "OH_INSTANCE=$INSTANCE_NAME"
    -v "$HOST_HOME:$HOST_HOME"
)
for m in "${EXTRA_MOUNTS[@]}"; do
    [ -e "$m" ] || warn "Extra mount '$m' does not exist on host (will create empty)."
    run_args+=(-v "$m:$m")
done

# ---- Isolation guards: shadow paths the container must never see/touch ----
# Anything we add to SHADOW_PATHS will be mounted as a tmpfs at that exact
# in-container path, so the bind-mounted host file is hidden behind a fresh
# empty fs. This protects:
#   * the wrapper repo itself (so `oh` inside the container can never modify
#     deploy.sh, the Dockerfile, etc.)
#   * ~/.openharness-docker (state about default instance, instance metadata)
WRAPPER_REPO="$(ohd_wrapper_repo_root)"
SHADOW_PATHS=()
# Only shadow if the path actually falls inside an attached bind-mount,
# otherwise the tmpfs mount would target a non-existent path inside the image
# and `docker run` would fail.
_is_visible_inside_container() {
    local p="$1"
    ohd_path_is_inside "$p" "$HOST_HOME" && return 0
    local m
    for m in "${EXTRA_MOUNTS[@]}"; do
        ohd_path_is_inside "$p" "$m" && return 0
    done
    return 1
}
if _is_visible_inside_container "$WRAPPER_REPO"; then
    SHADOW_PATHS+=("$WRAPPER_REPO")
    info "Wrapper repo is inside a bind-mount; shadowing it inside the container so 'oh' cannot touch it: $WRAPPER_REPO"
fi
if _is_visible_inside_container "$OHD_HOME"; then
    SHADOW_PATHS+=("$OHD_HOME")
    info "Wrapper state dir will be shadowed inside the container: $OHD_HOME"
fi
for p in "${SHADOW_PATHS[@]}"; do
    # tmpfs overlay; size cap small, mode 0755 owned by container's runtime user.
    run_args+=(--tmpfs "$p:rw,size=16m,mode=0755")
done

# ---- Per-instance state directories (so multi-instance does NOT bleed) ----
# OpenHarness keeps user-level state in $HOME/.openharness and $HOME/.ohmo.
# If we just bind-mounted $HOME, every instance would share those files — and
# the last 'deploy' would overwrite the previous instance's provider profile,
# memory and soul. Give each instance its own copy by bind-mounting a
# per-instance directory ON TOP OF the inherited $HOME mount, at the same
# in-container path the agent expects ($HOME/.openharness, $HOME/.ohmo).
PER_INSTANCE_ROOT_HOST="$HOST_HOME/.openharness-instances/$INSTANCE_NAME"
mkdir -p "$PER_INSTANCE_ROOT_HOST/openharness" "$PER_INSTANCE_ROOT_HOST/ohmo"
chown -R "$HOST_UID:$HOST_GID" "$PER_INSTANCE_ROOT_HOST" 2>/dev/null || true

run_args+=(
    -v "$PER_INSTANCE_ROOT_HOST/openharness:$HOST_HOME/.openharness"
    -v "$PER_INSTANCE_ROOT_HOST/ohmo:$HOST_HOME/.ohmo"
)
info "Per-instance state: $PER_INSTANCE_ROOT_HOST  (isolated from other instances)"

if ! ohd_container_exists "$CONTAINER_NAME"; then
    info "Creating container $CONTAINER_NAME ..."
    docker run "${run_args[@]}" "$IMAGE_TAG" idle >/dev/null
    ok "Container started: $CONTAINER_NAME"
fi

# Make sure it's running
if ! ohd_container_running "$CONTAINER_NAME"; then
    docker start "$CONTAINER_NAME" >/dev/null
fi

# ---------------- 6. configure OpenRouter provider inside container ----------------
info "Configuring OpenRouter provider inside the container ..."
if [ "$OPENROUTER_KEY" != "__KEEP__" ]; then
    # Stage a tiny configurator script + env-file inside the user's home (which is bind-mounted),
    # then execute and clean up. This avoids quoting nightmares with arbitrary model strings
    # and keeps the secret out of `ps` listings.
    stage_dir="$HOST_HOME/.openharness-docker-stage"
    mkdir -p "$stage_dir"
    chmod 700 "$stage_dir"

    env_file="$stage_dir/env-$$"
    {
        printf 'OPENAI_API_KEY=%s\n' "$OPENROUTER_KEY"
        printf 'OPENROUTER_API_KEY=%s\n' "$OPENROUTER_KEY"
        printf 'OH_DEFAULT_MODEL=%s\n' "$DEFAULT_MODEL"
    } > "$env_file"
    chmod 600 "$env_file"

    cfg_script="$stage_dir/configure-$$.sh"
    cat > "$cfg_script" <<'CFG_EOF'
#!/usr/bin/env bash
set -e
mkdir -p "$HOME/.openharness"
# (re)create the openrouter profile. `provider add` is idempotent in recent OH versions;
# if it errors because the profile exists, fall through to `provider use`.
oh provider add openrouter \
    --label "OpenRouter" \
    --provider openai \
    --api-format openai \
    --auth-source openai_api_key \
    --base-url "https://openrouter.ai/api/v1" \
    --model "$OH_DEFAULT_MODEL" 2>/dev/null || true
oh provider use openrouter >/dev/null 2>&1 || true
# Best-effort default model setting
oh config set default_model "$OH_DEFAULT_MODEL" 2>/dev/null || true
CFG_EOF
    chmod 700 "$cfg_script"

    docker exec -i --env-file "$env_file" \
        -u "$HOST_UID:$HOST_GID" \
        -e "HOME=$HOST_HOME" \
        "$CONTAINER_NAME" \
        bash "$cfg_script" || warn "Provider configuration returned a non-zero status; check 'oh provider list' inside the container."

    # Persist the API key:
    #  (1) inside the container at /etc/oh-runtime/secrets.env (root-owned 0600)
    #      so the entrypoint can source it for every `docker exec` call.
    #  (2) on the host at $PER_INSTANCE_ROOT_HOST/runtime-secrets.env (0600)
    #      so update-oh.sh can re-inject it after a container recreate. This file
    #      stays under per-instance dir, never bind-mounted into the container,
    #      and goes away when you `oh-ctl rm <name> --purge`.
    docker exec -i -u 0:0 "$CONTAINER_NAME" bash -c '
        set -e
        mkdir -p /etc/oh-runtime
        chmod 0700 /etc/oh-runtime
        cat > /etc/oh-runtime/secrets.env
        chmod 0600 /etc/oh-runtime/secrets.env
    ' < "$env_file"
    install -m 600 "$env_file" "$PER_INSTANCE_ROOT_HOST/runtime-secrets.env"

    # Wipe traces
    shred -u "$env_file"   2>/dev/null || rm -f "$env_file"
    rm -f "$cfg_script"
    rmdir "$stage_dir" 2>/dev/null || true
    ok "OpenRouter provider configured inside $CONTAINER_NAME"
fi

# ---------------- 7. persist instance metadata ----------------
# Serialize shadow paths so update-oh.sh can reapply them on container recreation.
shadow_paths_csv=""
for p in "${SHADOW_PATHS[@]}"; do
    [ -n "$shadow_paths_csv" ] && shadow_paths_csv+=":"
    shadow_paths_csv+="$p"
done
# Same for extra mounts.
extra_mounts_csv=""
for m in "${EXTRA_MOUNTS[@]}"; do
    [ -n "$extra_mounts_csv" ] && extra_mounts_csv+=":"
    extra_mounts_csv+="$m"
done

ohd_instance_upsert "$INSTANCE_NAME" \
    "image=$IMAGE_TAG" \
    "container=$CONTAINER_NAME" \
    "model=$DEFAULT_MODEL" \
    "host_home=$HOST_HOME" \
    "host_uid=$HOST_UID" \
    "host_gid=$HOST_GID" \
    "openrouter_key_set=yes" \
    "shadow_paths=$shadow_paths_csv" \
    "extra_mounts=$extra_mounts_csv" \
    "wrapper_repo=$WRAPPER_REPO" \
    "per_instance_root=$PER_INSTANCE_ROOT_HOST" \
    "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
            yes)
                ohd_set_default_instance "$INSTANCE_NAME"
                ok "Default instance changed to '$INSTANCE_NAME' (was '$current_default')."
                ;;
            no) info "Keeping default as '$current_default'." ;;
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
"$HERE/scripts/install-shims.sh" --repo "$HERE" --bin "$OHD_SHIM_BIN_DIR"

# ---------------- 10. summary ----------------
cat <<EOF

${C_GRN}${C_BLD}✓ Done.${C_RST}

Instance:    ${C_BLD}$INSTANCE_NAME${C_RST}
Container:   $CONTAINER_NAME
Image:       $IMAGE_TAG
Model:       $DEFAULT_MODEL
Default:     $(ohd_default_instance)

Try it now:
    ${C_BLD}cd ~/your/project${C_RST}
    ${C_BLD}oh -p "Summarize this repo"${C_RST}
    ${C_BLD}oh-ctl list${C_RST}
    ${C_BLD}oh --oh-instance $INSTANCE_NAME ...${C_RST}    # explicit override

If \`oh\` is not found, restart your shell or:
    export PATH="$OHD_SHIM_BIN_DIR:\$PATH"
EOF
