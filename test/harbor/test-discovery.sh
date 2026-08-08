#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare; mkdir -p "$VESTA/data/users/alice"; printf "PACKAGE='docker'\nSUSPENDED='no'\nDOCKER_PROJECTS='1'\nDOCKER_REGISTRY_MB='100'\n" >"$VESTA/data/users/alice/user.conf"
write_json(){ destination="$1"; json="$2"; directory="$(dirname "$destination")"; temporary="$(mktemp "$directory/.test.XXXXXX")"; printf '%s\n' "$json" >"$temporary"; vx_harbor_json_write_atomic "$destination" "$temporary"; rm -f "$temporary"; }
provider="$(vx_harbor_root)/provider.json"; write_json "$provider" "$(jq '.MODE="managed"|.ORIGIN="https://panel.example:8083"' "$provider")"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; stale="$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"; owner_path="$(vx_harbor_owner_state_path alice)"
write_json "$owner_path" "$(jq -n --arg now "$now" '{SCHEMA:1,OWNER:"alice",NAMESPACE:"vx-alice",PROJECT_ID:1,QUOTA_ID:1,QUOTA_MB:100,STATE:"runtime-ready",RUNTIME_ROBOT_ID:2,RUNTIME_USERNAME:"runtime",PUBLISHER_ROBOT_ID:null,PUBLISHER_USERNAME:null,PUBLISHER_ENABLED:false,LAST_ERROR:null,UPDATED_AT:$now}')"
write_json "$(vx_harbor_root)/observations/alice.json" "$(jq -n --arg now "$now" '{SCHEMA:1,GENERATION:"g1",OBSERVED_AT:$now,USED_MB:7}')"
write_json "$(vx_harbor_root)/observations/provider.json" "$(jq -n --arg now "$now" '{SCHEMA:1,HEALTH:"healthy",OBSERVED_AT:$now}')"
info="$(vx_harbor_registry_info_json alice shop)"; jq -e 'keys==["FRESHNESS","HEALTH","MANAGED","NAMESPACE","OBSERVED_AT","PUBLISHER_ENABLED","PUBLISHER_USERNAME","QUOTA_MB","REGISTRY","REPOSITORY","STATE","USED_MB"] and .STATE=="ready" and .HEALTH=="healthy" and .FRESHNESS=="fresh" and .USED_MB==7' <<<"$info" >/dev/null
write_json "$(vx_harbor_root)/observations/alice.json" "$(jq -n --arg stale "$stale" '{SCHEMA:1,GENERATION:"g2",OBSERVED_AT:$stale,USED_MB:8}')"; info="$(vx_harbor_registry_info_json alice shop)"; jq -e '.FRESHNESS=="stale" and .HEALTH=="degraded" and .USED_MB==8' <<<"$info" >/dev/null
write_json "$(vx_harbor_root)/observations/provider.json" "$(jq -n --arg stale "$stale" '{SCHEMA:1,HEALTH:"healthy",OBSERVED_AT:$stale}')"; info="$(vx_harbor_registry_info_json alice shop)"; jq -e '.HEALTH=="unavailable" and .FRESHNESS=="stale"' <<<"$info" >/dev/null
write_json "$(vx_harbor_root)/observations/provider.json" "$(jq -n --arg now "$now" '{SCHEMA:1,HEALTH:"degraded",OBSERVED_AT:$now}')"; info="$(vx_harbor_registry_info_json alice shop)"; jq -e '.HEALTH=="degraded"' <<<"$info" >/dev/null
! grep -Eq 'ROBOT_ID|PROJECT_ID|QUOTA_ID|secret|auth' <<<"$info"
printf 'PASS: exact registry discovery freshness and health\n'
