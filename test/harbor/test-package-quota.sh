#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$test_dir/lib.sh"
api_pid=
cleanup() {
    [[ -z "$api_pid" ]] || { kill "$api_pid" 2>/dev/null || :; wait "$api_pid" 2>/dev/null || :; }
    cleanup_vesta_root
}
trap cleanup EXIT
new_vesta_root
install_harbor_helpers
mkdir -p "$VESTA/data/users/alice"
printf "PACKAGE='starter'\nDOCKER_REGISTRY_MB='20'\nU_DOCKER_REGISTRY_MB='7'\nDOCKER_STORAGE_MB='99'\n" >"$VESTA/data/users/alice/user.conf"
update_user_value() { sed -i "s/^${2//\$/}='[^']*'/${2//\$/}='$3'/" "$VESTA/data/users/$1/user.conf"; }
source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
fake_socket="$HARBOR_TEST_ROOT/harbor.sock"
vx_harbor_local_socket_path() { printf '%s\n' "$fake_socket"; }
vx_harbor_provider_prepare

vx_harbor_registry_usage_set alice 12
grep -Fq "U_DOCKER_REGISTRY_MB='12'" "$VESTA/data/users/alice/user.conf" || fail 'usage not persisted'
grep -Fq "DOCKER_STORAGE_MB='99'" "$VESTA/data/users/alice/user.conf" || fail 'usage altered storage'

access_calls=0
vx_compose_shell_access_transition_complete() { access_calls=$((access_calls + 1)); }
operation_id="$(vx_harbor_package_transition_publish alice starter 20)"
operation="$VESTA/data/harbor/operations/alice.json"
vx_harbor_package_operation_validate "$operation" || fail 'invalid operation schema'
[[ "$(jq -r '.DESIRED_REGISTRY_MB|type' "$operation")" == string ]] || fail 'quota is not serialized as a string'
if jq '.DESIRED_REGISTRY_MB=20' "$operation" >"$HARBOR_TEST_ROOT/numeric.json" && \
   chmod 0600 "$HARBOR_TEST_ROOT/numeric.json" && \
   vx_harbor_package_operation_validate "$HARBOR_TEST_ROOT/numeric.json"; then
    fail 'numeric desired quota passed exact schema'
fi
vx_harbor_package_transition_recover alice
[[ "$(jq -r '.STATE' "$operation")" == converged && "$access_calls" == 1 ]] || fail 'disabled convergence failed'

# Publication failure leaves Vesta desired state untouched.
staged="$VESTA/data/users/alice/.user.conf.new.failure"
sed "s/PACKAGE='starter'/PACKAGE='failure'/;s/DOCKER_REGISTRY_MB='20'/DOCKER_REGISTRY_MB='21'/" \
    "$VESTA/data/users/alice/user.conf" >"$staged"
chmod --reference="$VESTA/data/users/alice/user.conf" "$staged"
before="$(sha256sum "$VESTA/data/users/alice/user.conf")"
ln "$operation" "$HARBOR_TEST_ROOT/operation-hardlink.json"
if vx_harbor_package_transition_install_desired alice failure 21 "$staged" \
    "$VESTA/data/users/alice/user.conf" 2>/dev/null; then
    fail 'publication failure installed desired state'
fi
rm -f -- "$HARBOR_TEST_ROOT/operation-hardlink.json"
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf")" == "$before" ]] || fail 'publication failure changed user.conf'
rm -f -- "$staged"

# A crash after operation publication never mutates external or shell state.
staged="$VESTA/data/users/alice/.user.conf.new.crash"
sed "s/PACKAGE='starter'/PACKAGE='crash'/;s/DOCKER_REGISTRY_MB='20'/DOCKER_REGISTRY_MB='22'/" \
    "$VESTA/data/users/alice/user.conf" >"$staged"
chmod --reference="$VESTA/data/users/alice/user.conf" "$staged"
_vx_harbor_package_transition_checkpoint() { return 1; }
if vx_harbor_package_transition_install_desired alice crash 22 "$staged" \
    "$VESTA/data/users/alice/user.conf"; then fail 'publication checkpoint did not interrupt'; fi
[[ "$(jq -r '.STATE' "$operation")" == pending ]] || fail 'publication crash lost pending operation'
if vx_harbor_package_transition_recover alice; then fail 'mismatched desired state reconciled'; fi
[[ "$(jq -r '.STATE,.LAST_ERROR' "$operation")" == $'failed\ndesired-state-mismatch' ]] || fail 'stale operation not marked safely'
[[ "$access_calls" == 1 ]] || fail 'stale operation changed shell access'
_vx_harbor_package_transition_checkpoint() { :; }
operation_id="$(vx_harbor_package_transition_install_desired alice crash 22 "$staged" \
    "$VESTA/data/users/alice/user.conf")"
vx_harbor_package_transition_recover alice
[[ "$(jq -r '.STATE' "$operation")" == converged ]] || fail 'same operation did not resume after publication crash'

jq '.MODE="managed"' "$VESTA/data/harbor/provider.json" >"$HARBOR_TEST_ROOT/provider.next"
vx_harbor_json_write_atomic "$VESTA/data/harbor/provider.json" "$HARBOR_TEST_ROOT/provider.next"
observed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf '{"USED_MB":15,"OBSERVED_AT":"%s","GENERATION":"g1"}\n' "$observed_at" >"$VESTA/data/harbor/observations/alice.json"
printf '{"SCHEMA":1,"OWNER":"alice","QUOTA_ID":1}\n' >"$VESTA/data/harbor/owners/alice.json"
printf 'silent\nshow-error\nuser = "integration:fixture-credential-canary"\n' >"$VESTA/data/harbor/secrets/integration.curl"
chmod 0600 "$VESTA/data/harbor/observations/alice.json" "$VESTA/data/harbor/owners/alice.json" "$VESTA/data/harbor/secrets/integration.curl"
state_file="$HARBOR_TEST_ROOT/api-state.json"
printf '{"configurations":{},"projects":[{"id":1,"name":"vx-alice","project_id":1,"metadata":{"public":"false"},"quota_id":1}],"quotas":[{"id":1,"ref":{"id":1},"hard":{"storage":-1},"used":{"storage":0}}],"robots":[],"artifacts":{},"volumes":{"storage":{"total":0,"free":0}},"next_project_id":2,"next_quota_id":2,"next_robot_id":1}\n' >"$state_file"
credential="$HARBOR_TEST_ROOT/credential.json"
printf '{"username":"integration","password":"fixture-credential-canary"}\n' >"$credential"
chmod 0600 "$credential"
ready="$HARBOR_TEST_ROOT/api.ready"
start_api() {
    : >"$ready"
    python3 "$test_dir/fixtures/fake-harbor-api.py" --unix-socket "$fake_socket" \
      --state "$state_file" --log "$HARBOR_TEST_ROOT/api.log" \
      --credential-file "$credential" --ready-file "$ready" &
    api_pid=$!
    for _ in $(seq 1 50); do [[ -S "$fake_socket" && -s "$ready" ]] && return; sleep 0.1; done
    fail 'Unix-socket fake Harbor did not start'
}
stop_api() { kill "$api_pid"; wait "$api_pid" 2>/dev/null || :; api_pid=; }

if vx_harbor_package_transition_check alice small 14; then fail 'decrease below fresh usage accepted'; fi
staged="$VESTA/data/users/alice/.user.conf.new.larger"
sed "s/PACKAGE='crash'/PACKAGE='larger'/;s/DOCKER_REGISTRY_MB='22'/DOCKER_REGISTRY_MB='25'/" \
  "$VESTA/data/users/alice/user.conf" >"$staged"
chmod --reference="$VESTA/data/users/alice/user.conf" "$staged"
managed_id="$(vx_harbor_package_transition_install_desired alice larger 25 "$staged" "$VESTA/data/users/alice/user.conf")"
if vx_harbor_package_transition_recover alice; then fail 'unavailable API converged'; fi
[[ "$(jq -r '.STATE,.LAST_ERROR' "$operation")" == $'pending\nprovider-unavailable' ]] || fail 'outage not pending'
start_api
vx_harbor_package_transition_recover alice
[[ "$(jq -r '.STATE' "$operation")" == converged ]] || fail 'real quota adapter did not converge'
[[ "$(jq -r '.quotas[0].hard.storage' "$state_file")" == 26214400 ]] || fail 'fake Harbor quota was not set'
grep -Fxq 'PUT /api/v2.0/quotas/1 200' "$HARBOR_TEST_ROOT/api.log" || fail 'narrow quota path not used'
stop_api

staged="$VESTA/data/users/alice/.user.conf.new.terminal"
sed "s/PACKAGE='larger'/PACKAGE='terminal'/;s/DOCKER_REGISTRY_MB='25'/DOCKER_REGISTRY_MB='30'/" \
  "$VESTA/data/users/alice/user.conf" >"$staged"
chmod --reference="$VESTA/data/users/alice/user.conf" "$staged"
vx_harbor_package_transition_install_desired alice terminal 30 "$staged" "$VESTA/data/users/alice/user.conf" >/dev/null
for _ in 1 2 3; do vx_harbor_package_transition_recover alice || :; done
[[ "$(jq -r '.STATE,.ATTEMPTS,.LAST_ERROR' "$operation")" == $'failed\n3\nretry-limit' ]] || fail 'bounded retry not terminal'
if vx_harbor_package_transition_publish alice other 40 >/dev/null 2>&1; then fail 'failed operation did not block conflict'; fi
[[ "$(vx_harbor_package_transition_publish alice terminal 30)" == "$(jq -r '.OPERATION_ID' "$operation")" ]] || fail 'same desired retry changed ID'

printf 'PASS: Harbor package forward reconciliation\n'
