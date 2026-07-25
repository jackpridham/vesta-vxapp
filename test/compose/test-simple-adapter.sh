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

for command_name in add change start stop restart delete; do
    command_path="$repo_root/bin/v-${command_name}-docker-container"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
if rg -n 'vx_docker_create_runtime|docker (run|create)' \
    "$repo_root/bin/v-add-docker-container"; then
    echo 'FAIL: simple add still creates a direct container' >&2
    exit 1
fi

echo "Compose simple-adapter tests passed."
