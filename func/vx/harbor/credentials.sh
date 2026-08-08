#!/usr/bin/env bash

_vx_harbor_random_secret() { /usr/bin/od -An -N32 -tx1 /dev/urandom | /usr/bin/tr -d ' \n'; }

vx_harbor_rotation_path() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ && "$2" =~ ^(runtime|publisher)$ ]] || return 1
    printf '%s/rotations/%s-%s.json\n' "$(vx_harbor_root)" "$1" "$2"
}

vx_harbor_rotation_validate() {
    local path="$1" name owner kind
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    name="$(basename "$path" .json)"; kind="${name##*-}"; owner="${name%-$kind}"
    _vx_harbor_authority_schema_validate rotation "$path" "$owner:$kind"
}

_vx_harbor_rotation_write() {
    local owner="$1" kind="$2" operation="$3" phase="$4" new_id="$5" new_user="$6" old_id="$7" path source now
    path="$(vx_harbor_rotation_path "$owner" "$kind")"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/rotations/.rotation.XXXXXX")" || return 1
    /usr/bin/jq -n --arg owner "$owner" --arg kind "$kind" --arg operation "$operation" --arg phase "$phase" --argjson new "$new_id" --arg user "$new_user" --argjson old "$old_id" --arg now "$now" '{SCHEMA:1,OPERATION_ID:$operation,OWNER:$owner,KIND:$kind,PHASE:$phase,NEW_ROBOT_ID:$new,NEW_USERNAME:$user,OLD_ROBOT_ID:$old,UPDATED_AT:$now}' >"$source" && vx_harbor_json_write_atomic "$path" "$source"
    local result=$?; /usr/bin/rm -f "$source"; return "$result"
}

_vx_harbor_rotation_checkpoint() { :; }

_vx_harbor_runtime_candidate_path() {
    local owner="$1" operation="$2"
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ && "$operation" =~ ^[a-f0-9]{32}$ ]] || return 1
    printf '%s/.harbor-runtime-rotation.%s.secret\n' "$(vx_compose_registry_root "$owner")" "$operation"
}

_vx_harbor_runtime_candidate_stage() {
    local owner="$1" operation="$2" secret="$3" path uid gid
    vx_compose_registry_prepare "$owner" || return 1
    path="$(_vx_harbor_runtime_candidate_path "$owner" "$operation")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    (umask 077; printf %s "$secret" >"$path") || return 1
    uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
    /usr/bin/chown "$uid:$gid" "$path" && /usr/bin/chmod 0600 "$path" \
        && [[ -f "$path" && ! -L "$path" && "$(/usr/bin/stat -c '%u:%g:%h:%a' "$path")" == "$uid:$gid:1:600" ]]
}

_vx_harbor_rotation_recover() {
    local owner="$1" kind="$2" origin="${3-}" path phase old operation new_id new_user owner_path candidate secret json now uid gid registry_root host expected_auth active_auth active_user
    path="$(vx_harbor_rotation_path "$owner" "$kind")"; [[ -f "$path" ]] || return 1
    vx_harbor_rotation_validate "$path" || return 2
    phase="$(/usr/bin/jq -r .PHASE "$path")"
    [[ "$phase" != converged ]] || { /usr/bin/jq -r '[.NEW_ROBOT_ID,.NEW_USERNAME]|@tsv' "$path"; return 0; }
    old="$(/usr/bin/jq -r .OLD_ROBOT_ID "$path")"; operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"; new_id="$(/usr/bin/jq -r .NEW_ROBOT_ID "$path")"; new_user="$(/usr/bin/jq -r .NEW_USERNAME "$path")"
    owner_path="$(vx_harbor_owner_state_path "$owner")"
    if [[ "$phase" == pending-switch ]]; then
        if [[ "$kind" == runtime ]]; then
            candidate="$(_vx_harbor_runtime_candidate_path "$owner" "$operation")" || return 1
            uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
            [[ -f "$candidate" && ! -L "$candidate" && "$(/usr/bin/stat -c '%u:%g:%h:%a' "$candidate")" == "$uid:$gid:1:600" ]] || return 1
            IFS= read -r secret <"$candidate"; [[ ${#secret} -ge 16 && ${#secret} -le 256 ]] || return 1
            registry_root="$(vx_compose_registry_root "$owner")"; host="${origin#https://}"
            expected_auth="$(printf '%s:%s' "$new_user" "$secret" | /usr/bin/base64 -w0)" || return 1
            active_auth="$(/usr/bin/jq -r --arg host "$host" '.auths[$host].auth // empty' "$registry_root/config.json" 2>/dev/null || :)"
            active_user="$(/usr/bin/jq -r --arg host "$host" '.[$host].USERNAME // empty' "$registry_root/registries.json" 2>/dev/null || :)"
            if [[ "$active_auth" != "$expected_auth" || "$active_user" != "$new_user" ]]; then
                vx_harbor_runtime_credential_switch "$owner" "$origin" "$new_user" "$secret" || return 1
            fi
            unset expected_auth active_auth active_user
            unset secret
        elif [[ -f "$owner_path" ]]; then
            vx_harbor_owner_state_validate "$owner_path" || return 1
            if ! /usr/bin/jq -e --argjson id "$new_id" --arg user "$new_user" '.PUBLISHER_ROBOT_ID==$id and .PUBLISHER_USERNAME==$user and .PUBLISHER_ENABLED==true' "$owner_path" >/dev/null; then
                now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
                json="$(/usr/bin/jq --argjson id "$new_id" --arg user "$new_user" --arg now "$now" '.PUBLISHER_ROBOT_ID=$id|.PUBLISHER_USERNAME=$user|.PUBLISHER_ENABLED=true|.STATE="publisher-ready"|.UPDATED_AT=$now|.LAST_ERROR=null' "$owner_path")"
                _vx_harbor_owner_write "$owner_path" "$json" || return 1
            fi
        else
            return 1
        fi
        _vx_harbor_rotation_checkpoint "$kind" authority-switched || return 76
        _vx_harbor_rotation_write "$owner" "$kind" "$operation" pending-revoke "$new_id" "$new_user" "$old" || return 1
        if [[ "$kind" == runtime ]]; then
            /usr/bin/unlink "$candidate" || return 1
            _vx_harbor_fsync "$(dirname -- "$candidate")" || return 1
        fi
    fi
    [[ "$old" == null ]] || vx_harbor_api_robot_delete "$old" >/dev/null || return 75
    _vx_harbor_rotation_write "$owner" "$kind" "$operation" converged "$new_id" "$new_user" "$old" || return 1
    printf '%s\t%s\n' "$new_id" "$new_user"
}

vx_harbor_runtime_credential_switch() {
    local owner="$1" origin="$2" username="$3" secret="$4" root config metadata temporary now auth host auth_file uid gid
    [[ "$origin" =~ ^https://([^/]+)$ && "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ && ${#secret} -ge 16 ]] || return 1
    host="${origin#https://}"
    root="$(vx_compose_registry_root "$owner")"; vx_compose_registry_prepare "$owner" || return 1; uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
    config="$root/config.json"; metadata="$root/registries.json"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    auth="$(printf '%s:%s' "$username" "$secret" | /usr/bin/base64 -w0)" || return 1
    auth_file="$(/usr/bin/mktemp "$root/.managed-auth.XXXXXX")" || return 1
    printf %s "$auth" >"$auth_file"; unset auth secret
    /usr/bin/chown "$uid:$gid" "$auth_file" && /usr/bin/chmod 0600 "$auth_file" || { /usr/bin/rm -f "$auth_file"; return 1; }
    temporary="$(/usr/bin/mktemp "$root/.config.XXXXXX")" || return 1
    /usr/bin/jq --arg host "$host" --rawfile auth "$auth_file" '.auths[$host]={auth:$auth}' "$config" >"$temporary" \
      && /usr/bin/chown "$uid:$gid" "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$config" || { /usr/bin/rm -f "$temporary" "$auth_file"; return 1; }
    /usr/bin/rm -f "$auth_file"
    temporary="$(/usr/bin/mktemp "$root/.registries.XXXXXX")" || return 1
    /usr/bin/jq -S --arg host "$host" --arg username "$username" --arg now "$now" \
      '.[$host]={REGISTRY:$host,USERNAME:$username,CREATED:(.[$host].CREATED//$now),ROTATED:$now,LAST_VALIDATION:"succeeded",MANAGED_BY:"harbor"}' "$metadata" >"$temporary" \
      && /usr/bin/chown "$uid:$gid" "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$metadata" || { /usr/bin/rm -f "$temporary"; return 1; }
}

vx_harbor_runtime_rotate() {
    local owner="$1" namespace="$2" origin="$3" old_id="$4" generation="$5" secret username response id operation retry_status retry_output
    retry_output="$(_vx_harbor_rotation_recover "$owner" runtime "$origin")" && { printf '%s\n' "$retry_output"; return 0; }
    retry_status=$?; [[ "$retry_status" == 1 ]] || return "$retry_status"
    secret="$(_vx_harbor_random_secret)" || return 1; username="$namespace-runtime-$generation"
    response="$(printf %s "$secret" | vx_harbor_api_robot_create "$namespace" "$username" pull)" || return 1
    id="$(/usr/bin/jq -er '.id' <<<"$response")" || return 1
    printf %s "$secret" | vx_harbor_api_credential_probe "$username" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    [[ -n "$old_id" ]] || old_id=null
    _vx_harbor_runtime_candidate_stage "$owner" "$operation" "$secret" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    unset secret
    if ! _vx_harbor_rotation_write "$owner" runtime "$operation" pending-switch "$id" "$username" "$old_id"; then
        /usr/bin/unlink "$(_vx_harbor_runtime_candidate_path "$owner" "$operation")" 2>/dev/null || :
        vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :
        return 1
    fi
    _vx_harbor_rotation_checkpoint runtime journal-published || return 76
    _vx_harbor_rotation_recover "$owner" runtime "$origin" || return
    vx_harbor_audit "$owner" runtime-rotation succeeded converged
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
    vx_harbor_audit "$owner" runtime-revocation succeeded retained
}
