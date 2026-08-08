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
    local stage="$1" origin_json="$2" secrets="$stage/secrets" template="$stage/extracted/harbor/harbor.yml.tmpl"
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
text=re.sub(r'^(  location:).*$' , r'\1 /var/lib/vesta-harbor/log', text, count=1, flags=re.M)
metric='# metric:\n#   enabled: false\n#   port: 9090\n#   path: /metrics'
if metric not in text: raise SystemExit(1)
text=text.replace(metric, 'metric:\n  enabled: true\n  port: 9090\n  path: /metrics', 1)
pathlib.Path(dst).write_text(text)
PY
    _vx_harbor_secure_file_set "$stage/harbor.yml" 0600
}

_vx_harbor_install_transform_generated() {
    local stage="$1" manifest="$2"
    /usr/bin/python3 - "$stage/docker-compose.yml" "$stage/common/config/nginx/nginx.conf" "$manifest" <<'PY'
import json,pathlib,re,sys
compose_path,nginx_path,manifest_path=map(pathlib.Path,sys.argv[1:])
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
block=block.replace('    volumes:\n', '    volumes:\n      - /run/vesta-harbor:/run/vesta-harbor\n', 1)
text='name: vesta-harbor\n'+text[:proxy.start(1)]+block+text[proxy.end(1):]
compose_path.write_text(text)
nginx=nginx_path.read_text()
nginx,count=re.subn(r'listen\s+8080\s*;', 'listen unix:/run/vesta-harbor/proxy.sock;', nginx, count=1)
if count != 1: raise SystemExit(1)
nginx_path.write_text(nginx)
PY
    _vx_harbor_secure_file_set "$stage/docker-compose.yml" 0600 || return 1
    _vx_harbor_secure_file_set "$stage/common/config/nginx/nginx.conf" 0600 || return 1
    vx_harbor_release_images_validate "$manifest" "$stage/docker-compose.yml"
}

_vx_harbor_install_generate() {
    local stage="$1" manifest="$2" origin prepare_id expected_config
    origin="$(vx_harbor_origin_json)" || return 1
    _vx_harbor_install_harbor_yml "$stage" "$origin" || return 1
    _vx_harbor_docker load --input "$stage/extracted/harbor/harbor.v2.15.0.tar.gz" >/dev/null || return 1
    prepare_id="$(_vx_harbor_docker image inspect --format '{{.Id}}' goharbor/prepare:v2.15.0)" || return 1
    expected_config="$(/usr/bin/jq -r '.generator_image.offline_config_digest' "$VESTA/install/harbor/release-provenance.json")" || return 1
    [[ "$prepare_id" == "$expected_config" ]] || return 1
    /usr/bin/mkdir -p "$stage/common/config" || return 1
    _vx_harbor_docker run --rm --network none --cap-drop ALL \
      --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER --cap-add SETGID --cap-add SETUID \
      --volume "$stage/harbor.yml:/input/harbor.yml:ro" \
      --volume "/var/lib/vesta-harbor:/data" \
      --volume "$stage:/compose_location" \
      --volume "$stage/common/config:/config" \
      "$prepare_id" prepare --conf /input/harbor.yml >/dev/null || return 1
    _vx_harbor_install_transform_generated "$stage" "$manifest"
}

_vx_harbor_install_migration_check() {
    local compose="$1"
    _vx_harbor_docker_bounded 30 compose --project-name vesta-harbor --file "$compose" exec -T postgresql pg_isready -U postgres >/dev/null 2>&1
}

_vx_harbor_install_health_check() {
    local response
    response="$(/usr/bin/timeout 30 /usr/bin/curl --fail --silent --show-error --max-time 20 \
      --unix-socket "$(vx_harbor_socket_path)" http://localhost/api/v2.0/health)" || return 1
    /usr/bin/jq -e '.status == "healthy" and (.components | type == "array")' <<<"$response" >/dev/null 2>&1
}

_vx_harbor_install_restore_file() {
    local target="$1" backup="$2" existed="$3"
    if [[ "$existed" == yes ]]; then /usr/bin/cp -a -- "$backup" "$target"; else /usr/bin/rm -f -- "$target"; fi
}

vx_harbor_install() {
    local root stage manifest compose ingress unit_target ingress_target nginx_main rollback provider_next candidate_main activation_main
    local unit_existed=no ingress_existed=no current_existed=no previous_existed=no previous_rotated=no candidate_activated=no service_active=no service_enabled=no committed=no
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
    [[ -d "$root/release/current" ]] && current_existed=yes
    [[ -d "$root/release/previous" ]] && previous_existed=yes
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-active vesta-harbor.service >/dev/null 2>&1 && service_active=yes || :
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" is-enabled vesta-harbor.service >/dev/null 2>&1 && service_enabled=yes || :
    _vx_harbor_install_rollback() {
        [[ "$committed" == yes ]] && return 0
        "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" stop vesta-harbor.service >/dev/null 2>&1 || :
        _vx_harbor_install_restore_file "$unit_target" "$rollback/unit" "$unit_existed" || :
        _vx_harbor_install_restore_file "$ingress_target" "$rollback/ingress" "$ingress_existed" || :
        /usr/bin/cp -a -- "$rollback/nginx-main" "$nginx_main" || :
        /usr/bin/cp -a -- "$rollback/provider.json" "$root/provider.json" || :
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
        _vx_harbor_install_rollback
        trap - HUP INT TERM
        /usr/bin/rm -rf -- "$rollback"
        vx_harbor_provider_lock_release
        return 1
    fi
    committed=yes
    trap - HUP INT TERM
    /usr/bin/rm -rf -- "$rollback"
    vx_harbor_provider_lock_release
}
