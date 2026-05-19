#!/usr/bin/env bash
# oh-ctl - control multiple OpenHarness sandbox instances.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

usage() {
    cat <<EOF
oh-ctl  -  manage OpenHarness sandbox instances

Usage:
  oh-ctl list                          List all instances and the default one
  oh-ctl set-default <name>            Set <name> as the default instance
  oh-ctl unset-default                 Clear the default instance
  oh-ctl status [name]                 Show container status (all if no name)
  oh-ctl start [name]                  Start a stopped container
  oh-ctl stop [name]                   Stop a running container
  oh-ctl restart [name]                Restart container (default if omitted)
  oh-ctl logs [name] [-f]              Show container logs
  oh-ctl shell [name]                  Open an interactive bash inside a container
  oh-ctl exec <name> -- <cmd...>       Run a command inside a specific instance
  oh-ctl rm <name> [--purge]           Remove the container (--purge wipes home volume + metadata)
  oh-ctl info <name>                   Show instance details (mounts, image, model, ...)

  oh-ctl mount list [name]             List active sandbox mounts for an instance
  oh-ctl mount add <host_path> [name] [--ro]
                                       Add a host directory as a sandbox mount.
                                       Requires recreating the container.
  oh-ctl mount rm <host_path> [name]   Remove a sandbox mount.
                                       Requires recreating the container.

Tips:
  Set OH_INSTANCE=<name> in your shell to override the default temporarily.
  Set OH_AUTO_MOUNT_CWD=1 to allow ad-hoc cwd mounting at \`oh\` time without
  the [y/N] prompt (off by default for safety).
EOF
}

# Look up the deploy.sh sibling (so 'mount add' can rebuild the container).
ohd_deployer() {
    local repo
    repo="$(ohd_wrapper_repo_root)"
    printf '%s/deploy.sh\n' "$repo"
}

# Recreate a container after the mounts list changed in config.
# Preserves whatever the user's default-instance setting currently is
# (we pass --no-default so this never accidentally promotes the instance).
ohd_recreate_with_current_mounts() {
    local instance="$1"
    local deployer; deployer="$(ohd_deployer)"
    [ -x "$deployer" ] || die "Cannot find deploy.sh at $deployer"
    info "Recreating container for instance '$instance' with the updated mount list..."
    # Build --mount args from the stored JSON list.
    local args=(--name "$instance" --no-self-update --yes --no-default)
    local mounts; mounts="$(ohd_instance_mounts_get "$instance")"
    while IFS=$'\t' read -r mhost mtarget mro; do
        [ -z "$mhost" ] && continue
        if [ "$mro" = "true" ]; then
            args+=(--mount "${mhost}:ro")
        else
            args+=(--mount "$mhost")
        fi
    done < <(printf '%s\n' "$mounts" | jq -r '.[] | [.host, .target, .readonly] | @tsv')
    # Run deploy.sh; deploy.sh will recreate the container preserving the home volume.
    "$deployer" "${args[@]}"
}

cmd="${1:-}"
shift || true

case "$cmd" in
    ""|-h|--help|help) usage; exit 0 ;;

    list|ls)
        ohd_init_config
        local_default="$(ohd_default_instance)"
        printf '  %-14s %-9s %-32s %s\n' NAME STATE IMAGE MODEL
        names="$(ohd_list_instance_names || true)"
        if [ -z "$names" ]; then
            warn "No instances yet. Run ./deploy.sh"
            exit 0
        fi
        while read -r n; do
            [ -z "$n" ] && continue
            ohd_print_instance_row "$n" "$local_default"
        done <<< "$names"
        echo
        if [ -n "$local_default" ]; then
            info "Default: $C_BLD$local_default$C_RST  (override per-call: OH_INSTANCE=name oh ...)"
        else
            warn "No default instance set. Use:  oh-ctl set-default <name>"
        fi
        ;;

    set-default)
        name="${1:-}"
        [ -z "$name" ] && die "Usage: oh-ctl set-default <name>"
        ohd_instance_exists "$name" || die "No such instance: $name"
        ohd_set_default_instance "$name"
        ok "Default instance set to: $name"
        ;;

    unset-default)
        ohd_config_read | jq '.default_instance = null' | ohd_config_write
        ok "Cleared default instance."
        ;;

    status)
        ohd_require_docker
        ohd_init_config
        target="${1:-}"
        if [ -n "$target" ]; then
            ohd_instance_exists "$target" || die "No such instance: $target"
            cname="$(ohd_container_name "$target")"
            docker ps -a --filter "name=^${cname}$" --filter "label=${OHD_LABEL}" \
                --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
        else
            docker ps -a --filter "label=${OHD_LABEL}" \
                --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.RunningFor}}'
        fi
        ;;

    start)
        ohd_require_docker
        target="${1:-$(ohd_default_instance)}"
        [ -z "$target" ] && die "No instance specified and no default set."
        cname="$(ohd_container_name "$target")"
        docker start "$cname" >/dev/null && ok "Started $cname"
        ;;

    stop)
        ohd_require_docker
        target="${1:-$(ohd_default_instance)}"
        [ -z "$target" ] && die "No instance specified and no default set."
        cname="$(ohd_container_name "$target")"
        docker stop "$cname" >/dev/null && ok "Stopped $cname"
        ;;

    restart)
        ohd_require_docker
        target="${1:-$(ohd_default_instance)}"
        [ -z "$target" ] && die "No instance specified and no default set."
        cname="$(ohd_container_name "$target")"
        docker restart "$cname" >/dev/null && ok "Restarted $cname"
        ;;

    logs)
        ohd_require_docker
        target="${1:-$(ohd_default_instance)}"; shift || true
        [ -z "$target" ] && die "No instance specified and no default set."
        cname="$(ohd_container_name "$target")"
        docker logs "$@" "$cname"
        ;;

    shell)
        ohd_require_docker
        target="${1:-$(ohd_default_instance)}"
        [ -z "$target" ] && die "No instance specified and no default set."
        ohd_instance_exists "$target" || die "No such instance: $target"
        cname="$(ohd_container_name "$target")"
        ohd_container_running "$cname" || docker start "$cname" >/dev/null
        # In sandbox mode, $HOME is /oh-home (named volume); host cwd is
        # NOT auto-mapped. The user can `cd /work/<mount>` from there.
        exec docker exec -it -w "/oh-home" -e "OH_INSTANCE=$target" "$cname" \
            oh-entrypoint exec -- bash -l
        ;;

    exec)
        ohd_require_docker
        target="${1:-}"; shift || true
        [ -z "$target" ] && die "Usage: oh-ctl exec <name> -- <cmd...>"
        ohd_instance_exists "$target" || die "No such instance: $target"
        if [ "${1:-}" = "--" ]; then shift; fi
        [ $# -eq 0 ] && die "No command provided. Usage: oh-ctl exec <name> -- <cmd...>"
        ohd_exec_in_container "$target" "$@"
        ;;

    rm|remove|destroy)
        ohd_require_docker
        target="${1:-}"; shift || true
        [ -z "$target" ] && die "Usage: oh-ctl rm <name> [--purge]"
        purge=0
        for a in "$@"; do [ "$a" = "--purge" ] && purge=1; done
        ohd_instance_exists "$target" || die "No such instance: $target"
        cname="$(ohd_container_name "$target")"
        if ohd_container_exists "$cname"; then
            docker rm -f "$cname" >/dev/null && ok "Container $cname removed"
        else
            warn "No container '$cname' to remove."
        fi
        if [ "$purge" -eq 1 ]; then
            home_vol="$(ohd_instance_get "$target" home_volume 2>/dev/null || true)"
            [ -z "$home_vol" ] && home_vol="$(ohd_home_volume_name "$target")"
            if docker volume inspect "$home_vol" >/dev/null 2>&1; then
                docker volume rm "$home_vol" >/dev/null && ok "Home volume '$home_vol' removed"
            fi
            ohd_instance_delete "$target"
            rm -rf "$OHD_INSTANCES_DIR/$target"
            ok "Instance metadata for '$target' purged."
        else
            info "Instance metadata kept; redeploy with: ./deploy.sh --name $target"
        fi
        ;;

    info)
        target="${1:-}"
        [ -z "$target" ] && die "Usage: oh-ctl info <name>"
        ohd_instance_exists "$target" || die "No such instance: $target"
        ohd_config_read | jq --arg n "$target" '.instances[$n] | {name: $n} + .'
        ;;

    mount)
        sub="${1:-}"; shift || true
        case "$sub" in
            list)
                target="${1:-$(ohd_default_instance)}"
                [ -z "$target" ] && die "No instance specified and no default set."
                ohd_instance_exists "$target" || die "No such instance: $target"
                ohd_instance_mounts_get "$target" | jq -r \
                  '.[] | "  \(.host)  ->  \(.target)\(if .readonly then "  :ro" else "" end)"'
                ;;
            add)
                hp="${1:-}"; shift || true
                [ -z "$hp" ] && die "Usage: oh-ctl mount add <host_path> [instance] [--ro]"
                target=""
                ro=0
                for a in "$@"; do
                    case "$a" in
                        --ro|:ro) ro=1 ;;
                        *) target="$a" ;;
                    esac
                done
                [ -z "$target" ] && target="$(ohd_default_instance)"
                [ -z "$target" ] && die "No instance specified and no default set."
                ohd_instance_exists "$target" || die "No such instance: $target"
                ohd_assert_mount_safe "$hp"
                canonical="$(ohd_canonicalise "$hp")"
                [ -d "$canonical" ] || die "$hp is not a directory."
                # Reject duplicates.
                existing="$(ohd_instance_mounts_get "$target")"
                if printf '%s' "$existing" | jq -e --arg h "$canonical" 'any(.host == $h)' >/dev/null; then
                    die "Mount '$canonical' is already attached to instance '$target'."
                fi
                # Pick a target path that doesn't collide with existing.
                base="$(basename -- "$canonical")"
                base="${base//[^A-Za-z0-9._-]/_}"
                [ -z "$base" ] && base="root"
                cand="$(ohd_container_target_for "$canonical")"
                n=2
                while printf '%s' "$existing" | jq -e --arg t "$cand" 'any(.target == $t)' >/dev/null; do
                    cand="$(ohd_container_target_for "$canonical" "$n")"
                    n=$((n+1))
                done
                ohd_instance_mount_add "$target" "$canonical" "$cand" "$ro"
                ok "Recorded mount: $canonical -> $cand$( [ "$ro" -eq 1 ] && echo " :ro" )"
                ohd_recreate_with_current_mounts "$target"
                ;;
            rm|remove)
                hp="${1:-}"; shift || true
                [ -z "$hp" ] && die "Usage: oh-ctl mount rm <host_path> [instance]"
                target="${1:-$(ohd_default_instance)}"
                [ -z "$target" ] && die "No instance specified and no default set."
                ohd_instance_exists "$target" || die "No such instance: $target"
                canonical="$(ohd_canonicalise "$hp")"
                existing="$(ohd_instance_mounts_get "$target")"
                if ! printf '%s' "$existing" | jq -e --arg h "$canonical" 'any(.host == $h)' >/dev/null; then
                    die "Mount '$canonical' is not attached to instance '$target'."
                fi
                new_arr="$(printf '%s' "$existing" | jq --arg h "$canonical" '[.[] | select(.host != $h)]')"
                printf '%s' "$new_arr" | ohd_instance_mounts_set "$target"
                ok "Removed mount: $canonical"
                ohd_recreate_with_current_mounts "$target"
                ;;
            ""|-h|--help)
                cat <<EOF
oh-ctl mount  -  manage sandbox mounts

  oh-ctl mount list [instance]
  oh-ctl mount add  <host_path> [instance] [--ro]
  oh-ctl mount rm   <host_path> [instance]

Adding or removing a mount recreates the container. The named-volume HOME
(\$HOME inside the container) is preserved across the recreation, so the
agent's openharness profile and conversation history are kept.
EOF
                ;;
            *) die "Unknown 'mount' subcommand: $sub" ;;
        esac
        ;;

    *)
        err "Unknown subcommand: $cmd"
        usage; exit 1 ;;
esac
