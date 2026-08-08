#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers
mkdir -p "$VESTA/install/harbor" "$VESTA/nginx/conf" "$HARBOR_TEST_ROOT/systemd" "$HARBOR_TEST_ROOT/run"
cp "$HARBOR_REPO_ROOT/install/harbor/"* "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/main.sh"
test_data_root="$HARBOR_TEST_ROOT/provider-data"
vx_harbor_data_root() { printf '%s\n' "$test_data_root"; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_authority_uid() { id -u; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
systemctl="$HARBOR_TEST_ROOT/systemctl"
cat >"$systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$1" in
  is-active|is-enabled) exit 1 ;;
  start)
    (
      fd=3; while [ "$fd" -le 255 ]; do eval "exec $fd>&-" 2>/dev/null || :; fd=$((fd+1)); done
      /usr/bin/flock -s "$PROVIDER_LOCK_PATH" -c ": >'$RECONCILE_DONE'"
    ) &
    printf '%s\n' "$!" >"$RECONCILE_PID"
    exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$systemctl"; export SYSTEMCTL_LOG="$HARBOR_TEST_ROOT/systemctl.log"
export PROVIDER_LOCK_PATH="$VESTA/data/harbor/locks/provider.lock" RECONCILE_DONE="$HARBOR_TEST_ROOT/reconcile.done" RECONCILE_PID="$HARBOR_TEST_ROOT/reconcile.pid"
VX_HARBOR_SYSTEMCTL="$systemctl"
VX_HARBOR_SYSTEMD_TARGET="$HARBOR_TEST_ROOT/systemd/vesta-harbor.service"
VX_HARBOR_NGINX_TARGET="$VESTA/nginx/conf/harbor-registry.conf"
VX_HARBOR_SOCKET_GID=33
printf 'events {}\nhttp { server { root %s/web; listen 8083 ssl; ssl_certificate /panel.pem; } }\n' "$VESTA" >"$VESTA/nginx/conf/nginx.conf"
VX_HARBOR_MIN_FREE_KB=0
_vx_harbor_install_requirements() { return 0; }
vx_harbor_origin_json() { printf '{"PORT":8083,"ORIGIN":"https://host.example:8083"}\n'; }
vx_harbor_release_stage() { mkdir -p "$1/extracted"; printf '{}\n' >"$1/evidence.json"; chmod 0600 "$1/evidence.json"; }
config_stage="$HARBOR_TEST_ROOT/config-stage"
mkdir -p "$config_stage/extracted/harbor"
printf '%s\n' \
  'hostname: reg.mydomain.com' \
  'http:' \
  '  port: 80' \
  '# https related config' \
  'https:' \
  '  port: 443' \
  '  certificate: /your/certificate/path' \
  '  private_key: /your/private/key/path' \
  '  # strong_ssl_ciphers: false' \
  '# # Harbor will set ipv4 enabled only by default if this block is not configured' \
  '# external_url: https://reg.mydomain.com:8433' \
  'harbor_admin_password: Harbor12345' \
  'database:' \
  '  password: root123' \
  'data_volume: /data' \
  'log:' \
  '  local:' \
  '    location: /var/log/harbor' \
  '# metric:' \
  '#   enabled: false' \
  '#   port: 9090' \
  '#   path: /metrics' >"$config_stage/extracted/harbor/harbor.yml.tmpl"
_vx_harbor_install_harbor_yml "$config_stage" '{"HOSTNAME":"host.example","ORIGIN":"https://host.example:8083"}'
! grep -q '^https:' "$config_stage/harbor.yml" || fail 'external proxy config retained Harbor TLS listener'
grep -q '^external_url: https://host.example:8083$' "$config_stage/harbor.yml" \
  || fail 'external proxy origin was not rendered'
grep -q '^    location: /var/lib/vesta-harbor/log$' "$config_stage/harbor.yml" \
  || fail 'managed Harbor log path was not rendered'
current_secrets="$VESTA/data/harbor/release/current/secrets"
mkdir -p "$current_secrets"
install -m 0600 "$config_stage/secrets/admin" "$current_secrets/admin"
install -m 0600 "$config_stage/secrets/database" "$current_secrets/database"
resume_stage="$HARBOR_TEST_ROOT/resume-stage"
mkdir -p "$resume_stage/extracted/harbor"
cp "$config_stage/extracted/harbor/harbor.yml.tmpl" "$resume_stage/extracted/harbor/harbor.yml.tmpl"
_vx_harbor_install_harbor_yml "$resume_stage" '{"HOSTNAME":"host.example","ORIGIN":"https://host.example:8083"}'
cmp -s "$current_secrets/admin" "$resume_stage/secrets/admin" || fail 'resumable install rotated bootstrap authority'
cmp -s "$current_secrets/database" "$resume_stage/secrets/database" || fail 'resumable install rotated database authority'
rm -rf "$VESTA/data/harbor/release/current"
chmod 0700 "$VESTA/data/harbor/release"
saved_image="$HARBOR_TEST_ROOT/saved-image.tar"; saved_root="$HARBOR_TEST_ROOT/saved-image"
mkdir -p "$saved_root"
printf '[{"Config":"blobs/sha256/%064d","Layers":["layer"],"RepoTags":null}]\n' 0 >"$saved_root/manifest.json"
tar -cf "$saved_image" -C "$saved_root" manifest.json
_vx_harbor_docker_bounded() { cat "$saved_image"; }
_vx_harbor_install_loaded_image_config_validate "sha256:$(printf '%064d' 1)" "sha256:$(printf '%064d' 0)" \
  || fail 'containerd image identity did not validate its pinned saved config'
! _vx_harbor_install_loaded_image_config_validate "sha256:$(printf '%064d' 1)" "sha256:$(printf '%064d' 2)" \
  || fail 'mismatched saved image config was accepted'
_vx_harbor_docker_bounded() { return 0; }
_vx_harbor_install_generate() {
  local stage="$1" manifest="$2"
  mkdir -m 0700 -p "$(vx_harbor_data_root)"
  mkdir -p "$stage/common/config/nginx" "$stage/secrets"
  cp "$HARBOR_REPO_ROOT/test/harbor/fixtures/harbor-v2.15.0-generated-compose.yml" "$stage/docker-compose.yml"
  cp "$HARBOR_REPO_ROOT/test/harbor/fixtures/harbor-v2.15.0-generated-nginx.conf" "$stage/common/config/nginx/nginx.conf"
  _vx_harbor_install_transform_generated "$stage" "$manifest"
}
vx_harbor_socket_validate() { return 0; }
_vx_harbor_install_migration_check() { return 0; }
_vx_harbor_install_health_check() { return 0; }
bootstrap_config="$HARBOR_TEST_ROOT/bootstrap-config.json"; bootstrap_robots="$HARBOR_TEST_ROOT/bootstrap-robots.json"
cleanup_fail=no
printf '{"self_registration":true,"project_creation_restriction":"everyone"}\n' >"$bootstrap_config"; printf '[]\n' >"$bootstrap_robots"
_vx_harbor_install_bootstrap_call() {
  local stage="$1" method="$2" path="$3" body="$4" output="$5"
  case "$method:$path" in
    GET:/api/v2.0/configurations) cp "$bootstrap_config" "$output" ;;
    PUT:/api/v2.0/configurations) printf '%s\n' "$body" >"$bootstrap_config"; printf '{}\n' >"$output" ;;
    GET:/api/v2.0/robots) cp "$bootstrap_robots" "$output" ;;
    POST:/api/v2.0/robots)
      jq -e '.duration==-1 and .level=="system" and .description=="vesta-managed:vesta-harbor" and ([.permissions[].access[].resource]|sort)==(["project","project","project","quota","quota","robot","robot","robot","robot","system-volumes"]|sort)' <<<"$body" >/dev/null || return 1
      jq -c '.+{id:71,disabled:false}|del(.secret)' <<<"$body" >"$output"; jq -s '.[0]+[.[1]]' "$bootstrap_robots" "$output" >"$bootstrap_robots.next"; mv "$bootstrap_robots.next" "$bootstrap_robots" ;;
    GET:/api/v2.0/robots/71) jq -c '.[]|select(.id==71)' "$bootstrap_robots" >"$output"; [[ -s "$output" ]] ;;
    PUT:/api/v2.0/robots/71) jq 'map(if .id==71 then .+{disabled:true} else . end)' "$bootstrap_robots" >"$bootstrap_robots.next"; mv "$bootstrap_robots.next" "$bootstrap_robots"; printf '{}\n' >"$output" ;;
    DELETE:/api/v2.0/robots/71) [[ "$cleanup_fail" != yes ]] || return 75; jq 'map(select(.id!=71))' "$bootstrap_robots" >"$bootstrap_robots.next"; mv "$bootstrap_robots.next" "$bootstrap_robots"; printf '{}\n' >"$output" ;;
    *) return 1 ;;
  esac
}
_vx_harbor_install_integration_probe() {
  grep -q '^user = "vesta-integration:' "$1" || return 1
  printf '{"status":"healthy"}\n' >"$2"
}
vx_harbor_ingress_activate() { install -m 0600 "$1" "$(vx_harbor_ingress_target)"; install -m 0600 "$3" "$(vx_harbor_nginx_main)"; }

printf 'prior-unit\n' >"$VX_HARBOR_SYSTEMD_TARGET"
printf 'prior-ingress\n' >"$VX_HARBOR_NGINX_TARGET"
vx_harbor_provider_prepare
mkdir -p "$VESTA/data/harbor/release/current" "$VESTA/data/harbor/release/previous"
printf 'prior-current\n' >"$VESTA/data/harbor/release/current/marker"
printf 'prior-previous\n' >"$VESTA/data/harbor/release/previous/marker"
prior_main="$(sha256sum "$VESTA/nginx/conf/nginx.conf"|awk '{print $1}')"
prior_provider="$(sha256sum "$VESTA/data/harbor/provider.json"|awk '{print $1}')"
_vx_harbor_install_phase() { [[ "$1" != health ]]; }
! vx_harbor_install || fail 'failed health was accepted'
[[ ! -e "$test_data_root" ]] || fail 'failed fresh install retained mutated provider data'
[[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail 'unit rollback failed'
[[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail 'ingress rollback failed'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail 'provider state changed on failure'
[[ -d "$VESTA/data/harbor/release" ]] || fail 'release/data retention root removed'
[[ "$(sha256sum "$VESTA/nginx/conf/nginx.conf"|awk '{print $1}')" == "$prior_main" ]] || fail 'main nginx rollback failed'
[[ "$(cat "$VESTA/data/harbor/release/current/marker")" == prior-current && "$(cat "$VESTA/data/harbor/release/previous/marker")" == prior-previous ]] || fail 'release evidence rollback failed'

for fail_phase in prerequisite release generation compose migration health socket integration ingress provider_render release_rotation provider_write final_cleanup; do
    _vx_harbor_install_phase() { [[ "$1" != "$fail_phase" ]]; }
    printf 'prior-unit\n' >"$VX_HARBOR_SYSTEMD_TARGET"
    printf 'prior-ingress\n' >"$VX_HARBOR_NGINX_TARGET"
    ! vx_harbor_install || fail "$fail_phase failure was accepted"
    [[ ! -e "$test_data_root" ]] || fail "$fail_phase fresh install retained mutated provider data"
    [[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail "$fail_phase unit rollback failed"
    [[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail "$fail_phase ingress rollback failed"
    jq -e '.self_registration==true and .project_creation_restriction=="everyone"' "$bootstrap_config" >/dev/null || fail "$fail_phase external configuration rollback failed"
    jq -e 'length==0' "$bootstrap_robots" >/dev/null || fail "$fail_phase left an integration robot orphan"
    [[ ! -e "$VESTA/data/harbor/operations/provider-install.json" ]] || fail "$fail_phase left resolved cleanup journal"
    [[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail "$fail_phase provider rollback failed"
    [[ "$(sha256sum "$VESTA/data/harbor/provider.json"|awk '{print $1}')" == "$prior_provider" ]] || fail "$fail_phase provider bytes changed"
    [[ "$(cat "$VESTA/data/harbor/release/current/marker")" == prior-current && "$(cat "$VESTA/data/harbor/release/previous/marker")" == prior-previous ]] || fail "$fail_phase release rollback failed"
    ! compgen -G "$VESTA/data/harbor/release/.install.*" >/dev/null || fail "$fail_phase retained pre-activation staging"
    vx_harbor_provider_lock_acquire exclusive || fail "$fail_phase stranded provider lock"
    vx_harbor_provider_lock_release
done
for json_phase in fsync rename; do
    _vx_harbor_install_phase() { :; }; _vx_harbor_json_write_phase() { [[ "$1" != "$json_phase" ]]; }
    ! vx_harbor_install || fail "$json_phase publication failure was accepted"
    [[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail "$json_phase provider rollback failed"
    vx_harbor_provider_lock_acquire exclusive || fail "$json_phase stranded provider lock"; vx_harbor_provider_lock_release
done
_vx_harbor_json_write_phase() { :; }
_vx_harbor_install_phase() { :; }
printf '[{"id":70,"name":"vesta-integration","description":"foreign-authority","disabled":false}]\n' >"$bootstrap_robots"
! vx_harbor_install || fail 'conflicting non-Vesta integration robot was accepted'
jq -e '.self_registration==true and .project_creation_restriction=="everyone"' "$bootstrap_config" >/dev/null || fail 'collision changed Harbor security configuration'
printf '[]\n' >"$bootstrap_robots"
rm -f "$RECONCILE_DONE"
vx_harbor_install || fail 'valid transactional install failed'
[[ -d "$test_data_root" ]] || fail 'committed install lost provider data'
for _ in {1..100}; do [[ -e "$RECONCILE_DONE" ]] && break; sleep .02; done
[[ -e "$RECONCILE_DONE" ]] || fail 'nonblocking post-start reconciliation did not proceed after install lock release'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == managed ]] || fail 'provider not managed after commit'
credential="$VESTA/data/harbor/secrets/integration.curl"
[[ "$(stat -c %a "$credential")" == 600 && "$(stat -c %h "$credential")" == 1 ]] || fail 'integration credential is not root-style 0600 single-link authority'
grep -q '^user = "vesta-integration:' "$credential" || fail 'routine integration identity missing'
! grep -q 'admin:' "$credential" || fail 'bootstrap identity remained routine authority'
compose="$VESTA/data/harbor/release/current/docker-compose.yml"
[[ "$(stat -c %a "$VESTA/data/harbor/release/current/common/config/nginx/nginx.conf")" == 644 ]] \
  || fail 'non-secret unprivileged proxy config is not readable'
head -1 "$VESTA/data/harbor/release/current/common/config/nginx/nginx.conf" \
  | grep -qx 'user nginx;' || fail 'proxy workers do not drop root authority'
entrypoint="$VESTA/data/harbor/release/current/common/config/nginx/proxy-entrypoint.sh"
[[ "$(stat -c %a "$entrypoint")" == 644 ]] || fail 'proxy socket supervisor mode is not fixed'
grep -q 'chown 0:33 "$socket"' "$entrypoint" || fail 'proxy socket group is not deterministic'
grep -q 'chmod 0660 "$socket"' "$entrypoint" || fail 'proxy socket mode is not deterministic'
grep -q '^name: vesta-harbor$' "$compose" || fail 'fixed project missing'
vx_harbor_release_images_validate "$VESTA/install/harbor/release-manifest.json" "$compose" || fail 'installed compose trust failed'
[[ "$(grep -c '^  [a-z].*:$' "$compose")" -ge 10 ]] || fail 'canonical service graph missing'
grep -q '/var/lib/vesta-harbor' "$compose" || fail 'durable provider storage missing'
grep -q '/run/vesta-harbor:/run/vesta-harbor' "$compose" || fail 'socket creation mount missing'
grep -A16 '^  proxy:' "$compose" | grep -q '^    user: "0:33"$' || fail 'proxy master cannot create group-protected socket'
grep -A16 '^  proxy:' "$compose" | grep -Fq 'command: ["/bin/sh", "/etc/nginx/proxy-entrypoint.sh"]' || fail 'proxy socket supervisor missing'
grep -A16 '^  proxy:' "$compose" | grep -Fq -- '--unix-socket' || fail 'proxy healthcheck does not use the isolated socket'
grep -A16 '^  proxy:' "$compose" | grep -q '^      - ALL$' || fail 'proxy capability drop missing'
grep -A16 '^  proxy:' "$compose" | grep -q '^      - no-new-privileges:true$' || fail 'proxy privilege ceiling missing'
grep -A16 '^  proxy:' "$compose" | grep -q '^      - FOWNER$' || fail 'required proxy startup capability missing'
! grep -A16 '^  proxy:' "$compose" | grep -q 'NET_BIND_SERVICE' || fail 'unneeded proxy bind capability survived transform'
! grep -q '^    ports:' "$compose" || fail 'canonical host ports survived transform'
grep -q 'depends_on:' "$compose" || fail 'canonical dependency graph missing'
grep -q 'env_file:' "$compose" || fail 'canonical generated component configuration missing'
grep -q '^start vesta-harbor.service$' "$SYSTEMCTL_LOG" || fail 'service was not started'
grep -q 'systemd-run .*--no-block.*v-sync-harbor-registry-owners' "$VX_HARBOR_SYSTEMD_TARGET" || fail 'post-start reconciliation is not nonblocking'
! grep -q '^ExecStartPost=/usr/local/vesta/bin/v-sync-harbor-registry-owners$' "$VX_HARBOR_SYSTEMD_TARGET" || fail 'synchronous owner reconciliation deadlock restored'
_vx_harbor_install_integration_configure "$VESTA/data/harbor/release/current" || fail 'owned integration identity was not idempotently resumed'
jq -e 'length==1 and .[0].name=="vesta-integration" and .[0].description=="vesta-managed:vesta-harbor"' "$bootstrap_robots" >/dev/null || fail 'idempotent install duplicated integration robot'
journal="$VESTA/data/harbor/operations/provider-install.json"
jq '.CANDIDATE_ROBOT_ID=71|.PRIOR_CONFIGURATION={self_registration:true,project_creation_restriction:"everyone"}' "$journal" >"$journal.next"; vx_harbor_json_write_atomic "$journal" "$journal.next"; rm -f "$journal.next"
cleanup_fail=yes
! _vx_harbor_install_external_cleanup "$VESTA/data/harbor/release/current" || fail 'unavailable external cleanup was accepted'
[[ -f "$journal" ]] && jq -e 'length==1 and .[0].disabled==true' "$bootstrap_robots" >/dev/null || fail 'failed cleanup lost durable candidate authority'
cleanup_fail=no
_vx_harbor_install_external_cleanup "$VESTA/data/harbor/release/current" || fail 'durable external cleanup did not resume'
[[ ! -e "$journal" ]] && jq -e 'length==0' "$bootstrap_robots" >/dev/null || fail 'resumed cleanup left an orphan robot'
jq -e '.self_registration==true and .project_creation_restriction=="everyone"' "$bootstrap_config" >/dev/null || fail 'resumed cleanup did not restore exact prior security configuration'
printf 'PASS: Harbor transactional install\n'
