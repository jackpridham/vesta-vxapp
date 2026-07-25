#!/usr/bin/env bash

vx_compose_metric_bytes() {
    local value="${1// /}"

    awk -v value="$value" '
        BEGIN {
            if (match(value, /^([0-9]+([.][0-9]+)?)([KMGT]?i?B)$/, parts) == 0) {
                exit 1
            }
            multiplier = 1
            if (parts[3] == "kB") multiplier = 1000
            if (parts[3] == "KB") multiplier = 1000
            if (parts[3] == "KiB") multiplier = 1024
            if (parts[3] == "MB") multiplier = 1000 * 1000
            if (parts[3] == "MiB") multiplier = 1024 * 1024
            if (parts[3] == "GB") multiplier = 1000 * 1000 * 1000
            if (parts[3] == "GiB") multiplier = 1024 * 1024 * 1024
            if (parts[3] == "TB") multiplier = 1000 * 1000 * 1000 * 1000
            if (parts[3] == "TiB") multiplier = 1024 * 1024 * 1024 * 1024
            printf "%.0f\n", parts[1] * multiplier
        }
    '
}

vx_compose_metrics_refresh_owner() {
    local owner="$1"
    local projects_root project_root latest user_conf
    local cpu=0 memory=0 pids=0 rx=0 tx=0 storage=0

    projects_root="$(vx_compose_projects_root "$owner")"
    for project_root in "$projects_root"/*; do
        [[ -f "$project_root/runtime/metrics.jsonl" ]] || continue
        latest="$(tail -n 1 "$project_root/runtime/metrics.jsonl")"
        jq -e 'type == "object"' <<<"$latest" >/dev/null 2>&1 || continue
        cpu="$(jq -n --argjson total "$cpu" --argjson item "$latest" \
            '$total + ($item.CPU_PCT // 0)')"
        memory=$((memory + $(jq -r '.MEMORY_MB // 0 | floor' <<<"$latest")))
        pids=$((pids + $(jq -r '.PIDS // 0 | floor' <<<"$latest")))
        rx="$(jq -n --argjson total "$rx" --argjson item "$latest" \
            '$total + ($item.RX_MBPS // 0)')"
        tx="$(jq -n --argjson total "$tx" --argjson item "$latest" \
            '$total + ($item.TX_MBPS // 0)')"
        storage=$((storage + $(jq -r '.STORAGE_MB // 0 | floor' <<<"$latest")))
    done
    user_conf="$VESTA/data/users/$owner/user.conf"
    [[ -f "$user_conf" ]] || : >"$user_conf"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_CPU_PCT "$cpu"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_MEMORY_MB "$memory"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_PIDS "$pids"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_RX_MBPS "$rx"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_TX_MBPS "$tx"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_RUNTIME_STORAGE_MB "$storage"
}

vx_compose_metrics_sample() {
    local owner="$1"
    local project="$2"
    local root docker_bin containers stats_file services_file line id service
    local cpu mem_usage net_io pids memory rx tx services storage sample
    local timestamp previous='null'
    local history temp_history
    local -a container_ids=()

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    containers="$(vx_compose_runtime_containers_json "$owner" "$project")" \
        || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] && container_ids+=("$id")
    done < <(jq -r '.[].Id' <<<"$containers")
    stats_file="$(mktemp "$root/runtime/.stats.XXXXXX")"
    services_file="$(mktemp "$root/runtime/.services.XXXXXX")"
    : >"$services_file"
    if ((${#container_ids[@]} > 0)); then
        env -i \
            PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" stats --no-stream --format '{{json .}}' \
            "${container_ids[@]}" >"$stats_file" \
            || {
                rm -f -- "$stats_file" "$services_file"
                return 1
            }
    else
        : >"$stats_file"
    fi
    while IFS= read -r line; do
        jq -e 'type == "object"' <<<"$line" >/dev/null 2>&1 || continue
        id="$(jq -r '.ID // empty' <<<"$line")"
        service="$(jq -r --arg id "$id" '
            .[]
            | .Id as $container_id
            | select(
                ($container_id | startswith($id))
                or ($id | startswith($container_id))
            )
            | .Config.Labels["com.docker.compose.service"]
        ' <<<"$containers" | head -n 1)"
        [[ -n "$service" ]] || continue
        cpu="$(jq -r '.CPUPerc // "0%" | sub("%$"; "")' <<<"$line")"
        mem_usage="$(jq -r '.MemUsage // "0B / 0B" | split("/")[0]' <<<"$line")"
        net_io="$(jq -r '.NetIO // "0B / 0B"' <<<"$line")"
        pids="$(jq -r '.PIDs // "0"' <<<"$line")"
        memory="$(vx_compose_metric_bytes "$mem_usage")" || memory=0
        rx="$(vx_compose_metric_bytes "$(cut -d/ -f1 <<<"$net_io")")" || rx=0
        tx="$(vx_compose_metric_bytes "$(cut -d/ -f2 <<<"$net_io")")" || tx=0
        [[ "$cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || cpu=0
        [[ "$pids" =~ ^[0-9]+$ ]] || pids=0
        jq -cn \
            --arg service "$service" \
            --argjson cpu "$cpu" \
            --argjson memory_bytes "$memory" \
            --argjson pids "$pids" \
            --argjson rx "$rx" \
            --argjson tx "$tx" '{
                SERVICE: $service,
                CPU_PCT: $cpu,
                MEMORY_MB: ($memory_bytes / 1048576),
                PIDS: $pids,
                RX_BYTES: $rx,
                TX_BYTES: $tx
            }' >>"$services_file"
    done <"$stats_file"
    services="$(jq -s '
        reduce .[] as $item ({};
            .[$item.SERVICE] = ($item | del(.SERVICE))
        )
    ' "$services_file")"
    rm -f -- "$stats_file" "$services_file"
    storage="$(du -sm -- "$root" "$(vx_compose_project_data_root "$owner" "$project")" \
        2>/dev/null | awk '{ total += $1 } END { print total + 0 }')"
    if declare -F vx_compose_project_volume_storage_mb >/dev/null 2>&1; then
        storage=$((storage + $(vx_compose_project_volume_storage_mb "$owner" "$project")))
    fi
    timestamp="$(vx_compose_now)"
    history="$root/runtime/metrics.jsonl"
    if [[ -f "$history" ]]; then
        previous="$(tail -n 1 "$history")"
        jq -e 'type == "object"' <<<"$previous" >/dev/null 2>&1 \
            || previous='null'
    fi
    sample="$(jq -cn \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg timestamp "$timestamp" \
        --argjson storage "$storage" \
        --argjson previous "$previous" \
        --argjson services "$services" '{
            OWNER: $owner,
            PROJECT: $project,
            TIMESTAMP: $timestamp,
            CPU_PCT: ([$services[].CPU_PCT] | add // 0),
            MEMORY_MB: ([$services[].MEMORY_MB] | add // 0),
            PIDS: ([$services[].PIDS] | add // 0),
            RX_BYTES: ([$services[].RX_BYTES] | add // 0),
            TX_BYTES: ([$services[].TX_BYTES] | add // 0),
            STORAGE_MB: $storage,
            SERVICES: $services
        }
        | . as $current
        | (
            if $previous == null then 0
            else (
                ($current.TIMESTAMP | fromdateiso8601)
                - ($previous.TIMESTAMP | fromdateiso8601)
            )
            end
        ) as $elapsed
        | .RX_MBPS = (
            if (
                $elapsed > 0
                and $current.RX_BYTES >= ($previous.RX_BYTES // 0)
            ) then
                (
                    ($current.RX_BYTES - ($previous.RX_BYTES // 0))
                    / 1048576 / $elapsed
                )
            else 0 end
        )
        | .TX_MBPS = (
            if (
                $elapsed > 0
                and $current.TX_BYTES >= ($previous.TX_BYTES // 0)
            ) then
                (
                    ($current.TX_BYTES - ($previous.TX_BYTES // 0))
                    / 1048576 / $elapsed
                )
            else 0 end
        )')"
    temp_history="$(mktemp "$root/runtime/.metrics.XXXXXX")"
    if [[ -f "$history" ]]; then
        tail -n 2015 "$history" >"$temp_history"
    fi
    printf '%s\n' "$sample" >>"$temp_history"
    tail -n 2016 "$temp_history" >"${temp_history}.bounded"
    chmod 0640 "${temp_history}.bounded"
    mv -f -- "${temp_history}.bounded" "$history"
    rm -f -- "$temp_history"
    vx_compose_metrics_refresh_owner "$owner"
    printf '%s\n' "$sample"
}

vx_compose_metrics_history() {
    local owner="$1"
    local project="$2"
    local period="$3"
    local root history seconds cutoff samples

    vx_compose_require_project "$owner" "$project" || return 1
    case "$period" in
        5m) seconds=300 ;;
        1h) seconds=3600 ;;
        1d) seconds=86400 ;;
        7d) seconds=604800 ;;
        *)
            vx_compose_error "invalid Compose metric period: $period"
            return 1
            ;;
    esac
    root="$(vx_compose_project_root "$owner" "$project")"
    history="$root/runtime/metrics.jsonl"
    cutoff="$(date -u -d "$seconds seconds ago" +'%Y-%m-%dT%H:%M:%SZ')"
    if [[ -f "$history" ]]; then
        samples="$(jq -sc --arg cutoff "$cutoff" \
            '[.[] | select(.TIMESTAMP >= $cutoff)]' "$history")"
    else
        samples='[]'
    fi
    jq -n \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg period "$period" \
        --argjson samples "$samples" '{
            OWNER: $owner,
            PROJECT: $project,
            PERIOD: $period,
            SAMPLES: $samples,
            LATEST: ($samples[-1] // null)
        }'
}
