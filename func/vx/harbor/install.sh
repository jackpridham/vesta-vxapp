#!/usr/bin/env bash

_vx_harbor_install_requirements() {
    local command available
    _vx_harbor_require_root || return 1
    for command in jq python3 sha256sum tar curl cosign docker systemctl nginx openssl; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
    [[ -x /usr/bin/age && -x /usr/bin/age-keygen ]] || return 1
    available="$(/usr/bin/df -Pk "$(vx_harbor_root)" | /usr/bin/awk 'NR==2 {print $4}')" || return 1
    [[ "$available" =~ ^[0-9]+$ ]] && (( available >= ${VX_HARBOR_MIN_FREE_KB:-10485760} ))
}

_vx_harbor_install_phase() { :; }
_vx_harbor_install_step() { VX_HARBOR_INSTALL_ACTIVE_STEP="$1"; }

_vx_harbor_docker() { /usr/bin/docker "$@"; }
_vx_harbor_docker_bounded() { local seconds="$1"; shift; /usr/bin/timeout "$seconds" /usr/bin/docker "$@"; }

_vx_harbor_install_secret() {
    local path="$1"
    /usr/bin/openssl rand -base64 36 >"$path" && _vx_harbor_secure_file_set "$path" 0600
}

_vx_harbor_install_harbor_yml() {
    local stage origin_json secrets template current_secrets
    stage="$1"; origin_json="$2"
    secrets="$stage/secrets"; template="$stage/extracted/harbor/harbor.yml.tmpl"
    /usr/bin/mkdir -m 0700 "$secrets" || return 1
    current_secrets="$(vx_harbor_root)/release/current/secrets"
    if [[ -e "$current_secrets/admin" || -e "$current_secrets/database" ]]; then
        vx_harbor_secure_regular_file "$current_secrets/admin" 0600 \
            && vx_harbor_secure_regular_file "$current_secrets/database" 0600 \
            && /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" \
              -m 0600 "$current_secrets/admin" "$secrets/admin" \
            && /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" \
              -m 0600 "$current_secrets/database" "$secrets/database" || return 1
    else
        _vx_harbor_install_secret "$secrets/admin" || return 1
        _vx_harbor_install_secret "$secrets/database" || return 1
    fi
    /usr/bin/python3 - "$template" "$stage/harbor.yml" "$secrets/admin" "$secrets/database" "$origin_json" <<'PY'
import json,pathlib,re,sys
src,dst,admin_path,db_path,origin_path=sys.argv[1:]
text=pathlib.Path(src).read_text()
origin=json.loads(origin_path)
admin=pathlib.Path(admin_path).read_text().strip(); db=pathlib.Path(db_path).read_text().strip()
text=re.sub(r'^hostname:.*$', 'hostname: '+origin['HOSTNAME'], text, count=1, flags=re.M)
text=re.sub(r'^harbor_admin_password:.*$', 'harbor_admin_password: '+admin, text, count=1, flags=re.M)
text=re.sub(r'^(database:\n  password:).*$' , r'\1 '+db, text, count=1, flags=re.M)
text=re.sub(r'^data_volume:.*$', 'data_volume: /var/lib/vesta-harbor', text, count=1, flags=re.M)
text=re.sub(r'^# external_url:.*$', 'external_url: '+origin['ORIGIN'], text, count=1, flags=re.M)
text=re.sub(r'^(    location:).*$' , r'\1 /var/lib/vesta-harbor/log', text, count=1, flags=re.M)
text,count=re.subn(r'(?ms)^# https related config\nhttps:\n.*?(?=^# # Harbor will set ipv4)', '', text, count=1)
if count != 1 or re.search(r'(?m)^https:', text): raise SystemExit(1)
metric='# metric:\n#   enabled: false\n#   port: 9090\n#   path: /metrics'
if metric not in text: raise SystemExit(1)
text=text.replace(metric, 'metric:\n  enabled: true\n  port: 9090\n  path: /metrics', 1)
pathlib.Path(dst).write_text(text)
PY
    _vx_harbor_secure_file_set "$stage/harbor.yml" 0600
}

_vx_harbor_install_transform_generated() {
    local stage="$1" manifest="$2" ingress_gid
    ingress_gid="${VX_HARBOR_SOCKET_GID:-}"
    if [[ -z "$ingress_gid" ]]; then
        ingress_gid="$(/usr/bin/getent group www-data | /usr/bin/awk -F: 'NR==1 {print $3}')" || return 1
    fi
    [[ "$ingress_gid" =~ ^[1-9][0-9]*$ ]] || return 1
    /usr/bin/python3 - "$stage/docker-compose.yml" "$stage/common/config/nginx/nginx.conf" \
      "$stage/common/config/nginx/proxy-entrypoint.sh" "$manifest" "$ingress_gid" <<'PY'
import json,pathlib,re,sys
compose_path,nginx_path,entrypoint_path,manifest_path=map(pathlib.Path,sys.argv[1:5])
ingress_gid=sys.argv[5]
images=json.loads(manifest_path.read_text())['images']
text=compose_path.read_text()
for name,digest in images.items():
    text=text.replace(f'image: {name}:v2.15.0', f'image: {name}@{digest}')
text=re.sub(r'(?m)^(    container_name: )(?!vesta-harbor-)(.+)$', r'\1vesta-harbor-\2', text)
text=re.sub(r'(?m)^    ports:\n(?:      - [^\n]*\n)+', '', text)
text=re.sub(r'(?m)^    logging:\n      driver: "syslog"\n      options:\n(?:        [^\n]*\n)+', '    logging:\n      driver: local\n', text)
proxy=re.search(r'(?ms)^(  proxy:\n.*?)(?=^  [a-z]|^networks:)', text)
if not proxy: raise SystemExit(1)
block=proxy.group(1)
if re.search(r'(?m)^    (?:user|command|security_opt):', block): raise SystemExit(1)
upstream_hardening='''    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
      - NET_BIND_SERVICE
'''
if block.count(upstream_hardening) != 1: raise SystemExit(1)
managed_hardening='''    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - FOWNER
      - SETGID
      - SETUID
    security_opt:
      - no-new-privileges:true
'''
block=block.replace(upstream_hardening, managed_hardening, 1)
block=block.replace('  proxy:\n', f'''  proxy:
    user: "0:{ingress_gid}"
    command: ["/bin/sh", "/etc/nginx/proxy-entrypoint.sh"]
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "--unix-socket", "/run/vesta-harbor/proxy.sock", "http://localhost/"]
''', 1)
block=block.replace('    volumes:\n', '    volumes:\n      - /run/vesta-harbor:/run/vesta-harbor\n', 1)
text='name: vesta-harbor\n'+text[:proxy.start(1)]+block+text[proxy.end(1):]
compose_path.write_text(text)
nginx=nginx_path.read_text()
if re.search(r'(?m)^user\s+', nginx): raise SystemExit(1)
nginx='user nginx;\n'+nginx
nginx,count=re.subn(r'listen\s+8080\s*;', 'listen unix:/run/vesta-harbor/proxy.sock;', nginx, count=1)
if count != 1: raise SystemExit(1)
nginx_path.write_text(nginx)
entrypoint_path.write_text(f'''#!/bin/sh
set -eu
socket=/run/vesta-harbor/proxy.sock
pid=
shutdown() {{ [ -z "$pid" ] || kill -QUIT "$pid" 2>/dev/null || :; }}
trap shutdown INT TERM QUIT
if [ -e "$socket" ] || [ -L "$socket" ]; then
    [ -S "$socket" ] && [ ! -L "$socket" ] || exit 1
    rm -f "$socket"
fi
/usr/sbin/nginx -g 'daemon off;' &
pid=$!
attempt=0
while [ ! -S "$socket" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
        status=0; wait "$pid" || status=$?; exit "$status"
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le 100 ] || {{ kill -QUIT "$pid" 2>/dev/null || :; wait "$pid" || :; exit 1; }}
    sleep 0.1
done
chown 0:{ingress_gid} "$socket"
chmod 0660 "$socket"
wait "$pid"
''')
PY
    _vx_harbor_secure_file_set "$stage/docker-compose.yml" 0600 || return 1
    _vx_harbor_secure_file_set "$stage/common/config/nginx/nginx.conf" 0644 || return 1
    _vx_harbor_secure_file_set "$stage/common/config/nginx/proxy-entrypoint.sh" 0644 || return 1
    vx_harbor_release_images_validate "$manifest" "$stage/docker-compose.yml"
}

_vx_harbor_install_loaded_image_config_validate() {
    local image_id="$1" expected_config="$2" saved_manifest
    [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ \
        && "$expected_config" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    saved_manifest="$(_vx_harbor_docker_bounded 60 image save "$image_id" \
        | /usr/bin/tar -xOf - manifest.json)" || return 1
    /usr/bin/jq -e --arg config "blobs/sha256/${expected_config#sha256:}" '
        type == "array" and length == 1
        and .[0].Config == $config
        and (.[] | (keys == ["Config", "Layers", "RepoTags"]
            or (keys == ["Config", "LayerSources", "Layers", "RepoTags"]
                and (.LayerSources | type == "object")
                and (.LayerSources | to_entries | all(
                    .key | test("^sha256:[0-9a-f]{64}$")
                ))
                and (.LayerSources | to_entries | all(
                    (.value | keys == ["digest", "mediaType", "size"])
                    and .value.digest == .key
                    and (.value.mediaType | type == "string" and length > 0)
                    and (.value.size | type == "number" and . > 0)
                )))))
        and (.[0].Layers | type == "array" and length > 0)
    ' <<<"$saved_manifest" >/dev/null 2>&1
}

_vx_harbor_install_generate() {
    local stage="$1" manifest="$2" origin prepare_id expected_config
    origin="$(vx_harbor_origin_json)" || return 1
    _vx_harbor_install_harbor_yml "$stage" "$origin" || return 1
    _vx_harbor_docker load --input "$stage/extracted/harbor/harbor.v2.15.0.tar.gz" >/dev/null || return 1
    prepare_id="$(_vx_harbor_docker image inspect --format '{{.Id}}' goharbor/prepare:v2.15.0)" || return 1
    expected_config="$(/usr/bin/jq -r '.generator_image.offline_config_digest' "$VESTA/install/harbor/release-provenance.json")" || return 1
    _vx_harbor_install_loaded_image_config_validate "$prepare_id" "$expected_config" || return 1
    /usr/bin/mkdir -p "$stage/common/config" || return 1
    _vx_harbor_docker run --rm --network none --cap-drop ALL \
      --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
      --volume "$stage/harbor.yml:/input/harbor.yml:ro" \
      --volume "/var/lib/vesta-harbor:/data" \
      --volume "$stage:/compose_location" \
      --volume "$stage/common/config:/config" \
      "$prepare_id" prepare --conf /input/harbor.yml >/dev/null || return 1
    _vx_harbor_install_transform_generated "$stage" "$manifest" || return 1
    /usr/bin/chown 0:0 /var/lib/vesta-harbor \
        && /usr/bin/chmod 0700 /var/lib/vesta-harbor
}

_vx_harbor_install_migration_check() {
    local compose="$1" attempt
    for attempt in {1..30}; do
        _vx_harbor_docker_bounded 5 compose --project-name vesta-harbor \
            --file "$compose" exec -T postgresql pg_isready -U postgres \
            >/dev/null 2>&1 && return 0
        /usr/bin/sleep 1
    done
    return 1
}

_vx_harbor_install_health_check() {
    local response attempt
    for attempt in {1..30}; do
        response="$(/usr/bin/timeout 7 /usr/bin/curl --fail --silent \
          --show-error --connect-timeout 2 --max-time 5 \
          --unix-socket "$(vx_harbor_socket_path)" \
          http://localhost/api/v2.0/health 2>/dev/null)" \
          && /usr/bin/jq -e '.status == "healthy" and (.components | type == "array")' \
            <<<"$response" >/dev/null 2>&1 && return 0
        /usr/bin/sleep 1
    done
    return 1
}

_vx_harbor_install_bootstrap_call() {
    local stage="$1" method="$2" path="$3" body="${4-}" output="$5" expected="${6:-200,201}"
    local config status admin socket
    [[ "$method" =~ ^(GET|POST|PUT|DELETE)$ && "$expected" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || return 1
    admin="$stage/secrets/admin"; socket="$(vx_harbor_socket_path)"
    vx_harbor_secure_regular_file "$admin" 0600 || return 1
    config="$stage/secrets/bootstrap.curl"
    { printf '%s\n' silent show-error; printf 'user = "admin:'; /usr/bin/tr -d '\n' <"$admin"; printf '"\n'; } >"$config" || return 1
    _vx_harbor_secure_file_set "$config" 0600 || return 1
    if [[ -n "$body" ]]; then
        (( ${#body} <= VX_HARBOR_API_MAX_INPUT )) || return 1
        /usr/bin/jq -e 'type=="object" and ([..|objects|has("secret")]|any|not)' <<<"$body" >/dev/null 2>&1 || return 1
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$config" \
          --unix-socket "$socket" --request "$method" --header 'Content-Type: application/json' \
          --data-binary @- --connect-timeout 3 --max-time 10 --max-filesize 1048576 \
          --output "$output" --write-out '%{http_code}' "http://localhost$path" \
          <<<"$body" 2>/dev/null)" || return 1
    else
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$config" \
          --unix-socket "$socket" --request "$method" --connect-timeout 3 --max-time 10 \
          --max-filesize 1048576 --output "$output" --write-out '%{http_code}' \
          "http://localhost$path" 2>/dev/null)" || return 1
    fi
    [[ ",$expected," == *",$status,"* ]]
}

_vx_harbor_install_bootstrap_robot_create_secret_once() {
    local stage="$1" body="$2" config socket basename exchange status response
    (( ${#body} > 0 && ${#body} <= VX_HARBOR_API_MAX_INPUT )) || return 1
    /usr/bin/jq -e 'type=="object" and (has("secret")|not) and .level=="system"' <<<"$body" >/dev/null 2>&1 || return 1
    basename="$(/usr/bin/jq -er '.name|select(type=="string")' <<<"$body")" || return 1
    config="$stage/secrets/bootstrap.curl"
    vx_harbor_secure_regular_file "$config" 0600 || return 1
    /usr/bin/awk '
      NR==1 {if ($0!="silent") exit 1; next}
      NR==2 {if ($0!="show-error") exit 1; next}
      NR==3 {if ($0 !~ /^user = "admin:[^"[:cntrl:]]+"$/) exit 1; next}
      {exit 1} END {if (NR!=3) exit 1}' "$config" || return 1
    socket="$(vx_harbor_socket_path)"
    exchange="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$config" \
      --unix-socket "$socket" --request POST --header 'Content-Type: application/json' \
      --data-binary @- --connect-timeout 3 --max-time 10 \
      --max-filesize "$VX_HARBOR_API_MAX_OUTPUT" --write-out $'\n%{http_code}' \
      http://localhost/api/v2.0/robots 2>/dev/null <<<"$body")" || return 75
    (( ${#exchange} <= VX_HARBOR_API_MAX_OUTPUT + 4 )) || return 1
    status="${exchange##*$'\n'}"; response="${exchange%$'\n'*}"
    unset exchange body
    [[ "$status" == 201 ]] || { unset response; return 75; }
    _vx_harbor_api_robot_created_validate "$response" '' "$basename" || { unset response; return 1; }
    /usr/bin/jq -cS . <<<"$response"
    unset response
}

_vx_harbor_install_integration_probe() {
    local credential="$1" output="$2" status attempt
    for attempt in {1..12}; do
        status="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$credential" \
          --unix-socket "$(vx_harbor_socket_path)" --request GET --connect-timeout 3 --max-time 10 \
          --max-filesize 4096 --output "$output" --write-out '%{http_code}' \
          http://localhost/api/v2.0/health 2>/dev/null)" \
          && [[ "$status" == 200 ]] \
          && /usr/bin/jq -e '.status=="healthy"' "$output" >/dev/null \
          && return 0
        (( attempt == 12 )) || /usr/bin/sleep 1
    done
    return 1
}

_vx_harbor_install_bootstrap_retry() {
    local attempt
    for attempt in {1..12}; do
        _vx_harbor_install_bootstrap_call "$@" && return 0
        (( attempt == 12 )) || /usr/bin/sleep 1
    done
    return 75
}

_vx_harbor_install_bootstrap_system_robots() {
    local stage="$1" output="$2" page page_output next count
    page_output="${output}.page"; next="${output}.next"
    printf '[]\n' >"$output" || return 1
    for page in {1..10}; do
        _vx_harbor_install_bootstrap_retry "$stage" GET \
          "/api/v2.0/robots?q=Level%3Dsystem&page=$page&page_size=100" \
          '' "$page_output" 200 || return
        /usr/bin/jq -e 'type=="array" and length<=100 and ([.[]|has("secret")]|any|not)' \
          "$page_output" >/dev/null 2>&1 || return 1
        count="$(/usr/bin/jq -r length "$page_output")" || return 1
        /usr/bin/jq -s '.[0]+.[1]' "$output" "$page_output" >"$next" \
          && /usr/bin/mv -fT "$next" "$output" || return 1
        if (( count < 100 )); then
            /usr/bin/rm -f -- "$page_output"
            /usr/bin/jq -e 'length<=1000 and ([.[]|has("secret")]|any|not)' \
              "$output" >/dev/null 2>&1
            return
        fi
    done
    return 1
}

_vx_harbor_install_bootstrap_robot_find() {
    local stage="$1" marker="$2" output robots matches count
    [[ "$marker" =~ ^vesta-managed:integration:[a-z0-9][a-z0-9-]{0,63}:v(2|3):[a-f0-9]{32}$ ]] || return 1
    output="$stage/integration-robots.json"
    _vx_harbor_install_bootstrap_system_robots "$stage" "$output" || return
    robots="$(/usr/bin/jq -cS . "$output")" || return 1
    matches="$(/usr/bin/jq -c --arg marker "$marker" '[.[]|select(.description==$marker)]' <<<"$robots")" || return 1
    count="$(/usr/bin/jq -r length <<<"$matches")" || return 1
    (( count <= 1 )) || return 1
    (( count == 1 )) || return 4
    /usr/bin/jq -cS '.[0]' <<<"$matches"
}

_vx_harbor_install_bootstrap_robot_delete_identity() {
    local stage="$1" robot_id="$2" username="$3" marker="$4" response count
    [[ "$robot_id" =~ ^[1-9][0-9]*$ \
        && "$username" =~ ^[A-Za-z0-9][-A-Za-z0-9._+$]{0,255}$ \
        && ${#marker} -ge 1 && ${#marker} -le 160 ]] || return 1
    response="$stage/integration-delete.json"
    _vx_harbor_install_bootstrap_system_robots "$stage" "$response" || return 75
    count="$(/usr/bin/jq --argjson id "$robot_id" --arg username "$username" --arg marker "$marker" \
      '[.[]|select(.id==$id and .name==$username and .description==$marker)]|length' "$response")" || return 1
    (( count <= 1 )) || return 1
    (( count == 1 )) || return 0
    _vx_harbor_install_bootstrap_retry "$stage" GET "/api/v2.0/robots/$robot_id" '' "$response" 200 || return 75
    /usr/bin/jq -e --argjson id "$robot_id" --arg username "$username" --arg marker "$marker" \
      '.id==$id and .name==$username and .description==$marker and .level=="system" and (has("secret")|not)' \
      "$response" >/dev/null || return 1
    _vx_harbor_install_bootstrap_retry "$stage" DELETE "/api/v2.0/robots/$robot_id" '' "$response" 200,404 || return 75
    _vx_harbor_install_bootstrap_system_robots "$stage" "$response" || return 75
    count="$(/usr/bin/jq --argjson id "$robot_id" --arg marker "$marker" \
      '[.[]|select(.id==$id or .description==$marker)]|length' "$response")" || return 1
    (( count == 0 ))
}

_vx_harbor_install_integration_permissions() {
    /usr/bin/jq -cn '[
      {kind:"system",namespace:"/",access:[
        {resource:"project",action:"create"},
        {resource:"project",action:"list"},
        {resource:"quota",action:"read"},
        {resource:"quota",action:"update"},
        {resource:"system-volumes",action:"read"}
      ]},
      {kind:"project",namespace:"*",access:[
        {resource:"project",action:"read"},
        {resource:"project",action:"update"},
        {resource:"robot",action:"create"},
        {resource:"robot",action:"read"},
        {resource:"robot",action:"list"},
        {resource:"robot",action:"delete"},
        {resource:"repository",action:"read"},
        {resource:"repository",action:"list"},
        {resource:"repository",action:"pull"},
        {resource:"repository",action:"push"},
        {resource:"artifact",action:"read"}
      ]}
    ]'
}

_vx_harbor_install_integration_robot_validate() {
    local path="$1" marker="$2" permissions
    permissions="$(_vx_harbor_install_integration_permissions)" || return 1
    /usr/bin/jq -e --arg marker "$marker" --argjson permissions "$permissions" '
      .description==$marker and .disable==false and .duration==-1 and .expires_at==-1
      and .level=="system" and .permissions==$permissions and (has("secret")|not)
    ' "$path" >/dev/null 2>&1
}

_vx_harbor_install_active_username() {
    local credential="$1"
    _vx_harbor_api_credentials_validate "$credential" || return 1
    /usr/bin/awk -F'"' 'NR==3 {value=$2; sub(/:.*/,"",value); print value}' "$credential"
}

_vx_harbor_install_configuration_subset() {
    /usr/bin/jq -ce '
        def setting:
            if type == "object" and has("value") then .value else . end;
        {
            self_registration: (.self_registration | setting),
            project_creation_restriction: (.project_creation_restriction | setting)
        }
        | select(.self_registration | type == "boolean")
        | select(.project_creation_restriction | type == "string")
    '
}

_vx_harbor_install_integration_configuration_denied() {
    local credential="$1" output="$2" socket status
    _vx_harbor_api_credentials_validate "$credential" || return 1
    socket="$(_vx_harbor_api_socket)"; _vx_harbor_api_socket_validate "$socket" || return 1
    status="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$credential" \
      --unix-socket "$socket" --request GET --connect-timeout 3 --max-time 10 --max-filesize 4096 \
      --output "$output" --write-out '%{http_code}' \
      http://localhost/api/v2.0/configurations 2>/dev/null)" || return 75
    [[ "$status" == 403 ]] && /usr/bin/jq -e '.errors|type=="array"' "$output" >/dev/null
}

_vx_harbor_install_delegated_probe() {
    local stage="$1" credential="$2" path operation project project_json project_id marker basename created robot_id username secret robot_read response result=0 cleanup_result=0
    path="$(_vx_harbor_install_journal_path)"; vx_harbor_install_journal_validate "$path" || return 1
    operation="$(/usr/bin/jq -r .OPERATION_ID "$path")"; project="$(/usr/bin/jq -r .PROBE_PROJECT_NAME "$path")"
    response="$stage/integration-delegated.json"
    _vx_harbor_install_step integration-delegated-project
    _vx_harbor_api_json_call_with_credential "$credential" POST /api/v2.0/projects 201 empty \
      "$(/usr/bin/jq -cn --arg name "$project" '{project_name:$name,metadata:{public:"false"}}')" \
      >/dev/null || result=$?
    (( result != 0 )) || project_json="$(_vx_harbor_api_call_with_credential "$credential" GET "/api/v2.0/projects/$project" 200 'type=="object" and .metadata.public=="false"')" || result=$?
    if (( result == 0 )); then
        project_id="$(/usr/bin/jq -er .project_id <<<"$project_json")" || result=1
    fi
    if (( result == 0 )); then
        _vx_harbor_install_journal_update '.PROBE_PROJECT_ID=$id' --argjson id "$project_id" || result=1
    fi
    marker="vesta-managed:candidate:probe:$operation"; basename="probe-${operation:0:16}"
    if (( result == 0 )); then
        _vx_harbor_install_step integration-delegated-robot-create
        created="$(_vx_harbor_api_robot_create_secret_once_with_credential "$credential" "$project_id" "$project" "$basename" "$marker" pull)" || result=$?
    fi
    if (( result == 0 )); then
        robot_id="$(/usr/bin/jq -er .id <<<"$created")" || result=1
        username="$(/usr/bin/jq -er .name <<<"$created")" || result=1
        secret="$(/usr/bin/jq -er .secret <<<"$created")" || result=1
    fi
    if (( result == 0 )); then
        _vx_harbor_install_journal_update '.PROBE_ROBOT_ID=$id' --argjson id "$robot_id" || result=1
    fi
    if (( result == 0 )); then
        _vx_harbor_install_step integration-delegated-credential
        printf %s "$secret" | vx_harbor_api_credential_probe "$username" || result=$?
        unset secret created
    fi
    if (( result == 0 )); then
        _vx_harbor_install_step integration-delegated-robot-list
        _vx_harbor_api_project_robots_list_with_credential "$credential" "$project_id" >/dev/null || result=$?
    fi
    if (( result == 0 )); then
        _vx_harbor_install_step integration-delegated-robot-read
        robot_read="$(_vx_harbor_api_project_robot_get_with_credential "$credential" "$project_id" "$robot_id" "$marker")" || result=$?
    fi
    if (( result == 0 )); then
        _vx_harbor_install_step integration-delegated-configuration-denial
        _vx_harbor_install_integration_configuration_denied "$credential" "$response" || result=$?
    fi
    (( result != 0 )) || _vx_harbor_install_step integration-delegated-cleanup
    if [[ -n "${project_id:-}" ]]; then
        if [[ -z "${robot_id:-}" ]]; then
            if robot_read="$(_vx_harbor_api_project_robot_find_with_credential "$credential" "$project_id" "$marker")"; then
                robot_id="$(/usr/bin/jq -er .id <<<"$robot_read")" || cleanup_result=1
            else
                [[ $? == 4 ]] || cleanup_result=1
            fi
        fi
        if [[ -n "${robot_id:-}" ]]; then
            _vx_harbor_api_project_robot_delete_with_credential "$credential" "$project_id" "$robot_id" "$marker" \
                || cleanup_result=1
        fi
    fi
    _vx_harbor_install_bootstrap_retry "$stage" DELETE "/api/v2.0/projects/$project" '' "$response" 200,404 \
        || cleanup_result=1
    unset secret created
    if (( cleanup_result != 0 )); then
        _vx_harbor_install_step integration-delegated-cleanup
        _vx_harbor_install_journal_update '.PHASE="cleanup-pending"' || return 1
        return 75
    fi
    _vx_harbor_install_journal_update '.PROBE_PROJECT_ID=null|.PROBE_ROBOT_ID=null|.PHASE="candidate-probed"' || return 1
    (( result == 0 )) || return "$result"
}

_vx_harbor_install_external_cleanup() {
    local stage="$1" path journal phase prior response observed marker basename candidate candidate_id candidate_user probe_project found result
    path="$(_vx_harbor_install_journal_path)"; [[ -f "$path" ]] || return 0
    vx_harbor_install_journal_validate "$path" || return 1
    journal="$(/usr/bin/jq -cS . "$path")" || return 1
    phase="$(/usr/bin/jq -r .PHASE <<<"$journal")"
    [[ "$phase" != retire-prior ]] || return 1
    prior="$(/usr/bin/jq -c '.PRIOR_CONFIGURATION' <<<"$journal" | _vx_harbor_install_configuration_subset)" || return 1
    marker="$(/usr/bin/jq -r .CANDIDATE_MARKER <<<"$journal")"; basename="$(/usr/bin/jq -r .CANDIDATE_BASENAME <<<"$journal")"
    candidate_id="$(/usr/bin/jq -r '.CANDIDATE_ROBOT_ID // empty' <<<"$journal")"; candidate_user="$(/usr/bin/jq -r '.CANDIDATE_USERNAME // empty' <<<"$journal")"
    probe_project="$(/usr/bin/jq -r .PROBE_PROJECT_NAME <<<"$journal")"; response="$stage/integration-cleanup.json"
    _vx_harbor_install_bootstrap_retry "$stage" DELETE "/api/v2.0/projects/$probe_project" '' "$response" 200,404 || return 75
    if found="$(_vx_harbor_install_bootstrap_robot_find "$stage" "$marker")"; then
        candidate="$(/usr/bin/jq -er .id <<<"$found")" || return 1
        [[ -z "$candidate_id" || "$candidate" == "$candidate_id" ]] || return 1
        candidate_user="$(/usr/bin/jq -er .name <<<"$found")" || return 1
        [[ "$candidate_user" == *"$basename" ]] || return 1
        _vx_harbor_install_bootstrap_robot_delete_identity "$stage" "$candidate" "$candidate_user" "$marker" || return 75
    else
        result=$?; (( result == 4 )) || return "$result"
    fi
    _vx_harbor_install_bootstrap_retry "$stage" PUT /api/v2.0/configurations "$prior" "$response" 200 || return 75
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" 200 || return 75
    observed="$(_vx_harbor_install_configuration_subset <"$response")" || return 75
    [[ "$observed" == "$prior" ]] || return 75
    /usr/bin/rm -f -- "$(vx_harbor_root)/secrets/.integration.curl.candidate" "$path"
    _vx_harbor_fsync "$(vx_harbor_root)/operations"
}

_vx_harbor_install_integration_finalize() {
    local stage="$1" path phase prior_id prior_user prior_marker json
    path="$(_vx_harbor_install_journal_path)"; [[ -f "$path" ]] || return 0
    vx_harbor_install_journal_validate "$path" || return 1
    phase="$(/usr/bin/jq -r .PHASE "$path")"
    if [[ "$phase" == reused ]]; then
        /usr/bin/rm -f -- "$path"; _vx_harbor_fsync "$(dirname -- "$path")"; return
    fi
    [[ "$phase" == switched || "$phase" == retire-prior ]] || return 1
    if [[ "$phase" == switched ]]; then
        json="$(/usr/bin/jq -c '.PHASE="retire-prior"' "$path")" || return 1
        _vx_harbor_install_journal_write "$json" || return 1
    fi
    prior_id="$(/usr/bin/jq -r '.PRIOR_ROBOT_ID // empty' "$path")"
    prior_user="$(/usr/bin/jq -r '.PRIOR_USERNAME // empty' "$path")"
    prior_marker="$(/usr/bin/jq -r '.PRIOR_MARKER // empty' "$path")"
    if [[ -n "$prior_id" ]]; then
        _vx_harbor_install_bootstrap_robot_delete_identity "$stage" "$prior_id" "$prior_user" "$prior_marker" || return 75
    fi
    /usr/bin/rm -f -- "$path"
    _vx_harbor_fsync "$(dirname -- "$path")"
}

_vx_harbor_install_integration_configure() {
    local stage="$1" root path response config_body installation operation basename marker probe_project prior observed journal permissions robot_body created robot_id username secret candidate probe robots active_username prior_robot prior_id=null prior_user=null prior_marker=null exact_current=no phase
    root="$(vx_harbor_root)"; path="$(_vx_harbor_install_journal_path)"; response="$stage/integration-response.json"
    if [[ -f "$path" ]]; then
        vx_harbor_install_journal_validate "$path" || return 1
        phase="$(/usr/bin/jq -r .PHASE "$path")"
        if [[ "$phase" == retire-prior ]]; then _vx_harbor_install_integration_finalize "$stage" || return 75; else _vx_harbor_install_external_cleanup "$stage" || return 75; fi
    fi
    installation="$(/usr/bin/jq -er '.INSTALLATION_ID // "vesta-harbor" | select(type=="string" and length>0)' "$root/provider.json")" || return 1
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    basename="vesta-integration-${operation:0:16}"; marker="vesta-managed:integration:$installation:v${VX_HARBOR_INTEGRATION_PERMISSION_VERSION}:$operation"; probe_project="vx-install-probe-${operation:0:12}"
    _vx_harbor_install_step integration-bootstrap-read
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" 200 || return 75
    prior="$(_vx_harbor_install_configuration_subset <"$response")" || return 1
    _vx_harbor_install_bootstrap_system_robots "$stage" "$response" || return 75
    robots="$(/usr/bin/jq -cS . "$response")" || return 1
    if [[ -f "$root/secrets/integration.curl" ]]; then
        active_username="$(_vx_harbor_install_active_username "$root/secrets/integration.curl")" || return 1
        prior_robot="$(/usr/bin/jq -c --arg username "$active_username" '[.[]|select(.name==$username)]' <<<"$robots")" || return 1
        [[ "$(/usr/bin/jq -r length <<<"$prior_robot")" == 1 ]] || return 1
        prior_robot="$(/usr/bin/jq -c '.[0]' <<<"$prior_robot")"; prior_id="$(/usr/bin/jq -r .id <<<"$prior_robot")"; prior_user="$active_username"; prior_marker="$(/usr/bin/jq -r .description <<<"$prior_robot")"
        printf '%s\n' "$prior_robot" >"$response"
        if [[ "$prior_marker" =~ ^vesta-managed:integration:${installation}:v${VX_HARBOR_INTEGRATION_PERMISSION_VERSION}:[a-f0-9]{32}$ ]] \
            && _vx_harbor_install_integration_robot_validate "$response" "$prior_marker"; then exact_current=yes; fi
    fi
    journal="$(/usr/bin/jq -cn --arg operation "$operation" --argjson prior "$prior" \
      --argjson prior_id "$prior_id" --arg prior_user "$prior_user" --arg prior_marker "$prior_marker" \
      --arg basename "$basename" --arg marker "$marker" --arg probe "$probe_project" \
      --argjson version "$VX_HARBOR_INTEGRATION_PERMISSION_VERSION" \
      '{SCHEMA:1,OPERATION_ID:$operation,PHASE:"prepared",PRIOR_CONFIGURATION:$prior,
        PRIOR_ROBOT_ID:$prior_id,
        PRIOR_USERNAME:(if $prior_id==null then null else $prior_user end),
        PRIOR_MARKER:(if $prior_id==null then null else $prior_marker end),
        CANDIDATE_BASENAME:$basename,CANDIDATE_MARKER:$marker,CANDIDATE_ROBOT_ID:null,
        CANDIDATE_USERNAME:null,PERMISSION_VERSION:$version,PROBE_PROJECT_NAME:$probe,
        PROBE_PROJECT_ID:null,PROBE_ROBOT_ID:null}')" || return 1
    _vx_harbor_install_journal_write "$journal" || return 1
    _vx_harbor_install_step integration-configuration
    config_body='{"self_registration":false,"project_creation_restriction":"adminonly"}'
    _vx_harbor_install_bootstrap_retry "$stage" PUT /api/v2.0/configurations "$config_body" "$response" 200 || return 75
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" 200 || return 75
    observed="$(_vx_harbor_install_configuration_subset <"$response")" || return 1
    [[ "$observed" == "$config_body" ]] || return 1
    if [[ "$exact_current" == yes ]]; then
        probe="$stage/integration-probe.json"; _vx_harbor_install_integration_probe "$root/secrets/integration.curl" "$probe" || return 1
        journal="$(/usr/bin/jq -c '.PHASE="reused"' "$path")" || return 1
        _vx_harbor_install_journal_write "$journal"
        return
    fi
    _vx_harbor_install_step integration-candidate-create
    permissions="$(_vx_harbor_install_integration_permissions)" || return 1
    robot_body="$(/usr/bin/jq -cn --arg name "$basename" --arg marker "$marker" --argjson permissions "$permissions" \
      '{name:$name,description:$marker,disable:false,duration:-1,level:"system",permissions:$permissions}')" || return 1
    /usr/bin/jq -e 'has("secret")|not' <<<"$robot_body" >/dev/null || return 1
    created="$(_vx_harbor_install_bootstrap_robot_create_secret_once "$stage" "$robot_body")" || return 75
    robot_id="$(/usr/bin/jq -er .id <<<"$created")"; username="$(/usr/bin/jq -er .name <<<"$created")"; secret="$(/usr/bin/jq -er .secret <<<"$created")" || return 1
    journal="$(/usr/bin/jq -c --argjson id "$robot_id" --arg user "$username" '.PHASE="candidate-created"|.CANDIDATE_ROBOT_ID=$id|.CANDIDATE_USERNAME=$user' "$path")" || return 1
    _vx_harbor_install_journal_write "$journal" || return 1
    candidate="$root/secrets/.integration.curl.candidate"
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || return 1
    (umask 077; printf 'silent\nshow-error\nuser = "%s:%s"\n' "$username" "$secret" >"$candidate") || return 1
    unset secret created robot_body
    _vx_harbor_secure_file_set "$candidate" 0600 || return 1
    _vx_harbor_api_credentials_validate "$candidate" || return 1
    _vx_harbor_install_step integration-candidate-validate
    _vx_harbor_install_bootstrap_retry "$stage" GET "/api/v2.0/robots/$robot_id" '' "$response" 200 || return 75
    _vx_harbor_install_integration_robot_validate "$response" "$marker" || return 1
    _vx_harbor_install_step integration-candidate-auth
    probe="$stage/integration-probe.json"; _vx_harbor_install_integration_probe "$candidate" "$probe" || return 1
    _vx_harbor_install_step integration-delegated-probe
    _vx_harbor_install_delegated_probe "$stage" "$candidate" || return 1
    _vx_harbor_install_step integration-switch
    /usr/bin/mv -fT "$candidate" "$root/secrets/integration.curl" || return 1
    vx_harbor_secure_regular_file "$root/secrets/integration.curl" 0600 || return 1
    _vx_harbor_fsync "$root/secrets" || return 1
    journal="$(/usr/bin/jq -c '.PHASE="switched"' "$path")" || return 1
    _vx_harbor_install_journal_write "$journal"
}

_vx_harbor_install_restore_file() {
    local target="$1" backup="$2" existed="$3"
    if [[ "$existed" == yes ]]; then /usr/bin/cp -a -- "$backup" "$target"; else /usr/bin/rm -f -- "$target"; fi
}

vx_harbor_install() {
    local root data_root stage manifest compose ingress unit_target ingress_target nginx_main rollback provider_next candidate_main activation_main rollback_status finalize_status
    local unit_existed=no ingress_existed=no integration_existed=no current_existed=no previous_existed=no previous_rotated=no candidate_activated=no service_active=no service_enabled=no data_root_existed=no committed=no
    local failure_reason
    VX_HARBOR_INSTALL_ACTIVE_STEP=initialization
    root="$(vx_harbor_root)" || return 1
    vx_harbor_provider_prepare || return 1
    vx_harbor_provider_lock_acquire exclusive || return 1
    data_root="$(vx_harbor_data_root)" || { vx_harbor_provider_lock_release; return 1; }
    [[ "$data_root" == /* && "$data_root" != / && "$(dirname "$data_root")" != / ]] \
        || { vx_harbor_provider_lock_release; return 1; }
    if [[ -e "$data_root" || -L "$data_root" ]]; then
        [[ -d "$data_root" && ! -L "$data_root" \
            && "$(/usr/bin/stat -c '%u:%g:%a' "$data_root")" \
              == "$(_vx_harbor_authority_uid):$(_vx_harbor_authority_gid):700" ]] \
            || { vx_harbor_provider_lock_release; return 1; }
        data_root_existed=yes
    fi
    stage="$(/usr/bin/mktemp -d "$root/release/.install.XXXXXX")" || { vx_harbor_provider_lock_release; return 1; }
    rollback="$(/usr/bin/mktemp -d "$root/.install-rollback.XXXXXX")" || { vx_harbor_provider_lock_release; return 1; }
    unit_target="$(vx_harbor_systemd_target)"; ingress_target="$(vx_harbor_ingress_target)"
    nginx_main="$(vx_harbor_nginx_main)"
    [[ ! -L "$unit_target" && ! -L "$ingress_target" \
        && -d "$(dirname "$unit_target")" && ! -L "$(dirname "$unit_target")" \
        && -d "$(dirname "$ingress_target")" && ! -L "$(dirname "$ingress_target")" ]] \
        || { /usr/bin/rm -rf -- "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
    if [[ -e "$unit_target" ]]; then
        /usr/bin/cp -a "$unit_target" "$rollback/unit" || { /usr/bin/rm -rf "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
        unit_existed=yes
    fi
    if [[ -e "$ingress_target" ]]; then
        /usr/bin/cp -a "$ingress_target" "$rollback/ingress" || { /usr/bin/rm -rf "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
        ingress_existed=yes
    fi
    /usr/bin/cp -a "$nginx_main" "$rollback/nginx-main" || { /usr/bin/rm -rf "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
    /usr/bin/cp -a "$root/provider.json" "$rollback/provider.json" || { /usr/bin/rm -rf "$stage" "$rollback"; vx_harbor_provider_lock_release; return 1; }
    if [[ -e "$root/secrets/integration.curl" ]]; then
        vx_harbor_secure_regular_file "$root/secrets/integration.curl" 0600 || return 1
        /usr/bin/cp -a "$root/secrets/integration.curl" "$rollback/integration.curl" || return 1
        integration_existed=yes
    fi
    [[ -d "$root/release/current" ]] && current_existed=yes
    [[ -d "$root/release/previous" ]] && previous_existed=yes
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-active vesta-harbor.service >/dev/null 2>&1 && service_active=yes || :
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-enabled vesta-harbor.service >/dev/null 2>&1 && service_enabled=yes || :
    _vx_harbor_install_rollback() {
        local data_cleanup_status=0
        [[ "$committed" == yes ]] && return 0
        _vx_harbor_install_external_cleanup "$stage" || return 75
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service >/dev/null 2>&1 || :
        if [[ "$candidate_activated" == yes && -f "$stage/docker-compose.yml" ]]; then
            _vx_harbor_docker_bounded 120 compose --project-name vesta-harbor \
                --file "$stage/docker-compose.yml" down --remove-orphans \
                >/dev/null 2>&1 || :
            local socket
            socket="$(vx_harbor_socket_path)"
            if [[ -e "$socket" || -L "$socket" ]]; then
                if [[ -S "$socket" && ! -L "$socket" ]]; then
                    /usr/bin/rm -f -- "$socket" || data_cleanup_status=75
                else
                    data_cleanup_status=75
                fi
            fi
        fi
        if [[ "$data_root_existed" == no && ( -e "$data_root" || -L "$data_root" ) ]]; then
            if [[ -d "$data_root" && ! -L "$data_root" ]]; then
                /usr/bin/rm -rf --one-file-system -- "$data_root" || data_cleanup_status=75
            else
                data_cleanup_status=75
            fi
        fi
        _vx_harbor_install_restore_file "$unit_target" "$rollback/unit" "$unit_existed" || :
        _vx_harbor_install_restore_file "$ingress_target" "$rollback/ingress" "$ingress_existed" || :
        /usr/bin/cp -a -- "$rollback/nginx-main" "$nginx_main" || :
        /usr/bin/cp -a -- "$rollback/provider.json" "$root/provider.json" || :
        _vx_harbor_install_restore_file "$root/secrets/integration.curl" "$rollback/integration.curl" "$integration_existed" || :
        /usr/bin/rm -f -- "$root/secrets/.integration.curl.candidate"
        if [[ "$candidate_activated" == yes ]]; then
            /usr/bin/rm -rf -- "$root/release/current"
            if [[ "$current_existed" == yes ]]; then
                if [[ "$previous_rotated" == yes && -d "$root/release/previous" ]]; then
                    /usr/bin/mv "$root/release/previous" "$root/release/current" || :
                elif [[ -d "$root/release/.prior-current" ]]; then
                    /usr/bin/mv "$root/release/.prior-current" "$root/release/current" || :
                fi
            fi
        fi
        if [[ "$previous_rotated" == yes ]]; then
            [[ "$previous_existed" == yes && -d "$rollback/previous" ]] && /usr/bin/mv "$rollback/previous" "$root/release/previous" || :
        fi
        if [[ "$candidate_activated" != yes \
            && "$stage" == "$root"/release/.install.* ]]; then
            /usr/bin/rm -rf -- "$stage"
        fi
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" daemon-reload >/dev/null 2>&1 || :
        [[ "$service_enabled" == yes ]] && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" enable vesta-harbor.service >/dev/null 2>&1 || "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" disable vesta-harbor.service >/dev/null 2>&1 || :
        [[ "$service_active" == yes ]] && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service >/dev/null 2>&1 || :
        vx_harbor_panel_nginx_test "$nginx_main" >/dev/null 2>&1 \
            && vx_harbor_panel_nginx_reload >/dev/null 2>&1 || :
        return "$data_cleanup_status"
    }
    trap '_vx_harbor_install_rollback; vx_harbor_provider_lock_release 2>/dev/null || :; exit 1' HUP INT TERM
    _vx_harbor_install_apply() {
        _vx_harbor_install_step prerequisite
        _vx_harbor_install_requirements || return 1
        _vx_harbor_install_phase prerequisite || return 1
        _vx_harbor_install_step release
        vx_harbor_release_stage "$stage" || return 1
        _vx_harbor_install_phase release || return 1
        manifest="$(vx_harbor_release_manifest)"; compose="$stage/docker-compose.yml"; ingress="$stage/harbor-registry.conf"
        candidate_main="$stage/nginx.candidate.conf"; activation_main="$stage/nginx.activation.conf"; provider_next="$stage/provider.next.json"
        _vx_harbor_install_step generation
        _vx_harbor_install_generate "$stage" "$manifest" || return 1
        vx_harbor_ingress_render "$ingress" "$candidate_main" "$activation_main" || return 1
        _vx_harbor_install_phase generation || return 1
        if [[ "$current_existed" == yes ]]; then /usr/bin/mv "$root/release/current" "$root/release/.prior-current" || return 1; fi
        /usr/bin/mv "$stage" "$root/release/current" || return 1
        candidate_activated=yes
        stage="$root/release/current"
        ingress="$stage/harbor-registry.conf"
        candidate_main="$stage/nginx.candidate.conf"; activation_main="$stage/nginx.activation.conf"; provider_next="$stage/provider.next.json"
        /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$VESTA/install/harbor/vesta-harbor.service" "$unit_target" || return 1
        _vx_harbor_install_step compose
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" daemon-reload || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" enable vesta-harbor.service || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service || return 1
        _vx_harbor_install_phase compose || return 1
        _vx_harbor_install_step migration
        _vx_harbor_install_migration_check "$stage/docker-compose.yml" || return 1
        _vx_harbor_install_phase migration || return 1
        _vx_harbor_install_step socket
        vx_harbor_socket_validate || return 1
        _vx_harbor_install_phase socket || return 1
        _vx_harbor_install_step health
        _vx_harbor_install_health_check || return 1
        _vx_harbor_install_phase health || return 1
        _vx_harbor_install_step integration
        _vx_harbor_install_integration_configure "$stage" || return 1
        _vx_harbor_install_phase integration || return 1
        _vx_harbor_install_step ingress
        vx_harbor_ingress_activate "$ingress" "$candidate_main" "$activation_main" || return 1
        _vx_harbor_install_phase ingress || return 1
        _vx_harbor_install_step provider-render
        /usr/bin/jq --arg origin "$(vx_harbor_origin_json | /usr/bin/jq -r '.ORIGIN')" \
          --arg hash "$(/usr/bin/sha256sum "$manifest" | /usr/bin/awk '{print $1}')" \
          '.MODE="managed" | .RUNNING_VERSION="v2.15.0" | .PINNED_VERSION="v2.15.0" | .ORIGIN=$origin | .RELEASE_MANIFEST_SHA256=$hash | .INSTALLATION_ID=(.INSTALLATION_ID // "vesta-harbor")' \
          "$root/provider.json" >"$provider_next" || return 1
        _vx_harbor_install_phase provider_render || return 1
        _vx_harbor_install_step release-rotation
        [[ "$previous_existed" == yes ]] && /usr/bin/mv "$root/release/previous" "$rollback/previous"
        [[ -d "$root/release/.prior-current" ]] && /usr/bin/mv "$root/release/.prior-current" "$root/release/previous"
        previous_rotated=yes
        _vx_harbor_install_phase release_rotation || return 1
        _vx_harbor_install_step provider-write
        vx_harbor_json_write_atomic "$root/provider.json" "$provider_next" || return 1
        _vx_harbor_install_phase provider_write || return 1
        _vx_harbor_install_step final-cleanup
        _vx_harbor_install_phase final_cleanup || return 1
    }
    if ! _vx_harbor_install_apply; then
        rollback_status=0; _vx_harbor_install_rollback || rollback_status=$?
        trap - HUP INT TERM
        (( rollback_status != 0 )) || /usr/bin/rm -rf -- "$rollback"
        vx_harbor_provider_lock_release
        failure_reason="transaction-rolled-back-at-${VX_HARBOR_INSTALL_ACTIVE_STEP}"
        unset VX_HARBOR_INSTALL_ACTIVE_STEP
        if (( rollback_status != 0 )); then
            vx_harbor_audit system provider-install failed cleanup-pending || return 1
            return "$rollback_status"
        fi
        vx_harbor_audit system provider-install failed "$failure_reason" || return 1
        return 1
    fi
    committed=yes
    unset VX_HARBOR_INSTALL_ACTIVE_STEP
    trap - HUP INT TERM
    /usr/bin/rm -rf -- "$rollback"
    finalize_status=0
    _vx_harbor_install_integration_finalize "$stage" || finalize_status=$?
    vx_harbor_provider_lock_release
    if (( finalize_status != 0 )); then
        vx_harbor_audit system provider-install failed cleanup-pending || return 1
        return "$finalize_status"
    fi
    vx_harbor_audit system provider-install succeeded managed || return 1
}
