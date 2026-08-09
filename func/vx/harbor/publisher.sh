#!/usr/bin/env bash

_vx_harbor_publisher_recipient_read() {
    local recipient pattern='^age1[ac-hj-np-z02-9]{58}$'
    IFS= read -r -N 129 recipient <&0 || [[ ${#recipient} -gt 0 ]]
    [[ ${#recipient} -le 128 ]] || return 1
    [[ "$recipient" != *$'\n'* && "$recipient" != *$'\r'* && "$recipient" =~ $pattern ]] || return 1
    printf %s "$recipient"
}

_vx_harbor_rotation_remove() {
    local path="$1"
    [[ "$path" == "$(vx_harbor_root)"/rotations/*.json && -f "$path" && ! -L "$path" ]] || return 1
    /usr/bin/unlink "$path" || return 1
    _vx_harbor_fsync "$(dirname -- "$path")"
}

vx_harbor_publisher_recover_locked() {
    local owner="$1" path owner_path phase operation project_id namespace marker new_id new_user old_id
    local found result state_switched=no
    path="$(vx_harbor_rotation_path "$owner" publisher)"; [[ -f "$path" ]] || return 4
    vx_harbor_rotation_validate "$path" || return 2
    owner_path="$(vx_harbor_owner_state_path "$owner")"; vx_harbor_owner_state_validate "$owner_path" || return 1
    phase="$(/usr/bin/jq -r .PHASE "$path")"; operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"
    project_id="$(/usr/bin/jq -r .PROJECT_ID "$path")"; marker="$(/usr/bin/jq -r .DESCRIPTION "$path")"
    new_id="$(/usr/bin/jq -r .NEW_ROBOT_ID "$path")"; new_user="$(/usr/bin/jq -r '.NEW_USERNAME // empty' "$path")"
    old_id="$(/usr/bin/jq -r .OLD_ROBOT_ID "$path")"; namespace="$(/usr/bin/jq -r .NAMESPACE "$owner_path")"
    if [[ "$phase" != prepared ]] && /usr/bin/jq -e --argjson id "$new_id" --arg user "$new_user" \
      '.PUBLISHER_ENABLED==true and .PUBLISHER_ROBOT_ID==$id and .PUBLISHER_USERNAME==$user' "$owner_path" >/dev/null; then
        state_switched=yes
    fi
    case "$phase" in
        prepared)
            if found="$(vx_harbor_api_project_robot_find "$project_id" "$marker")"; then
                new_id="$(/usr/bin/jq -er .id <<<"$found")" || return 1
                vx_harbor_api_project_robot_delete "$project_id" "$new_id" "$marker" || return
            else
                result=$?; (( result == 4 )) || return "$result"
            fi
            _vx_harbor_rotation_remove "$path" || return 1
            return 4
            ;;
        candidate-created|pending-switch)
            if [[ "$state_switched" != yes ]]; then
                vx_harbor_api_project_robot_delete "$project_id" "$new_id" "$marker" || return
                _vx_harbor_rotation_remove "$path" || return 1
                return 4
            fi
            _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" pending-revoke "$new_id" "$new_user" "$old_id" || return 1
            phase=pending-revoke
            ;;
        pending-revoke)
            [[ "$state_switched" == yes ]] || return 1
            ;;
        converged)
            [[ "$state_switched" == yes ]] || return 1
            return 0
            ;;
        *) return 1 ;;
    esac
    _vx_harbor_owned_robot_delete "$owner" publisher "$namespace" "$project_id" "$old_id" || return 75
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" converged "$new_id" "$new_user" "$old_id"
}

vx_harbor_publisher_rotate_locked() {
    local owner="$1" recipient path namespace project_id old_id operation basename marker response
    local id username secret ciphertext now json recovery_status
    recipient="$(_vx_harbor_publisher_recipient_read)" \
        || { vx_harbor_failure_audit "$owner" publisher-rotation schema 1; return 1; }
    path="$(vx_harbor_owner_state_path "$owner")"
    vx_harbor_owner_state_validate "$path" \
        || { vx_harbor_failure_audit "$owner" publisher-rotation schema 1; return 1; }
    if vx_harbor_publisher_recover_locked "$owner"; then
        :
    else
        recovery_status=$?
        (( recovery_status == 4 )) \
            || { vx_harbor_failure_audit "$owner" publisher-rotation recovery "$recovery_status"; return "$recovery_status"; }
    fi
    namespace="$(/usr/bin/jq -r .NAMESPACE "$path")"; project_id="$(/usr/bin/jq -r .PROJECT_ID "$path")"
    old_id="$(/usr/bin/jq -r .PUBLISHER_ROBOT_ID "$path")"
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')" || return 1
    basename="publisher-$operation"; marker="vesta-managed:vesta-harbor:$owner:publisher:$operation"
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" prepared null '' "$old_id" \
        || { vx_harbor_failure_audit "$owner" publisher-rotation journal 1; return 1; }
    response="$(_vx_harbor_api_project_robot_create_secret_once "$project_id" "$namespace" "$basename" "$marker" push-pull)" \
        || { vx_harbor_failure_audit "$owner" publisher-rotation api 75; return 75; }
    id="$(/usr/bin/jq -er .id <<<"$response")" || { unset response; return 1; }
    username="$(/usr/bin/jq -er .name <<<"$response")" || { unset response; return 1; }
    secret="$(/usr/bin/jq -er .secret <<<"$response")" || { unset response; return 1; }
    unset response
    printf %s "$secret" | vx_harbor_api_credential_probe "$username" \
        || { unset secret; vx_harbor_api_project_robot_delete "$project_id" "$id" "$marker" >/dev/null 2>&1 || :; return 75; }
    ciphertext="$(printf %s "$secret" | /usr/bin/age --armor --encrypt --recipient "$recipient")" \
        || { unset secret ciphertext; vx_harbor_api_project_robot_delete "$project_id" "$id" "$marker" >/dev/null 2>&1 || :; return 1; }
    unset secret recipient
    [[ "$ciphertext" == '-----BEGIN AGE ENCRYPTED FILE-----'* \
        && "$ciphertext" == *'-----END AGE ENCRYPTED FILE-----' ]] \
        || { unset ciphertext; vx_harbor_api_project_robot_delete "$project_id" "$id" "$marker" >/dev/null 2>&1 || :; return 1; }
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" candidate-created "$id" "$username" "$old_id" || return 1
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" pending-switch "$id" "$username" "$old_id" || return 1
    _vx_harbor_rotation_checkpoint publisher journal-published || return 76
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    json="$(/usr/bin/jq --argjson id "$id" --arg user "$username" --arg now "$now" \
      '.PUBLISHER_ROBOT_ID=$id|.PUBLISHER_USERNAME=$user|.PUBLISHER_ENABLED=true|.STATE="publisher-ready"|.UPDATED_AT=$now|.LAST_ERROR=null' "$path")" || return 1
    _vx_harbor_owner_write "$path" "$json" || return 1
    _vx_harbor_rotation_checkpoint publisher authority-switched || return 76
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" pending-revoke "$id" "$username" "$old_id" || return 1
    _vx_harbor_owned_robot_delete "$owner" publisher "$namespace" "$project_id" "$old_id" || return 75
    _vx_harbor_rotation_write "$owner" publisher "$project_id" "$operation" converged "$id" "$username" "$old_id" || return 1
    vx_harbor_audit "$owner" publisher-rotation succeeded converged || return 1
    printf '%s\n' "$ciphertext"
    unset ciphertext
}

vx_harbor_publisher_revoke_locked() {
    local owner="$1" path="$2" id namespace project_id now json
    vx_harbor_owner_state_validate "$path" || { vx_harbor_failure_audit "$owner" publisher-revocation schema 1; return; }
    id="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID' "$path")"
    namespace="$(/usr/bin/jq -r .NAMESPACE "$path")"; project_id="$(/usr/bin/jq -r .PROJECT_ID "$path")"
    _vx_harbor_owned_robot_delete "$owner" publisher "$namespace" "$project_id" "$id" \
        || { vx_harbor_failure_audit "$owner" publisher-revocation outage 75; return; }
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    json="$(/usr/bin/jq --arg now "$now" '.PUBLISHER_ROBOT_ID=null|.PUBLISHER_USERNAME=null|.PUBLISHER_ENABLED=false|.STATE=(if .RUNTIME_ROBOT_ID==null then "retained" else "publisher-disabled" end)|.UPDATED_AT=$now' "$path")" || return 1
    _vx_harbor_owner_write "$path" "$json" || return 1
    vx_harbor_audit "$owner" publisher-revocation succeeded retained
}

vx_harbor_registry_info_json() {
    local owner="$1" project="$2" path provider observation provider_observation origin internal_state state health freshness quota used observed now observed_epoch provider_at provider_epoch provider_health publisher
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1; path="$(vx_harbor_owner_state_path "$owner")"; provider="$(vx_harbor_root)/provider.json"
    if ! vx_harbor_provider_enabled; then /usr/bin/jq -n '{MANAGED:false,STATE:"disabled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; fi
    vx_harbor_owner_is_eligible "$owner" || { /usr/bin/jq -n '{MANAGED:true,STATE:"not-entitled",REGISTRY:null,NAMESPACE:null,REPOSITORY:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,QUOTA_MB:0,USED_MB:0,HEALTH:"unavailable",OBSERVED_AT:null,FRESHNESS:"unavailable"}'; return; }
    vx_harbor_owner_state_validate "$path" || return 1; observation="$(vx_harbor_root)/observations/$owner.json"; provider_observation="$(vx_harbor_root)/observations/provider.json"; origin="$(/usr/bin/jq -r '.ORIGIN' "$provider")"; internal_state="$(/usr/bin/jq -r '.STATE' "$path")"; quota="$(/usr/bin/jq -c '.QUOTA_MB' "$path")"; publisher="$(/usr/bin/jq -r '.PUBLISHER_USERNAME // empty' "$path")"
    case "$internal_state" in project-ready) state=provisioning;; runtime-ready|publisher-ready) state=ready;; publisher-disabled) state=publisher-disabled;; retained) state=retained;; unavailable) state=unavailable;; *) return 1;; esac
    used=0; observed=null; freshness=unavailable; health=unavailable; now="$(/usr/bin/date -u +%s)"
    if [[ -f "$observation" ]] && vx_harbor_secure_regular_file "$observation" 0600 && /usr/bin/jq -e 'keys==["GENERATION","OBSERVED_AT","SCHEMA","USED_MB"] and .SCHEMA==1 and (.USED_MB|type=="number" and .>=0)' "$observation" >/dev/null; then
        used="$(/usr/bin/jq -r .USED_MB "$observation")"; observed_value="$(/usr/bin/jq -r .OBSERVED_AT "$observation")"; observed_epoch="$(/usr/bin/date -u -d "$observed_value" +%s 2>/dev/null || :)"
        if [[ "$observed_epoch" =~ ^[0-9]+$ && "$observed_epoch" -le $((now + 30)) ]]; then observed="$(/usr/bin/jq -c .OBSERVED_AT "$observation")"; if (( now - observed_epoch <= 300 )); then freshness=fresh; else freshness=stale; fi; fi
    fi
    if [[ -f "$provider_observation" ]] && vx_harbor_secure_regular_file "$provider_observation" 0600 && /usr/bin/jq -e 'keys==["HEALTH","OBSERVED_AT","SCHEMA"] and .SCHEMA==1 and (.HEALTH|IN("healthy","degraded","unavailable"))' "$provider_observation" >/dev/null; then
        provider_at="$(/usr/bin/jq -r .OBSERVED_AT "$provider_observation")"; provider_epoch="$(/usr/bin/date -u -d "$provider_at" +%s 2>/dev/null || :)"; provider_health="$(/usr/bin/jq -r .HEALTH "$provider_observation")"
        if [[ "$provider_epoch" =~ ^[0-9]+$ ]] && (( provider_epoch <= now + 30 && now - provider_epoch <= 300 )); then health="$provider_health"; [[ "$freshness" == stale && "$health" == healthy ]] && health=degraded; [[ "$freshness" == unavailable ]] && health=unavailable; fi
    fi
    /usr/bin/jq -n --arg state "$state" --arg registry "${origin#https://}" --arg ns "$(/usr/bin/jq -r '.NAMESPACE' "$path")" --arg project "$project" --arg publisher "$publisher" --argjson enabled "$(/usr/bin/jq '.PUBLISHER_ENABLED' "$path")" --argjson quota "$quota" --argjson used "$used" --arg health "$health" --argjson observed "$observed" --arg freshness "$freshness" '{MANAGED:true,STATE:$state,REGISTRY:$registry,NAMESPACE:$ns,REPOSITORY:($registry+"/"+$ns+"/"+$project),PUBLISHER_USERNAME:(if $publisher=="" then null else $publisher end),PUBLISHER_ENABLED:$enabled,QUOTA_MB:$quota,USED_MB:$used,HEALTH:$health,OBSERVED_AT:$observed,FRESHNESS:$freshness}'
}
