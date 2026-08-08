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
VX_HARBOR_MIN_FREE_KB=0
_vx_harbor_install_requirements() { return 0; }
vx_harbor_origin_json() { printf '{"PORT":8083,"ORIGIN":"https://host.example:8083"}\n'; }
vx_harbor_release_stage() { mkdir -p "$1/extracted"; printf '{}\n' >"$1/evidence.json"; chmod 0600 "$1/evidence.json"; }
vx_harbor_socket_validate() { return 0; }
vx_harbor_ingress_activate() { install -m 0600 "$1" "$(vx_harbor_ingress_target)"; }

printf 'prior-unit\n' >"$VX_HARBOR_SYSTEMD_TARGET"
printf 'prior-ingress\n' >"$VX_HARBOR_NGINX_TARGET"
VX_HARBOR_HEALTH_CHECK=/bin/false
! vx_harbor_install || fail 'failed health was accepted'
[[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail 'unit rollback failed'
[[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail 'ingress rollback failed'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail 'provider state changed on failure'
[[ -d "$VESTA/data/harbor/release" ]] || fail 'release/data retention root removed'

VX_HARBOR_HEALTH_CHECK=/bin/true
for fail_phase in prerequisite release generation compose migration health socket ingress; do
    _vx_harbor_install_phase() { [[ "$1" != "$fail_phase" ]]; }
    printf 'prior-unit\n' >"$VX_HARBOR_SYSTEMD_TARGET"
    printf 'prior-ingress\n' >"$VX_HARBOR_NGINX_TARGET"
    ! vx_harbor_install || fail "$fail_phase failure was accepted"
    [[ "$(cat "$VX_HARBOR_SYSTEMD_TARGET")" == prior-unit ]] || fail "$fail_phase unit rollback failed"
    [[ "$(cat "$VX_HARBOR_NGINX_TARGET")" == prior-ingress ]] || fail "$fail_phase ingress rollback failed"
    [[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == disabled ]] || fail "$fail_phase provider rollback failed"
done
_vx_harbor_install_phase() { :; }
vx_harbor_install || fail 'valid transactional install failed'
[[ "$(jq -r .MODE "$VESTA/data/harbor/provider.json")" == managed ]] || fail 'provider not managed after commit'
grep -q '^name: vesta-harbor$' "$VESTA/data/harbor/release/current/compose.yaml" || fail 'fixed project missing'
vx_harbor_release_images_validate "$VESTA/install/harbor/release-manifest.json" "$VESTA/data/harbor/release/current/compose.yaml" || fail 'installed compose trust failed'
grep -q '^start vesta-harbor.service$' "$SYSTEMCTL_LOG" || fail 'service was not started'
printf 'PASS: Harbor transactional install\n'
