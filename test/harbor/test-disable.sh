#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; new_vesta_root; trap cleanup_vesta_root EXIT; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ :; }; _vx_harbor_authority_uid(){ id -u; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }; vx_harbor_provider_prepare
root="$(vx_harbor_root)"; tmp="$(mktemp "$root/.provider.XXXXXX")"; jq '.MODE="managed"' "$root/provider.json" >"$tmp"; vx_harbor_json_write_atomic "$root/provider.json" "$tmp"; rm -f "$tmp"
revocations="$HARBOR_TEST_ROOT/revocations"; vx_harbor_api_robot_disable(){ printf '%s\n' "$1" >>"$revocations"; }; _vx_harbor_service_is_active(){ return 0; }; _vx_harbor_service_stop(){ :; }; vx_harbor_ingress_target(){ printf '%s\n' "$HARBOR_TEST_ROOT/ingress"; }; _vx_harbor_disable_ingress_remove(){ :; }; vx_harbor_audit(){ :; }
vx_harbor_provider_lock_acquire exclusive; plan="$(vx_harbor_disable_plan_locked)"; token="$(jq -r .TOKEN <<<"$plan")"; vx_harbor_disable_locked "$token" >/dev/null; vx_harbor_provider_lock_release
[[ "$(jq -r .MODE "$root/provider.json")" == disabled ]] || fail 'provider not marked disabled'
[[ -d "$root/backups" ]] || fail 'retained provider data removed'
printf 'PASS: planned retained-data Harbor disable\n'
