#!/usr/bin/env bash

# VX-owned service apply boundary.  Native Vesta restart commands retain their
# legacy scheduling semantics; active services here are only ever reloaded.
vx_graceful_apply_configtest() (
    local service_name service_limit
    for service_name in "$@"; do
        [[ -n "$service_name" && "$service_name" != remote ]] || continue
        case "$service_name" in
            apache2)
                /usr/sbin/apache2ctl configtest >/dev/null 2>&1 || return 1
                ;;
            nginx)
                service_limit=$(/usr/bin/systemctl show nginx --property=LimitNOFILESoft --value 2>/dev/null) || service_limit=''
                if [[ -n "$service_limit" ]]; then
                    [[ "$service_limit" =~ ^[0-9]+$ ]] || return 1
                    ulimit -Sn "$service_limit" || return 1
                fi
                /usr/sbin/nginx -t >/dev/null 2>&1 || return 1
                ;;
            *) /usr/sbin/service "$service_name" configtest >/dev/null 2>&1 || return 1 ;;
        esac
    done
)

vx_graceful_apply() {
    local restart=${1:-} recover_inactive=${2:-no} service_name roles=''
    shift 2
    local -a services=("$@")

    [[ "$restart" != no ]] || return 0
    vx_graceful_apply_configtest "${services[@]}" || return 1

    # Keep public deferral behavior, but queue the VX reload boundary rather
    # than an upstream stop/start command.
    if [[ "$restart" == scheduled || ( -z "$restart" && "${SCHEDULED_RESTART:-no}" == yes ) ]]; then
        for service_name in "${services[@]}"; do
            [[ -n "$service_name" && "$service_name" != remote ]] || continue
            [[ " $roles " == *" web "* || "$service_name" != "${WEB_SYSTEM:-}" ]] || roles="${roles:+$roles }web"
            [[ " $roles " == *" proxy "* || "$service_name" != "${PROXY_SYSTEM:-}" ]] || roles="${roles:+$roles }proxy"
        done
        [[ -n "$roles" ]] || return 0
        printf '%s %s now\n' "$BIN/v-apply-vx-graceful-services" "$roles" \
            >>"$VESTA/data/queue/restart.pipe"
        return
    fi

    for service_name in "${services[@]}"; do
        [[ -n "$service_name" && "$service_name" != remote ]] || continue
        if /usr/bin/systemctl is-active --quiet "$service_name"; then
            # A failed reload of an active service is a failed apply.  Do not
            # conceal it with a restart, which would interrupt live requests.
            /usr/sbin/service "$service_name" reload >/dev/null 2>&1 || return 1
            /usr/bin/systemctl is-active --quiet "$service_name" || return 1
        elif [[ "$recover_inactive" == yes ]]; then
            "$BIN/v-restart-service" "$service_name" >/dev/null 2>&1 || return 1
            /usr/bin/systemctl is-active --quiet "$service_name" || return 1
        else
            return 1
        fi
    done
}
