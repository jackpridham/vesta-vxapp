#!/usr/bin/env bash

_vx_harbor_random_secret() { /usr/bin/od -An -N32 -tx1 /dev/urandom | /usr/bin/tr -d ' \n'; }

vx_harbor_rotation_path() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ && "$2" =~ ^(runtime|publisher)$ ]] || return 1
    printf '%s/rotations/%s-%s.json\n' "$(vx_harbor_root)" "$1" "$2"
}

vx_harbor_rotation_validate() {
    vx_harbor_secure_regular_file "$1" 0600 || return 1
    /usr/bin/jq -e 'type=="object" and keys==["KIND","NEW_ROBOT_ID","NEW_USERNAME","OLD_ROBOT_ID","OPERATION_ID","OWNER","PHASE","SCHEMA","UPDATED_AT"] and .SCHEMA==1 and (.KIND|IN("runtime","publisher")) and (.OPERATION_ID|test("^[a-f0-9]{32}$")) and (.PHASE|IN("pending-revoke","converged")) and ([.NEW_ROBOT_ID,.OLD_ROBOT_ID]|all(.==null or (type=="number" and .>=1)))' "$1" >/dev/null 2>&1
}

_vx_harbor_rotation_write() {
    local owner="$1" kind="$2" operation="$3" phase="$4" new_id="$5" new_user="$6" old_id="$7" path source now
    path="$(vx_harbor_rotation_path "$owner" "$kind")"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/rotations/.rotation.XXXXXX")" || return 1
    /usr/bin/jq -n --arg owner "$owner" --arg kind "$kind" --arg operation "$operation" --arg phase "$phase" --argjson new "$new_id" --arg user "$new_user" --argjson old "$old_id" --arg now "$now" '{SCHEMA:1,OPERATION_ID:$operation,OWNER:$owner,KIND:$kind,PHASE:$phase,NEW_ROBOT_ID:$new,NEW_USERNAME:$user,OLD_ROBOT_ID:$old,UPDATED_AT:$now}' >"$source" && vx_harbor_json_write_atomic "$path" "$source"
    local result=$?; /usr/bin/rm -f "$source"; return "$result"
}

_vx_harbor_rotation_retry_revoke() {
    local owner="$1" kind="$2" path old operation new_id new_user
    path="$(vx_harbor_rotation_path "$owner" "$kind")"; [[ -f "$path" ]] || return 1
    vx_harbor_rotation_validate "$path" || return 2
    [[ "$(/usr/bin/jq -r .PHASE "$path")" == pending-revoke ]] || return 1
    old="$(/usr/bin/jq -r .OLD_ROBOT_ID "$path")"; operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"; new_id="$(/usr/bin/jq -r .NEW_ROBOT_ID "$path")"; new_user="$(/usr/bin/jq -r .NEW_USERNAME "$path")"
    [[ "$old" == null ]] || vx_harbor_api_robot_delete "$old" >/dev/null || return 75
    _vx_harbor_rotation_write "$owner" "$kind" "$operation" converged "$new_id" "$new_user" "$old" || return 1
    printf '%s\t%s\n' "$new_id" "$new_user"
}

vx_harbor_runtime_credential_switch() {
    local owner="$1" origin="$2" username="$3" secret="$4" root config metadata temporary now auth host auth_file
    [[ "$origin" =~ ^https://([^/]+)$ && "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ && ${#secret} -ge 16 ]] || return 1
    host="${origin#https://}"
    root="$(vx_compose_registry_root "$owner")"; vx_compose_registry_prepare "$owner" || return 1
    config="$root/config.json"; metadata="$root/registries.json"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    auth="$(printf '%s:%s' "$username" "$secret" | /usr/bin/base64 -w0)" || return 1
    auth_file="$(/usr/bin/mktemp "$root/.managed-auth.XXXXXX")" || return 1
    printf %s "$auth" >"$auth_file"; unset auth secret
    /usr/bin/chown 0:0 "$auth_file" && /usr/bin/chmod 0600 "$auth_file" || { /usr/bin/rm -f "$auth_file"; return 1; }
    temporary="$(/usr/bin/mktemp "$root/.config.XXXXXX")" || return 1
    /usr/bin/jq --arg host "$host" --rawfile auth "$auth_file" '.auths[$host]={auth:$auth}' "$config" >"$temporary" \
      && /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$config" || { /usr/bin/rm -f "$temporary" "$auth_file"; return 1; }
    /usr/bin/rm -f "$auth_file"
    temporary="$(/usr/bin/mktemp "$root/.registries.XXXXXX")" || return 1
    /usr/bin/jq -S --arg host "$host" --arg username "$username" --arg now "$now" \
      '.[$host]={REGISTRY:$host,USERNAME:$username,CREATED:(.[$host].CREATED//$now),ROTATED:$now,LAST_VALIDATION:"succeeded",MANAGED_BY:"harbor"}' "$metadata" >"$temporary" \
      && /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$metadata" || { /usr/bin/rm -f "$temporary"; return 1; }
}

vx_harbor_runtime_rotate() {
    local owner="$1" namespace="$2" origin="$3" old_id="$4" generation="$5" secret username response id operation retry_status retry_output
    retry_output="$(_vx_harbor_rotation_retry_revoke "$owner" runtime)" && { printf '%s\n' "$retry_output"; return 0; }
    retry_status=$?; [[ "$retry_status" == 1 ]] || return "$retry_status"
    secret="$(_vx_harbor_random_secret)" || return 1; username="$namespace-runtime-$generation"
    response="$(printf %s "$secret" | vx_harbor_api_robot_create "$namespace" "$username" pull)" || return 1
    id="$(/usr/bin/jq -er '.id' <<<"$response")" || return 1
    printf %s "$secret" | vx_harbor_api_credential_probe "$username" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    vx_harbor_runtime_credential_switch "$owner" "$origin" "$username" "$secret" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    unset secret
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    [[ -n "$old_id" ]] || old_id=null
    _vx_harbor_rotation_write "$owner" runtime "$operation" pending-revoke "$id" "$username" "$old_id" || return 1
    if [[ "$old_id" == null ]] || vx_harbor_api_robot_delete "$old_id" >/dev/null; then
        _vx_harbor_rotation_write "$owner" runtime "$operation" converged "$id" "$username" "$old_id" || return 1
    fi
    printf '%s\t%s\n' "$id" "$username"
}

vx_harbor_runtime_revoke() {
    local owner="$1" origin="$2" id="$3" root host temporary
    [[ "$id" == null || -z "$id" ]] || vx_harbor_api_robot_disable "$id" >/dev/null || return 1
    root="$(vx_compose_registry_root "$owner")"; host="${origin#https://}"
    [[ -d "$root" ]] || return 0
    for file in config.json registries.json; do
        [[ -f "$root/$file" ]] || continue
        temporary="$(/usr/bin/mktemp "$root/.$file.XXXXXX")" || return 1
        if [[ "$file" == config.json ]]; then /usr/bin/jq --arg h "$host" 'del(.auths[$h])' "$root/$file" >"$temporary"; else /usr/bin/jq --arg h "$host" 'del(.[$h])' "$root/$file" >"$temporary"; fi
        /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" && /usr/bin/mv -fT "$temporary" "$root/$file" || return 1
    done
}
