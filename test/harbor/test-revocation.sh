#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare; provider="$(vx_harbor_root)/provider.json"; temporary="$(mktemp "$(vx_harbor_root)/.provider.XXXXXX")"; jq '.MODE="managed"|.ORIGIN="https://panel.example:8083"' "$provider" >"$temporary"; vx_harbor_json_write_atomic "$provider" "$temporary"; rm -f "$temporary"
mkdir -p "$VESTA/data/users/alice"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; owner_path="$(vx_harbor_owner_state_path alice)"; temporary="$(mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")"; jq -n --arg now "$now" '{SCHEMA:1,OWNER:"alice",NAMESPACE:"vx-alice",PROJECT_ID:1,QUOTA_ID:1,QUOTA_MB:100,STATE:"publisher-ready",RUNTIME_ROBOT_ID:10,RUNTIME_USERNAME:"runtime",PUBLISHER_ROBOT_ID:20,PUBLISHER_USERNAME:"publisher",PUBLISHER_ENABLED:true,LAST_ERROR:null,UPDATED_AT:$now}' >"$temporary"; vx_harbor_json_write_atomic "$owner_path" "$temporary"; rm -f "$temporary"
vx_compose_shell_access_lock_acquire(){ return 0; }; vx_compose_shell_access_lock_release(){ return 0; }; vx_compose_registry_lock_acquire(){ return 0; }; vx_compose_registry_lock_release(){ return 0; }
outage=yes; revoke_log="$HARBOR_TEST_ROOT/revoke.log"; vx_harbor_api_robot_disable(){ [[ "$outage" != yes ]] || return 75; printf '%s\n' "$1" >>"$revoke_log"; }
vx_harbor_owner_delete_prepare alice
tombstone="$(vx_harbor_tombstone_path alice)"; vx_harbor_tombstone_validate "$tombstone"; jq -e '.PHASE=="publisher" and .PUBLISHER_ROBOT_ID==20 and .RUNTIME_ROBOT_ID==10' "$tombstone" >/dev/null
rm -rf "$VESTA/data/users/alice"; outage=no; vx_harbor_owners_reconcile
[[ ! -e "$tombstone" && "$(cat "$revoke_log")" == $'20\n10' && -f "$owner_path" ]]
printf 'PASS: delete tombstone outage and restart revocation\n'
