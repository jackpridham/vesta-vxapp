#!/usr/bin/env bash

vx_harbor_publisher_change_locked() {
    local owner="$1" secret_file="$2" path namespace old generation username response id now json old_json
    path="$(vx_harbor_owner_state_path "$owner")"; vx_harbor_owner_state_validate "$path" || return 1
    [[ -f "$secret_file" && ! -L "$secret_file" && "$(/usr/bin/stat -c %s "$secret_file")" -le 65536 ]] || return 1
    IFS= read -r secret <"$secret_file"; [[ ${#secret} -ge 16 && ${#secret} -le 256 && "$secret" != *$'\n'* ]] || return 1
    old_json="$(<"$path")"; namespace="$(/usr/bin/jq -r '.NAMESPACE' "$path")"; old="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID' "$path")"; generation="$(/usr/bin/date -u +%s)"; username="$namespace-publisher-$generation"
    response="$(printf %s "$secret" | vx_harbor_api_robot_create "$namespace" "$username" push-pull)" || return 75; unset secret; id="$(/usr/bin/jq -er '.id' <<<"$response")" || return 1
    vx_harbor_api_robot_get "$id" >/dev/null || return 75
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; json="$(/usr/bin/jq --argjson id "$id" --arg user "$username" --arg now "$now" '.PUBLISHER_ROBOT_ID=$id|.PUBLISHER_USERNAME=$user|.PUBLISHER_ENABLED=true|.STATE="publisher-ready"|.UPDATED_AT=$now|.LAST_ERROR=null' "$path")"
    _vx_harbor_owner_write "$path" "$json" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    if [[ "$old" != null ]] && ! vx_harbor_api_robot_delete "$old" >/dev/null; then
        vx_harbor_api_robot_disable "$id" >/dev/null 2>&1 || :
        _vx_harbor_owner_write "$path" "$old_json" || :
        return 75
    fi
}

vx_harbor_publisher_revoke_locked() { local owner="$1" path="$2" id now json; vx_harbor_owner_state_validate "$path" || return 1; id="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID' "$path")"; [[ "$id" == null ]] || vx_harbor_api_robot_disable "$id" >/dev/null || return 75; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; json="$(/usr/bin/jq --arg now "$now" '.PUBLISHER_ROBOT_ID=null|.PUBLISHER_USERNAME=null|.PUBLISHER_ENABLED=false|.STATE=(if .RUNTIME_ROBOT_ID==null then "retained" else "publisher-disabled" end)|.UPDATED_AT=$now' "$path")"; _vx_harbor_owner_write "$path" "$json"; }

vx_harbor_registry_info_json() {
    local owner="$1" project="$2" path provider observation origin state health freshness quota used observed now epoch age publisher
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1; path="$(vx_harbor_owner_state_path "$owner")"; provider="$(vx_harbor_root)/provider.json"
    if ! vx_harbor_provider_enabled; then /usr/bin/jq -n '{MANAGED:false,STATE:"disabled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; fi
    vx_harbor_owner_is_eligible "$owner" || { /usr/bin/jq -n '{MANAGED:true,STATE:"not-entitled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; }
    vx_harbor_owner_state_validate "$path" || return 1; observation="$(vx_harbor_root)/observations/$owner.json"; origin="$(/usr/bin/jq -r '.ORIGIN' "$provider")"; state="$(/usr/bin/jq -r '.STATE' "$path")"; quota="$(/usr/bin/jq -c '.QUOTA_MB' "$path")"; publisher="$(/usr/bin/jq -r '.PUBLISHER_USERNAME // empty' "$path")"
    used=0; observed=null; freshness=unavailable; health=unavailable
    if [[ -f "$observation" ]] && usage="$(_vx_harbor_observation_json "$owner" 2>/dev/null)"; then used="$(/usr/bin/jq -r '.USED_MB' <<<"$usage")"; observed="$(/usr/bin/jq -c '.OBSERVED_AT' <<<"$usage")"; freshness=fresh; health=healthy; fi
    /usr/bin/jq -n --arg state "${state/runtime-ready/ready}" --arg registry "${origin#https://}" --arg ns "$(/usr/bin/jq -r '.NAMESPACE' "$path")" --arg project "$project" --arg publisher "$publisher" --argjson enabled "$(/usr/bin/jq '.PUBLISHER_ENABLED' "$path")" --argjson quota "$quota" --argjson used "$used" --arg health "$health" --argjson observed "$observed" --arg freshness "$freshness" '{MANAGED:true,STATE:$state,REGISTRY:$registry,NAMESPACE:$ns,REPOSITORY:($registry+"/"+$ns+"/"+$project),PUBLISHER_USERNAME:(if $publisher=="" then null else $publisher end),PUBLISHER_ENABLED:$enabled,QUOTA_MB:$quota,USED_MB:$used,HEALTH:$health,OBSERVED_AT:$observed,FRESHNESS:$freshness}'
}
