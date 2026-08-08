#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers
mkdir -p "$VESTA/install/harbor" "$VESTA/nginx/conf" "$HARBOR_TEST_ROOT/systemd" "$HARBOR_TEST_ROOT/run"
cp "$HARBOR_REPO_ROOT/install/harbor/"* "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root() { return 0; }
_vx_harbor_authority_uid() { id -u; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
systemctl="$HARBOR_TEST_ROOT/systemctl"
cat >"$systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$1" in is-active|is-enabled) exit 1;; *) exit 0;; esac
SH
chmod +x "$systemctl"; export SYSTEMCTL_LOG="$HARBOR_TEST_ROOT/systemctl.log"
VX_HARBOR_SYSTEMCTL="$systemctl"
VX_HARBOR_SYSTEMD_TARGET="$HARBOR_TEST_ROOT/systemd/vesta-harbor.service"
VX_HARBOR_NGINX_TARGET="$VESTA/nginx/conf/harbor-registry.conf"
printf 'events {}\nhttp { server { root %s/web; listen 8083 ssl; ssl_certificate /panel.pem; } }\n' "$VESTA" >"$VESTA/nginx/conf/nginx.conf"
VX_HARBOR_MIN_FREE_KB=0
_vx_harbor_install_requirements() { return 0; }
vx_harbor_origin_json() { printf '{"PORT":8083,"ORIGIN":"https://host.example:8083"}\n'; }
vx_harbor_release_stage() { mkdir -p "$1/extracted"; printf '{}\n' >"$1/evidence.json"; chmod 0600 "$1/evidence.json"; }
_vx_harbor_install_generate() {
  local stage="$1" manifest="$2"
  mkdir -p "$stage/common/config/nginx" "$stage/secrets"
  cp "$HARBOR_REPO_ROOT/test/harbor/fixtures/harbor-v2.15.0-generated-compose.yml" "$stage/docker-compose.yml"
  cp "$HARBOR_REPO_ROOT/test/harbor/fixtures/harbor-v2.15.0-generated-nginx.conf" "$stage/common/config/nginx/nginx.conf"
  _vx_harbor_install_transform_generated "$stage" "$manifest"
}
vx_harbor_socket_validate() { return 0; }
_vx_harbor_install_migration_check() { return 0; }
_vx_harbor_install_health_check() { return 0; }
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
[[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail 'unit rollback failed'
[[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail 'ingress rollback failed'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail 'provider state changed on failure'
[[ -d "$VESTA/data/harbor/release" ]] || fail 'release/data retention root removed'
[[ "$(sha256sum "$VESTA/nginx/conf/nginx.conf"|awk '{print $1}')" == "$prior_main" ]] || fail 'main nginx rollback failed'
[[ "$(cat "$VESTA/data/harbor/release/current/marker")" == prior-current && "$(cat "$VESTA/data/harbor/release/previous/marker")" == prior-previous ]] || fail 'release evidence rollback failed'

for fail_phase in prerequisite release generation compose migration health socket ingress provider_render release_rotation provider_write final_cleanup; do
    _vx_harbor_install_phase() { [[ "$1" != "$fail_phase" ]]; }
    printf 'prior-unit\n' >"$VX_HARBOR_SYSTEMD_TARGET"
    printf 'prior-ingress\n' >"$VX_HARBOR_NGINX_TARGET"
    ! vx_harbor_install || fail "$fail_phase failure was accepted"
    [[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail "$fail_phase unit rollback failed"
    [[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail "$fail_phase ingress rollback failed"
    [[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail "$fail_phase provider rollback failed"
    [[ "$(sha256sum "$VESTA/data/harbor/provider.json"|awk '{print $1}')" == "$prior_provider" ]] || fail "$fail_phase provider bytes changed"
    [[ "$(cat "$VESTA/data/harbor/release/current/marker")" == prior-current && "$(cat "$VESTA/data/harbor/release/previous/marker")" == prior-previous ]] || fail "$fail_phase release rollback failed"
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
vx_harbor_install || fail 'valid transactional install failed'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == managed ]] || fail 'provider not managed after commit'
compose="$VESTA/data/harbor/release/current/docker-compose.yml"
grep -q '^name: vesta-harbor$' "$compose" || fail 'fixed project missing'
vx_harbor_release_images_validate "$VESTA/install/harbor/release-manifest.json" "$compose" || fail 'installed compose trust failed'
[[ "$(grep -c '^  [a-z].*:$' "$compose")" -ge 10 ]] || fail 'canonical service graph missing'
grep -q '/var/lib/vesta-harbor' "$compose" || fail 'durable provider storage missing'
grep -q '/run/vesta-harbor:/run/vesta-harbor' "$compose" || fail 'socket creation mount missing'
! grep -q '^    ports:' "$compose" || fail 'canonical host ports survived transform'
grep -q 'depends_on:' "$compose" || fail 'canonical dependency graph missing'
grep -q 'env_file:' "$compose" || fail 'canonical generated component configuration missing'
grep -q '^start vesta-harbor.service$' "$SYSTEMCTL_LOG" || fail 'service was not started'
printf 'PASS: Harbor transactional install\n'
