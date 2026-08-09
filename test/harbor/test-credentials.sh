#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }
_vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid(){ id -g; }
_vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
vx_compose_registry_root(){ printf '%s/data/users/%s/docker-registry\n' "$VESTA" "$1"; }
vx_compose_registry_prepare(){
    local root
    root="$(vx_compose_registry_root "$1")"; mkdir -p "$root/home"; chmod 0700 "$root" "$root/home"
    [[ -f "$root/config.json" ]] || printf '{"auths":{}}\n' >"$root/config.json"
    [[ -f "$root/registries.json" ]] || printf '{}\n' >"$root/registries.json"
    chmod 0600 "$root/config.json" "$root/registries.json"
}

create_count="$HARBOR_TEST_ROOT/create"; delete_log="$HARBOR_TEST_ROOT/delete"
printf 0 >"$create_count"; : >"$delete_log"
runtime_secret='runtime-secret-0123456789abcdef'
_vx_harbor_api_project_robot_create_secret_once(){
    local project="$1" namespace="$2" basename="$3" marker="$4" access="$5" value
    [[ "$project" == 7 && "$access" == pull && "$marker" == "vesta-managed:vesta-harbor:${namespace#vx-}:runtime:${basename#runtime-}" ]]
    value="$(<"$create_count")"; value=$((value+1)); printf '%s\n' "$value" >"$create_count"
    jq -cn --arg name "robot\$$namespace+$basename" --arg secret "$runtime_secret" --argjson id "$((30+value))" \
      '{creation_time:"2026-08-09T00:00:00Z",expires_at:-1,id:$id,name:$name,secret:$secret}'
}
vx_harbor_api_credential_probe(){ [[ "$(cat)" == "$runtime_secret" ]]; }
vx_harbor_api_project_robot_find(){ return 4; }
vx_harbor_api_project_robots_list(){ printf '[]\n'; }
vx_harbor_api_project_robot_delete(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$delete_log"; }
prepare_owner(){ mkdir -p "$VESTA/data/users/$1"; vx_compose_registry_prepare "$1"; }

# A failure before the prepared journal is durable creates no Harbor robot.
prepare_owner journalfail; fail_journal=yes
_vx_harbor_json_write_phase(){ [[ "${fail_journal:-no}" != yes ]]; }
! vx_harbor_runtime_rotate journalfail vx-journalfail 7 https://panel.example:8083 null >/dev/null
[[ ! -e "$(vx_harbor_rotation_path journalfail runtime)" && "$(<"$create_count")" == 0 ]]
fail_journal=no

# A crash after the generated secret is staged resumes without another create.
prepare_owner crashjournal; crash_point=journal-published
_vx_harbor_rotation_checkpoint(){ [[ "$1:$2" != "runtime:$crash_point" ]]; }
! vx_harbor_runtime_rotate crashjournal vx-crashjournal 7 https://panel.example:8083 null >/dev/null
journal="$(vx_harbor_rotation_path crashjournal runtime)"
jq -e '.SCHEMA==2 and .PHASE=="candidate-created" and .PROJECT_ID==7 and .OLD_ROBOT_ID==null' "$journal" >/dev/null
before="$(<"$create_count")"; crash_point=none
result="$(vx_harbor_runtime_rotate crashjournal vx-crashjournal 7 https://panel.example:8083 null)"
[[ "$(<"$create_count")" == "$before" && "$result" == $'31\trobot$vx-crashjournal+runtime-'* ]]
jq -e '.PHASE=="converged"' "$journal" >/dev/null

# A crash after the auth switch replays the same staged generation.
prepare_owner crashswitch; crash_point=authority-switched
! vx_harbor_runtime_rotate crashswitch vx-crashswitch 7 https://panel.example:8083 null >/dev/null
journal="$(vx_harbor_rotation_path crashswitch runtime)"
jq -e '.PHASE=="pending-switch"' "$journal" >/dev/null
jq -e '.["panel.example:8083"].USERNAME|startswith("robot$vx-crashswitch+runtime-")' \
  "$(vx_compose_registry_root crashswitch)/registries.json" >/dev/null
before="$(<"$create_count")"; mapping_hash="$(sha256sum "$(vx_compose_registry_root crashswitch)/config.json" "$(vx_compose_registry_root crashswitch)/registries.json")"
crash_point=none
vx_harbor_runtime_rotate crashswitch vx-crashswitch 7 https://panel.example:8083 null >/dev/null
[[ "$(<"$create_count")" == "$before" && "$(sha256sum "$(vx_compose_registry_root crashswitch)/config.json" "$(vx_compose_registry_root crashswitch)/registries.json")" == "$mapping_hash" ]]
jq -e '.PHASE=="converged"' "$journal" >/dev/null
! grep -Fq "$runtime_secret" "$(vx_harbor_root)/audit.log" || fail 'runtime secret entered audit'

prepare_owner revokeaudit; vx_harbor_api_robot_disable(){ return 1; }
! vx_harbor_runtime_revoke revokeaudit https://panel.example:8083 99
jq -e 'select(.OPERATION=="runtime-revocation" and .RESULT=="failed" and .REASON=="outage")' "$(vx_harbor_root)/audit.log" >/dev/null || fail 'runtime revocation failure was not audited'
printf 'PASS: generated runtime credential rotation recovery\n'
