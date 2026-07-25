#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

# Globals intentionally model vx_docker_load_spec output consumed by the
# compatibility helper.
# shellcheck disable=SC2034
declare -g \
    NAME=site \
    IMAGE=nginx:alpine \
    COMMAND='' \
    ENV='NODE_ENV=production' \
    MOUNTS='' \
    CONTAINER_PORT=8080 \
    RESTART_POLICY=unless-stopped \
    HEALTHCHECK_TYPE=none \
    HEALTHCHECK_TARGET='' \
    HEALTHCHECK_INTERVAL=60
vx_compose_simple_render_loaded alice 18080 "$test_root/compose.yaml"
grep -Fq '127.0.0.1:18080:8080' "$test_root/compose.yaml"
grep -Fq 'NODE_ENV=production' "$test_root/compose.yaml"
grep -Fq 'cap_drop: [ALL]' "$test_root/compose.yaml"
mkdir "$test_root/candidate"
vx_compose_simple_metadata_write_candidate \
    alice 18080 "$test_root/candidate"
jq -e '
    .OWNER == "alice"
    and .NAME == "site"
    and .IMAGE == "nginx:alpine"
    and .ENV == "NODE_ENV=production"
    and .HOST_PORT == "18080"
    and .CONTAINER_PORT == "8080"
' "$test_root/candidate/simple.json" >/dev/null \
    || {
        echo 'FAIL: safe simple-form metadata was not rendered' >&2
        exit 1
    }
[[ "$(stat -c '%a' "$test_root/candidate/simple.json")" == 600 ]] \
    || {
        echo 'FAIL: simple-form metadata mode is not protected' >&2
        exit 1
    }

for command_name in add change start stop restart delete; do
    command_path="$repo_root/bin/v-${command_name}-docker-container"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
if grep -En 'vx_docker_create_runtime|docker (run|create)' \
    "$repo_root/bin/v-add-docker-container"; then
    echo 'FAIL: simple add still creates a direct container' >&2
    exit 1
fi
grep -Fq 'advanced Compose projects cannot use the simple editor' \
    "$repo_root/bin/v-change-docker-container" \
    || {
        echo 'FAIL: simple change adapter does not enforce provenance' >&2
        exit 1
    }

echo "Compose simple-adapter tests passed."
