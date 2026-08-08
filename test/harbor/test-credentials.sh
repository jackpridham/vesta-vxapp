#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
create_counter="$HARBOR_TEST_ROOT/create"; probe_counter="$HARBOR_TEST_ROOT/probe"; switch_counter="$HARBOR_TEST_ROOT/switch"; delete_fail="$HARBOR_TEST_ROOT/fail"; printf 0 >"$create_counter"; printf 0 >"$probe_counter"; printf 0 >"$switch_counter"; touch "$delete_fail"
vx_harbor_api_robot_create(){ cat >"$HARBOR_TEST_ROOT/create-secret"; value="$(cat "$create_counter")"; printf '%s\n' "$((value+1))" >"$create_counter"; printf '{"id":31,"name":"runtime-new","disabled":false}\n'; }
vx_harbor_api_credential_probe(){ cat >"$HARBOR_TEST_ROOT/probe-secret"; value="$(cat "$probe_counter")"; printf '%s\n' "$((value+1))" >"$probe_counter"; [[ "$(cat "$HARBOR_TEST_ROOT/probe-secret")" == "$(cat "$HARBOR_TEST_ROOT/create-secret")" ]]; }
vx_harbor_runtime_credential_switch(){ value="$(cat "$switch_counter")"; printf '%s\n' "$((value+1))" >"$switch_counter"; }
vx_harbor_api_robot_delete(){ [[ ! -e "$delete_fail" ]]; }
result="$(vx_harbor_runtime_rotate alice vx-alice https://panel.example:8083 11 100)"
[[ "$result" == $'31\tvx-alice-runtime-100' && "$(cat "$create_counter")" == 1 && "$(cat "$probe_counter")" == 1 && "$(cat "$switch_counter")" == 1 ]]
rotation="$(vx_harbor_rotation_path alice runtime)"; jq -e '.PHASE=="pending-revoke" and .OLD_ROBOT_ID==11 and .NEW_ROBOT_ID==31' "$rotation" >/dev/null; operation="$(jq -r .OPERATION_ID "$rotation")"
rm -f "$delete_fail"; retry="$(vx_harbor_runtime_rotate alice vx-alice https://panel.example:8083 11 101)"
[[ "$retry" == $'31\tvx-alice-runtime-100' && "$(cat "$create_counter")" == 1 && "$(jq -r .OPERATION_ID "$rotation")" == "$operation" ]]
jq -e '.PHASE=="converged"' "$rotation" >/dev/null
printf 'PASS: runtime auth-switch-revoke retry\n'
