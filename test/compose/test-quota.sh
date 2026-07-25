#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice/docker-projects" "$HOMEDIR/alice/docker"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

user_conf="$VESTA/data/users/alice/user.conf"
{
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
        printf "VALIDATOR_VERSION='1'\n"
        printf "PROFILE='standard'\n"
        printf "PROFILE_VERSION='1'\n"
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

sed -i "s/DOCKER_PORTS='2'/DOCKER_PORTS='0'/" "$user_conf"
if vx_compose_quota_check_current alice 2>"$test_root/disabled.error"; then
    fail "zero quota did not disable existing port use"
fi
grep -Fq 'Compose quota exceeded [DOCKER_PORTS]' "$test_root/disabled.error" \
    || fail "disabled quota returned the wrong diagnostic"

echo "Compose quota tests passed."
