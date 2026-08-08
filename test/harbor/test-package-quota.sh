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
printf "U_DOCKER_REGISTRY_MB='7'\nDOCKER_STORAGE_MB='99'\n" \
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
token="$(vx_harbor_package_transition_prepare alice 20)" \
    || fail 'disabled transition prepare failed'
[[ "$token" == *.* ]] || fail 'disabled transition token is not signed'
vx_harbor_package_transition_commit alice "$token" \
    || fail 'disabled transition commit failed'
vx_harbor_provider_lock_release

jq '.MODE = "managed"' "$VESTA/data/harbor/provider.json" \
    >"$VESTA/data/harbor/provider.next"
vx_harbor_json_write_atomic \
    "$VESTA/data/harbor/provider.json" "$VESTA/data/harbor/provider.next"
rm -f "$VESTA/data/harbor/provider.next"
cat >"$VESTA/data/harbor/observations/alice.json" <<'EOF'
{"USED_MB":15,"OBSERVED_AT":"2026-08-08T00:00:00Z"}
EOF
chmod 0600 "$VESTA/data/harbor/observations/alice.json"
cat >"$VESTA/data/harbor/owners/alice.json" <<'EOF'
{"QUOTA_MB":20}
EOF
chmod 0600 "$VESTA/data/harbor/owners/alice.json"
quota_log="$HARBOR_TEST_ROOT/quota.log"
vx_harbor_owner_quota_set() { printf '%s:%s\n' "$1" "$2" >>"$quota_log"; }

vx_harbor_provider_lock_acquire shared
if vx_harbor_package_transition_prepare alice 14 >/dev/null; then
    fail 'managed transition accepted quota below observed use'
fi
managed_token="$(vx_harbor_package_transition_prepare alice 25)" \
    || fail 'managed transition rejected a quota above observed use'
grep -Fxq 'alice:25' "$quota_log" \
    || fail 'managed transition did not prepare the Harbor quota'
vx_harbor_package_transition_rollback alice "$managed_token" \
    || fail 'managed transition rollback failed'
grep -Fxq 'alice:20' "$quota_log" \
    || fail 'managed transition rollback did not restore the prior quota'
rm -f "$VESTA/data/harbor/observations/alice.json"
if vx_harbor_package_transition_prepare alice 20 >/dev/null; then
    fail 'managed transition succeeded without observed usage'
fi
vx_harbor_provider_lock_release

printf 'Harbor package quota tests passed.\n'
