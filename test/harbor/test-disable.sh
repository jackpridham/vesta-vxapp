#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; new_vesta_root; trap cleanup_vesta_root EXIT; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ :; }; _vx_harbor_authority_uid(){ id -u; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }; vx_harbor_provider_prepare
root="$(vx_harbor_root)"; tmp="$(mktemp "$root/.provider.XXXXXX")"; jq '.MODE="managed"' "$root/provider.json" >"$tmp"; vx_harbor_json_write_atomic "$root/provider.json" "$tmp"; rm -f "$tmp"

nginx_log="$HARBOR_TEST_ROOT/nginx.log"
nginx_main="$HARBOR_TEST_ROOT/nginx.conf"
nginx_ingress="$HARBOR_TEST_ROOT/harbor-registry.conf"
backup_main="$HARBOR_TEST_ROOT/nginx.backup.conf"
backup_ingress="$HARBOR_TEST_ROOT/harbor-registry.backup.conf"
printf 'events {}\nhttp {\n server {\n  include %s;\n }\n}\n' \
    "$nginx_ingress" >"$nginx_main"
printf 'location = /v2/ { return 200; }\n' >"$nginx_ingress"
cp "$nginx_main" "$backup_main"
cp "$nginx_ingress" "$backup_ingress"
vx_harbor_ingress_target(){ printf '%s\n' "$nginx_ingress"; }
vx_harbor_nginx_main(){ printf '%s\n' "$nginx_main"; }
vx_harbor_panel_nginx_test(){
    [[ -f "$1" && ! -L "$1" ]] || return 1
    printf 'test:%s\n' "$1" >>"$nginx_log"
}
vx_harbor_panel_nginx_reload(){ printf 'reload\n' >>"$nginx_log"; }
_vx_harbor_disable_ingress_remove \
    || fail 'disable did not use the Vesta panel nginx boundary'
[[ ! -e "$nginx_ingress" ]] \
    || fail 'disable retained the managed Harbor ingress include'
! grep -Fq "include $nginx_ingress;" "$nginx_main" \
    || fail 'disable retained the managed include in panel nginx'
[[ "$(sed -n '1p' "$nginx_log")" == test:* \
    && "$(sed -n '2p' "$nginx_log")" == "test:$nginx_main" \
    && "$(sed -n '3p' "$nginx_log")" == reload ]] \
    || fail 'disable did not validate candidate and active panel nginx before reload'
: >"$nginx_log"
_vx_harbor_disable_restore \
    "$nginx_ingress" "$nginx_main" "$backup_ingress" "$backup_main" yes no \
    || fail 'disable rollback did not restore through the panel nginx boundary'
cmp -s "$backup_ingress" "$nginx_ingress" \
    && cmp -s "$backup_main" "$nginx_main" \
    || fail 'disable rollback did not restore exact ingress bytes'
[[ "$(sed -n '1p' "$nginx_log")" == "test:$nginx_main" \
    && "$(sed -n '2p' "$nginx_log")" == reload ]] \
    || fail 'disable rollback did not validate panel nginx before reload'
! grep -Eq '/usr/sbin/nginx|reload nginx[.]service' \
    "$HARBOR_REPO_ROOT/func/vx/harbor/disable.sh" \
    || fail 'disable retains the Debian nginx control plane'

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; now_epoch="$(date -u +%s)"; owner="$root/owners/alice.json"; jq -n --arg now "$now" '{SCHEMA:1,OWNER:"alice",NAMESPACE:"alice",PROJECT_ID:1,QUOTA_ID:2,QUOTA_MB:1024,STATE:"publisher-ready",RUNTIME_ROBOT_ID:10,RUNTIME_USERNAME:"robot$alice-runtime",PUBLISHER_ROBOT_ID:20,PUBLISHER_USERNAME:"robot$alice-publisher",PUBLISHER_ENABLED:true,LAST_ERROR:null,UPDATED_AT:$now}' >"$tmp"; vx_harbor_json_write_atomic "$owner" "$tmp"
revocations="$HARBOR_TEST_ROOT/revocations"; _vx_harbor_owned_robot_delete(){ printf '%s\n' "$5" >>"$revocations"; }; _vx_harbor_disable_integration_revoke(){ :; }; _vx_harbor_service_is_active(){ return 0; }; _vx_harbor_service_stop(){ :; }; vx_harbor_ingress_target(){ printf '%s\n' "$HARBOR_TEST_ROOT/ingress"; }; vx_harbor_nginx_main(){ printf '%s\n' "$HARBOR_TEST_ROOT/nginx.conf"; }; : >"$HARBOR_TEST_ROOT/nginx.conf"; _vx_harbor_disable_ingress_remove(){ :; }; vx_harbor_audit(){ :; }
vx_harbor_provider_lock_acquire exclusive; plan="$(vx_harbor_disable_plan_locked)"; token="$(jq -r .TOKEN <<<"$plan")"; vx_harbor_provider_lock_release
operation="$root/operations/alice.json"; jq -n --argjson now "$now_epoch" '{SCHEMA:1,OPERATION_ID:"0123456789abcdef0123456789abcdef",OWNER:"alice",DESIRED_PACKAGE:"default",DESIRED_REGISTRY_MB:"1024",STATE:"pending",ATTEMPTS:0,LAST_ERROR:null,CREATED_AT:$now,UPDATED_AT:$now}' >"$tmp"; vx_harbor_json_write_atomic "$operation" "$tmp"
set +e; vx_harbor_provider_lock_acquire exclusive; vx_harbor_disable_locked "$token" >/dev/null; code=$?; vx_harbor_provider_lock_release; set -e
[[ "$code" != 0 && ! -e "$revocations" && "$(jq -r .MODE "$root/provider.json")" == managed ]] || fail 'new blocker did not abort disable before revocation'
rm -f "$operation"; vx_harbor_provider_lock_acquire exclusive; plan="$(vx_harbor_disable_plan_locked)"; token="$(jq -r .TOKEN <<<"$plan")"; vx_harbor_disable_locked "$token" >/dev/null; vx_harbor_provider_lock_release
[[ "$(jq -r .MODE "$root/provider.json")" == disabled ]] || fail 'provider not marked disabled'
[[ "$(tr '\n' ':' <"$revocations")" == 20:10: ]] || fail 'publisher/runtime revocation order regressed'
[[ -d "$root/backups" ]] || fail 'retained provider data removed'
printf 'PASS: blocker-bound transactional Harbor disable\n'
