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

# Legacy command adapters consume the populated record globals after return.
# shellcheck disable=SC2034
vx_compose_simple_load_legacy_record() {
    local owner="$1"
    local project="$2"
    local root metadata simple_file canonical containers runtime_name
    local routes_file domain route

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    simple_file="$root/simple.json"
    canonical="$root/runtime/canonical.json"
    [[ -f "$simple_file" && ! -L "$simple_file"
        && "$(stat -c '%a' "$simple_file")" == 600 ]] \
        || {
            vx_compose_error 'simple Compose provenance metadata is unavailable'
            return 1
        }
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" \
        --slurpfile canonical "$canonical" '
        .IMAGE as $image
        | .GENERATED == true
        and .OWNER == $owner
        and .NAME == $project
        and (.IMAGE | type == "string" and length > 0)
        and ($canonical[0].services | length) == 1
        and any($canonical[0].services[]; .image == $image)
        and all(
            .COMMAND, .ENV, .MOUNTS, .HOST_PORT, .CONTAINER_PORT,
            .DOMAIN, .ROUTE_PATH, .AUTO_START, .RESTART_POLICY,
            .HEALTHCHECK_TYPE, .HEALTHCHECK_TARGET,
            .HEALTHCHECK_INTERVAL, .CPU_ALERT_PCT, .MEM_ALERT_MB,
            .NET_ALERT_MBPS, .ALERT_EMAIL;
            type == "string"
        )
    ' "$simple_file" >/dev/null \
        || {
            vx_compose_error 'simple Compose provenance metadata is invalid'
            return 1
        }

    NAME="$(jq -r '.NAME' "$simple_file")"
    OWNER="$owner"
    IMAGE="$(jq -r '.IMAGE' "$simple_file")"
    COMMAND="$(jq -r '.COMMAND' "$simple_file")"
    ENV="$(jq -r '.ENV' "$simple_file")"
    MOUNTS="$(jq -r '.MOUNTS' "$simple_file")"
    HOST_PORT="$(jq -r '.HOST_PORT' "$simple_file")"
    CONTAINER_PORT="$(jq -r '.CONTAINER_PORT' "$simple_file")"
    DOMAIN="$(jq -r '.DOMAIN' "$simple_file")"
    ROUTE_PATH="$(jq -r '.ROUTE_PATH' "$simple_file")"
    AUTO_START="$(jq -r '.AUTO_START' "$simple_file")"
    RESTART_POLICY="$(jq -r '.RESTART_POLICY' "$simple_file")"
    HEALTHCHECK_TYPE="$(jq -r '.HEALTHCHECK_TYPE' "$simple_file")"
    HEALTHCHECK_TARGET="$(jq -r '.HEALTHCHECK_TARGET' "$simple_file")"
    HEALTHCHECK_INTERVAL="$(jq -r '.HEALTHCHECK_INTERVAL' "$simple_file")"
    CPU_ALERT_PCT="$(jq -r '.CPU_ALERT_PCT' "$simple_file")"
    MEM_ALERT_MB="$(jq -r '.MEM_ALERT_MB' "$simple_file")"
    NET_ALERT_MBPS="$(jq -r '.NET_ALERT_MBPS' "$simple_file")"
    ALERT_EMAIL="$(jq -r '.ALERT_EMAIL' "$simple_file")"
    STATUS="$(vx_compose_meta_get "$metadata" STATE)" || return 1
    CREATED="$(vx_compose_meta_get "$metadata" CREATED)" || return 1
    UPDATED="$(vx_compose_meta_get "$metadata" UPDATED)" || return 1

    runtime_name="$(vx_compose_meta_get "$metadata" COMPOSE_PROJECT)" \
        || return 1
    containers="$(vx_compose_runtime_containers_json "$owner" "$project")" \
        || {
            vx_compose_error 'simple Compose runtime ownership is invalid'
            return 1
        }
    [[ "$(jq -r 'length' <<<"$containers")" -le 1 ]] \
        || {
            vx_compose_error 'simple Compose runtime has multiple containers'
            return 1
        }
    CTN_NAME="$(jq -r '.[0].Name // empty | ltrimstr("/")' \
        <<<"$containers")"
    [[ -n "$CTN_NAME" ]] || CTN_NAME="$runtime_name-$project-1"

    HEALTH_STATUS=unknown
    LAST_HEALTH_AT=''
    if [[ -f "$root/runtime/last-health.json"
        && ! -L "$root/runtime/last-health.json" ]]; then
        HEALTH_STATUS="$(jq -r '.STATUS // "unknown"' \
            "$root/runtime/last-health.json")" || return 1
        LAST_HEALTH_AT="$(jq -r '.UPDATED // ""' \
            "$root/runtime/last-health.json")" || return 1
    fi

    PROXY_MODE=''
    PROXY_TARGET=''
    routes_file="$(vx_compose_routes_desired_path "$owner" "$project")"
    domain="$DOMAIN"
    if [[ -n "$domain" && -f "$routes_file" && ! -L "$routes_file" ]]; then
        route="$(jq -ce --arg domain "$domain" '
            .[$domain]
            | select(
                (.SCHEME == "http" or .SCHEME == "https")
                and (
                    (.HOST_PORT | tostring)
                    | test("^[1-9][0-9]{0,4}$")
                )
            )
        ' "$routes_file")" \
            || {
                vx_compose_error \
                    "simple Compose route metadata is invalid for $domain"
                return 1
            }
        PROXY_MODE=proxy
        PROXY_TARGET="$(jq -r \
            '.SCHEME + "://127.0.0.1:" + (.HOST_PORT | tostring)' \
            <<<"$route")"
    fi
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
    if id -u "$owner" >/dev/null 2>&1; then
        vx_compose_prepare_project_data_roots "$owner" "$project" || return 1
    else
        install -d -m 0750 "$bind_root"
    fi
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        source="${item%%:*}"
        [[ "$source" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || return 1
        if id -u "$owner" >/dev/null 2>&1; then
            vx_compose_managed_bind_leaf_prepare \
                "$owner" "$project" "$source" || return 1
        else
            install -d -m 0750 "$bind_root/$source"
        fi
    done <<<"${MOUNTS//||/$'\n'}"
}

vx_compose_simple_alerts_write_candidate() {
    local candidate="$1"
    local notify temp_file

    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    temp_file="$candidate/.alerts.conf.new"
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
        }' >"$temp_file" || return 1
    chmod 0640 "$temp_file" || return 1
    mv -f -- "$temp_file" "$candidate/alerts.conf"
}

vx_compose_simple_add_loaded() {
    local owner="$1"
    local host_port="$2"
    local temp_root compose_file candidate root result=0
    local ports_locked=no quota_locked=no routes_locked=no

    temp_root="$(mktemp -d)"
    compose_file="$temp_root/compose.yaml"
    candidate="$temp_root/candidate"
    vx_compose_lock_acquire "$owner" "$NAME" || {
        rm -rf -- "$temp_root"
        return 1
    }
    if ! {
        vx_compose_simple_prepare_binds "$owner" "$NAME" \
        && vx_compose_simple_render_loaded "$owner" "$host_port" "$compose_file" \
        && vx_compose_prepare_candidate \
            "$owner" "$NAME" "$compose_file" "$candidate" standard \
        && vx_compose_simple_metadata_write_candidate \
            "$owner" "$host_port" "$candidate" \
        && vx_compose_simple_alerts_write_candidate "$candidate" \
        && vx_compose_routes_stage_simple \
            "$owner" "$NAME" "$candidate/canonical.json" "${DOMAIN:-}" \
            "$NAME" "$CONTAINER_PORT" "${ROUTE_PATH:-/}" \
            "$candidate/routes.conf"
    }; then
        rm -rf -- "$temp_root"
        vx_compose_lock_release
        return 1
    fi
    vx_compose_ports_lock_acquire || {
        rm -rf -- "$temp_root"
        vx_compose_lock_release
        return 1
    }
    ports_locked=yes
    vx_compose_owner_quota_lock_acquire "$owner" || {
        rm -rf -- "$temp_root"
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    quota_locked=yes
    vx_compose_routes_lock_acquire "$owner" || {
        rm -rf -- "$temp_root"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    routes_locked=yes
    if ! vx_compose_routes_validate_reservations \
        "$owner" "$NAME" "$candidate/routes.conf" \
        || ! vx_compose_store_new "$owner" "$NAME" standard "$candidate"; then
        rm -rf -- "$temp_root"
        vx_compose_routes_lock_release
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    rm -rf -- "$temp_root"
    root="$(vx_compose_project_root "$owner" "$NAME")"
    if [[ "${AUTO_START:-yes}" == yes ]]; then
        vx_compose_deploy "$owner" "$NAME" || result=1
    else
        vx_compose_update_state "$owner" "$NAME" stopped || result=1
    fi
    if [[ "$result" -ne 0 ]]; then
        vx_compose_remove "$owner" "$NAME" >/dev/null 2>&1 || true
        [[ "$routes_locked" != yes ]] || vx_compose_routes_lock_release
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if ! vx_compose_audit "$root" simple-add succeeded; then
        vx_compose_routes_lock_release
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    vx_compose_routes_lock_release
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
    vx_compose_lock_release
}

vx_compose_simple_change_loaded() {
    local owner="$1"
    local project="$2"
    local host_port="$3"
    local root temp_root compose_file candidate final_state=running

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
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
        && vx_compose_simple_alerts_write_candidate "$candidate" \
        && vx_compose_routes_stage_simple \
            "$owner" "$project" "$candidate/canonical.json" "${DOMAIN:-}" \
            "$project" "$CONTAINER_PORT" "${ROUTE_PATH:-/}" \
            "$candidate/routes.conf" \
        && {
            [[ "${AUTO_START:-yes}" == yes ]] || final_state=stopped
        } \
        && vx_compose_transaction_update \
            "$owner" "$project" "$candidate" '' "$final_state"
    }; then
        rm -rf -- "$temp_root"
        return 1
    fi
    rm -rf -- "$temp_root"
    vx_compose_audit "$root" simple-change succeeded
}
