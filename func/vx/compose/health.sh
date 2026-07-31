#!/usr/bin/env bash

vx_compose_runtime_containers_json() {
    local owner="$1"
    local project="$2"
    local root docker_bin container_id raw raw_ids
    local -a container_ids=()

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    raw_ids="$(
        env -i \
            PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" ps -aq \
            --filter 'label=vx.managed=yes' \
            --filter "label=vx.user=$owner" \
            --filter "label=vx.project=$project"
    )" || return 1
    while IFS= read -r container_id; do
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] \
            && container_ids+=("$container_id")
    done <<<"$raw_ids"
    if ((${#container_ids[@]} == 0)); then
        printf '[]\n'
        return
    fi
    raw="$(
        env -i \
            PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" inspect "${container_ids[@]}"
    )" || return 1
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg runtime "$(vx_compose_runtime_name "$owner" "$project")" '
            type == "array"
            and all(.[];
                .Config.Labels["vx.managed"] == "yes"
                and .Config.Labels["vx.user"] == $owner
                and .Config.Labels["vx.project"] == $project
                and .Config.Labels["com.docker.compose.project"] == $runtime
                and (
                    .Config.Labels["com.docker.compose.service"]
                    | type == "string" and length > 0
                )
            )
        ' <<<"$raw" >/dev/null \
        || {
            vx_compose_error 'Compose runtime container ownership mismatch'
            return 1
        }
    jq -c . <<<"$raw"
}

vx_compose_health_collect() {
    local owner="$1"
    local project="$2"
    local root canonical metadata desired containers snapshot temp_file
    local source freshness observed_at

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    canonical="$root/runtime/canonical.json"
    metadata="$root/project.conf"
    desired="$(vx_compose_meta_get "$metadata" STATE)" || return 1
    observed_at="$(vx_compose_now)"
    source=docker
    freshness=fresh
    if ! containers="$(
        vx_compose_runtime_containers_json "$owner" "$project"
    )"; then
        containers='[]'
        source=docker-unavailable
        freshness=unavailable
    fi
    snapshot="$(jq -n \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg desired "$desired" \
        --arg observed_at "$observed_at" \
        --arg source "$source" \
        --arg freshness "$freshness" \
        --argjson canonical "$(cat "$canonical")" \
        --argjson containers "$containers" '
        def service_state($service):
            [
                $containers[]
                | select(
                    .Config.Labels["com.docker.compose.service"] == $service
                )
            ] as $matches
            | (
                $canonical.services[$service].healthcheck != null
                and (
                    $canonical.services[$service].healthcheck.disable
                    // false
                ) != true
            ) as $has_check
            | if ($matches | length) != 1 then
                {
                    RUNTIME_STATE: "missing",
                    HEALTH: "unknown",
                    HEALTHCHECK: $has_check,
                    CONTAINER_ID: null,
                    RESTART_COUNT: 0,
                    STARTED_AT: null,
                    UPTIME_SECONDS: 0,
                    OOM_KILLED: false,
                    FAILING_STREAK: 0,
                    HEALTH_OUTPUT: ""
                }
              else
                $matches[0] as $container
                | ($container.State.Status // "unknown") as $runtime
                | (
                    if $runtime == "running" and $has_check then
                        ($container.State.Health.Status // "unknown")
                    elif $runtime == "running" then "healthy"
                    elif ($runtime == "created" or $runtime == "restarting") then
                        "starting"
                    elif $desired == "running" then "unhealthy"
                    else "unknown"
                    end
                ) as $health
                | {
                    RUNTIME_STATE: $runtime,
                    HEALTH: (
                        if (
                            $health == "healthy"
                            or $health == "starting"
                            or $health == "unhealthy"
                            or $health == "degraded"
                        ) then $health else "unknown" end
                    ),
                    HEALTHCHECK: $has_check,
                    CONTAINER_ID: $container.Id,
                    RESTART_COUNT: (
                        $container.RestartCount // 0
                        | if type == "number" and . >= 0 then . else 0 end
                    ),
                    STARTED_AT: (
                        $container.State.StartedAt
                        // null
                        | if type == "string" and length > 0 then . else null end
                    ),
                    UPTIME_SECONDS: (
                        ($container.State.StartedAt // "") as $started
                        | (
                            $started
                            | sub("\\.[0-9]+Z$"; "Z")
                            | fromdateiso8601?
                        ) as $epoch
                        | if $epoch == null then 0
                          else ([0, (now - $epoch | floor)] | max)
                          end
                    ),
                    OOM_KILLED: (
                        $container.State.OOMKilled // false
                        | if type == "boolean" then . else false end
                    ),
                    FAILING_STREAK: (
                        $container.State.Health.FailingStreak // 0
                        | if type == "number" and . >= 0 then . else 0 end
                    ),
                    HEALTH_OUTPUT: (
                        [
                            $container.State.Health.Log[]?
                            | select((.Output // "") != "")
                        ]
                        | if length > 0
                            then "[redacted health check output]"
                            else ""
                          end
                    )
                }
              end;
        (reduce ($canonical.services | keys[]) as $service
            ({}; .[$service] = service_state($service))) as $services
        | (
            [$services[].HEALTH]
            | if index("unhealthy") != null then "unhealthy"
              elif index("degraded") != null then "degraded"
              elif index("starting") != null then "starting"
              elif index("unknown") != null then "unknown"
              else "healthy"
              end
        ) as $status
        | {
            OWNER: $owner,
            PROJECT: $project,
            STATUS: $status,
            OBSERVED_AT: $observed_at,
            UPDATED: $observed_at,
            SOURCE: $source,
            AGE_SECONDS: 0,
            FRESHNESS: $freshness,
            SERVICES: $services
        }
    ')" || return 1
    temp_file="$(mktemp "$root/runtime/.last-health.XXXXXX")"
    jq -S . <<<"$snapshot" >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f -- "$temp_file" "$root/runtime/last-health.json"
    cat "$root/runtime/last-health.json"
}

vx_compose_health_observation_json() {
    local owner="$1"
    local project="$2"
    local max_age="${3:-120}"
    local root snapshot now_epoch observed_epoch age

    [[ "$max_age" =~ ^[0-9]+$ ]] || return 1
    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    snapshot="$root/runtime/last-health.json"
    if [[ ! -f "$snapshot" || -L "$snapshot" ]]; then
        jq -n \
            --arg owner "$owner" \
            --arg project "$project" \
            --arg observed_at "$(vx_compose_now)" '{
                OWNER: $owner,
                PROJECT: $project,
                STATUS: "unknown",
                OBSERVED_AT: $observed_at,
                UPDATED: $observed_at,
                SOURCE: "snapshot-unavailable",
                AGE_SECONDS: 0,
                FRESHNESS: "unavailable",
                SERVICES: {}
            }'
        return
    fi
    now_epoch="$(date -u +%s)"
    observed_epoch="$(jq -r '
        (.OBSERVED_AT // .UPDATED // "")
        | sub("\\.[0-9]+Z$"; "Z")
        | fromdateiso8601? // 0
    ' "$snapshot")"
    age=$((now_epoch - observed_epoch))
    ((age >= 0)) || age=0
    jq \
        --argjson age "$age" \
        --argjson max_age "$max_age" '
            .AGE_SECONDS = $age
            | .FRESHNESS = (
                if (.FRESHNESS // "") == "unavailable"
                    or $age > ($max_age * 10)
                    then "unavailable"
                elif $age > $max_age then "stale"
                else "fresh"
                end
            )
            | .OBSERVED_AT = (.OBSERVED_AT // .UPDATED)
            | .SOURCE = (.SOURCE // "legacy-snapshot")
        ' "$snapshot"
}

vx_compose_monitor_project() {
    local owner="$1"
    local project="$2"
    local root health metrics

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    health="$(vx_compose_health_collect "$owner" "$project")" || return 1
    metrics="$(vx_compose_metrics_sample "$owner" "$project")" || return 1
    vx_compose_alerts_evaluate \
        "$owner" "$project" \
        "$root/runtime/last-health.json" \
        "$root/runtime/metrics.jsonl" || return 1
    jq -n \
        --argjson health "$health" \
        --argjson metrics "$metrics" \
        '{HEALTH: $health, METRICS: $metrics}'
}

vx_compose_monitor_all() {
    local user_root projects_root project_root owner project

    for user_root in "$VESTA/data/users"/*; do
        [[ -d "$user_root" ]] || continue
        owner="$(basename -- "$user_root")"
        vx_compose_owner_is_valid "$owner" || continue
        projects_root="$user_root/docker-projects"
        [[ -d "$projects_root" ]] || continue
        for project_root in "$projects_root"/*; do
            [[ -d "$project_root" && -f "$project_root/project.conf" ]] \
                || continue
            project="$(basename -- "$project_root")"
            vx_compose_project_is_valid "$project" || continue
            vx_compose_monitor_project "$owner" "$project" >/dev/null 2>&1 \
                || true
        done
    done
}
