#!/usr/bin/env bash

vx_harbor_owner_namespace() {
    local owner="$1" digest
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    if [[ "$owner" =~ ^[a-z0-9][a-z0-9-]{0,29}$ ]]; then printf 'vx-%s\n' "$owner"; else digest="$(/usr/bin/printf %s "$owner" | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')"; printf 'vx-u-%s\n' "$digest"; fi
}

vx_harbor_owner_state_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -e 'type=="object" and keys==["LAST_ERROR","NAMESPACE","OWNER","PROJECT_ID","PUBLISHER_ENABLED","PUBLISHER_ROBOT_ID","PUBLISHER_USERNAME","QUOTA_ID","QUOTA_MB","RUNTIME_ROBOT_ID","RUNTIME_USERNAME","SCHEMA","STATE","UPDATED_AT"] and .SCHEMA==1 and (.OWNER|test("^[a-z0-9][a-z0-9_-]{0,31}$")) and (.NAMESPACE|test("^[a-z0-9][a-z0-9-]{0,127}$")) and (.PROJECT_ID|type=="number" and .>=1) and (.QUOTA_ID|type=="number" and .>=1) and (.QUOTA_MB=="unlimited" or (.QUOTA_MB|type=="number" and .>=0)) and (.STATE|IN("project-ready","runtime-ready","publisher-ready","publisher-disabled","retained","unavailable")) and (.PUBLISHER_ENABLED|type=="boolean") and ([.RUNTIME_ROBOT_ID,.PUBLISHER_ROBOT_ID]|all(.==null or (type=="number" and .>=1))) and ([.RUNTIME_USERNAME,.PUBLISHER_USERNAME,.LAST_ERROR]|all(.==null or type=="string")) and (.UPDATED_AT|type=="string")' "$path" >/dev/null 2>&1
}

_vx_harbor_owner_desired() {
    local owner="$1" conf="$VESTA/data/users/$owner/user.conf"
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    /usr/bin/awk -F"'" '/^(PACKAGE|SUSPENDED|DOCKER_PROJECTS|DOCKER_REGISTRY_MB)=/{v[$1]=$2;c[$1]++} END{for(k in c)if(c[k]!=1)exit 1;if(v["PACKAGE"]!~/^[A-Za-z0-9._-]+$/||v["SUSPENDED"]!~/^(yes|no)$/||v["DOCKER_PROJECTS"]!~/^(0|[1-9][0-9]*|unlimited)$/||v["DOCKER_REGISTRY_MB"]!~/^(0|[1-9][0-9]*|unlimited)$/)exit 1; print v["PACKAGE"]"\t"v["SUSPENDED"]"\t"v["DOCKER_PROJECTS"]"\t"v["DOCKER_REGISTRY_MB"]}' "$conf"
}

vx_harbor_owner_is_eligible() { local d; d="$(_vx_harbor_owner_desired "$1")" || return 1; IFS=$'\t' read -r _ suspended projects quota <<<"$d"; [[ "$suspended" == no && "$projects" != 0 && "$quota" != 0 ]]; }

_vx_harbor_owner_write() { local path="$1" json="$2" source; source="$(/usr/bin/mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")" || return 1; /usr/bin/printf '%s\n' "$json" >"$source" && vx_harbor_json_write_atomic "$path" "$source"; local r=$?; /usr/bin/rm -f "$source"; return "$r"; }

vx_harbor_owner_reconcile_locked() {
    local owner="$1" desired package suspended projects quota namespace path project project_id quota_id old_runtime generation runtime origin now state_json usage
    desired="$(_vx_harbor_owner_desired "$owner")" || return 1; IFS=$'\t' read -r package suspended projects quota <<<"$desired"
    vx_harbor_package_transition_recover "$owner" || [[ -e "$(vx_harbor_operation_path "$owner")" ]] || return 1
    namespace="$(vx_harbor_owner_namespace "$owner")"; path="$(vx_harbor_owner_state_path "$owner")"
    if ! vx_harbor_owner_is_eligible "$owner"; then
        [[ -f "$path" ]] || return 0
        vx_harbor_owner_state_validate "$path" || return 1
        vx_harbor_publisher_revoke_locked "$owner" "$path" || return 1
        vx_harbor_runtime_revoke "$owner" "$(/usr/bin/jq -r '.ORIGIN' "$(vx_harbor_root)/provider.json")" "$(/usr/bin/jq -r '.RUNTIME_ROBOT_ID' "$path")" || return 1
        now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; state_json="$(/usr/bin/jq --arg now "$now" '.STATE="retained"|.RUNTIME_ROBOT_ID=null|.RUNTIME_USERNAME=null|.PUBLISHER_ROBOT_ID=null|.PUBLISHER_USERNAME=null|.PUBLISHER_ENABLED=false|.UPDATED_AT=$now' "$path")"; _vx_harbor_owner_write "$path" "$state_json"; return
    fi
    vx_harbor_api_health >/dev/null || return 75
    project="$(vx_harbor_api_project_get "$namespace" 2>/dev/null || :)"
    if [[ -z "$project" ]]; then vx_harbor_api_project_create "$namespace" || return 75; project="$(vx_harbor_api_project_get "$namespace")" || return 75; fi
    /usr/bin/jq -e --arg n "$namespace" '.name==$n and .metadata.public=="false"' <<<"$project" >/dev/null || return 1
    project_id="$(/usr/bin/jq -er '.project_id' <<<"$project")"; quota_id="$(/usr/bin/jq -er '.quota_id' <<<"$project")"
    [[ ! -f "$path" ]] || { vx_harbor_owner_state_validate "$path" || return 1; /usr/bin/jq -e --arg o "$owner" --arg n "$namespace" --argjson p "$project_id" --argjson q "$quota_id" '.OWNER==$o and .NAMESPACE==$n and .PROJECT_ID==$p and .QUOTA_ID==$q' "$path" >/dev/null || return 1; }
    vx_harbor_api_quota_set_bytes "$quota_id" "$(vx_harbor_quota_bytes "$quota")" >/dev/null || return 75
    vx_harbor_quota_observe "$owner" "$quota_id" || return 75
    old_runtime=null; [[ ! -f "$path" ]] || old_runtime="$(/usr/bin/jq -r '.RUNTIME_ROBOT_ID' "$path")"
    generation="$(/usr/bin/date -u +%s)"; origin="$(/usr/bin/jq -er '.ORIGIN|select(type=="string")' "$(vx_harbor_root)/provider.json")" || return 1
    if [[ "$old_runtime" != null ]] && vx_harbor_api_robot_get "$old_runtime" >/dev/null; then
        runtime_id="$old_runtime"; runtime_user="$(/usr/bin/jq -r '.RUNTIME_USERNAME' "$path")"
    else
        IFS=$'\t' read -r runtime_id runtime_user < <(vx_harbor_runtime_rotate "$owner" "$namespace" "$origin" "$old_runtime" "$generation") || return 75
    fi
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; [[ "$quota" == unlimited ]] && quota_json='"unlimited"' || quota_json="$quota"
    state_json="$(/usr/bin/jq -n --arg owner "$owner" --arg namespace "$namespace" --argjson project "$project_id" --argjson quota_id "$quota_id" --argjson quota "$quota_json" --argjson runtime "$runtime_id" --arg runtime_user "$runtime_user" --arg now "$now" '{SCHEMA:1,OWNER:$owner,NAMESPACE:$namespace,PROJECT_ID:$project,QUOTA_ID:$quota_id,QUOTA_MB:$quota,STATE:"runtime-ready",RUNTIME_ROBOT_ID:$runtime,RUNTIME_USERNAME:$runtime_user,PUBLISHER_ROBOT_ID:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,LAST_ERROR:null,UPDATED_AT:$now}')" || return 1
    if [[ -f "$path" ]] && /usr/bin/jq -e '.PUBLISHER_ENABLED==true and .PUBLISHER_ROBOT_ID!=null' "$path" >/dev/null; then
        state_json="$(/usr/bin/jq --slurpfile old "$path" '.PUBLISHER_ROBOT_ID=$old[0].PUBLISHER_ROBOT_ID|.PUBLISHER_USERNAME=$old[0].PUBLISHER_USERNAME|.PUBLISHER_ENABLED=true|.STATE="publisher-ready"' <<<"$state_json")"
    fi
    _vx_harbor_owner_write "$path" "$state_json" || return 1
    vx_harbor_package_transition_recover "$owner" || return 1
}

vx_harbor_owner_reconcile() {
    local owner="$1" result
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1; vx_harbor_provider_prepare || return 1; vx_harbor_provider_enabled || return 0
    vx_harbor_provider_lock_acquire shared || return 1; vx_compose_shell_access_lock_acquire "$owner" || { vx_harbor_provider_lock_release; return 1; }; vx_compose_registry_lock_acquire "$owner" || { vx_compose_shell_access_lock_release; vx_harbor_provider_lock_release; return 1; }
    vx_harbor_owner_reconcile_locked "$owner"; result=$?
    vx_compose_registry_lock_release; vx_compose_shell_access_lock_release; vx_harbor_provider_lock_release
    return "$result"
}

vx_harbor_owner_revoke() {
    local owner="$1" path origin runtime result
    path="$(vx_harbor_owner_state_path "$owner")"; [[ -f "$path" ]] || return 0
    vx_harbor_provider_enabled || return 0
    vx_harbor_provider_lock_acquire shared || return 1; vx_compose_shell_access_lock_acquire "$owner" || { vx_harbor_provider_lock_release; return 1; }; vx_compose_registry_lock_acquire "$owner" || { vx_compose_shell_access_lock_release; vx_harbor_provider_lock_release; return 1; }
    vx_harbor_owner_state_validate "$path" || result=1
    if [[ -z "${result:-}" ]]; then
        origin="$(/usr/bin/jq -r '.ORIGIN' "$(vx_harbor_root)/provider.json")"; runtime="$(/usr/bin/jq -r '.RUNTIME_ROBOT_ID' "$path")"
        if vx_harbor_publisher_revoke_locked "$owner" "$path"; then
            vx_harbor_runtime_revoke "$owner" "$origin" "$runtime" || result=1
        else
            result=1
        fi
        if [[ -z "${result:-}" ]]; then local now json; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"; json="$(/usr/bin/jq --arg now "$now" '.RUNTIME_ROBOT_ID=null|.RUNTIME_USERNAME=null|.STATE="retained"|.UPDATED_AT=$now' "$path")"; _vx_harbor_owner_write "$path" "$json" || result=1; fi
    fi
    vx_compose_registry_lock_release; vx_compose_shell_access_lock_release; vx_harbor_provider_lock_release
    [[ -z "${result:-}" ]]
}

vx_harbor_owners_reconcile() { local d owner result=0; for d in "$VESTA"/data/users/*; do [[ -d "$d" && ! -L "$d" ]] || continue; owner="${d##*/}"; [[ "$owner" == admin ]] && continue; vx_harbor_owner_reconcile "$owner" || result=1; done; return "$result"; }

vx_harbor_owners_list_json() { local files=() f; for f in "$(vx_harbor_root)"/owners/*.json; do [[ -f "$f" ]] || continue; vx_harbor_owner_state_validate "$f" || return 1; files+=("$f"); done; ((${#files[@]})) && /usr/bin/jq -sc 'map({OWNER,NAMESPACE,STATE,QUOTA_MB,PUBLISHER_ENABLED,UPDATED_AT})|sort_by(.OWNER)' "${files[@]}" || printf '[]\n'; }
