#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice" \
    "$VESTA/data/users/bob" \
    "$HOMEDIR/alice" \
    "$HOMEDIR/bob"
for owner in alice bob; do
    {
        printf "DOCKER_PROJECTS='2'\n"
        printf "DOCKER_SERVICES='2'\n"
        printf "DOCKER_CPUS='1.000'\n"
        printf "DOCKER_MEMORY_MB='512'\n"
        printf "DOCKER_PIDS='128'\n"
        printf "DOCKER_STORAGE_MB='64'\n"
        printf "DOCKER_PORTS='2'\n"
        printf "DOCKER_SECRETS='0'\n"
        printf "DOCKER_VOLUMES='0'\n"
    } >"$VESTA/data/users/$owner/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_docker="$test_root/fake-docker"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s\n" "$*" >>"$(dirname -- "$0")/docker.log"'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

candidate="$test_root/candidate"
mkdir -p "$candidate"
printf 'services: {app: {image: alpine:3.20}}\n' >"$candidate/compose.yaml"
printf '{"name":"vx-alice-app","services":{"app":{"image":"alpine:3.20"}}}\n' \
    >"$candidate/canonical.json"
(
    cd "$candidate"
    sha256sum canonical.json >canonical.sha256
)
{
    printf "POLICY_SCHEMA='1'\n"
    printf "VALIDATOR_VERSION='2'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='2'\n"
    printf "SERVICES='1'\n"
    printf "CPUS_MILLI='250'\n"
    printf "MEMORY_MB='64'\n"
    printf "PIDS='32'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"
printf '{"app":{"REFERENCE":"alpine:3.20","IMAGE_ID":"sha256:fixture","REPO_DIGESTS":["alpine@sha256:fixture"],"OS":"linux","ARCHITECTURE":"amd64"}}\n' \
    >"$candidate/images.json"
vx_compose_store_new alice app standard "$candidate"

if vx_compose_start bob app 2>"$test_root/cross-owner.error"; then
    fail "cross-owner start was accepted"
fi
[[ ! -s "$test_root/docker.log" ]] \
    || fail "cross-owner start reached Docker"
grep -Fq 'Compose project does not exist: bob/app' "$test_root/cross-owner.error" \
    || fail "cross-owner start did not fail at owner-scoped lookup"

[[ "$(vx_compose_runtime_name alice app)" == vx-alice-app ]] \
    || fail "Alice runtime name is unstable"
[[ "$(vx_compose_runtime_name bob app)" == vx-bob-app ]] \
    || fail "Bob runtime name is not isolated"

echo "Compose ownership isolation tests passed."
