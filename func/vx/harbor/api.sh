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
    local method="$1" path="$2" expected="$3" schema="$4" payload="${5-}"
    local socket credential curl_bin temporary status size
    [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ && "$expected" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || return 1
    vx_harbor_local_api_guard "$(_vx_harbor_api_socket)" "$method" "$path" || return 1
    [[ ${#payload} -le $VX_HARBOR_API_MAX_INPUT ]] || return 1
    [[ -z "$payload" ]] || /usr/bin/jq -e 'type=="object"' <<<"$payload" >/dev/null 2>&1 || return 1
    socket="$(_vx_harbor_api_socket)" || return 1
    _vx_harbor_api_socket_validate "$socket" || return 1
    credential="$(vx_harbor_root)/secrets/integration.curl"
    _vx_harbor_api_credentials_validate "$credential" || return 1
    curl_bin="$(_vx_harbor_api_curl)" || return 1
    [[ "$curl_bin" == /usr/bin/curl ]] || return 1
    temporary="$(/usr/bin/mktemp "$(vx_harbor_root)/.api-response.XXXXXX")" || return 1
    if [[ -n "$payload" ]]; then
        status="$(/usr/bin/printf %s "$payload" | /usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" \
          --config "$credential" --unix-socket "$socket" --request "$method" \
          --header 'Content-Type: application/json' --data-binary @- --connect-timeout 3 \
          --max-time 10 --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --output "$temporary" \
          --write-out '%{http_code}' "http://localhost$path" 2>/dev/null)" || { /usr/bin/rm -f "$temporary"; return 75; }
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

vx_harbor_api_health() { _vx_harbor_api_call GET /api/v2.0/health 200 '.status=="healthy"'; }
vx_harbor_api_projects() { _vx_harbor_api_call GET /api/v2.0/projects 200 'type=="array"'; }
vx_harbor_api_project_get() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1" 200 'type=="object" and (.project_id|type=="number")'; }
vx_harbor_api_project_create() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || return 1; _vx_harbor_api_call POST /api/v2.0/projects 201 empty "$(/usr/bin/jq -cn --arg n "$1" '{project_name:$n,metadata:{public:"false"}}')"; }
vx_harbor_api_project_private() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || return 1; _vx_harbor_api_call PUT "/api/v2.0/projects/$1" 200 empty '{"metadata":{"public":"false"}}'; }
vx_harbor_api_quota_get() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call GET "/api/v2.0/quotas/$1" 200 'type=="object" and (.id|type=="number")'; }
vx_harbor_api_quota_set_bytes() { [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^-1$|^[0-9]+$ ]] || return 1; _vx_harbor_api_call PUT "/api/v2.0/quotas/$1" 200 empty "$(/usr/bin/jq -cn --argjson b "$2" '{hard:{storage:$b}}')"; }
vx_harbor_api_robots() { local value; value="$(_vx_harbor_api_call GET /api/v2.0/robots 200 'type=="array"')" || return; /usr/bin/jq -cS 'map(del(.secret))' <<<"$value"; }
vx_harbor_api_robot_create() {
    local project="$1" name="$2" access="$3" input payload result response
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$name" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && ( "$access" == pull || "$access" == push-pull ) ]] || return 1
    input="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.robot-input.XXXXXX")" || return 1
    _vx_harbor_secure_file_set "$input" 0600 || { /usr/bin/rm -f "$input"; return 1; }
    IFS= read -r -N 257 secret <&0 || [[ ${#secret} -gt 0 ]]
    [[ ${#secret} -ge 16 && ${#secret} -le 256 && "$secret" != *$'\n'* ]] || { /usr/bin/rm -f "$input"; return 1; }
    printf %s "$secret" >"$input"; unset secret
    payload="$(/usr/bin/jq -cn --arg p "$project" --arg n "$name" --rawfile s "$input" --arg a "$access" '{name:$n,secret:$s,level:"system",permissions:[{kind:"project",namespace:$p,access:(if $a=="pull" then [{resource:"repository",action:"pull"}] else [{resource:"repository",action:"pull"},{resource:"repository",action:"push"}] end)}]}')" || { /usr/bin/rm -f "$input"; return 1; }
    /usr/bin/rm -f "$input"
    response="$(_vx_harbor_api_call POST /api/v2.0/robots 201 'type=="object" and (.id|type=="number")' "$payload")"; result=$?
    unset payload
    (( result == 0 )) || return "$result"
    /usr/bin/jq -cS '{id,name,disabled}' <<<"$response"
}
vx_harbor_api_robot_get() { local value; [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1; value="$(_vx_harbor_api_call GET "/api/v2.0/robots/$1" 200 'type=="object" and (.id|type=="number")')" || return; /usr/bin/jq -cS 'del(.secret)' <<<"$value"; }
vx_harbor_api_robot_disable() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call PUT "/api/v2.0/robots/$1" 200 empty '{"disabled":true}'; }
vx_harbor_api_robot_delete() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call DELETE "/api/v2.0/robots/$1" 200 empty; }
vx_harbor_api_repositories() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories" 200 'type=="array"'; }
vx_harbor_api_artifact() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$2" =~ ^[A-Za-z0-9._-]+$ && "$3" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1; _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories/$2/artifacts/$3" 200 'type=="object"'; }
vx_harbor_api_volume() { _vx_harbor_api_call GET /api/v2.0/systeminfo/volumes 200 'type=="object" and (.storage|type=="object")'; }
