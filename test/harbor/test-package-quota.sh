#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
source "$test_dir/lib.sh"

trap cleanup_vesta_root EXIT
new_vesta_root
install_harbor_helpers
mkdir -p "$VESTA/data/users/alice"
printf "U_DOCKER_REGISTRY_MB='7'\nDOCKER_STORAGE_MB='99'\nRKEY='journal-secret-canary'\n" \
    >"$VESTA/data/users/alice/user.conf"

update_user_value() {
    local owner="$1" key="${2//\$/}" value="$3"
    sed -i "s/^${key}='[^']*'/${key}='${value}'/" \
        "$VESTA/data/users/$owner/user.conf"
}

source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
_vx_harbor_transition_access_restore() { :; }
access_group_state=no
access_deny_state=yes
_vx_harbor_transition_access_converge() {
    access_group_state=yes
    access_deny_state=no
}

vx_harbor_registry_usage_set alice 12 \
    || fail 'valid measured registry usage was rejected'
grep -Fq "U_DOCKER_REGISTRY_MB='12'" "$VESTA/data/users/alice/user.conf" \
    || fail 'measured registry usage was not persisted'
grep -Fq "DOCKER_STORAGE_MB='99'" "$VESTA/data/users/alice/user.conf" \
    || fail 'registry usage altered Compose storage usage'
for invalid in -1 01 unlimited malformed; do
    if vx_harbor_registry_usage_set alice "$invalid"; then
        fail "invalid measured registry usage was accepted: $invalid"
    fi
done

vx_harbor_provider_prepare
vx_harbor_provider_lock_acquire shared
disabled_stage="$HARBOR_TEST_ROOT/disabled.user.conf.next"
cp "$VESTA/data/users/alice/user.conf" "$disabled_stage"
printf "PACKAGE='disabled-next'\nDOCKER_REGISTRY_MB='20'\n" >>"$disabled_stage"
token="$(vx_harbor_package_transition_prepare \
    alice 20 disabled-next "$disabled_stage" /bin/bash no no)" \
    || fail 'disabled transition prepare failed'
[[ "$token" == *.* ]] || fail 'disabled transition token is not signed'
cp "$disabled_stage" "$VESTA/data/users/alice/user.conf"
vx_harbor_package_transition_user_conf_applied alice "$token" \
    || fail 'disabled transition did not accept the staged user state'
vx_harbor_package_transition_side_effects_applied alice "$token" \
    || fail 'disabled transition side effects could not be recorded'
vx_harbor_package_transition_commit alice "$token" \
    || fail 'disabled transition commit failed'
vx_harbor_package_transition_access_complete alice "$token" \
    || fail 'disabled transition access could not be completed'
vx_harbor_package_transition_finalize alice "$token" \
    || fail 'disabled transition could not be finalized'
vx_harbor_provider_lock_release

jq '.MODE = "managed"' "$VESTA/data/harbor/provider.json" \
    >"$VESTA/data/harbor/provider.next"
vx_harbor_json_write_atomic \
    "$VESTA/data/harbor/provider.json" "$VESTA/data/harbor/provider.next"
rm -f "$VESTA/data/harbor/provider.next"
observed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
cat >"$VESTA/data/harbor/observations/alice.json" <<EOF
{"USED_MB":15,"OBSERVED_AT":"$observed_at","GENERATION":"generation-1"}
EOF
chmod 0600 "$VESTA/data/harbor/observations/alice.json"
cat >"$VESTA/data/harbor/owners/alice.json" <<'EOF'
{"QUOTA_MB":20}
EOF
chmod 0600 "$VESTA/data/harbor/owners/alice.json"
quota_log="$HARBOR_TEST_ROOT/quota.log"
vx_harbor_owner_quota_set() {
    printf '%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >>"$quota_log"
}

transition_stage="$HARBOR_TEST_ROOT/user.conf.next"
cp "$VESTA/data/users/alice/user.conf" "$transition_stage"
sed -i "s/^PACKAGE=.*/PACKAGE='next'/; s/^DOCKER_REGISTRY_MB=.*/DOCKER_REGISTRY_MB='25'/" \
    "$transition_stage"

vx_harbor_provider_lock_acquire shared
if vx_harbor_package_transition_prepare \
    alice 14 next "$transition_stage" /bin/bash no no >/dev/null; then
    fail 'managed transition accepted quota below observed use'
fi
managed_token="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)" \
    || fail 'managed transition rejected a quota above observed use'
grep -Fxq "alice:25:generation-1:$observed_at" "$quota_log" \
    || fail 'managed transition did not prepare the Harbor quota'
vx_harbor_package_transition_rollback alice "$managed_token" \
    || fail 'managed transition rollback failed'
grep -Fq 'alice:20:generation-1:' "$quota_log" \
    || fail 'managed transition rollback did not restore the prior quota'

original_conf="$HARBOR_TEST_ROOT/user.conf.original"
cp "$VESTA/data/users/alice/user.conf" "$original_conf"
original_digest="$(sha256sum "$original_conf" | awk '{print $1}')"
new_digest="$(sha256sum "$transition_stage" | awk '{print $1}')"
abort_at=
concurrent_at=
_vx_harbor_transition_checkpoint() {
    if [[ "$1" == "$concurrent_at" ]]; then
        sed -i "s/^U_DOCKER_REGISTRY_MB='[^']*'/U_DOCKER_REGISTRY_MB='${concurrent_value}'/" \
            "$VESTA/data/users/alice/user.conf"
    fi
    [[ "$1" != "$abort_at" ]]
}

concurrent_at=journal-written
concurrent_value=99
if vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no >/dev/null; then
    fail 'prepare ignored user.conf mutation after coherent capture'
fi
concurrent_at=
vx_harbor_package_transition_recover alice \
    || fail 'capture-race recovery failed'
grep -Fq "U_DOCKER_REGISTRY_MB='99'" "$VESTA/data/users/alice/user.conf" \
    || fail 'capture-race recovery overwrote a fresh usage update'
cp "$original_conf" "$VESTA/data/users/alice/user.conf"

concurrent_token="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
vx_harbor_package_transition_user_conf_apply \
    alice "$concurrent_token" "$transition_stage" \
    || fail 'field-aware package apply failed'
sed -i "s/^U_DOCKER_REGISTRY_MB='[^']*'/U_DOCKER_REGISTRY_MB='77'/" \
    "$VESTA/data/users/alice/user.conf"
vx_harbor_package_transition_rollback alice "$concurrent_token" \
    || fail 'post-apply concurrent-writer rollback failed'
grep -Fq "PACKAGE='disabled-next'" "$VESTA/data/users/alice/user.conf" \
    || fail 'post-apply rollback did not restore package-controlled fields'
grep -Fq "U_DOCKER_REGISTRY_MB='77'" "$VESTA/data/users/alice/user.conf" \
    || fail 'post-apply rollback overwrote a concurrent usage update'
cp "$original_conf" "$VESTA/data/users/alice/user.conf"

recovery_token="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
vx_harbor_package_transition_user_conf_apply \
    alice "$recovery_token" "$transition_stage" \
    || fail 'recovery-race package apply failed'
concurrent_at=recovery-before-user-conf
concurrent_value=88
vx_harbor_package_transition_rollback alice "$recovery_token" \
    || fail 'during-recovery concurrent-writer rollback failed'
concurrent_at=
grep -Fq "PACKAGE='disabled-next'" "$VESTA/data/users/alice/user.conf" \
    || fail 'during-recovery merge did not restore package fields'
grep -Fq "U_DOCKER_REGISTRY_MB='88'" "$VESTA/data/users/alice/user.conf" \
    || fail 'during-recovery merge overwrote a fresh usage update'
cp "$original_conf" "$VESTA/data/users/alice/user.conf"

abort_at=journal-written
if vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no >/dev/null; then
    fail 'prepare survived abrupt termination before Harbor mutation'
fi
[[ "$(jq -r '.STATE' "$VESTA/data/harbor/transactions/alice.json")" == prepared ]] \
    || fail 'pre-mutation crash did not leave a prepared recovery journal'
[[ "$(stat -c '%u:%g:%a' "$VESTA/data/harbor/transactions/alice.json")" \
    == "$EUID:$(id -g):600" ]] \
    || fail 'transition journal authority or mode is invalid'
[[ "$(stat -c '%u:%g:%a' "$VESTA/data/harbor/transactions/alice.user.conf.before")" \
    == "$EUID:$(id -g):600" ]] \
    || fail 'transition preimage authority or mode is invalid'
if grep -Fq 'journal-secret-canary' "$VESTA/data/harbor/transactions/alice.json"; then
    fail 'transition journal contains user.conf secrets'
fi
abort_at=
vx_harbor_package_transition_recover alice \
    || fail 'pre-mutation journal recovery failed'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf" | awk '{print $1}')" == "$original_digest" ]] \
    || fail 'pre-mutation recovery changed user.conf'

abort_at=quota-mutated
if vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no >/dev/null; then
    fail 'prepare survived abrupt termination after Harbor mutation'
fi
[[ "$(jq -r '.STATE' "$VESTA/data/harbor/transactions/alice.json")" == prepared ]] \
    || fail 'post-quota crash lost its rollback journal'
abort_at=
vx_harbor_package_transition_recover alice \
    || fail 'post-quota crash recovery failed'
[[ "$(tail -n1 "$quota_log")" == alice:20:generation-1:* ]] \
    || fail 'post-quota recovery did not restore the old Harbor quota'

token_after_quota="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
cp "$transition_stage" "$VESTA/data/users/alice/user.conf"
vx_harbor_package_transition_recover alice \
    || fail 'post-user.conf-rename crash recovery failed'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf" | awk '{print $1}')" == "$original_digest" ]] \
    || fail 'post-user.conf-rename recovery did not restore user.conf'

transition_now="$(date -u +%s)"
_vx_harbor_now_epoch() { printf '%s\n' "$transition_now"; }
expired_token="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
transition_now=$((transition_now + VX_HARBOR_TRANSITION_TTL_SECONDS + 1))
if vx_harbor_package_transition_user_conf_applied alice "$expired_token"; then
    fail 'expired transition token was accepted'
fi
vx_harbor_package_transition_recover alice \
    || fail 'expired transition recovery failed'

token_after_state="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
cp "$transition_stage" "$VESTA/data/users/alice/user.conf"
vx_harbor_package_transition_user_conf_applied alice "$token_after_state" \
    || fail 'user.conf-applied state could not be recorded'
vx_harbor_package_transition_recover alice \
    || fail 'post-user.conf-state crash recovery failed'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf" | awk '{print $1}')" == "$original_digest" ]] \
    || fail 'post-user.conf-state recovery did not restore user.conf'

token_committed="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
cp "$transition_stage" "$VESTA/data/users/alice/user.conf"
vx_harbor_package_transition_user_conf_applied alice "$token_committed" \
    || fail 'committed-boundary user state could not be recorded'
vx_harbor_package_transition_side_effects_applied alice "$token_committed" \
    || fail 'committed-boundary side effects could not be recorded'
abort_at=committed
if vx_harbor_package_transition_commit alice "$token_committed"; then
    fail 'commit checkpoint did not simulate abrupt termination'
fi
[[ "$(jq -r '.STATE' "$VESTA/data/harbor/transactions/alice.json")" == committed ]] \
    || fail 'post-commit crash did not retain committed journal state'
abort_at=
vx_harbor_package_transition_recover alice \
    || fail 'post-commit recovery failed'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf" | awk '{print $1}')" == "$new_digest" ]] \
    || fail 'post-commit recovery rolled back committed user.conf'
[[ "$access_group_state" == yes && "$access_deny_state" == no ]] \
    || fail 'committed recovery did not converge shell access state'
if vx_harbor_package_transition_commit alice "$token_committed"; then
    fail 'single-use transition token was accepted after recovery'
fi

cp "$original_conf" "$VESTA/data/users/alice/user.conf"
access_group_state=no
access_deny_state=yes
token_access_crash="$(vx_harbor_package_transition_prepare \
    alice 25 next "$transition_stage" /bin/bash no no)"
vx_harbor_package_transition_user_conf_apply \
    alice "$token_access_crash" "$transition_stage"
vx_harbor_package_transition_side_effects_applied alice "$token_access_crash"
vx_harbor_package_transition_commit alice "$token_access_crash"
abort_at=access-converged
if vx_harbor_package_transition_access_complete alice "$token_access_crash"; then
    fail 'access-completion crash checkpoint did not fire'
fi
abort_at=
vx_harbor_package_transition_recover alice \
    || fail 'post-access-convergence crash recovery failed'
[[ "$access_group_state" == yes && "$access_deny_state" == no ]] \
    || fail 'post-access-convergence recovery lost correct access state'

# Return to the old state for observation-validation cases.
cp "$original_conf" "$VESTA/data/users/alice/user.conf"
rm -f "$VESTA/data/harbor/observations/alice.json"
if vx_harbor_package_transition_prepare \
    alice 20 next "$transition_stage" /bin/bash no no >/dev/null; then
    fail 'managed transition succeeded without observed usage'
fi

for invalid_observation in stale future missing-generation; do
    case "$invalid_observation" in
        stale) invalid_at="$(date -u -d '10 minutes ago' +'%Y-%m-%dT%H:%M:%SZ')"; generation=generation-2 ;;
        future) invalid_at="$(date -u -d '10 minutes' +'%Y-%m-%dT%H:%M:%SZ')"; generation=generation-3 ;;
        missing-generation) invalid_at="$observed_at"; generation= ;;
    esac
    jq -n --arg at "$invalid_at" --arg generation "$generation" \
        '{USED_MB:15,OBSERVED_AT:$at} +
        (if $generation == "" then {} else {GENERATION:$generation} end)' \
        >"$VESTA/data/harbor/observations/alice.json"
    chmod 0600 "$VESTA/data/harbor/observations/alice.json"
    if vx_harbor_package_transition_prepare \
        alice 25 next "$transition_stage" /bin/bash no no >/dev/null; then
        fail "managed transition accepted $invalid_observation observation"
    fi
done

declare -F vx_harbor_package_transition_recover >/dev/null \
    || fail 'durable package transition recovery helper is missing'
vx_harbor_provider_lock_release

printf 'Harbor package quota tests passed.\n'
