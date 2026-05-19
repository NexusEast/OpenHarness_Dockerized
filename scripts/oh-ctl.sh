#!/usr/bin/env bash
# oh-ctl - control multiple OpenHarness containers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"

usage() {
    cat <<EOF
oh-ctl  -  manage OpenHarness Docker instances

Usage:
  oh-ctl list                        List all instances and show the default one
  oh-ctl set-default <name>          Set <name> as the default instance
  oh-ctl unset-default               Clear the default instance
  oh-ctl status [name]               Show container status (all if no name)
  oh-ctl start [name]                Start a stopped container
  oh-ctl stop [name]                 Stop a running container
  oh-ctl restart [name]              Restart container (default if omitted)
  oh-ctl logs [name] [-f]            Show container logs
  oh-ctl shell [name]                Open an interactive bash inside container
  oh-ctl exec <name> -- <cmd...>     Run a command inside a specific instance
  oh-ctl rm <name> [--purge]         Remove the container (--purge also wipes its instance metadata)
  oh-ctl info <name>                 Show instance details

Tips:
  Set OH_INSTANCE=<name> in your shell to override the default temporarily.
EOF
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
        host_cwd="$(pwd)"
        case "$host_cwd" in
            /private/*) host_cwd_in="${host_cwd#/private}" ;;
            *)          host_cwd_in="$host_cwd" ;;
        esac
        exec docker exec -it -w "$host_cwd_in" -e "OH_INSTANCE=$target" "$cname" oh-entrypoint exec -- bash -l
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
            per_inst_root="$(ohd_instance_get "$target" per_instance_root)"
            ohd_instance_delete "$target"
            rm -rf "$OHD_INSTANCES_DIR/$target"
            if [ -n "$per_inst_root" ] && [ -d "$per_inst_root" ]; then
                rm -rf "$per_inst_root"
                ok "Per-instance state purged: $per_inst_root"
            fi
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

    *)
        err "Unknown subcommand: $cmd"
        usage; exit 1 ;;
esac
