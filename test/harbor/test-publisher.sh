#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
create_count="$HARBOR_TEST_ROOT/create"; delete_log="$HARBOR_TEST_ROOT/delete"; printf 0 >"$create_count"; : >"$delete_log"
vx_harbor_api_robot_create(){ cat >/dev/null; value="$(cat "$create_count")"; value=$((value+1)); printf '%s\n' "$value" >"$create_count"; printf '{"id":%s,"name":"%s","disabled":false}\n' "$((40+value))" "$2"; }
publisher_secret='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'
vx_harbor_api_credential_probe(){ [[ "$(cat)" == "$publisher_secret" ]]; }
vx_harbor_api_robot_delete(){ printf '%s\n' "$1" >>"$delete_log"; }
prepare_owner(){ owner="$1"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; path="$(vx_harbor_owner_state_path "$owner")"; source_file="$(mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")"; jq -n --arg owner "$owner" --arg ns "vx-$owner" --arg now "$now" '{SCHEMA:1,OWNER:$owner,NAMESPACE:$ns,PROJECT_ID:1,QUOTA_ID:1,QUOTA_MB:100,STATE:"publisher-ready",RUNTIME_ROBOT_ID:10,RUNTIME_USERNAME:"runtime",PUBLISHER_ROBOT_ID:20,PUBLISHER_USERNAME:"publisher-old",PUBLISHER_ENABLED:true,LAST_ERROR:null,UPDATED_AT:$now}' >"$source_file"; vx_harbor_json_write_atomic "$path" "$source_file"; rm -f "$source_file"; }

prepare_owner journalfail; fail_journal=yes
_vx_harbor_json_write_phase(){ [[ "${fail_journal:-no}" != yes ]]; }
! printf short | vx_harbor_publisher_change_locked journalfail
! printf 'bad+publisher/secret________________________________' | vx_harbor_publisher_change_locked journalfail
! printf '%0130d' 0 | vx_harbor_publisher_change_locked journalfail
! printf %s "$publisher_secret" | vx_harbor_publisher_change_locked journalfail
jq -e '.PUBLISHER_ROBOT_ID==20' "$(vx_harbor_owner_state_path journalfail)" >/dev/null; [[ ! -e "$(vx_harbor_rotation_path journalfail publisher)" ]]; fail_journal=no

prepare_owner crashjournal; crash_point=journal-published
_vx_harbor_rotation_checkpoint(){ [[ "$1:$2" != "publisher:$crash_point" ]]; }
! printf %s "$publisher_secret" | vx_harbor_publisher_change_locked crashjournal
journal="$(vx_harbor_rotation_path crashjournal publisher)"; jq -e '.PHASE=="pending-switch"' "$journal" >/dev/null; jq -e '.PUBLISHER_ROBOT_ID==20' "$(vx_harbor_owner_state_path crashjournal)" >/dev/null; before="$(cat "$create_count")"
crash_point=none; printf %s "$publisher_secret" | vx_harbor_publisher_change_locked crashjournal
[[ "$(cat "$create_count")" == "$before" ]]; jq -e '.PUBLISHER_ROBOT_ID==42' "$(vx_harbor_owner_state_path crashjournal)" >/dev/null; jq -e '.PHASE=="converged"' "$journal" >/dev/null

prepare_owner crashswitch; crash_point=authority-switched
! printf %s "$publisher_secret" | vx_harbor_publisher_change_locked crashswitch
journal="$(vx_harbor_rotation_path crashswitch publisher)"; jq -e '.PHASE=="pending-switch"' "$journal" >/dev/null; jq -e '.PUBLISHER_ROBOT_ID==43' "$(vx_harbor_owner_state_path crashswitch)" >/dev/null; before="$(cat "$create_count")"; mapping_hash="$(sha256sum "$(vx_harbor_owner_state_path crashswitch)")"
crash_point=none; printf %s "$publisher_secret" | vx_harbor_publisher_change_locked crashswitch
[[ "$(cat "$create_count")" == "$before" && "$(sha256sum "$(vx_harbor_owner_state_path crashswitch)")" == "$mapping_hash" ]]; jq -e '.PHASE=="converged"' "$journal" >/dev/null
printf 'PASS: publisher journal-before-switch crash recovery\n'
