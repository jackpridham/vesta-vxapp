#!/usr/bin/env bash

vx_harbor_publisher_change_locked() {
    local owner="$1" path namespace old generation username response id now json operation secret retry_status
    path="$(vx_harbor_owner_state_path "$owner")"; vx_harbor_owner_state_validate "$path" || return 1
    _vx_harbor_rotation_retry_revoke "$owner" publisher >/dev/null && return 0
    retry_status=$?; [[ "$retry_status" == 1 ]] || return "$retry_status"
    IFS= read -r -N 257 secret <&0 || [[ ${#secret} -gt 0 ]]; [[ ${#secret} -ge 16 && ${#secret} -le 256 && "$secret" != *$'\n'* ]] || return 1
    namespace="$(/usr/bin/jq -r '.NAMESPACE' "$path")"; old="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID' "$path")"; generation="$(/usr/bin/date -u +%s)"; username="$namespace-publisher-$generation"
    response="$(printf %s "$secret" | vx_harbor_api_robot_create "$namespace" "$username" push-pull)" || return 75; id="$(/usr/bin/jq -er '.id' <<<"$response")" || return 1
    printf %s "$secret" | vx_harbor_api_credential_probe "$username" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 75; }
    unset secret
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; json="$(/usr/bin/jq --argjson id "$id" --arg user "$username" --arg now "$now" '.PUBLISHER_ROBOT_ID=$id|.PUBLISHER_USERNAME=$user|.PUBLISHER_ENABLED=true|.STATE="publisher-ready"|.UPDATED_AT=$now|.LAST_ERROR=null' "$path")"
    _vx_harbor_owner_write "$path" "$json" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    _vx_harbor_rotation_write "$owner" publisher "$operation" pending-revoke "$id" "$username" "$old" || return 1
    if [[ "$old" == null ]] || vx_harbor_api_robot_delete "$old" >/dev/null; then
        _vx_harbor_rotation_write "$owner" publisher "$operation" converged "$id" "$username" "$old" || return 1
    fi
}

vx_harbor_publisher_revoke_locked() { local owner="$1" path="$2" id now json; vx_harbor_owner_state_validate "$path" || return 1; id="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID' "$path")"; [[ "$id" == null ]] || vx_harbor_api_robot_disable "$id" >/dev/null || return 75; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; json="$(/usr/bin/jq --arg now "$now" '.PUBLISHER_ROBOT_ID=null|.PUBLISHER_USERNAME=null|.PUBLISHER_ENABLED=false|.STATE=(if .RUNTIME_ROBOT_ID==null then "retained" else "publisher-disabled" end)|.UPDATED_AT=$now' "$path")"; _vx_harbor_owner_write "$path" "$json"; }

vx_harbor_registry_info_json() {
    local owner="$1" project="$2" path provider observation provider_observation origin internal_state state health freshness quota used observed now observed_epoch provider_at provider_epoch provider_health publisher
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1; path="$(vx_harbor_owner_state_path "$owner")"; provider="$(vx_harbor_root)/provider.json"
    if ! vx_harbor_provider_enabled; then /usr/bin/jq -n '{MANAGED:false,STATE:"disabled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; fi
    vx_harbor_owner_is_eligible "$owner" || { /usr/bin/jq -n '{MANAGED:true,STATE:"not-entitled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; }
    vx_harbor_owner_state_validate "$path" || return 1; observation="$(vx_harbor_root)/observations/$owner.json"; provider_observation="$(vx_harbor_root)/observations/provider.json"; origin="$(/usr/bin/jq -r '.ORIGIN' "$provider")"; internal_state="$(/usr/bin/jq -r '.STATE' "$path")"; quota="$(/usr/bin/jq -c '.QUOTA_MB' "$path")"; publisher="$(/usr/bin/jq -r '.PUBLISHER_USERNAME // empty' "$path")"
    case "$internal_state" in project-ready) state=provisioning;; runtime-ready|publisher-ready) state=ready;; publisher-disabled) state=publisher-disabled;; retained) state=retained;; unavailable) state=unavailable;; *) return 1;; esac
    used=0; observed=null; freshness=unavailable; health=unavailable; now="$(/usr/bin/date -u +%s)"
    if [[ -f "$observation" ]] && vx_harbor_secure_regular_file "$observation" 0600 && /usr/bin/jq -e 'keys==["GENERATION","OBSERVED_AT","USED_MB"] and (.USED_MB|type=="number" and .>=0)' "$observation" >/dev/null; then
        used="$(/usr/bin/jq -r .USED_MB "$observation")"; observed_value="$(/usr/bin/jq -r .OBSERVED_AT "$observation")"; observed_epoch="$(/usr/bin/date -u -d "$observed_value" +%s 2>/dev/null || :)"
        if [[ "$observed_epoch" =~ ^[0-9]+$ && "$observed_epoch" -le $((now + 30)) ]]; then observed="$(/usr/bin/jq -c .OBSERVED_AT "$observation")"; if (( now - observed_epoch <= 300 )); then freshness=fresh; else freshness=stale; fi; fi
    fi
    if [[ -f "$provider_observation" ]] && vx_harbor_secure_regular_file "$provider_observation" 0600 && /usr/bin/jq -e 'keys==["HEALTH","OBSERVED_AT"] and (.HEALTH|IN("healthy","degraded","unavailable"))' "$provider_observation" >/dev/null; then
        provider_at="$(/usr/bin/jq -r .OBSERVED_AT "$provider_observation")"; provider_epoch="$(/usr/bin/date -u -d "$provider_at" +%s 2>/dev/null || :)"; provider_health="$(/usr/bin/jq -r .HEALTH "$provider_observation")"
        if [[ "$provider_epoch" =~ ^[0-9]+$ ]] && (( provider_epoch <= now + 30 && now - provider_epoch <= 300 )); then health="$provider_health"; [[ "$freshness" == stale && "$health" == healthy ]] && health=degraded; [[ "$freshness" == unavailable ]] && health=unavailable; fi
    fi
    /usr/bin/jq -n --arg state "$state" --arg registry "${origin#https://}" --arg ns "$(/usr/bin/jq -r '.NAMESPACE' "$path")" --arg project "$project" --arg publisher "$publisher" --argjson enabled "$(/usr/bin/jq '.PUBLISHER_ENABLED' "$path")" --argjson quota "$quota" --argjson used "$used" --arg health "$health" --argjson observed "$observed" --arg freshness "$freshness" '{MANAGED:true,STATE:$state,REGISTRY:$registry,NAMESPACE:$ns,REPOSITORY:($registry+"/"+$ns+"/"+$project),PUBLISHER_USERNAME:(if $publisher=="" then null else $publisher end),PUBLISHER_ENABLED:$enabled,QUOTA_MB:$quota,USED_MB:$used,HEALTH:$health,OBSERVED_AT:$observed,FRESHNESS:$freshness}'
}
