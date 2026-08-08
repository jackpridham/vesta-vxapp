#!/usr/bin/env bash

VX_HARBOR_API_MAX_INPUT=65536
VX_HARBOR_API_MAX_OUTPUT=1048576

_vx_harbor_api_socket() { vx_harbor_local_socket_path; }
_vx_harbor_api_curl() { printf '%s\n' /usr/bin/curl; }

_vx_harbor_api_credentials_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/awk '
      NR==1 {if ($0!="silent") exit 1; next}
      NR==2 {if ($0!="show-error") exit 1; next}
      NR==3 {if ($0 !~ /^user = "[^"[:cntrl:]]+:[^"[:cntrl:]]+"$/) exit 1; next}
      {exit 1} END {if (NR!=3) exit 1}' "$path"
}

_vx_harbor_api_socket_validate() {
    local socket="$1" uid gid mode
    uid="$(_vx_harbor_authority_uid)"; gid="$(_vx_harbor_authority_gid)"
    [[ -S "$socket" && ! -L "$socket" && "$(/usr/bin/stat -c '%u:%g:%F' "$socket" 2>/dev/null)" == "$uid:$gid:socket" ]] || return 1
    mode="$(/usr/bin/stat -c %a "$socket")" || return 1
    (( (8#$mode & 0022) == 0 ))
}

_vx_harbor_api_call() {
    local method="$1" path="$2" expected="$3" schema="$4" body_file="${5-}"
    local socket credential curl_bin temporary status size
    [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ && "$expected" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || return 1
    vx_harbor_local_api_guard "$(_vx_harbor_api_socket)" "$method" "$path" || return 1
    if [[ -n "$body_file" ]]; then
        vx_harbor_secure_regular_file "$body_file" 0600 || return 1
        [[ "$(dirname -- "$body_file")" == "$(vx_harbor_root)/secrets" ]] || return 1
        size="$(/usr/bin/stat -c %s "$body_file")" || return 1
        (( size > 0 && size <= VX_HARBOR_API_MAX_INPUT )) || return 1
        /usr/bin/jq -e 'type=="object"' "$body_file" >/dev/null 2>&1 || return 1
    fi
    socket="$(_vx_harbor_api_socket)" || return 1
    _vx_harbor_api_socket_validate "$socket" || return 1
    credential="$(vx_harbor_root)/secrets/integration.curl"
    _vx_harbor_api_credentials_validate "$credential" || return 1
    curl_bin="$(_vx_harbor_api_curl)" || return 1
    [[ "$curl_bin" == /usr/bin/curl ]] || return 1
    temporary="$(/usr/bin/mktemp "$(vx_harbor_root)/.api-response.XXXXXX")" || return 1
    if [[ -n "$body_file" ]]; then
        exec {VX_HARBOR_API_BODY_FD}<"$body_file" || { /usr/bin/rm -f "$temporary"; return 1; }
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" \
          --config "$credential" --unix-socket "$socket" --request "$method" \
          --header 'Content-Type: application/json' --data-binary @- --connect-timeout 3 \
          --max-time 10 --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --output "$temporary" \
          --write-out '%{http_code}' "http://localhost$path" <&$VX_HARBOR_API_BODY_FD 2>/dev/null)" || { exec {VX_HARBOR_API_BODY_FD}<&-; /usr/bin/rm -f "$temporary"; return 75; }
        exec {VX_HARBOR_API_BODY_FD}<&-
        unset VX_HARBOR_API_BODY_FD
    else
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" --config "$credential" \
          --unix-socket "$socket" --request "$method" --connect-timeout 3 --max-time 10 \
          --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --output "$temporary" \
          --write-out '%{http_code}' "http://localhost$path" 2>/dev/null)" || { /usr/bin/rm -f "$temporary"; return 75; }
    fi
    size="$(/usr/bin/stat -c %s "$temporary" 2>/dev/null)" || { /usr/bin/rm -f "$temporary"; return 1; }
    (( size <= VX_HARBOR_API_MAX_OUTPUT )) || { /usr/bin/rm -f "$temporary"; return 1; }
    [[ ",$expected," == *",$status,"* ]] || { /usr/bin/rm -f "$temporary"; return 1; }
    if [[ "$schema" == empty ]]; then
        (( size == 0 )) || /usr/bin/jq -e 'type=="object" or type=="array"' "$temporary" >/dev/null 2>&1 || { /usr/bin/rm -f "$temporary"; return 1; }
    else
        /usr/bin/jq -e "$schema" "$temporary" >/dev/null 2>&1 || { /usr/bin/rm -f "$temporary"; return 1; }
        /usr/bin/jq -cS . "$temporary"
    fi
    /usr/bin/rm -f "$temporary"
}

_vx_harbor_api_json_call() {
    local method="$1" path="$2" expected="$3" schema="$4" json="$5" body result
    body="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.api-body.XXXXXX")" || return 1
    printf '%s\n' "$json" >"$body"; unset json
    _vx_harbor_secure_file_set "$body" 0600 || { /usr/bin/rm -f "$body"; return 1; }
    _vx_harbor_api_call "$method" "$path" "$expected" "$schema" "$body"; result=$?
    /usr/bin/rm -f "$body"
    return "$result"
}

vx_harbor_api_health() { _vx_harbor_api_call GET /api/v2.0/health 200 '.status=="healthy"'; }
vx_harbor_api_projects() { _vx_harbor_api_call GET /api/v2.0/projects 200 'type=="array"'; }
vx_harbor_api_project_get() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1" 200 'type=="object" and (.project_id|type=="number")'; }
vx_harbor_api_project_create() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || return 1; _vx_harbor_api_json_call POST /api/v2.0/projects 201 empty "$(/usr/bin/jq -cn --arg n "$1" '{project_name:$n,metadata:{public:"false"}}')"; }
vx_harbor_api_project_private() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || return 1; _vx_harbor_api_json_call PUT "/api/v2.0/projects/$1" 200 empty '{"metadata":{"public":"false"}}'; }
vx_harbor_api_quota_get() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call GET "/api/v2.0/quotas/$1" 200 'type=="object" and (.id|type=="number")'; }
vx_harbor_api_quota_set_bytes() { [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^-1$|^[0-9]+$ ]] || return 1; _vx_harbor_api_json_call PUT "/api/v2.0/quotas/$1" 200 empty "$(/usr/bin/jq -cn --argjson b "$2" '{hard:{storage:$b}}')"; }
vx_harbor_api_robots() { local value; value="$(_vx_harbor_api_call GET /api/v2.0/robots 200 'type=="array"')" || return; /usr/bin/jq -cS 'map(del(.secret))' <<<"$value"; }
vx_harbor_api_robot_create() {
    local project="$1" name="$2" access="$3" input body result response secret
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$name" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && ( "$access" == pull || "$access" == push-pull ) ]] || return 1
    input="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.robot-input.XXXXXX")" || return 1
    _vx_harbor_secure_file_set "$input" 0600 || { /usr/bin/rm -f "$input"; return 1; }
    IFS= read -r -N 257 secret <&0 || [[ ${#secret} -gt 0 ]]
    [[ ${#secret} -ge 16 && ${#secret} -le 256 && "$secret" != *$'\n'* ]] || { /usr/bin/rm -f "$input"; return 1; }
    printf %s "$secret" >"$input"; unset secret
    body="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.robot-body.XXXXXX")" || { /usr/bin/rm -f "$input"; return 1; }
    /usr/bin/jq -cn --arg p "$project" --arg n "$name" --rawfile s "$input" --arg a "$access" '{name:$n,secret:$s,level:"system",permissions:[{kind:"project",namespace:$p,access:(if $a=="pull" then [{resource:"repository",action:"pull"}] else [{resource:"repository",action:"pull"},{resource:"repository",action:"push"}] end)}]}' >"$body" || { /usr/bin/rm -f "$input" "$body"; return 1; }
    _vx_harbor_secure_file_set "$body" 0600 || { /usr/bin/rm -f "$input" "$body"; return 1; }
    /usr/bin/rm -f "$input"
    response="$(_vx_harbor_api_call POST /api/v2.0/robots 201 'type=="object" and (.id|type=="number")' "$body")"; result=$?
    /usr/bin/rm -f "$body"
    (( result == 0 )) || return "$result"
    /usr/bin/jq -cS '{id,name,disabled}' <<<"$response"
}
vx_harbor_api_robot_get() { local value; [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1; value="$(_vx_harbor_api_call GET "/api/v2.0/robots/$1" 200 'type=="object" and (.id|type=="number")')" || return; /usr/bin/jq -cS 'del(.secret)' <<<"$value"; }
vx_harbor_api_robot_disable() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_json_call PUT "/api/v2.0/robots/$1" 200 empty '{"disabled":true}'; }
vx_harbor_api_robot_delete() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call DELETE "/api/v2.0/robots/$1" 200 empty; }
vx_harbor_api_repositories() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories" 200 'type=="array"'; }
vx_harbor_api_artifact() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$2" =~ ^[A-Za-z0-9._-]+$ && "$3" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1; _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories/$2/artifacts/$3" 200 'type=="object"'; }
vx_harbor_api_volume() { _vx_harbor_api_call GET /api/v2.0/systeminfo/volumes 200 'type=="object" and (.storage|type=="object")'; }

vx_harbor_api_credential_probe() {
    local username="$1" secret config socket curl_bin status temporary
    [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || return 1
    IFS= read -r -N 257 secret <&0 || [[ ${#secret} -gt 0 ]]
    [[ ${#secret} -ge 16 && ${#secret} -le 256 && "$secret" != *$'\n'* ]] || return 1
    config="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.probe-curl.XXXXXX")" || return 1
    { printf '%s\n' silent show-error; printf 'user = "'; printf %s "$username"; printf ':'; printf %s "$secret"; printf '"\n'; } >"$config"
    unset secret
    _vx_harbor_secure_file_set "$config" 0600 || { /usr/bin/rm -f "$config"; return 1; }
    _vx_harbor_api_credentials_validate "$config" || { /usr/bin/rm -f "$config"; return 1; }
    socket="$(_vx_harbor_api_socket)"; _vx_harbor_api_socket_validate "$socket" || { /usr/bin/rm -f "$config"; return 1; }
    curl_bin="$(_vx_harbor_api_curl)"; [[ "$curl_bin" == /usr/bin/curl ]] || { /usr/bin/rm -f "$config"; return 1; }
    temporary="$(/usr/bin/mktemp "$(vx_harbor_root)/.probe-response.XXXXXX")" || { /usr/bin/rm -f "$config"; return 1; }
    status="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" --config "$config" --unix-socket "$socket" --request GET --connect-timeout 3 --max-time 10 --max-filesize 4096 --output "$temporary" --write-out '%{http_code}' http://localhost/v2/ 2>/dev/null)" || { /usr/bin/rm -f "$config" "$temporary"; return 75; }
    /usr/bin/rm -f "$config" "$temporary"
    [[ "$status" == 200 ]]
}
