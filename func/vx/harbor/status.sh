#!/usr/bin/env bash

vx_harbor_local_socket_path() {
    printf '%s\n' '/run/vesta-harbor/proxy.sock'
}

vx_harbor_local_api_guard() {
    local socket="$1" method="$2" path="$3"
    [[ "$socket" == "$(vx_harbor_local_socket_path)" ]] || return 1
    [[ "$method" == GET ]] || return 1
    [[ "$path" == /api/v2.0/health ]]
}

vx_harbor_public_endpoint_guard() {
    local method="$1" path="$2"
    [[ "$method" == GET ]] || return 1
    [[ "$path" == /v2/ || "$path" == /service/token ]]
}

vx_harbor_status_json() {
    local root provider origin mode pinned running health pending failed backup_age certificate_state now backup_time
    root="$(vx_harbor_root)" || return 1
    provider="$root/provider.json"
    vx_harbor_provider_state_validate "$provider" || return 1
    mode="$(/usr/bin/jq -r '.MODE' "$provider")"
    pinned="$(/usr/bin/jq -r '.PINNED_VERSION' "$provider")"
    running="$(/usr/bin/jq -r '.RUNNING_VERSION // empty' "$provider")"
    origin="$(vx_harbor_origin_json 2>/dev/null || :)"
    certificate_state=unavailable
    [[ -n "$origin" ]] && certificate_state=valid
    origin="$(/usr/bin/jq -r '.ORIGIN // empty' <<<"${origin:-null}" 2>/dev/null || :)"
    health=unavailable
    [[ "$mode" == disabled ]] && health=disabled
    pending=0
    failed=0
    if /usr/bin/find "$root/operations" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | /usr/bin/grep -q .; then
        pending="$(/usr/bin/jq -s '[.[] | select(.STATE == "pending")] | length' "$root"/operations/*.json)"
        failed="$(/usr/bin/jq -s '[.[] | select(.STATE == "failed")] | length' "$root"/operations/*.json)"
    fi
    backup_age=null
    if [[ -n "$(/usr/bin/jq -r '.LAST_BACKUP_ID // empty' "$provider")" ]]; then
        backup_time="$(/usr/bin/stat -c %Y "$root/backups/$(/usr/bin/jq -r '.LAST_BACKUP_ID' "$provider")" 2>/dev/null || :)"
        now="$(/usr/bin/date -u +%s)"
        [[ "$backup_time" =~ ^[0-9]+$ && "$backup_time" -le "$now" ]] && backup_age=$((now - backup_time))
    fi
    /usr/bin/jq -n --arg mode "$mode" --arg pinned "$pinned" \
      --arg running "$running" --arg origin "$origin" --arg health "$health" \
      --argjson pending "$pending" --argjson failed "$failed" \
      --argjson backup_age "$backup_age" --arg certificate "$certificate_state" '
      {MODE:$mode,PINNED_VERSION:$pinned,RUNNING_VERSION:(if $running=="" then null else $running end),
       ORIGIN:(if $origin=="" then null else $origin end),HEALTH:$health,
       PENDING_OPERATIONS:$pending,FAILED_OPERATIONS:$failed,
       BACKUP_AGE_SECONDS:$backup_age,CERTIFICATE_STATE:$certificate}'
}
