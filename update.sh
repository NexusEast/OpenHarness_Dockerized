#!/usr/bin/env bash
# update.sh - pull/rebuild the latest openharness-ai image and recreate containers.
#
# Usage:
#   ./update.sh                   # rebuild image, recreate every instance
#   ./update.sh --name oh-default # only update one instance
#   ./update.sh --version 0.1.9   # pin a specific openharness-ai version
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scripts/lib/common.sh"

ohd_require_supported_platform
ohd_require_jq
ohd_require_docker
ohd_init_config

ONLY=""
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name)    ONLY="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: update.sh [--name NAME] [--version VER]"; exit 0 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

names="$(ohd_list_instance_names)"
[ -z "$names" ] && die "No instances to update. Run ./deploy.sh first."

# Process each instance. We rebuild image once per unique image tag.
declare -A built=()
while read -r name; do
    [ -z "$name" ] && continue
    [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue

    image="$(ohd_instance_get "$name" image)"; [ -z "$image" ] && image="$OHD_IMAGE_TAG_DEFAULT"
    if [ -z "${built[$image]+_}" ]; then
        info "Rebuilding image: $image (instance=$name)"
        bargs=(
            --build-arg "HOST_UID=$(id -u)"
            --build-arg "HOST_GID=$(id -g)"
            --build-arg "HOST_USER=$(id -un)"
            --build-arg "HOST_HOME=$HOME"
            --no-cache
        )
        [ -n "$VERSION" ] && bargs+=(--build-arg "OPENHARNESS_VERSION=$VERSION")
        docker build "${bargs[@]}" -t "$image" "$HERE/docker"
        built[$image]=1
    fi

    cname="$(ohd_container_name "$name")"
    info "Re-creating container $cname ..."
    if ohd_container_exists "$cname"; then
        docker rm -f "$cname" >/dev/null
    fi
    # Reuse stored host_home (the value used at first deploy) to keep paths stable.
    host_home="$(ohd_instance_get "$name" host_home)"; [ -z "$host_home" ] && host_home="$HOME"
    host_uid="$(ohd_instance_get "$name" host_uid)"; [ -z "$host_uid" ] && host_uid="$(id -u)"
    host_gid="$(ohd_instance_get "$name" host_gid)"; [ -z "$host_gid" ] && host_gid="$(id -g)"
    extras_csv="$(ohd_instance_get "$name" extra_mounts)"
    shadows_csv="$(ohd_instance_get "$name" shadow_paths)"
    per_inst_root="$(ohd_instance_get "$name" per_instance_root)"
    # Backwards-compat: if a pre-existing instance has no per_instance_root in
    # metadata (deployed by an older version), recompute the canonical location.
    [ -z "$per_inst_root" ] && per_inst_root="$host_home/.openharness-instances/$name"
    mkdir -p "$per_inst_root/openharness" "$per_inst_root/ohmo"
    chown -R "$host_uid:$host_gid" "$per_inst_root" 2>/dev/null || true

    run_args=(
        -d --restart unless-stopped
        --name "$cname"
        --label "$OHD_LABEL"
        --label "dev.openharness.instance=$name"
        --hostname "$cname"
        -e "HOST_UID=$host_uid" -e "HOST_GID=$host_gid"
        -e "HOST_USER=$(id -un)" -e "HOST_HOME=$host_home"
        -e "OH_RUNTIME_HOME=$host_home" -e "OH_INSTANCE=$name"
        -v "$host_home:$host_home"
        -v "$per_inst_root/openharness:$host_home/.openharness"
        -v "$per_inst_root/ohmo:$host_home/.ohmo"
    )
    if [ -n "$extras_csv" ]; then
        IFS=':' read -r -a extras_arr <<< "$extras_csv"
        for m in "${extras_arr[@]}"; do
            [ -n "$m" ] && run_args+=(-v "$m:$m")
        done
    fi
    if [ -n "$shadows_csv" ]; then
        IFS=':' read -r -a shadows_arr <<< "$shadows_csv"
        for p in "${shadows_arr[@]}"; do
            [ -n "$p" ] && run_args+=(--tmpfs "$p:rw,size=16m,mode=0755")
        done
    fi

    docker run "${run_args[@]}" "$image" idle >/dev/null

    # Re-inject runtime secrets from the host-side per-instance copy.
    secret_file="$per_inst_root/runtime-secrets.env"
    if [ -f "$secret_file" ]; then
        docker exec -i -u 0:0 "$cname" bash -c '
            set -e
            mkdir -p /etc/oh-runtime
            chmod 0700 /etc/oh-runtime
            cat > /etc/oh-runtime/secrets.env
            chmod 0600 /etc/oh-runtime/secrets.env
        ' < "$secret_file"
    fi

    ok "Updated $cname"
done <<< "$names"

ok "All requested instances updated."
info "Tip: 'oh provider list' inside any container to confirm OpenRouter is still configured."
