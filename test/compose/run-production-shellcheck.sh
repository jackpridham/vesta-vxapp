#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v shellcheck >/dev/null 2>&1 \
    || { echo 'FAIL: shellcheck is unavailable' >&2; exit 1; }

mapfile -t compose_adapters < <(
    {
        find bin -maxdepth 1 -type f -name 'v-*docker*' -print
        printf '%s\n' \
            bin/v-check-docker-engine \
            bin/v-install-docker-service \
            bin/v-update-sys-rrd-docker
    } | sort -u
)

# Adapter-local analysis deliberately omits -x. Every adapter is checked once
# without repeatedly expanding the shared Compose helper dependency graph.
shellcheck -S warning -e SC1091 "${compose_adapters[@]}"

# main.sh sources every Compose helper, so one source-following invocation
# validates the complete shared helper graph and all cross-helper state.
shellcheck -x -S warning -e SC1091 func/vx/compose/main.sh
