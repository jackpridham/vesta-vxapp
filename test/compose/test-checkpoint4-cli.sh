#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

commands=(
    v-pull-docker-image
    v-load-docker-image
    v-add-docker-registry
    v-delete-docker-registry
    v-list-docker-registries
    v-add-docker-secret
    v-change-docker-secret
    v-delete-docker-secret
    v-list-docker-secrets
)

for command_name in "${commands[@]}"; do
    command_path="$repo_root/bin/$command_name"
    [[ -x "$command_path" ]] \
        || {
            echo "FAIL: missing executable command $command_name" >&2
            exit 1
        }
    grep -Fq '# info:' "$command_path" \
        || {
            echo "FAIL: missing info header $command_name" >&2
            exit 1
        }
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: command bypasses vx helpers $command_name" >&2
            exit 1
        }
done

echo "Compose Checkpoint 4 CLI tests passed."
