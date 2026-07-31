#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/packages" \
    "$VESTA/data/users/alice/docker-projects" \
    "$VESTA/data/users/bob/docker-projects" \
    "$HOMEDIR/alice/docker" \
    "$HOMEDIR/bob/docker"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

user_conf="$VESTA/data/users/alice/user.conf"
{
    printf "PACKAGE='tenant-plan'\n"
    printf "DOCKER_PROJECTS='2'\n"
    printf "DOCKER_SERVICES='3'\n"
    printf "DOCKER_CPUS='1.000'\n"
    printf "DOCKER_MEMORY_MB='256'\n"
    printf "DOCKER_PIDS='128'\n"
    printf "DOCKER_STORAGE_MB='32'\n"
    printf "DOCKER_PORTS='2'\n"
    printf "DOCKER_SECRETS='0'\n"
    printf "DOCKER_VOLUMES='0'\n"
} >"$user_conf"

cat >"$VESTA/data/packages/tenant-plan.pkg" <<'EOF'
DOCKER_PROJECTS='4'
DOCKER_SERVICES='6'
DOCKER_CPUS='2.500'
DOCKER_MEMORY_MB='2048'
DOCKER_PIDS='512'
DOCKER_STORAGE_MB='4096'
DOCKER_PORTS='8'
DOCKER_SECRETS='3'
DOCKER_VOLUMES='5'
EOF

make_policy() {
    local output="$1"
    local services="$2"
    local cpu="$3"
    local memory="$4"
    local pids="$5"
    local ports="$6"

    mkdir -p "$(dirname -- "$output")"
    {
        printf "POLICY_SCHEMA='1'\n"
        printf "VALIDATOR_VERSION='2'\n"
        printf "PROFILE='standard'\n"
        printf "PROFILE_VERSION='2'\n"
        printf "SERVICES='%s'\n" "$services"
        printf "CPUS_MILLI='%s'\n" "$cpu"
        printf "MEMORY_MB='%s'\n" "$memory"
        printf "PIDS='%s'\n" "$pids"
        printf "STORAGE_MB='0'\n"
        printf "PORTS='%s'\n" "$ports"
        printf "SECRETS='0'\n"
        printf "VOLUMES='0'\n"
    } >"$output"
    case "$output" in
        "$VESTA/data/users/alice/docker-projects/"*)
            printf "OWNER='alice'\n" >"$(dirname -- "$output")/project.conf"
            ;;
    esac
}

make_policy "$VESTA/data/users/alice/docker-projects/one/policy.conf" 1 250 64 32 1
make_policy "$test_root/candidate.conf" 2 750 192 96 1

vx_compose_quota_check_candidate alice two "$test_root/candidate.conf" create

make_policy "$VESTA/data/users/alice/docker-projects/two/policy.conf" 2 750 192 96 1
if vx_compose_quota_check_candidate alice three "$test_root/candidate.conf" create \
    2>"$test_root/project.error"; then
    fail "project quota overage was accepted"
fi
grep -Fq 'Compose quota exceeded [DOCKER_PROJECTS]' "$test_root/project.error" \
    || fail "project overage returned the wrong diagnostic"

make_policy "$test_root/too-many-services.conf" 3 250 64 32 0
if vx_compose_quota_check_candidate \
    alice two "$test_root/too-many-services.conf" update \
    2>"$test_root/services.error"; then
    fail "service quota overage was accepted"
fi
grep -Fq 'Compose quota exceeded [DOCKER_SERVICES]' "$test_root/services.error" \
    || fail "service overage returned the wrong diagnostic"

make_policy "$test_root/update.conf" 1 250 64 32 0
vx_compose_quota_check_candidate alice two "$test_root/update.conf" update \
    || fail "update did not exclude the replaced project revision"

vx_compose_refresh_counters alice
grep -Fq "U_DOCKER_PROJECTS='2'" "$user_conf" \
    || fail "project counter was not persisted"
grep -Fq "U_DOCKER_SERVICES='3'" "$user_conf" \
    || fail "service counter was not persisted"
grep -Fq "U_DOCKER_CPUS='1.000'" "$user_conf" \
    || fail "CPU counter was not persisted"
grep -Fq "U_DOCKER_MEMORY_MB='256'" "$user_conf" \
    || fail "memory counter was not persisted"

quota_json="$(vx_compose_quota_diagnostic_json alice)"
jq -e '
    .USER == "alice"
    and .PACKAGE == "tenant-plan"
    and (.QUOTAS | length) == 9
    and .QUOTAS[0] == {
        "FIELD":"DOCKER_PROJECTS",
        "LABEL":"Projects",
        "UNIT":"count",
        "PACKAGE_VALUE":"4",
        "EFFECTIVE_VALUE":"2",
        "USED":"2"
    }
    and .QUOTAS[1].FIELD == "DOCKER_SERVICES"
    and .QUOTAS[1].PACKAGE_VALUE == "6"
    and .QUOTAS[1].EFFECTIVE_VALUE == "3"
    and .QUOTAS[1].USED == "3"
    and .QUOTAS[2].FIELD == "DOCKER_CPUS"
    and .QUOTAS[2].UNIT == "cores"
    and .QUOTAS[2].PACKAGE_VALUE == "2.500"
    and .QUOTAS[2].EFFECTIVE_VALUE == "1.000"
    and .QUOTAS[2].USED == "1.000"
    and .QUOTAS[3].UNIT == "MiB"
    and .QUOTAS[3].USED == "256"
    and .QUOTAS[4].FIELD == "DOCKER_PIDS"
    and .QUOTAS[5].UNIT == "MiB"
    and .QUOTAS[6].FIELD == "DOCKER_PORTS"
    and .QUOTAS[7].FIELD == "DOCKER_SECRETS"
    and .QUOTAS[8].FIELD == "DOCKER_VOLUMES"
' <<<"$quota_json" >/dev/null \
    || fail "authoritative quota diagnostic omitted or changed a dimension"

mkdir -p "$VESTA/func/vx"
ln -s "$repo_root/func/vx/compose" "$VESTA/func/vx/compose"
cat >"$VESTA/func/main.sh" <<'EOF'
E_ARGS=2
E_INVALID=3
check_args() {
    [[ "$2" -ge "$1" ]] || exit "$E_ARGS"
}
is_format_valid() {
    :
}
is_object_valid() {
    :
}
check_result() {
    printf '%s\n' "$2" >&2
    exit "$1"
}
EOF
cli_json="$("$repo_root/bin/v-list-docker-compose-quota" alice json)"
jq -e '
    .USER == "alice"
    and .QUOTAS[2].PACKAGE_VALUE == "2.500"
    and .QUOTAS[2].USED == "1.000"
' <<<"$cli_json" >/dev/null \
    || fail "quota CLI JSON changed the helper contract"
cli_plain="$("$repo_root/bin/v-list-docker-compose-quota" alice plain)"
[[ "$(wc -l <<<"$cli_plain")" -eq 9 ]] \
    || fail "quota CLI plain format omitted dimensions"
grep -Fq $'DOCKER_MEMORY_MB\t2048\t256\t256\tMiB' <<<"$cli_plain" \
    || fail "quota CLI plain format changed value ordering or units"
if "$repo_root/bin/v-list-docker-compose-quota" alice yaml \
    >"$test_root/invalid-format.out" 2>&1; then
    fail "quota CLI accepted an unsupported format"
fi

cat >"$VESTA/data/packages/legacy-unlimited.pkg" <<'EOF'
DOCKER_CONTAINERS='unlimited'
EOF
cat >"$VESTA/data/users/bob/user.conf" <<'EOF'
PACKAGE='legacy-unlimited'
DOCKER_CONTAINERS='unlimited'
U_DOCKER_PROJECTS='0'
U_DOCKER_SERVICES='0'
U_DOCKER_CPUS='0.000'
U_DOCKER_MEMORY_MB='0'
U_DOCKER_PIDS='0'
U_DOCKER_STORAGE_MB='0'
U_DOCKER_PORTS='0'
U_DOCKER_SECRETS='0'
U_DOCKER_VOLUMES='0'
EOF
legacy_json="$(vx_compose_quota_diagnostic_json bob)"
jq -e '
    [.QUOTAS[] | .PACKAGE_VALUE] | all(. == "unlimited")
' <<<"$legacy_json" >/dev/null \
    || fail "legacy unlimited package compatibility was not preserved"
jq -e '
    [.QUOTAS[] | .EFFECTIVE_VALUE] | all(. == "unlimited")
' <<<"$legacy_json" >/dev/null \
    || fail "legacy unlimited effective compatibility was not preserved"

sed -i "s/DOCKER_PORTS='2'/DOCKER_PORTS='0'/" "$user_conf"
if vx_compose_quota_check_current alice 2>"$test_root/disabled.error"; then
    fail "zero quota did not disable existing port use"
fi
grep -Fq 'Compose quota exceeded [DOCKER_PORTS]' "$test_root/disabled.error" \
    || fail "disabled quota returned the wrong diagnostic"

php "$repo_root/test/test_compose_quota_php.php"

echo "Compose quota tests passed."
