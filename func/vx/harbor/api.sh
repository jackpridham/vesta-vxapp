#!/usr/bin/env bash

VX_HARBOR_API_MAX_INPUT=65536
VX_HARBOR_API_MAX_OUTPUT=1048576
VX_HARBOR_ROBOT_LIST_PAGE_SIZE=100
VX_HARBOR_ROBOT_LIST_MAX_PAGES=10

_vx_harbor_api_socket() { vx_harbor_local_socket_path; }
_vx_harbor_api_curl() { printf '%s\n' /usr/bin/curl; }
_vx_harbor_api_integration_credential() { printf '%s/secrets/integration.curl\n' "$(vx_harbor_root)"; }

_vx_harbor_api_failure() {
    local reason="$1" status="${2:-1}"
    vx_harbor_audit system typed-api failed "$reason" || return 1
    return "$status"
}

_vx_harbor_api_credentials_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/awk '
      NR==1 {if ($0!="silent") exit 1; next}
      NR==2 {if ($0!="show-error") exit 1; next}
      NR==3 {if ($0 !~ /^user = "[A-Za-z0-9][A-Za-z0-9._+$-]{0,255}:[A-Za-z0-9_-]{8,256}"$/) exit 1; next}
      {exit 1} END {if (NR!=3) exit 1}' "$path"
}

_vx_harbor_api_socket_validate() {
    local socket="$1"
    [[ "$socket" == "$(vx_harbor_socket_path)" ]] || return 1
    vx_harbor_socket_validate
}

_vx_harbor_api_call_with_credential() {
    local credential="$1" method="$2" path="$3" expected="$4" schema="$5" body_file="${6-}"
    local socket curl_bin temporary status size
    [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ && "$expected" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || return 1
    [[ "$method $path" != 'POST /api/v2.0/robots' ]] || return 1
    vx_harbor_local_api_guard "$(_vx_harbor_api_socket)" "$method" "$path" || return 1
    if [[ -n "$body_file" ]]; then
        vx_harbor_secure_regular_file "$body_file" 0600 || return 1
        [[ "$(dirname -- "$body_file")" == "$(vx_harbor_root)/secrets" ]] || return 1
        size="$(/usr/bin/stat -c %s "$body_file")" || return 1
        (( size > 0 && size <= VX_HARBOR_API_MAX_INPUT )) || return 1
        /usr/bin/jq -e 'type=="object" and ([..|objects|has("secret")]|any|not)' "$body_file" >/dev/null 2>&1 || return 1
    fi
    socket="$(_vx_harbor_api_socket)" || return 1
    _vx_harbor_api_socket_validate "$socket" || return 1
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
          --write-out '%{http_code}' "http://localhost$path" <&$VX_HARBOR_API_BODY_FD 2>/dev/null)" \
          || { exec {VX_HARBOR_API_BODY_FD}<&-; /usr/bin/rm -f "$temporary"; _vx_harbor_api_failure transport 75; return; }
        exec {VX_HARBOR_API_BODY_FD}<&-
        unset VX_HARBOR_API_BODY_FD
    else
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" --config "$credential" \
          --unix-socket "$socket" --request "$method" --connect-timeout 3 --max-time 10 \
          --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --output "$temporary" \
          --write-out '%{http_code}' "http://localhost$path" 2>/dev/null)" \
          || { /usr/bin/rm -f "$temporary"; _vx_harbor_api_failure transport 75; return; }
    fi
    size="$(/usr/bin/stat -c %s "$temporary" 2>/dev/null)" || { /usr/bin/rm -f "$temporary"; return 1; }
    (( size <= VX_HARBOR_API_MAX_OUTPUT )) || { /usr/bin/rm -f "$temporary"; return 1; }
    [[ ",$expected," == *",$status,"* ]] || { /usr/bin/rm -f "$temporary"; _vx_harbor_api_failure unexpected-status 1; return; }
    if [[ "$schema" == empty ]]; then
        (( size == 0 )) || /usr/bin/jq -e '(type=="object" or type=="array") and ([..|objects|has("secret")]|any|not)' "$temporary" >/dev/null 2>&1 \
            || { /usr/bin/rm -f "$temporary"; return 1; }
    else
        /usr/bin/jq -e "($schema) and ([..|objects|has(\"secret\")]|any|not)" "$temporary" >/dev/null 2>&1 \
            || { /usr/bin/rm -f "$temporary"; _vx_harbor_api_failure invalid-response 1; return; }
        /usr/bin/jq -cS . "$temporary"
    fi
    /usr/bin/rm -f "$temporary"
}

_vx_harbor_api_call() {
    _vx_harbor_api_call_with_credential "$(_vx_harbor_api_integration_credential)" "$@"
}

_vx_harbor_api_json_call_with_credential() {
    local credential="$1" method="$2" path="$3" expected="$4" schema="$5" json="$6" body result
    body="$(/usr/bin/mktemp "$(vx_harbor_root)/secrets/.api-body.XXXXXX")" || return 1
    printf '%s\n' "$json" >"$body"; unset json
    _vx_harbor_secure_file_set "$body" 0600 || { /usr/bin/rm -f "$body"; return 1; }
    _vx_harbor_api_call_with_credential "$credential" "$method" "$path" "$expected" "$schema" "$body"; result=$?
    /usr/bin/rm -f "$body"
    return "$result"
}

_vx_harbor_api_json_call() {
    _vx_harbor_api_json_call_with_credential "$(_vx_harbor_api_integration_credential)" "$@"
}

_vx_harbor_api_marker_validate() {
    [[ "$1" =~ ^vesta-managed:candidate:probe:[a-f0-9]{32}$ \
        || "$1" =~ ^vesta-managed:vesta-harbor:[a-z0-9][a-z0-9_-]{0,31}:(runtime|publisher):[a-f0-9]{32}$ ]]
}

_vx_harbor_api_robot_created_validate() {
    local response="$1" namespace="$2" basename="$3" username suffix prefix
    (( ${#response} <= VX_HARBOR_API_MAX_OUTPUT )) || return 1
    /usr/bin/jq -e '
      keys==["creation_time","expires_at","id","name","secret"]
      and (.id|type=="number" and floor==. and .>0)
      and (.name|type=="string" and length>=1 and length<=256)
      and (.secret|type=="string" and test("^[A-Za-z0-9_-]{8,256}$"))
      and (.creation_time|type=="string" and length>=20 and length<=40)
      and .expires_at==-1
    ' <<<"$response" >/dev/null 2>&1 || return 1
    username="$(/usr/bin/jq -er .name <<<"$response")" || return 1
    suffix="$basename"
    [[ -z "$namespace" ]] || suffix="$namespace+$basename"
    [[ "$username" == *"$suffix" && "$username" != "$suffix" ]] || return 1
    prefix="${username%"$suffix"}"
    [[ "$prefix" =~ ^[-A-Za-z0-9._+$]+$ ]]
}

_vx_harbor_api_robot_create_secret_once_with_credential() {
    local credential="$1" project_id="$2" namespace="$3" basename="$4" marker="$5" access="$6"
    local body socket curl_bin exchange status response
    [[ "$project_id" =~ ^[1-9][0-9]*$ \
        && "$namespace" =~ ^[a-z0-9][a-z0-9-]{0,127}$ \
        && "$basename" =~ ^[a-z0-9][a-z0-9-]{0,127}$ \
        && ( "$access" == pull || "$access" == push-pull ) ]] || return 1
    _vx_harbor_api_marker_validate "$marker" || return 1
    _vx_harbor_api_credentials_validate "$credential" || return 1
    socket="$(_vx_harbor_api_socket)" || return 1
    vx_harbor_local_api_guard "$socket" POST /api/v2.0/robots || return 1
    _vx_harbor_api_socket_validate "$socket" || return 1
    curl_bin="$(_vx_harbor_api_curl)" || return 1
    [[ "$curl_bin" == /usr/bin/curl ]] || return 1
    body="$(/usr/bin/jq -cn --arg n "$basename" --arg marker "$marker" \
      --arg p "$namespace" --arg a "$access" \
      '{name:$n,description:$marker,disable:false,duration:-1,level:"project",
        permissions:[{kind:"project",namespace:$p,access:
          (if $a=="pull" then [{resource:"repository",action:"pull"}]
           else [{resource:"repository",action:"pull"},{resource:"repository",action:"push"}] end)}]}')" \
      || return 1
    (( ${#body} > 0 && ${#body} <= VX_HARBOR_API_MAX_INPUT )) || return 1
    /usr/bin/jq -e 'has("secret")|not' <<<"$body" >/dev/null || return 1
    exchange="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" --config "$credential" \
      --unix-socket "$socket" --request POST --header 'Content-Type: application/json' \
      --data-binary @- --connect-timeout 3 --max-time 10 \
      --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --write-out $'\n%{http_code}' \
      http://localhost/api/v2.0/robots 2>/dev/null <<<"$body")" \
      || { _vx_harbor_api_failure transport 75; return; }
    (( ${#exchange} <= VX_HARBOR_API_MAX_OUTPUT + 4 )) || return 1
    status="${exchange##*$'\n'}"
    response="${exchange%$'\n'*}"
    unset exchange body
    [[ "$status" == 201 ]] || { unset response; _vx_harbor_api_failure unexpected-status 1; return; }
    _vx_harbor_api_robot_created_validate "$response" "$namespace" "$basename" \
        || { unset response; _vx_harbor_api_failure invalid-response 1; return; }
    /usr/bin/jq -cS . <<<"$response"
    unset response
}

_vx_harbor_api_project_robot_create_secret_once() {
    _vx_harbor_api_robot_create_secret_once_with_credential \
        "$(_vx_harbor_api_integration_credential)" "$@"
}

vx_harbor_api_health() { _vx_harbor_api_call GET /api/v2.0/health 200 '.status=="healthy"'; }
vx_harbor_api_project_get() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1" 200 'type=="object" and (.project_id|type=="number")'; }
vx_harbor_api_project_create() {
    local namespace="$1"
    [[ "$namespace" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] || return 1
    _vx_harbor_api_json_call POST /api/v2.0/projects 201 empty \
        "$(/usr/bin/jq -cn --arg n "$namespace" '{project_name:$n,metadata:{public:"false"}}')"
}
vx_harbor_api_quota_get() { [[ "$1" =~ ^[1-9][0-9]*$ ]] && _vx_harbor_api_call GET "/api/v2.0/quotas/$1" 200 'type=="object" and (.id|type=="number")'; }
vx_harbor_api_quota_set_bytes() { [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^-1$|^[0-9]+$ ]] || return 1; _vx_harbor_api_json_call PUT "/api/v2.0/quotas/$1" 200 empty "$(/usr/bin/jq -cn --argjson b "$2" '{hard:{storage:$b}}')"; }

_vx_harbor_api_project_robots_list_with_credential() {
    local credential="$1" project_id="$2" path value page count robots='[]'
    [[ "$project_id" =~ ^[1-9][0-9]*$ ]] || return 1
    for (( page=1; page<=VX_HARBOR_ROBOT_LIST_MAX_PAGES; page++ )); do
        path="/api/v2.0/robots?q=Level%3Dproject%2CProjectID%3D${project_id}&page=${page}&page_size=${VX_HARBOR_ROBOT_LIST_PAGE_SIZE}"
        value="$(_vx_harbor_api_call_with_credential "$credential" GET "$path" 200 'type=="array" and length<=100')" || return
        count="$(/usr/bin/jq -r length <<<"$value")" || return 1
        robots="$(/usr/bin/jq -cn --argjson current "$robots" --argjson page "$value" '$current+$page')" || return 1
        if (( count < VX_HARBOR_ROBOT_LIST_PAGE_SIZE )); then
            /usr/bin/jq -cS 'map(del(.secret))' <<<"$robots"
            return
        fi
    done
    return 1
}

vx_harbor_api_project_robots_list() {
    _vx_harbor_api_project_robots_list_with_credential "$(_vx_harbor_api_integration_credential)" "$1"
}

_vx_harbor_api_project_robot_find_with_credential() {
    local credential="$1" project_id="$2" marker="$3" robots matches count
    [[ "$project_id" =~ ^[1-9][0-9]*$ ]] || return 1
    _vx_harbor_api_marker_validate "$marker" || return 1
    robots="$(_vx_harbor_api_project_robots_list_with_credential "$credential" "$project_id")" || return
    matches="$(/usr/bin/jq -c --arg marker "$marker" '[.[]|select(.description==$marker)]' <<<"$robots")" || return 1
    count="$(/usr/bin/jq -r length <<<"$matches")" || return 1
    (( count <= 1 )) || return 1
    (( count == 1 )) || return 4
    /usr/bin/jq -cS '.[0]' <<<"$matches"
}

vx_harbor_api_project_robot_find() {
    _vx_harbor_api_project_robot_find_with_credential \
        "$(_vx_harbor_api_integration_credential)" "$@"
}

_vx_harbor_api_project_robot_get_with_credential() {
    local credential="$1" project_id="$2" robot_id="$3" marker="$4" listed value
    [[ "$robot_id" =~ ^[1-9][0-9]*$ ]] || return 1
    listed="$(_vx_harbor_api_project_robot_find_with_credential "$credential" "$project_id" "$marker")" || return
    /usr/bin/jq -e --argjson id "$robot_id" '.id==$id and .level=="project" and (has("secret")|not)' <<<"$listed" >/dev/null || return 1
    value="$(_vx_harbor_api_call_with_credential "$credential" GET "/api/v2.0/robots/$robot_id" 200 'type=="object" and (.id|type=="number")')" || return
    /usr/bin/jq -e --argjson listed "$listed" '
      .id==$listed.id and .name==$listed.name and .description==$listed.description
      and .level=="project" and .permissions==$listed.permissions and (has("secret")|not)
    ' <<<"$value" >/dev/null || return 1
    /usr/bin/jq -cS . <<<"$value"
}

vx_harbor_api_project_robot_get() {
    _vx_harbor_api_project_robot_get_with_credential \
        "$(_vx_harbor_api_integration_credential)" "$@"
}

_vx_harbor_api_project_robot_delete_with_credential() {
    local credential="$1" project_id="$2" robot_id="$3" marker="$4" listed result
    [[ "$robot_id" =~ ^[1-9][0-9]*$ ]] || return 1
    if listed="$(_vx_harbor_api_project_robot_find_with_credential "$credential" "$project_id" "$marker")"; then
        result=0
    else
        result=$?
    fi
    (( result == 4 )) && return 0
    (( result == 0 )) || return "$result"
    /usr/bin/jq -e --argjson id "$robot_id" '.id==$id and .level=="project"' <<<"$listed" >/dev/null || return 1
    _vx_harbor_api_project_robot_get_with_credential "$credential" "$project_id" "$robot_id" "$marker" >/dev/null || return 1
    _vx_harbor_api_call_with_credential "$credential" DELETE "/api/v2.0/robots/$robot_id" 200,404 empty >/dev/null || return
    _vx_harbor_api_call_with_credential "$credential" GET "/api/v2.0/robots/$robot_id" 404 'type=="object" and (.errors|type=="array")' >/dev/null
}

vx_harbor_api_project_robot_delete() {
    _vx_harbor_api_project_robot_delete_with_credential \
        "$(_vx_harbor_api_integration_credential)" "$@"
}

vx_harbor_api_repositories() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ ]] && _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories" 200 'type=="array"'; }
vx_harbor_api_artifact() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,127}$ && "$2" =~ ^[A-Za-z0-9._-]+$ && "$3" =~ ^sha256:[a-f0-9]{64}$ ]] || return 1; _vx_harbor_api_call GET "/api/v2.0/projects/$1/repositories/$2/artifacts/$3" 200 'type=="object"'; }
vx_harbor_api_volume() { _vx_harbor_api_call GET /api/v2.0/systeminfo/volumes 200 'type=="object" and (.storage|type=="object")'; }

vx_harbor_api_credential_probe() {
    local username="$1" secret config socket curl_bin status
    [[ "$username" =~ ^[A-Za-z0-9][-A-Za-z0-9._+$]{0,255}$ ]] || return 1
    IFS= read -r -N 257 secret <&0 || [[ ${#secret} -gt 0 ]]
    [[ "$secret" =~ ^[A-Za-z0-9_-]{8,256}$ ]] || { unset secret; return 1; }
    config="$(printf 'silent\nshow-error\nuser = "%s:%s"\n' "$username" "$secret")" || { unset secret; return 1; }
    unset secret
    socket="$(_vx_harbor_api_socket)"; _vx_harbor_api_socket_validate "$socket" || { unset config; return 1; }
    curl_bin="$(_vx_harbor_api_curl)"; [[ "$curl_bin" == /usr/bin/curl ]] || { unset config; return 1; }
    status="$(/usr/bin/env -i PATH=/usr/bin:/bin "$curl_bin" --config - \
      --unix-socket "$socket" --request GET --connect-timeout 3 --max-time 10 \
      --max-filesize 4096 --output /dev/null --write-out '%{http_code}' \
      http://localhost/v2/ 2>/dev/null <<<"$config")" || { unset config; return 75; }
    unset config
    [[ "$status" == 200 ]]
}
