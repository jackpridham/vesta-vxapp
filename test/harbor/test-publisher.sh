#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
owner=alice; path="$(vx_harbor_owner_state_path "$owner")"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
source_file="$(mktemp "$(vx_harbor_root)/owners/.source.XXXXXX")"
jq -n --arg now "$now" '{SCHEMA:1,OWNER:"alice",NAMESPACE:"vx-alice",PROJECT_ID:1,QUOTA_ID:1,QUOTA_MB:100,STATE:"publisher-ready",RUNTIME_ROBOT_ID:10,RUNTIME_USERNAME:"runtime-old",PUBLISHER_ROBOT_ID:20,PUBLISHER_USERNAME:"publisher-old",PUBLISHER_ENABLED:true,LAST_ERROR:null,UPDATED_AT:$now}' >"$source_file"
vx_harbor_json_write_atomic "$path" "$source_file"; rm -f "$source_file"
create_counter="$HARBOR_TEST_ROOT/create-count"; delete_counter="$HARBOR_TEST_ROOT/delete-count"; captured="$HARBOR_TEST_ROOT/captured"; printf 0 >"$create_counter"; printf 0 >"$delete_counter"; delete_fail_file="$HARBOR_TEST_ROOT/delete-fail"; touch "$delete_fail_file"
vx_harbor_api_robot_create(){ cat >"$captured"; value="$(cat "$create_counter")"; printf '%s\n' "$((value+1))" >"$create_counter"; printf '{"id":30,"name":"publisher-new","disabled":false}\n'; }
vx_harbor_api_credential_probe(){ [[ "$(cat)" == publisher-secret-0123456789 ]]; }
vx_harbor_api_robot_delete(){ value="$(cat "$delete_counter")"; printf '%s\n' "$((value+1))" >"$delete_counter"; [[ ! -e "$delete_fail_file" ]]; }
publisher_secret=publisher-secret-0123456789
printf %s "$publisher_secret" | vx_harbor_publisher_change_locked "$owner"
jq -e '.PUBLISHER_ROBOT_ID==30 and .PUBLISHER_ENABLED==true' "$path" >/dev/null
rotation="$(vx_harbor_rotation_path "$owner" publisher)"; jq -e '.PHASE=="pending-revoke" and .OLD_ROBOT_ID==20 and .NEW_ROBOT_ID==30' "$rotation" >/dev/null
operation="$(jq -r .OPERATION_ID "$rotation")"; [[ "$(cat "$create_counter")" == 1 && "$(cat "$captured")" == "$publisher_secret" ]]
rm -f "$delete_fail_file"
printf ignored-secret-value-123456 | vx_harbor_publisher_change_locked "$owner"
[[ "$(cat "$create_counter")" == 1 && "$(jq -r .OPERATION_ID "$rotation")" == "$operation" ]]
jq -e '.PHASE=="converged"' "$rotation" >/dev/null
! grep -R -F "$publisher_secret" "$(vx_harbor_root)" "$HARBOR_TEST_ROOT"/vesta/data/users 2>/dev/null
adapter_root="$HARBOR_TEST_ROOT/adapter"; mkdir -p "$adapter_root/func/vx/compose" "$adapter_root/func/vx/harbor" "$adapter_root/conf"
printf '%s\n' 'check_args(){ [[ "$2" == "$1" ]] || exit 1; }' 'is_format_valid(){ :; }' 'is_object_valid(){ :; }' 'check_result(){ [[ "$1" == 0 ]] || exit 1; }' >"$adapter_root/func/main.sh"
printf ':\n' >"$adapter_root/func/vx/compose/main.sh"; printf ':\n' >"$adapter_root/func/vx/harbor/main.sh"; printf ':\n' >"$adapter_root/conf/vesta.conf"
! VESTA="$adapter_root" bash "$HARBOR_REPO_ROOT/bin/v-change-user-harbor-registry-publisher" alice /tmp/caller-secret
printf 'PASS: publisher auth-switch-revoke retry\n'
