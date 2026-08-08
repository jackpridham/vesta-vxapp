#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$test_dir/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root
install_harbor_helpers
mkdir -p "$VESTA/data/users/alice"
printf "U_DOCKER_REGISTRY_MB='7'\nDOCKER_STORAGE_MB='99'\n" >"$VESTA/data/users/alice/user.conf"
update_user_value() { sed -i "s/^${2//\$/}='[^']*'/${2//\$/}='$3'/" "$VESTA/data/users/$1/user.conf"; }
source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
vx_harbor_provider_prepare

vx_harbor_registry_usage_set alice 12
grep -Fq "U_DOCKER_REGISTRY_MB='12'" "$VESTA/data/users/alice/user.conf" || fail 'usage not persisted'
grep -Fq "DOCKER_STORAGE_MB='99'" "$VESTA/data/users/alice/user.conf" || fail 'usage altered storage'

access_calls=0
vx_compose_shell_access_transition_complete() { access_calls=$((access_calls + 1)); }
vx_harbor_package_transition_check alice starter 20
operation_id="$(vx_harbor_package_transition_publish alice starter 20)"
[[ "$operation_id" =~ ^[a-f0-9]{32}$ ]] || fail 'invalid operation ID'
operation="$VESTA/data/harbor/operations/alice.json"
vx_harbor_package_operation_validate "$operation" || fail 'invalid operation schema'
[[ "$(jq -r '.STATE' "$operation")" == pending ]] || fail 'operation not pending before reconcile'
vx_harbor_package_transition_recover alice
[[ "$(jq -r '.STATE' "$operation")" == converged ]] || fail 'disabled mode did not converge'
[[ "$access_calls" == 1 ]] || fail 'disabled mode did not converge shell access'

jq '.MODE="managed"' "$VESTA/data/harbor/provider.json" >"$HARBOR_TEST_ROOT/provider.next"
vx_harbor_json_write_atomic "$VESTA/data/harbor/provider.json" "$HARBOR_TEST_ROOT/provider.next"
observed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '{"USED_MB":15,"OBSERVED_AT":"%s","GENERATION":"g1"}\n' "$observed_at" >"$VESTA/data/harbor/observations/alice.json"
chmod 0600 "$VESTA/data/harbor/observations/alice.json"
if vx_harbor_package_transition_check alice small 14; then fail 'decrease below fresh usage accepted'; fi
[[ "$(jq -r '.DESIRED_PACKAGE' "$operation")" == starter ]] || fail 'rejected decrease published desired operation'

new_id="$(vx_harbor_package_transition_publish alice larger 25)"
quota_calls=0
vx_harbor_owner_quota_set() { quota_calls=$((quota_calls + 1)); return 1; }
if vx_harbor_package_transition_recover alice; then fail 'provider outage converged'; fi
[[ "$(jq -r '.STATE,.ATTEMPTS,.LAST_ERROR' "$operation")" == $'pending\n1\nprovider-unavailable' ]] || fail 'outage not pending'
[[ "$(vx_harbor_package_transition_publish alice larger 25)" == "$new_id" ]] || fail 'retry changed operation ID'
if vx_harbor_package_transition_publish alice conflict 30 >/dev/null 2>&1; then fail 'conflicting change accepted'; fi

vx_harbor_owner_quota_set() { printf '%s:%s:%s:%s:%s:%s\n' "$@" >"$HARBOR_TEST_ROOT/quota.log"; }
vx_harbor_package_transition_recover alice
[[ "$(jq -r '.STATE' "$operation")" == converged ]] || fail 'success did not converge'
grep -Fq "alice:25:g1:$observed_at:$new_id:forward" "$HARBOR_TEST_ROOT/quota.log" || fail 'quota setter arguments wrong'

vx_harbor_package_transition_publish alice terminal 30 >/dev/null
vx_harbor_owner_quota_set() { return 1; }
for _ in 1 2 3; do vx_harbor_package_transition_recover alice || :; done
[[ "$(jq -r '.STATE,.ATTEMPTS,.LAST_ERROR' "$operation")" == $'failed\n3\nretry-limit' ]] || fail 'bounded retry not terminal'
if vx_harbor_package_transition_publish alice other 40 >/dev/null 2>&1; then fail 'failed operation did not block conflict'; fi
[[ "$(vx_harbor_package_transition_publish alice terminal 30)" == "$(jq -r '.OPERATION_ID' "$operation")" ]] || fail 'failed operation resume changed ID'
[[ "$(jq -r '.STATE,.ATTEMPTS' "$operation")" == $'pending\n0' ]] || fail 'same desired operation did not resume'

printf 'PASS: Harbor package forward reconciliation\n'
