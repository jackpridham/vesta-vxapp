#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
provider="$(vx_harbor_root)/provider.json"; source_file="$(mktemp "$(vx_harbor_root)/.provider.XXXXXX")"; jq '.MODE="managed"|.ORIGIN="https://panel.example:8083"' "$provider" >"$source_file"; vx_harbor_json_write_atomic "$provider" "$source_file"; rm -f "$source_file"
mkdir -p "$VESTA/data/users/alice"; printf "PACKAGE='docker'\nSUSPENDED='no'\nDOCKER_PROJECTS='2'\nDOCKER_REGISTRY_MB='100'\n" >"$VESTA/data/users/alice/user.conf"
mkdir -p "$VESTA/data/users/legacy"; printf "PACKAGE='legacy'\nSUSPENDED='no'\n" >"$VESTA/data/users/legacy/user.conf"
[[ "$(_vx_harbor_owner_desired legacy)" == $'legacy\tno\t0\t0' ]] \
  || fail 'legacy owner limits did not default fail-closed'
! vx_harbor_owner_is_eligible legacy || fail 'legacy owner received implicit registry entitlement'
now_epoch="$(date -u +%s)"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; operation="$(vx_harbor_operation_path alice)"; source_file="$(mktemp "$(vx_harbor_root)/operations/.op.XXXXXX")"
jq -n --argjson now "$now_epoch" '{SCHEMA:1,OPERATION_ID:"0123456789abcdef0123456789abcdef",OWNER:"alice",DESIRED_PACKAGE:"docker",DESIRED_REGISTRY_MB:"100",STATE:"pending",ATTEMPTS:0,LAST_ERROR:null,CREATED_AT:$now,UPDATED_AT:$now}' >"$source_file"; vx_harbor_json_write_atomic "$operation" "$source_file"; rm -f "$source_file"
source_file="$(mktemp "$(vx_harbor_root)/observations/.obs.XXXXXX")"; jq -n --arg now "$now" '{SCHEMA:1,USED_MB:5,OBSERVED_AT:$now,GENERATION:"generation-1"}' >"$source_file"; vx_harbor_json_write_atomic "$(vx_harbor_root)/observations/alice.json" "$source_file"; rm -f "$source_file"
owner_path="$(vx_harbor_owner_state_path alice)"; source_file="$(mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")"; jq -n --arg now "$now" '{SCHEMA:1,OWNER:"alice",NAMESPACE:"vx-alice",PROJECT_ID:7,QUOTA_ID:9,QUOTA_MB:100,STATE:"runtime-ready",RUNTIME_ROBOT_ID:11,RUNTIME_USERNAME:"runtime",PUBLISHER_ROBOT_ID:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,LAST_ERROR:null,UPDATED_AT:$now}' >"$source_file"; vx_harbor_json_write_atomic "$owner_path" "$source_file"; rm -f "$source_file"
quota_record="$HARBOR_TEST_ROOT/quota"; vx_harbor_api_quota_set_bytes(){ printf '%s\t%s\n' "$1" "$2" >"$quota_record"; }; vx_compose_shell_access_transition_complete(){ return 0; }
vx_harbor_package_transition_recover alice
[[ "$(cat "$quota_record")" == $'9\t104857600' ]]; jq -e '.STATE=="converged"' "$operation" >/dev/null
collision="$(vx_harbor_owner_state_path bob)"; source_file="$(mktemp "$(vx_harbor_root)/owners/.owner.XXXXXX")"; jq --arg owner bob '.OWNER=$owner' "$owner_path" >"$source_file"; vx_harbor_json_write_atomic "$collision" "$source_file"; rm -f "$source_file"
! vx_harbor_namespace_collision_check charlie vx-alice
private_project='{"name":"vx-alice","project_id":7,"quota_id":9,"metadata":{"public":"false"}}'
public_project='{"name":"vx-alice","project_id":7,"quota_id":9,"metadata":{"public":"true"}}'
! _vx_harbor_owner_project_validate alice vx-alice "$owner_path.missing" "$private_project" existing
_vx_harbor_owner_project_validate alice vx-alice "$owner_path.missing" "$private_project" created
_vx_harbor_owner_project_validate alice vx-alice "$owner_path" "$private_project" existing
! _vx_harbor_owner_project_validate alice vx-alice "$owner_path" "$public_project" existing
! _vx_harbor_owner_project_validate alice vx-bob "$owner_path" "$private_project" existing
printf 'PASS: full owner mapping package recovery and collision rejection\n'
