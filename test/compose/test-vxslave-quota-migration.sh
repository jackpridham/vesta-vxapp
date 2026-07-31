#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

source_package="$test_root/current-vxslave.pkg"
cat >"$source_package" <<'EOF'
WEB_DOMAINS='unlimited'
DNS_DOMAINS='4'
MAIL_DOMAINS='2'
DATABASES='3'
DOCKER_PROJECTS='unlimited'
DOCKER_SERVICES='unlimited'
DOCKER_CPUS='unlimited'
DOCKER_MEMORY_MB='unlimited'
DOCKER_PIDS='unlimited'
DOCKER_STORAGE_MB='unlimited'
DOCKER_PORTS='unlimited'
DOCKER_SECRETS='unlimited'
DOCKER_VOLUMES='unlimited'
BACKUPS='5'
EOF
source_bytes="$(sha256sum "$source_package" | awk '{print $1}')"
source_user="$test_root/prior-user.conf"
cat >"$source_user" <<'EOF'
PACKAGE='existing-vxslave'
DOCKER_PROJECTS='unlimited'
DOCKER_SERVICES='unlimited'
DOCKER_CPUS='unlimited'
DOCKER_MEMORY_MB='unlimited'
DOCKER_PIDS='unlimited'
DOCKER_STORAGE_MB='unlimited'
DOCKER_PORTS='unlimited'
DOCKER_SECRETS='unlimited'
DOCKER_VOLUMES='unlimited'
U_DOCKER_PROJECTS='1'
U_DOCKER_SERVICES='1'
U_DOCKER_CPUS='1.000'
U_DOCKER_MEMORY_MB='1024'
U_DOCKER_PIDS='256'
U_DOCKER_STORAGE_MB='1024'
U_DOCKER_PORTS='1'
U_DOCKER_SECRETS='1'
U_DOCKER_VOLUMES='2'
EOF
source_user_bytes="$(sha256sum "$source_user" | awk '{print $1}')"
output_dir="$test_root/prepared"
"$repo_root/install/migrations/vxslave-compose-quota/prepare.sh" \
    "$source_package" "$source_user" "$output_dir" existing-vxslave \
    >"$test_root/prepare.out"

[[ "$(sha256sum "$output_dir/rollback.pkg" | awk '{print $1}')" \
    == "$source_bytes" ]] || fail 'rollback package was not byte exact'
for line in \
    "WEB_DOMAINS='unlimited'" \
    "DNS_DOMAINS='4'" \
    "MAIL_DOMAINS='2'" \
    "DATABASES='3'" \
    "BACKUPS='5'"; do
    grep -Fxq "$line" "$output_dir/vxslave-compose.pkg" \
        || fail "non-Docker package field changed: $line"
done
cmp -s \
    "$repo_root/install/migrations/vxslave-compose-quota/docker-quota.conf" \
    <(grep '^DOCKER_' "$output_dir/vxslave-compose.pkg") \
    || fail 'candidate does not contain the exact approved Docker limits'
grep -Fq 'v-add-user-package' "$output_dir/apply-and-rollback.txt" \
    || fail 'exact apply command was not emitted'
grep -Fq 'v-update-user-counters slave' \
    "$output_dir/apply-and-rollback.txt" \
    || fail 'exact counter recalculation command was not emitted'
grep -Fq "rollback.sh '$output_dir' slave 'existing-vxslave'" \
    "$output_dir/apply-and-rollback.txt" \
    || fail 'exact rollback command was not emitted'
[[ "$(sha256sum "$output_dir/rollback-user.conf" | awk '{print $1}')" \
    == "$source_user_bytes" ]] || fail 'rollback user was not byte exact'

if "$repo_root/install/migrations/vxslave-compose-quota/prepare.sh" \
    "$test_root/default.pkg" "$source_user" "$test_root/forbidden" default \
    >"$test_root/forbidden.out" 2>&1; then
    fail 'shared default package migration was accepted'
fi

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/packages" \
    "$VESTA/data/users/rehearsal/docker-projects" \
    "$HOMEDIR/rehearsal/docker"
cp "$output_dir/vxslave-compose.pkg" \
    "$VESTA/data/packages/vxslave-compose.pkg"
cp "$source_package" "$VESTA/data/packages/existing-vxslave.pkg"
printf "UNRELATED='keep-me'\n" >"$VESTA/data/packages/unrelated.pkg"
unrelated_sha="$(
    sha256sum "$VESTA/data/packages/unrelated.pkg" | awk '{print $1}'
)"
cp "$source_user" "$VESTA/data/users/rehearsal/user.conf"
cat >"$VESTA/data/users/rehearsal/user.conf" <<'EOF'
PACKAGE='vxslave-compose'
DOCKER_PROJECTS='1'
DOCKER_SERVICES='1'
DOCKER_CPUS='1.000'
DOCKER_MEMORY_MB='1024'
DOCKER_PIDS='256'
DOCKER_STORAGE_MB='1024'
DOCKER_PORTS='1'
DOCKER_SECRETS='1'
DOCKER_VOLUMES='2'
U_DOCKER_PROJECTS='1'
U_DOCKER_SERVICES='1'
U_DOCKER_CPUS='1.000'
U_DOCKER_MEMORY_MB='1024'
U_DOCKER_PIDS='256'
U_DOCKER_STORAGE_MB='1024'
U_DOCKER_PORTS='1'
U_DOCKER_SECRETS='1'
U_DOCKER_VOLUMES='2'
EOF
# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

vx_compose_quota_check_values \
    rehearsal 1 1 1000 1024 256 1024 1 1 2 \
    || fail 'exact current usage was rejected'
fields=(
    DOCKER_PROJECTS
    DOCKER_SERVICES
    DOCKER_CPUS
    DOCKER_MEMORY_MB
    DOCKER_PIDS
    DOCKER_STORAGE_MB
    DOCKER_PORTS
    DOCKER_SECRETS
    DOCKER_VOLUMES
)
declare -a quota_growth_values=(2 2 1001 1025 257 1025 2 2 3)
for index in "${!fields[@]}"; do
    declare -a quota_candidate_values=(1 1 1000 1024 256 1024 1 1 2)
    quota_candidate_values[index]="${quota_growth_values[index]}"
    if vx_compose_quota_check_values \
        rehearsal "${quota_candidate_values[@]}" \
        2>"$test_root/growth.error"; then
        fail "growth boundary was accepted: ${fields[$index]}"
    fi
    grep -Fq "Compose quota exceeded [${fields[$index]}]" \
        "$test_root/growth.error" \
        || fail "growth boundary returned wrong field: ${fields[$index]}"
done

quota_json="$(vx_compose_quota_diagnostic_json rehearsal)"
jq -e '
    [.QUOTAS[].EFFECTIVE_VALUE]
        == ["1","1","1.000","1024","256","1024","1","1","2"]
    and [.QUOTAS[].USED]
        == ["1","1","1.000","1024","256","1024","1","1","2"]
' <<<"$quota_json" >/dev/null \
    || fail 'applied rehearsal state did not match the approved limits'

printf "CORRUPTED='yes'\n" \
    >"$VESTA/data/packages/existing-vxslave.pkg"
"$repo_root/install/migrations/vxslave-compose-quota/rollback.sh" \
    "$output_dir" rehearsal existing-vxslave "$VESTA" \
    >"$test_root/rollback.out"
cmp -s "$source_user" \
    "$VESTA/data/users/rehearsal/user.conf" \
    || fail 'prior user bytes were not restored exactly'
cmp -s "$source_package" \
    "$VESTA/data/packages/existing-vxslave.pkg" \
    || fail 'prior package bytes were not reinstalled exactly'
[[ ! -e "$VESTA/data/packages/vxslave-compose.pkg" ]] \
    || fail 'dedicated rehearsal package remained after rollback'
[[ "$(sha256sum "$VESTA/data/packages/unrelated.pkg" | awk '{print $1}')" \
    == "$unrelated_sha" ]] || fail 'rollback changed an unrelated package'

tampered_dir="$test_root/tampered"
cp -a "$output_dir" "$tampered_dir"
printf "TAMPERED='yes'\n" >>"$tampered_dir/rollback-user.conf"
restored_package_sha="$(
    sha256sum "$VESTA/data/packages/existing-vxslave.pkg" | awk '{print $1}'
)"
restored_user_sha="$(
    sha256sum "$VESTA/data/users/rehearsal/user.conf" | awk '{print $1}'
)"
if "$repo_root/install/migrations/vxslave-compose-quota/rollback.sh" \
    "$tampered_dir" rehearsal existing-vxslave "$VESTA" \
    >"$test_root/tampered-rollback.out" 2>&1; then
    fail 'rollback accepted tampered saved bytes'
fi
[[ "$(sha256sum "$VESTA/data/packages/existing-vxslave.pkg" \
    | awk '{print $1}')" == "$restored_package_sha" ]] \
    || fail 'failed rollback changed the prior package'
[[ "$(sha256sum "$VESTA/data/users/rehearsal/user.conf" \
    | awk '{print $1}')" == "$restored_user_sha" ]] \
    || fail 'failed rollback changed the prior user'

if "$repo_root/install/migrations/vxslave-compose-quota/rollback.sh" \
    "$output_dir" rehearsal ../escape "$VESTA" \
    >"$test_root/unsafe-rollback.out" 2>&1; then
    fail 'rollback accepted an unsafe package target'
fi

echo "vxslave quota migration local rehearsal passed."
