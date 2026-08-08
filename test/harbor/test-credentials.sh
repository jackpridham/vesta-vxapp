#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ id -g; }; _vx_harbor_secure_file_set(){ chmod "$2" "$1"; }
vx_harbor_provider_prepare
vx_compose_registry_root(){ printf '%s/data/users/%s/docker-registry\n' "$VESTA" "$1"; }
vx_compose_registry_prepare(){ root="$(vx_compose_registry_root "$1")"; mkdir -p "$root/home"; chmod 0700 "$root" "$root/home"; [[ -f "$root/config.json" ]] || printf '{"auths":{}}\n' >"$root/config.json"; [[ -f "$root/registries.json" ]] || printf '{}\n' >"$root/registries.json"; chmod 0600 "$root/config.json" "$root/registries.json"; }
create_count="$HARBOR_TEST_ROOT/create"; delete_log="$HARBOR_TEST_ROOT/delete"; printf 0 >"$create_count"; : >"$delete_log"
vx_harbor_api_robot_create(){ secret="$(cat)"; [[ ${#secret} -ge 16 ]]; value="$(cat "$create_count")"; value=$((value+1)); printf '%s\n' "$value" >"$create_count"; printf '{"id":%s,"name":"%s","disabled":false}\n' "$((30+value))" "$2"; }
vx_harbor_api_credential_probe(){ [[ "$(cat)" == runtime-secret-0123456789abcdef ]]; }
vx_harbor_api_robot_delete(){ printf '%s\n' "$1" >>"$delete_log"; }
_vx_harbor_random_secret(){ printf %s runtime-secret-0123456789abcdef; }
prepare_owner(){ mkdir -p "$VESTA/data/users/$1"; vx_compose_registry_prepare "$1"; }

# Journal publication failure leaves active registry authority untouched.
prepare_owner journalfail; fail_journal=yes
_vx_harbor_json_write_phase(){ [[ "${fail_journal:-no}" != yes ]]; }
! vx_harbor_runtime_rotate journalfail vx-journalfail https://panel.example:8083 11 100 >/dev/null
[[ ! -e "$(vx_harbor_rotation_path journalfail runtime)" ]]
jq -e '.auths=={}' "$(vx_compose_registry_root journalfail)/config.json" >/dev/null
fail_journal=no

# Crash after durable journal publication recovers without another robot.
prepare_owner crashjournal; crash_point=journal-published
_vx_harbor_rotation_checkpoint(){ [[ "$1:$2" != "runtime:$crash_point" ]]; }
! vx_harbor_runtime_rotate crashjournal vx-crashjournal https://panel.example:8083 12 101 >/dev/null
journal="$(vx_harbor_rotation_path crashjournal runtime)"; jq -e '.PHASE=="pending-switch" and .OLD_ROBOT_ID==12' "$journal" >/dev/null; before="$(cat "$create_count")"
crash_point=none; result="$(vx_harbor_runtime_rotate crashjournal vx-crashjournal https://panel.example:8083 12 102)"
[[ "$(cat "$create_count")" == "$before" && "$result" == $'32\tvx-crashjournal-runtime-101' ]]; jq -e '.PHASE=="converged"' "$journal" >/dev/null

# Crash after authority switch is idempotently replayed from pending-switch.
prepare_owner crashswitch; crash_point=authority-switched
! vx_harbor_runtime_rotate crashswitch vx-crashswitch https://panel.example:8083 13 103 >/dev/null
journal="$(vx_harbor_rotation_path crashswitch runtime)"; jq -e '.PHASE=="pending-switch"' "$journal" >/dev/null
jq -e '.["panel.example:8083"].USERNAME=="vx-crashswitch-runtime-103"' "$(vx_compose_registry_root crashswitch)/registries.json" >/dev/null; before="$(cat "$create_count")"; mapping_hash="$(sha256sum "$(vx_compose_registry_root crashswitch)/config.json" "$(vx_compose_registry_root crashswitch)/registries.json")"
crash_point=none; vx_harbor_runtime_rotate crashswitch vx-crashswitch https://panel.example:8083 13 104 >/dev/null
[[ "$(cat "$create_count")" == "$before" && "$(sha256sum "$(vx_compose_registry_root crashswitch)/config.json" "$(vx_compose_registry_root crashswitch)/registries.json")" == "$mapping_hash" ]]; jq -e '.PHASE=="converged"' "$journal" >/dev/null
jq -e 'select(.OPERATION=="runtime-rotation" and .RESULT=="failed") | .REASON|IN("journal","switch")' "$(vx_harbor_root)/audit.log" >/dev/null || fail 'runtime failures were not enum-audited'
! grep -Fq runtime-secret-0123456789abcdef "$(vx_harbor_root)/audit.log" || fail 'runtime secret entered audit'
prepare_owner revokeaudit; vx_harbor_api_robot_disable(){ return 1; }
! vx_harbor_runtime_revoke revokeaudit https://panel.example:8083 99
jq -e 'select(.OPERATION=="runtime-revocation" and .RESULT=="failed" and .REASON=="outage")' "$(vx_harbor_root)/audit.log" >/dev/null || fail 'runtime revocation failure was not audited'
printf 'PASS: runtime journal-before-switch crash recovery\n'
