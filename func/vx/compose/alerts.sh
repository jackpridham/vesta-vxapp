#!/usr/bin/env bash

vx_compose_alerts_list_json() {
    local owner="$1"
    local project="$2"
    local root alerts

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    alerts='[]'
    if [[ -f "$root/alerts.json" ]]; then
        alerts="$(jq -c 'if type == "array" then . else [] end' \
            "$root/alerts.json")" || return 1
    fi
    jq -n \
        --arg owner "$owner" \
        --arg project "$project" \
        --argjson alerts "$alerts" \
        '{OWNER: $owner, PROJECT: $project, ALERTS: $alerts}'
}

vx_compose_alert_notify() {
    local owner="$1"
    local project="$2"
    local type="$3"
    local value="$4"

    [[ -n "${VX_COMPOSE_NOTIFICATION_COMMAND:-}" ]] || return 0
    [[ -x "$VX_COMPOSE_NOTIFICATION_COMMAND" ]] || return 1
    "$VX_COMPOSE_NOTIFICATION_COMMAND" \
        "$owner" "$project" "$type" "$value"
}

vx_compose_backup_alert_set() {
    local owner="$1" project="$2" type="$3" message="$4"
    local root old updated temp aid notify=no
    case "$type" in
        missed-run|backup-failure|freshness-breach|encryption-unavailable|\
        replication-lag|replication-failure|restore-test-failure) ;;
        *) return 1 ;;
    esac
    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    message="$(vx_compose_redact_text "$root" "$message")"
    old='[]'
    [[ ! -f "$root/alerts.json" ]] \
        || old="$(jq -c 'if type=="array" then . else [] end' \
            "$root/alerts.json" 2>/dev/null)" || old='[]'
    if jq -e --arg type "$type" \
        'any(.[]; .TYPE==$type and .STATUS=="open")' <<<"$old" >/dev/null; then
        return 0
    fi
    aid="$(jq '[.[].AID] | max // 0 | . + 1' <<<"$old")"
    updated="$(jq -c --arg type "$type" --arg value "$message" \
        --arg now "$(vx_compose_now)" --argjson aid "$aid" \
        '. + [{AID:$aid,TYPE:$type,STATUS:"open",ACK:false,OPENED:$now,
            CLOSED:null,VALUE:$value,THRESHOLD:"resolved"}]' <<<"$old")" \
        || return 1
    temp="$(mktemp "$root/.alerts.XXXXXX")" || return 1
    if ! jq -S . <<<"$updated" >"$temp" \
        || ! chmod 0640 "$temp" \
        || ! mv -f -- "$temp" "$root/alerts.json"; then
        rm -f -- "$temp"
        return 1
    fi
    [[ ! -f "$root/alerts.conf" ]] \
        || notify="$(jq -r '.NOTIFY // false' "$root/alerts.conf" 2>/dev/null)"
    vx_compose_audit "$root" "alert-$type" opened "$message" || :
    [[ "$notify" != true ]] \
        || vx_compose_alert_notify "$owner" "$project" "$type" "$message" || :
}

vx_compose_backup_alert_close() {
    local owner="$1" project="$2" type="$3" root temp
    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -f "$root/alerts.json" ]] || return 0
    jq -e --arg type "$type" \
        'any(.[]; .TYPE==$type and .STATUS=="open")' \
        "$root/alerts.json" >/dev/null || return 0
    temp="$(mktemp "$root/.alerts.XXXXXX")" || return 1
    if ! jq --arg type "$type" --arg now "$(vx_compose_now)" \
        'map(if .TYPE==$type and .STATUS=="open"
            then .STATUS="closed" | .CLOSED=$now else . end)' \
        "$root/alerts.json" >"$temp" \
        || ! chmod 0640 "$temp" \
        || ! mv -f -- "$temp" "$root/alerts.json"; then
        rm -f -- "$temp"
        return 1
    fi
    vx_compose_audit "$root" "alert-$type" closed 'condition recovered' || :
}

vx_compose_alerts_evaluate() {
    local owner="$1"
    local project="$2"
    local health_file="$3"
    local metrics_file="$4"
    local root config old desired updated temp_file notify type value metrics
    local memory_limit memory_threshold
    local -a opened_types=() closed_types=()

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    config="$root/alerts.conf"
    [[ -f "$config" && -f "$health_file" && -f "$metrics_file" ]] \
        || return 1
    jq -e '
        type == "object"
        and (.CPU_PCT | type == "number")
        and (.MEMORY_PCT | type == "number")
        and (.NETWORK_MBPS | type == "number")
        and (.NOTIFY | type == "boolean")
    ' "$config" >/dev/null || return 1
    jq -e 'type == "object"' "$health_file" >/dev/null || return 1
    metrics="$(tail -n 1 "$metrics_file")"
    jq -e 'type == "object"' <<<"$metrics" >/dev/null || return 1
    memory_limit="$(vx_compose_meta_get "$root/policy.conf" MEMORY_MB 2>/dev/null)" \
        || memory_limit=0
    [[ "$memory_limit" =~ ^[0-9]+$ ]] || memory_limit=0
    memory_threshold="$(jq -n \
        --argjson limit "$memory_limit" \
        --argjson pct "$(jq '.MEMORY_PCT' "$config")" \
        '$limit * $pct / 100')"
    desired="$(jq -n \
        --arg health "$(jq -r '.STATUS // "unknown"' "$health_file")" \
        --argjson cpu "$(jq '.CPU_PCT // 0' <<<"$metrics")" \
        --argjson memory "$(jq '.MEMORY_MB // 0' <<<"$metrics")" \
        --argjson rx "$(jq '.RX_MBPS // 0' <<<"$metrics")" \
        --argjson tx "$(jq '.TX_MBPS // 0' <<<"$metrics")" \
        --argjson cpu_threshold "$(jq '.CPU_PCT' "$config")" \
        --argjson memory_threshold "$memory_threshold" \
        --argjson network_threshold "$(jq '.NETWORK_MBPS' "$config")" '[
            {
                TYPE: "health",
                ACTIVE: ($health == "unhealthy" or $health == "degraded"),
                VALUE: $health,
                THRESHOLD: "healthy"
            },
            {
                TYPE: "cpu",
                ACTIVE: ($cpu >= $cpu_threshold),
                VALUE: $cpu,
                THRESHOLD: $cpu_threshold
            },
            {
                TYPE: "memory",
                ACTIVE: ($memory >= $memory_threshold and $memory_threshold > 0),
                VALUE: $memory,
                THRESHOLD: $memory_threshold
            },
            {
                TYPE: "network",
                ACTIVE: (([$rx, $tx] | max) >= $network_threshold),
                VALUE: ([$rx, $tx] | max),
                THRESHOLD: $network_threshold
            }
        ]')"
    old='[]'
    [[ ! -f "$root/alerts.json" ]] \
        || old="$(jq -c 'if type == "array" then . else [] end' \
            "$root/alerts.json")"
    while IFS= read -r type; do
        opened_types+=("$type")
    done < <(jq -r --argjson old "$old" '
        .[] as $want
        | select($want.ACTIVE)
        | select(
            ([
                $old[]
                | select(
                    .TYPE == $want.TYPE
                    and .STATUS == "open"
                )
            ] | length)
            == 0
        )
        | $want.TYPE
    ' <<<"$desired")
    updated="$(jq -n \
        --arg now "$(vx_compose_now)" \
        --argjson old "$old" \
        --argjson desired "$desired" '
        def current($type):
            [$old[] | select(.TYPE == $type and .STATUS == "open")] | last;
        def max_aid: ([$old[].AID] | max // 0);
        reduce $desired[] as $want
            ({
                alerts: $old,
                next: (max_aid + 1)
            };
                (current($want.TYPE)) as $current
                | if $want.ACTIVE and $current == null then
                    .alerts += [{
                        AID: .next,
                        TYPE: $want.TYPE,
                        STATUS: "open",
                        ACK: false,
                        OPENED: $now,
                        CLOSED: null,
                        VALUE: $want.VALUE,
                        THRESHOLD: $want.THRESHOLD
                    }]
                    | .next += 1
                  elif $want.ACTIVE then
                    .alerts |= map(
                        if .AID == $current.AID then
                            .VALUE = $want.VALUE
                            | .THRESHOLD = $want.THRESHOLD
                        else . end
                    )
                  elif $current != null then
                    .alerts |= map(
                        if .AID == $current.AID then
                            .STATUS = "closed"
                            | .CLOSED = $now
                            | .VALUE = $want.VALUE
                        else . end
                    )
                  else . end
            )
        | .alerts
    ')"
    while IFS= read -r type; do
        closed_types+=("$type")
    done < <(jq -r --argjson old "$old" '
        $old[] as $prior
        | select($prior.STATUS == "open")
        | select(
            any(.[];
                .TYPE == $prior.TYPE and .ACTIVE == false
            )
        )
        | $prior.TYPE
    ' <<<"$desired")
    temp_file="$(mktemp "$root/.alerts.XXXXXX")"
    jq -S . <<<"$updated" >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f -- "$temp_file" "$root/alerts.json"
    notify="$(jq -r '.NOTIFY' "$config")"
    for type in "${opened_types[@]}"; do
        value="$(jq -r --arg type "$type" \
            '.[] | select(.TYPE == $type) | .VALUE' <<<"$desired")"
        vx_compose_audit "$root" "alert-$type" opened \
            "threshold exceeded: $value" || true
        [[ "$notify" != true ]] \
            || vx_compose_alert_notify "$owner" "$project" "$type" "$value" \
            || true
    done
    for type in "${closed_types[@]}"; do
        vx_compose_audit "$root" "alert-$type" closed 'threshold recovered' \
            || true
    done
}

vx_compose_alert_acknowledge() {
    local owner="$1"
    local project="$2"
    local aid="$3"
    local root temp_file

    vx_compose_require_project "$owner" "$project" || return 1
    [[ "$aid" =~ ^[1-9][0-9]*$ ]] \
        || {
            vx_compose_error 'invalid Compose alert identifier'
            return 1
        }
    root="$(vx_compose_project_root "$owner" "$project")"
    jq -e --argjson aid "$aid" \
        'any(.[]; .AID == $aid)' "$root/alerts.json" >/dev/null \
        || {
            vx_compose_error "Compose alert does not exist: $aid"
            return 1
        }
    temp_file="$(mktemp "$root/.alerts.XXXXXX")"
    jq --argjson aid "$aid" \
        'map(if .AID == $aid then .ACK = true else . end)' \
        "$root/alerts.json" >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f -- "$temp_file" "$root/alerts.json"
    vx_compose_audit "$root" alert-acknowledge succeeded \
        "acknowledged alert $aid"
}
