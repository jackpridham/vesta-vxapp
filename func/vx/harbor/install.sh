#!/usr/bin/env bash

_vx_harbor_install_requirements() {
    local command available
    _vx_harbor_require_root || return 1
    for command in jq python3 sha256sum tar curl cosign docker systemctl nginx openssl; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
    available="$(/usr/bin/df -Pk "$(vx_harbor_root)" | /usr/bin/awk 'NR==2 {print $4}')" || return 1
    [[ "$available" =~ ^[0-9]+$ ]] && (( available >= ${VX_HARBOR_MIN_FREE_KB:-10485760} ))
}

_vx_harbor_install_phase() { :; }

_vx_harbor_docker() { /usr/bin/docker "$@"; }
_vx_harbor_docker_bounded() { local seconds="$1"; shift; /usr/bin/timeout "$seconds" /usr/bin/docker "$@"; }

_vx_harbor_install_secret() {
    local path="$1"
    /usr/bin/openssl rand -base64 36 >"$path" && _vx_harbor_secure_file_set "$path" 0600
}

_vx_harbor_install_harbor_yml() {
    local stage origin_json secrets template
    stage="$1"; origin_json="$2"
    secrets="$stage/secrets"; template="$stage/extracted/harbor/harbor.yml.tmpl"
    /usr/bin/mkdir -m 0700 "$secrets" || return 1
    _vx_harbor_install_secret "$secrets/admin" || return 1
    _vx_harbor_install_secret "$secrets/database" || return 1
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
    /usr/bin/python3 - "$stage/docker-compose.yml" "$stage/common/config/nginx/nginx.conf" "$manifest" "$ingress_gid" <<'PY'
import json,pathlib,re,sys
compose_path,nginx_path,manifest_path=map(pathlib.Path,sys.argv[1:4])
ingress_gid=sys.argv[4]
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
      - SETGID
      - SETUID
    security_opt:
      - no-new-privileges:true
'''
block=block.replace(upstream_hardening, managed_hardening, 1)
block=block.replace('  proxy:\n', f'''  proxy:
    user: "0:{ingress_gid}"
    command: ["/bin/sh", "-c", "umask 0117; exec nginx -g 'daemon off;'"]
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
PY
    _vx_harbor_secure_file_set "$stage/docker-compose.yml" 0600 || return 1
    _vx_harbor_secure_file_set "$stage/common/config/nginx/nginx.conf" 0644 || return 1
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
        and (.[] | keys == ["Config", "Layers", "RepoTags"])
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
    local stage="$1" method="$2" path="$3" body="${4-}" output="$5"
    local config status admin socket
    admin="$stage/secrets/admin"; socket="$(vx_harbor_socket_path)"
    vx_harbor_secure_regular_file "$admin" 0600 || return 1
    config="$stage/secrets/bootstrap.curl"
    { printf '%s\n' silent show-error; printf 'user = "admin:'; /usr/bin/tr -d '\n' <"$admin"; printf '"\n'; } >"$config" || return 1
    _vx_harbor_secure_file_set "$config" 0600 || return 1
    if [[ -n "$body" ]]; then
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
    [[ "$status" == 200 || "$status" == 201 ]]
}

_vx_harbor_install_integration_probe() {
    local credential="$1" output="$2" status
    status="$(/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/curl --config "$credential" \
      --unix-socket "$(vx_harbor_socket_path)" --request GET --connect-timeout 3 --max-time 10 \
      --max-filesize 4096 --output "$output" --write-out '%{http_code}' \
      http://localhost/api/v2.0/health 2>/dev/null)" || return 1
    [[ "$status" == 200 ]] && /usr/bin/jq -e '.status=="healthy"' "$output" >/dev/null
}

_vx_harbor_install_journal_path() { printf '%s/operations/provider-install.json\n' "$(vx_harbor_root)"; }

_vx_harbor_install_journal_write() {
    local json="$1" path source
    path="$(_vx_harbor_install_journal_path)"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/operations/.provider-install.XXXXXX")" || return 1
    printf '%s\n' "$json" >"$source" && vx_harbor_json_write_atomic "$path" "$source"
    local result=$?; /usr/bin/rm -f "$source"; return "$result"
}

_vx_harbor_install_bootstrap_retry() {
    local attempt
    for attempt in 1 2 3; do _vx_harbor_install_bootstrap_call "$@" && return 0; done
    return 75
}

_vx_harbor_install_external_cleanup() {
    local stage="$1" path journal prior candidate response body
    path="$(_vx_harbor_install_journal_path)"; [[ -f "$path" ]] || return 0
    journal="$(/usr/bin/jq -cS . "$path")" || return 1
    prior="$(/usr/bin/jq -c '.PRIOR_CONFIGURATION' <<<"$journal")" || return 1
    candidate="$(/usr/bin/jq -r '.CANDIDATE_ROBOT_ID // empty' <<<"$journal")" || return 1
    response="$stage/integration-cleanup.json"
    if [[ -n "$candidate" ]]; then
        body='{"disabled":true}'
        _vx_harbor_install_bootstrap_retry "$stage" PUT "/api/v2.0/robots/$candidate" "$body" "$response" || return 75
        _vx_harbor_install_bootstrap_retry "$stage" DELETE "/api/v2.0/robots/$candidate" '' "$response" || return 75
    fi
    _vx_harbor_install_bootstrap_retry "$stage" PUT /api/v2.0/configurations "$prior" "$response" || return 75
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" || return 75
    /usr/bin/jq -e --argjson prior "$prior" '.==$prior' "$response" >/dev/null || return 75
    /usr/bin/rm -f -- "$(vx_harbor_root)/secrets/.integration.curl.candidate" "$path"
    _vx_harbor_fsync "$(vx_harbor_root)/operations"
}

_vx_harbor_install_integration_configure() {
    local stage="$1" root response config_body secret username robot_body candidate probe robots existing installation operation journal robot_id prior
    root="$(vx_harbor_root)"; response="$stage/integration-response.json"
    _vx_harbor_install_external_cleanup "$stage" || return 75
    installation="$(/usr/bin/jq -r '.INSTALLATION_ID // "vesta-harbor"' "$root/provider.json")"
    operation="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" || return 75
    /usr/bin/jq -e 'type=="object"' "$response" >/dev/null || return 1
    prior="$(/usr/bin/jq -cS . "$response")"
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/robots '' "$response" || return 75
    robots="$(/usr/bin/jq -cS 'map(select(.name=="vesta-integration"))' "$response")" || return 1
    (( $(/usr/bin/jq 'length' <<<"$robots") <= 1 )) || return 1
    existing="$(/usr/bin/jq -c '.[0] // null' <<<"$robots")"
    if [[ "$existing" != null ]] && ! /usr/bin/jq -e --arg marker "vesta-managed:$installation" '.description==$marker' <<<"$existing" >/dev/null; then return 1; fi
    journal="$(/usr/bin/jq -cn --arg operation "$operation" --argjson prior "$prior" --argjson existing "$existing" '{SCHEMA:1,OPERATION_ID:$operation,PHASE:"prepared",PRIOR_CONFIGURATION:$prior,PRIOR_ROBOT:$existing,CANDIDATE_ROBOT_ID:null}')" || return 1
    _vx_harbor_install_journal_write "$journal" || return 1
    config_body='{"self_registration":false,"project_creation_restriction":"adminonly"}'
    _vx_harbor_install_bootstrap_retry "$stage" PUT /api/v2.0/configurations "$config_body" "$response" || return 75
    _vx_harbor_install_bootstrap_retry "$stage" GET /api/v2.0/configurations '' "$response" || return 75
    /usr/bin/jq -e '.self_registration==false and .project_creation_restriction=="adminonly"' "$response" >/dev/null || return 1
    if [[ "$existing" != null && -f "$root/secrets/integration.curl" ]]; then
        robot_id="$(/usr/bin/jq -r .id <<<"$existing")"; candidate="$root/secrets/integration.curl"
    else
    secret="$(/usr/bin/od -An -N36 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')" || return 1
    username=vesta-integration
    robot_body="$(/usr/bin/jq -cn --arg name "$username" --arg secret "$secret" --arg marker "vesta-managed:$installation" \
      '{name:$name,description:$marker,secret:$secret,level:"system",permissions:[{kind:"system",namespace:"/",access:[{resource:"project",action:"create"},{resource:"project",action:"list"},{resource:"project",action:"update"},{resource:"quota",action:"read"},{resource:"quota",action:"update"},{resource:"robot",action:"create"},{resource:"robot",action:"read"},{resource:"robot",action:"update"},{resource:"robot",action:"delete"},{resource:"system-volumes",action:"read"}]}]}')" || return 1
    _vx_harbor_install_bootstrap_retry "$stage" POST /api/v2.0/robots "$robot_body" "$response" || return 75
    robot_id="$(/usr/bin/jq -er '.id|select(type=="number" and .>0)' "$response")" || return 1
    journal="$(/usr/bin/jq -c --argjson id "$robot_id" '.PHASE="candidate-created"|.CANDIDATE_ROBOT_ID=$id' <<<"$journal")"; _vx_harbor_install_journal_write "$journal" || return 1
    candidate="$root/secrets/.integration.curl.candidate"
    { printf '%s\n' silent show-error; printf 'user = "%s:%s"\n' "$username" "$secret"; } >"$candidate" || return 1
    unset secret robot_body
    _vx_harbor_secure_file_set "$candidate" 0600 || return 1
    _vx_harbor_api_credentials_validate "$candidate" || return 1
    fi
    _vx_harbor_install_bootstrap_retry "$stage" GET "/api/v2.0/robots/$robot_id" '' "$response" || return 75
    /usr/bin/jq -e --arg marker "vesta-managed:$installation" '.name=="vesta-integration" and .disabled==false and .description==$marker and .level=="system" and ([.permissions[].access[]|.resource+":"+.action]|sort)==(["project:create","project:list","project:update","quota:read","quota:update","robot:create","robot:delete","robot:read","robot:update","system-volumes:read"]|sort)' "$response" >/dev/null || return 1
    probe="$stage/integration-probe.json"
    _vx_harbor_install_integration_probe "$candidate" "$probe" || return 1
    [[ "$candidate" == "$root/secrets/integration.curl" ]] || /usr/bin/mv -fT "$candidate" "$root/secrets/integration.curl" || return 1
    vx_harbor_secure_regular_file "$root/secrets/integration.curl" 0600
}

_vx_harbor_install_restore_file() {
    local target="$1" backup="$2" existed="$3"
    if [[ "$existed" == yes ]]; then /usr/bin/cp -a -- "$backup" "$target"; else /usr/bin/rm -f -- "$target"; fi
}

vx_harbor_install() {
    local root stage manifest compose ingress unit_target ingress_target nginx_main rollback provider_next candidate_main activation_main rollback_status
    local unit_existed=no ingress_existed=no integration_existed=no current_existed=no previous_existed=no previous_rotated=no candidate_activated=no service_active=no service_enabled=no committed=no
    root="$(vx_harbor_root)" || return 1
    vx_harbor_provider_prepare || return 1
    vx_harbor_provider_lock_acquire exclusive || return 1
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
        [[ "$committed" == yes ]] && return 0
        _vx_harbor_install_external_cleanup "$stage" || return 75
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service >/dev/null 2>&1 || :
        if [[ "$candidate_activated" == yes && -f "$stage/docker-compose.yml" ]]; then
            _vx_harbor_docker_bounded 120 compose --project-name vesta-harbor \
                --file "$stage/docker-compose.yml" down --remove-orphans \
                >/dev/null 2>&1 || :
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
        "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t >/dev/null 2>&1 && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service >/dev/null 2>&1 || :
    }
    trap '_vx_harbor_install_rollback; vx_harbor_provider_lock_release 2>/dev/null || :; exit 1' HUP INT TERM
    _vx_harbor_install_apply() {
        _vx_harbor_install_requirements || return 1
        _vx_harbor_install_phase prerequisite || return 1
        vx_harbor_release_stage "$stage" || return 1
        _vx_harbor_install_phase release || return 1
        manifest="$(vx_harbor_release_manifest)"; compose="$stage/docker-compose.yml"; ingress="$stage/harbor-registry.conf"
        candidate_main="$stage/nginx.candidate.conf"; activation_main="$stage/nginx.activation.conf"; provider_next="$stage/provider.next.json"
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
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" daemon-reload || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" enable vesta-harbor.service || return 1
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" start vesta-harbor.service || return 1
        _vx_harbor_install_phase compose || return 1
        _vx_harbor_install_migration_check "$stage/docker-compose.yml" || return 1
        _vx_harbor_install_phase migration || return 1
        vx_harbor_socket_validate || return 1
        _vx_harbor_install_phase socket || return 1
        _vx_harbor_install_health_check || return 1
        _vx_harbor_install_phase health || return 1
        _vx_harbor_install_integration_configure "$stage" || return 1
        _vx_harbor_install_phase integration || return 1
        vx_harbor_ingress_activate "$ingress" "$candidate_main" "$activation_main" || return 1
        _vx_harbor_install_phase ingress || return 1
        /usr/bin/jq --arg origin "$(vx_harbor_origin_json | /usr/bin/jq -r '.ORIGIN')" \
          --arg hash "$(/usr/bin/sha256sum "$manifest" | /usr/bin/awk '{print $1}')" \
          '.MODE="managed" | .RUNNING_VERSION="v2.15.0" | .PINNED_VERSION="v2.15.0" | .ORIGIN=$origin | .RELEASE_MANIFEST_SHA256=$hash | .INSTALLATION_ID=(.INSTALLATION_ID // "vesta-harbor")' \
          "$root/provider.json" >"$provider_next" || return 1
        _vx_harbor_install_phase provider_render || return 1
        [[ "$previous_existed" == yes ]] && /usr/bin/mv "$root/release/previous" "$rollback/previous"
        [[ -d "$root/release/.prior-current" ]] && /usr/bin/mv "$root/release/.prior-current" "$root/release/previous"
        previous_rotated=yes
        _vx_harbor_install_phase release_rotation || return 1
        vx_harbor_json_write_atomic "$root/provider.json" "$provider_next" || return 1
        _vx_harbor_install_phase provider_write || return 1
        _vx_harbor_install_phase final_cleanup || return 1
    }
    if ! _vx_harbor_install_apply; then
        rollback_status=0; _vx_harbor_install_rollback || rollback_status=$?
        trap - HUP INT TERM
        (( rollback_status != 0 )) || /usr/bin/rm -rf -- "$rollback"
        vx_harbor_provider_lock_release
        if (( rollback_status != 0 )); then
            vx_harbor_audit system provider-install failed cleanup-pending || return 1
            return "$rollback_status"
        fi
        vx_harbor_audit system provider-install failed transaction-rolled-back || return 1
        return 1
    fi
    committed=yes
    /usr/bin/rm -f -- "$(_vx_harbor_install_journal_path)"
    _vx_harbor_fsync "$root/operations" || return 1
    trap - HUP INT TERM
    /usr/bin/rm -rf -- "$rollback"
    vx_harbor_provider_lock_release
    vx_harbor_audit system provider-install succeeded managed || return 1
}
