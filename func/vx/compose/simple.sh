#!/usr/bin/env bash

# Render the already validated globals produced by vx_docker_load_spec. This is
# the narrow compatibility seam between the legacy simple form and Compose.
vx_compose_simple_metadata_write_candidate() {
    local owner="$1"
    local host_port="$2"
    local candidate="$3"

    jq -n -S \
        --arg owner "$owner" \
        --arg name "$NAME" \
        --arg image "$IMAGE" \
        --arg command "${COMMAND:-}" \
        --arg environment "${ENV:-}" \
        --arg mounts "${MOUNTS:-}" \
        --arg host_port "$host_port" \
        --arg container_port "$CONTAINER_PORT" \
        --arg domain "${DOMAIN:-}" \
        --arg route_path "${ROUTE_PATH:-}" \
        --arg auto_start "${AUTO_START:-yes}" \
        --arg restart_policy "${RESTART_POLICY:-unless-stopped}" \
        --arg healthcheck_type "${HEALTHCHECK_TYPE:-none}" \
        --arg healthcheck_target "${HEALTHCHECK_TARGET:-}" \
        --arg healthcheck_interval "${HEALTHCHECK_INTERVAL:-60}" \
        --arg cpu_alert_pct "${CPU_ALERT_PCT:-85}" \
        --arg mem_alert_mb "${MEM_ALERT_MB:-1024}" \
        --arg net_alert_mbps "${NET_ALERT_MBPS:-50}" \
        --arg alert_email "${ALERT_EMAIL:-yes}" '{
            GENERATED: true,
            OWNER: $owner,
            NAME: $name,
            IMAGE: $image,
            COMMAND: $command,
            ENV: $environment,
            MOUNTS: $mounts,
            HOST_PORT: $host_port,
            CONTAINER_PORT: $container_port,
            DOMAIN: $domain,
            ROUTE_PATH: $route_path,
            AUTO_START: $auto_start,
            RESTART_POLICY: $restart_policy,
            HEALTHCHECK_TYPE: $healthcheck_type,
            HEALTHCHECK_TARGET: $healthcheck_target,
            HEALTHCHECK_INTERVAL: $healthcheck_interval,
            CPU_ALERT_PCT: $cpu_alert_pct,
            MEM_ALERT_MB: $mem_alert_mb,
            NET_ALERT_MBPS: $net_alert_mbps,
            ALERT_EMAIL: $alert_email
        }' >"$candidate/simple.json" || return 1
    chmod 0600 "$candidate/simple.json"
}

vx_compose_simple_render_loaded() {
    local owner="$1"
    local host_port="$2"
    local output_file="$3"
    local record

    record="NAME='$NAME' CTN_NAME='vx-$owner-$NAME' OWNER='$owner' \
IMAGE='$IMAGE' COMMAND='${COMMAND:-}' ENV='${ENV:-}' MOUNTS='${MOUNTS:-}' \
HOST_PORT='$host_port' CONTAINER_PORT='$CONTAINER_PORT' DOMAIN='${DOMAIN:-}' \
ROUTE_PATH='${ROUTE_PATH:-}' AUTO_START='${AUTO_START:-yes}' \
RESTART_POLICY='${RESTART_POLICY:-unless-stopped}' \
HEALTHCHECK_TYPE='${HEALTHCHECK_TYPE:-none}' \
HEALTHCHECK_TARGET='${HEALTHCHECK_TARGET:-}' \
HEALTHCHECK_INTERVAL='${HEALTHCHECK_INTERVAL:-60}'"
    vx_compose_migration_render "$owner" "$record" "$output_file"
}

vx_compose_simple_prepare_binds() {
    local owner="$1"
    local project="$2"
    local item source bind_root

    [[ -n "${MOUNTS:-}" ]] || return 0
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    install -d -m 0750 "$bind_root"
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        source="${item%%:*}"
        [[ "$source" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || return 1
        install -d -m 0750 "$bind_root/$source"
        if id -u "$owner" >/dev/null 2>&1; then
            chown "$owner:$owner" "$bind_root/$source"
        fi
    done <<<"${MOUNTS//||/$'\n'}"
}

vx_compose_simple_alerts_write() {
    local owner="$1"
    local project="$2"
    local root notify

    root="$(vx_compose_project_root "$owner" "$project")"
    notify=false
    [[ "${ALERT_EMAIL:-yes}" != yes ]] || notify=true
    jq -n \
        --argjson cpu "${CPU_ALERT_PCT:-85}" \
        --argjson memory_mb "${MEM_ALERT_MB:-1024}" \
        --argjson network "${NET_ALERT_MBPS:-50}" \
        --argjson notify "$notify" '{
            CPU_PCT: $cpu,
            MEMORY_PCT: ($memory_mb * 100 / 128),
            NETWORK_MBPS: $network,
            NOTIFY: $notify
        }' >"$root/.alerts.conf.new" || return 1
    chmod 0640 "$root/.alerts.conf.new"
    mv -f -- "$root/.alerts.conf.new" "$root/alerts.conf"
}

vx_compose_simple_add_loaded() {
    local owner="$1"
    local host_port="$2"
    local temp_root compose_file candidate root result=0

    temp_root="$(mktemp -d)"
    compose_file="$temp_root/compose.yaml"
    candidate="$temp_root/candidate"
    if ! {
        vx_compose_simple_prepare_binds "$owner" "$NAME" \
        && vx_compose_simple_render_loaded "$owner" "$host_port" "$compose_file" \
        && vx_compose_prepare_candidate \
            "$owner" "$NAME" "$compose_file" "$candidate" standard \
        && vx_compose_simple_metadata_write_candidate \
            "$owner" "$host_port" "$candidate" \
        && vx_compose_store_new "$owner" "$NAME" standard "$candidate"
    }; then
        rm -rf -- "$temp_root"
        return 1
    fi
    rm -rf -- "$temp_root"
    root="$(vx_compose_project_root "$owner" "$NAME")"
    vx_compose_simple_alerts_write "$owner" "$NAME" || return 1
    if [[ "${AUTO_START:-yes}" == yes ]]; then
        vx_compose_deploy "$owner" "$NAME" || result=1
    else
        vx_compose_update_state "$owner" "$NAME" stopped || result=1
    fi
    if [[ "$result" -eq 0 && -n "${DOMAIN:-}" ]]; then
        vx_compose_route_add \
            "$owner" "$NAME" "$DOMAIN" "$NAME" "$CONTAINER_PORT" \
            http "${ROUTE_PATH:-/}" || result=1
    fi
    if [[ "$result" -ne 0 ]]; then
        vx_compose_remove "$owner" "$NAME" >/dev/null 2>&1 || true
        return 1
    fi
    vx_compose_audit "$root" simple-add succeeded
}

vx_compose_simple_change_loaded() {
    local owner="$1"
    local project="$2"
    local host_port="$3"
    local root old_revision old_routes temp_root compose_file candidate
    local route_ok=yes

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    old_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    old_routes="$(mktemp)"
    install -m 0600 "$root/routes.conf" "$old_routes"
    temp_root="$(mktemp -d)"
    compose_file="$temp_root/compose.yaml"
    candidate="$temp_root/candidate"
    if ! {
        vx_compose_simple_prepare_binds "$owner" "$project" \
        && vx_compose_simple_render_loaded "$owner" "$host_port" "$compose_file" \
        && vx_compose_prepare_candidate \
            "$owner" "$project" "$compose_file" "$candidate" standard \
        && vx_compose_simple_metadata_write_candidate \
            "$owner" "$host_port" "$candidate" \
        && vx_compose_transaction_update \
            "$owner" "$project" "$candidate"
    }; then
        rm -rf -- "$temp_root" "$old_routes"
        return 1
    fi
    rm -rf -- "$temp_root"
    vx_compose_routes_clear "$owner" "$project" || route_ok=no
    if [[ "$route_ok" == yes && -n "${DOMAIN:-}" ]]; then
        vx_compose_route_add \
            "$owner" "$project" "$DOMAIN" "$project" \
            "$CONTAINER_PORT" http "${ROUTE_PATH:-/}" || route_ok=no
    fi
    if [[ "$route_ok" != yes ]]; then
        vx_compose_rollback "$owner" "$project" "$old_revision" || true
        install -m 0640 "$old_routes" "$root/routes.conf"
        vx_compose_routes_apply "$owner" "$project" || true
        rm -f -- "$old_routes"
        return 1
    fi
    rm -f -- "$old_routes"
    vx_compose_simple_alerts_write "$owner" "$project" || return 1
    [[ "${AUTO_START:-yes}" == yes ]] \
        || vx_compose_stop "$owner" "$project" || return 1
    vx_compose_audit "$root" simple-change succeeded
}
