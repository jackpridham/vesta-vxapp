#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" "$HOMEDIR/alice" "$HOMEDIR/bob"
for owner in alice bob; do
    {
        printf "DOCKER_PROJECTS='4'\n"
        printf "DOCKER_SERVICES='8'\n"
        printf "DOCKER_CPUS='4.000'\n"
        printf "DOCKER_MEMORY_MB='4096'\n"
        printf "DOCKER_PIDS='512'\n"
        printf "DOCKER_STORAGE_MB='128'\n"
        printf "DOCKER_PORTS='8'\n"
        printf "DOCKER_SECRETS='0'\n"
        printf "DOCKER_VOLUMES='0'\n"
    } >"$VESTA/data/users/$owner/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(vx_compose_runtime_name alice app)" == "vx-alice-app" ]] \
    || fail "stable runtime project name is wrong"
vx_compose_project_is_valid app || fail "valid project key was rejected"
if vx_compose_project_is_valid 'Bad/App'; then
    fail "unsafe project key was accepted"
fi

candidate="$test_root/candidate"
mkdir -p "$candidate"
printf '%s\n' 'services: {}' >"$candidate/compose.yaml"
printf '%s\n' '{"name":"vx-alice-app","services":{}}' >"$candidate/canonical.json"
printf '%s\n' 'abc123' >"$candidate/canonical.sha256"
{
    printf "POLICY_SCHEMA='1'\n"
    printf "VALIDATOR_VERSION='2'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='2'\n"
    printf "SERVICES='0'\n"
    printf "CPUS_MILLI='0'\n"
    printf "MEMORY_MB='0'\n"
    printf "PIDS='0'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"

vx_compose_store_new alice app standard "$candidate"
project_root="$(vx_compose_project_root alice app)"

[[ -f "$project_root/compose.yaml" ]] || fail "canonical Compose file was not stored"
[[ -f "$project_root/runtime/canonical.json" ]] || fail "canonical JSON was not stored"
[[ -f "$project_root/revisions/000001/compose.yaml" ]] || fail "first revision was not stored"
[[ "$(vx_compose_meta_get "$project_root/project.conf" OWNER)" == alice ]] \
    || fail "owner metadata is wrong"
[[ "$(vx_compose_meta_get "$project_root/project.conf" COMPOSE_PROJECT)" == vx-alice-app ]] \
    || fail "runtime name metadata is wrong"
[[ "$(stat -c '%a' "$project_root")" == 750 ]] || fail "project directory mode is wrong"
[[ "$(stat -c '%a' "$project_root/variables.env")" == 600 ]] \
    || fail "controlled env file mode is wrong"
[[ "$(stat -c '%a' "$project_root/project.conf")" == 640 ]] \
    || fail "metadata mode is wrong"
[[ "$(stat -c '%a' "$project_root/secrets")" == 700 ]] \
    || fail "protected secrets directory mode is wrong"
[[ -f "$(vx_compose_lock_path alice app)" ]] \
    || fail "project lock was not created"

[[ ! -e "$(vx_compose_project_root bob app)" ]] \
    || fail "project leaked into another owner's storage"
if vx_compose_require_project bob app 2>/dev/null; then
    fail "cross-owner project lookup succeeded"
fi

printf '%s\n' 'services: {web: {image: example.test/web:v2}}' >"$candidate/compose.yaml"
printf '%s\n' '{"name":"vx-alice-app","services":{"web":{"image":"example.test/web:v2"}}}' \
    >"$candidate/canonical.json"
printf '%s\n' 'def456' >"$candidate/canonical.sha256"
vx_compose_store_revision alice app "$candidate" validated

[[ "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 2 ]] \
    || fail "revision did not increment"
[[ -f "$project_root/revisions/000002/compose.yaml" ]] \
    || fail "second immutable revision is missing"
[[ -f "$project_root/revisions/000001/compose.yaml" ]] \
    || fail "first revision was overwritten"

echo "Compose storage tests passed."
