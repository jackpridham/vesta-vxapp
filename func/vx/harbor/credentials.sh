#!/usr/bin/env bash

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
    local owner="$1" kind="$2" project_id="$3" operation="$4" phase="$5"
    local new_id="$6" new_user="$7" old_id="$8" path source now basename description result
    path="$(vx_harbor_rotation_path "$owner" "$kind")" || return 1
    basename="$kind-$operation"
    description="vesta-managed:vesta-harbor:$owner:$kind:$operation"
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/rotations/.rotation.XXXXXX")" || return 1
    /usr/bin/jq -n \
      --arg owner "$owner" --arg kind "$kind" --arg operation "$operation" \
      --argjson project "$project_id" --arg basename "$basename" \
      --arg description "$description" --arg phase "$phase" \
      --argjson new "$new_id" --arg user "$new_user" --argjson old "$old_id" \
      --arg now "$now" \
      '{SCHEMA:2,OPERATION_ID:$operation,OWNER:$owner,KIND:$kind,
        PROJECT_ID:$project,ROBOT_BASENAME:$basename,DESCRIPTION:$description,
        PHASE:$phase,NEW_ROBOT_ID:$new,NEW_USERNAME:(if $user=="" then null else $user end),
        OLD_ROBOT_ID:$old,UPDATED_AT:$now}' >"$source" \
        && _vx_harbor_secure_file_set "$source" 0600 \
        && _vx_harbor_authority_schema_validate rotation "$source" "$owner:$kind" \
        && vx_harbor_json_write_atomic "$path" "$source"
    result=$?
    /usr/bin/rm -f "$source"
    (( result == 0 )) || return "$result"
    vx_harbor_rotation_validate "$path"
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
        && [[ -f "$path" && ! -L "$path" \
            && "$(/usr/bin/stat -c '%u:%g:%h:%a' "$path")" == "$uid:$gid:1:600" ]]
}

_vx_harbor_runtime_candidate_read() {
    local owner="$1" operation="$2" path uid gid secret
    path="$(_vx_harbor_runtime_candidate_path "$owner" "$operation")" || return 1
    uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
    [[ -f "$path" && ! -L "$path" \
        && "$(/usr/bin/stat -c '%u:%g:%h:%a' "$path")" == "$uid:$gid:1:600" ]] || return 1
    IFS= read -r -N 257 secret <"$path" || [[ ${#secret} -gt 0 ]]
    [[ "$secret" =~ ^[A-Za-z0-9_-]{8,256}$ ]] || { unset secret; return 1; }
    printf %s "$secret"
    unset secret
}

_vx_harbor_owned_robot_delete() {
    local owner="$1" kind="$2" namespace="$3" project_id="$4" robot_id="$5"
    local robots robot marker
    [[ "$robot_id" == null || -z "$robot_id" ]] && return 0
    robots="$(vx_harbor_api_project_robots_list "$project_id")" || return
    robot="$(/usr/bin/jq -ce --argjson id "$robot_id" '[.[]|select(.id==$id)]|if length==1 then .[0] else empty end' <<<"$robots")" || return 1
    /usr/bin/jq -e --arg owner "$owner" --arg kind "$kind" --arg namespace "$namespace" '
      .level=="project"
      and (.description|test("^vesta-managed:vesta-harbor:"+$owner+":"+$kind+":[a-f0-9]{32}$"))
      and .permissions==[{kind:"project",namespace:$namespace,access:
        (if $kind=="runtime" then [{resource:"repository",action:"pull"}]
         else [{resource:"repository",action:"pull"},{resource:"repository",action:"push"}] end)}]
    ' <<<"$robot" >/dev/null || return 1
    marker="$(/usr/bin/jq -er .description <<<"$robot")" || return 1
    vx_harbor_api_project_robot_delete "$project_id" "$robot_id" "$marker"
}

vx_harbor_runtime_credential_switch() {
    local owner="$1" origin="$2" username="$3" secret="$4" root config metadata temporary now auth host auth_file uid gid
    local username_pattern='^[A-Za-z0-9][A-Za-z0-9._+$-]{0,255}$'
    [[ "$origin" =~ ^https://([^/]+)$ && "$username" =~ $username_pattern && ${#secret} -ge 8 ]] || return 1
    host="${origin#https://}"
    root="$(vx_compose_registry_root "$owner")"; vx_compose_registry_prepare "$owner" || return 1
    uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
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

_vx_harbor_runtime_recover() {
    local owner="$1" namespace="$2" origin="$3" path phase operation project_id basename marker
    local new_id new_user old_id candidate secret found result root host active_user active_auth
    path="$(vx_harbor_rotation_path "$owner" runtime)"; [[ -f "$path" ]] || return 4
    vx_harbor_rotation_validate "$path" || return 2
    phase="$(/usr/bin/jq -r .PHASE "$path")"; operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"
    project_id="$(/usr/bin/jq -r .PROJECT_ID "$path")"; basename="$(/usr/bin/jq -r .ROBOT_BASENAME "$path")"
    marker="$(/usr/bin/jq -r .DESCRIPTION "$path")"; new_id="$(/usr/bin/jq -r .NEW_ROBOT_ID "$path")"
    new_user="$(/usr/bin/jq -r '.NEW_USERNAME // empty' "$path")"; old_id="$(/usr/bin/jq -r .OLD_ROBOT_ID "$path")"
    [[ "$phase" != converged ]] || { printf '%s\t%s\n' "$new_id" "$new_user"; return 0; }
    if [[ "$phase" == prepared ]]; then
        if found="$(vx_harbor_api_project_robot_find "$project_id" "$marker")"; then
            new_id="$(/usr/bin/jq -er .id <<<"$found")" || return 1
            vx_harbor_api_project_robot_delete "$project_id" "$new_id" "$marker" || return
        else
            result=$?; (( result == 4 )) || return "$result"
        fi
        return 4
    fi
    if [[ "$phase" == candidate-created || "$phase" == pending-switch ]]; then
        candidate="$(_vx_harbor_runtime_candidate_path "$owner" "$operation")" || return 1
        if ! secret="$(_vx_harbor_runtime_candidate_read "$owner" "$operation")"; then
            vx_harbor_api_project_robot_delete "$project_id" "$new_id" "$marker" || return
            [[ ! -e "$candidate" && ! -L "$candidate" ]] || /usr/bin/unlink "$candidate" || return 1
            /usr/bin/unlink "$path" || return 1
            _vx_harbor_fsync "$(dirname -- "$path")" || return 1
            return 4
        fi
        printf %s "$secret" | vx_harbor_api_credential_probe "$new_user" || { unset secret; return 75; }
        [[ "$phase" == pending-switch ]] || _vx_harbor_rotation_write "$owner" runtime "$project_id" "$operation" pending-switch "$new_id" "$new_user" "$old_id" || { unset secret; return 1; }
        vx_harbor_runtime_credential_switch "$owner" "$origin" "$new_user" "$secret" || { unset secret; return 1; }
        unset secret
        _vx_harbor_rotation_checkpoint runtime authority-switched || return 76
        _vx_harbor_rotation_write "$owner" runtime "$project_id" "$operation" pending-revoke "$new_id" "$new_user" "$old_id" || return 1
        /usr/bin/unlink "$candidate" || return 1
        _vx_harbor_fsync "$(dirname -- "$candidate")" || return 1
        phase=pending-revoke
    fi
    if [[ "$phase" == pending-revoke ]]; then
        root="$(vx_compose_registry_root "$owner")"; host="${origin#https://}"
        active_user="$(/usr/bin/jq -r --arg host "$host" '.[$host].USERNAME // empty' "$root/registries.json" 2>/dev/null || :)"
        active_auth="$(/usr/bin/jq -r --arg host "$host" '.auths[$host].auth // empty' "$root/config.json" 2>/dev/null || :)"
        [[ "$active_user" == "$new_user" && -n "$active_auth" ]] || return 1
        _vx_harbor_owned_robot_delete "$owner" runtime "$namespace" "$project_id" "$old_id" || return 75
        _vx_harbor_rotation_write "$owner" runtime "$project_id" "$operation" converged "$new_id" "$new_user" "$old_id" || return 1
        printf '%s\t%s\n' "$new_id" "$new_user"
        return 0
    fi
    return 1
}

_vx_harbor_rotation_recover() {
    local owner="$1" kind="$2" origin="${3-}" namespace="${4-}"
    case "$kind" in
        runtime) _vx_harbor_runtime_recover "$owner" "$namespace" "$origin" ;;
        publisher) vx_harbor_publisher_recover_locked "$owner" ;;
        *) return 1 ;;
    esac
}

vx_harbor_runtime_rotate() {
    local owner="$1" namespace="$2" project_id="$3" origin="$4" old_id="$5"
    local path operation basename marker response id username secret retry_status result
    path="$(vx_harbor_rotation_path "$owner" runtime)"
    if [[ -f "$path" ]]; then
        if result="$(_vx_harbor_runtime_recover "$owner" "$namespace" "$origin")"; then
            printf '%s\n' "$result"
            return 0
        else
            retry_status=$?
        fi
        (( retry_status == 4 )) || { vx_harbor_failure_audit "$owner" runtime-rotation recovery "$retry_status"; return "$retry_status"; }
    fi
    if [[ -f "$path" ]]; then
        operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"
    else
        operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')" || return 1
        [[ -n "$old_id" ]] || old_id=null
        _vx_harbor_rotation_write "$owner" runtime "$project_id" "$operation" prepared null '' "$old_id" || return 1
    fi
    basename="runtime-$operation"; marker="vesta-managed:vesta-harbor:$owner:runtime:$operation"
    response="$(_vx_harbor_api_project_robot_create_secret_once "$project_id" "$namespace" "$basename" "$marker" pull)" \
        || { vx_harbor_failure_audit "$owner" runtime-rotation api 75; return 75; }
    id="$(/usr/bin/jq -er .id <<<"$response")" || { unset response; return 1; }
    username="$(/usr/bin/jq -er .name <<<"$response")" || { unset response; return 1; }
    secret="$(/usr/bin/jq -er .secret <<<"$response")" || { unset response; return 1; }
    unset response
    _vx_harbor_runtime_candidate_stage "$owner" "$operation" "$secret" || { unset secret; return 1; }
    unset secret
    _vx_harbor_rotation_write "$owner" runtime "$project_id" "$operation" candidate-created "$id" "$username" "$old_id" || return 1
    _vx_harbor_rotation_checkpoint runtime journal-published || return 76
    result="$(_vx_harbor_runtime_recover "$owner" "$namespace" "$origin")" || { retry_status=$?; vx_harbor_failure_audit "$owner" runtime-rotation switch "$retry_status"; return "$retry_status"; }
    vx_harbor_audit "$owner" runtime-rotation succeeded converged || return 1
    printf '%s\n' "$result"
}

vx_harbor_runtime_revoke() {
    local owner="$1" origin="$2" id="$3" root host temporary
    [[ "$id" == null || -z "$id" ]] || vx_harbor_api_robot_disable "$id" >/dev/null || { vx_harbor_failure_audit "$owner" runtime-revocation outage 75; return; }
    root="$(vx_compose_registry_root "$owner")"; host="${origin#https://}"
    [[ -d "$root" ]] || return 0
    for file in config.json registries.json; do
        [[ -f "$root/$file" ]] || continue
        temporary="$(/usr/bin/mktemp "$root/.$file.XXXXXX")" || { vx_harbor_failure_audit "$owner" runtime-revocation switch 1; return; }
        if [[ "$file" == config.json ]]; then /usr/bin/jq --arg h "$host" 'del(.auths[$h])' "$root/$file" >"$temporary"; else /usr/bin/jq --arg h "$host" 'del(.[$h])' "$root/$file" >"$temporary"; fi
        /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" && /usr/bin/mv -fT "$temporary" "$root/$file" || { vx_harbor_failure_audit "$owner" runtime-revocation switch 1; return; }
    done
    vx_harbor_audit "$owner" runtime-revocation succeeded retained
}
