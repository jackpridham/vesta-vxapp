#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/compose-one" \
    "$VESTA/data/users/alice/docker-projects/compose-two"
printf '%s\n' "NAME='legacy-one'" \
    >"$VESTA/data/users/alice/docker.conf"
touch \
    "$VESTA/data/users/alice/docker-projects/compose-one/project.conf" \
    "$VESTA/data/users/alice/docker-projects/compose-two/project.conf"
# shellcheck source=func/vx/docker.sh
source "$repo_root/func/vx/docker.sh"
[[ "$(vx_docker_count_owner_records alice)" == 3 ]] \
    || fail 'legacy container quota does not include Compose projects'

quota_fields=(
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

cmp -s \
    "$repo_root/conf/vx-docker-policy.conf" \
    "$repo_root/example-of-linux-root-folder/usr/local/vesta/conf/vx-docker-policy.conf" \
    || fail "runtime and synthetic policy defaults differ"

while IFS= read -r package_file; do
    for field in "${quota_fields[@]}"; do
        grep -Eq "^${field}='(0|unlimited)'$" "$package_file" \
            || fail "$package_file is missing $field"
    done
done < <(
    find \
        "$repo_root/install/debian" \
        "$repo_root/example-of-linux-root-folder/usr/local/vesta/data/packages" \
        -path '*/packages/*.pkg' -type f -print
)

for command_name in \
    v-add-user \
    v-change-user-package \
    v-update-user-counters \
    v-list-user-package \
    v-list-user \
    v-list-users; do
    grep -Fq 'func/vx/compose/main.sh' "$repo_root/bin/$command_name" \
        || fail "$command_name does not use Compose package helpers"
done

for command_name in v-suspend-user v-unsuspend-user v-delete-user v-rebuild-user; do
    grep -Fq 'func/vx/compose/main.sh' "$repo_root/bin/$command_name" \
        || fail "$command_name does not load Compose owner lifecycle helpers"
done
grep -Fq 'vx_compose_suspend_owner' "$repo_root/bin/v-suspend-user" \
    || fail "user suspension omits Compose projects"
grep -Fq 'vx_compose_unsuspend_owner' "$repo_root/bin/v-unsuspend-user" \
    || fail "user restoration omits Compose projects"
grep -Fq 'vx_compose_remove_owner_runtime' "$repo_root/bin/v-delete-user" \
    || fail "user deletion omits Compose projects"
grep -Fq 'vx_compose_rebuild_owner' "$repo_root/bin/v-rebuild-user" \
    || fail "user rebuild omits Compose projects"

for field in "${quota_fields[@]}"; do
    grep -Fq "\"$field\"" "$repo_root/bin/v-list-user-package" \
        || fail "package JSON omits $field"
    grep -Fq "\"$field\"" "$repo_root/bin/v-list-user" \
        || fail "user JSON omits $field"
    grep -Fq "\"U_$field\"" "$repo_root/bin/v-list-user" \
        || fail "user JSON omits U_$field"
done

echo "Compose package integration tests passed."
