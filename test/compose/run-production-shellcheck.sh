#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

command -v shellcheck >/dev/null 2>&1 \
    || { echo 'FAIL: shellcheck is unavailable' >&2; exit 1; }
command -v timeout >/dev/null 2>&1 \
    || { echo 'FAIL: timeout is unavailable' >&2; exit 1; }

mapfile -t compose_adapters < <(
    {
        find bin -maxdepth 1 -type f -name 'v-*docker*' -print
        printf '%s\n' \
            bin/v-check-docker-engine \
            bin/v-install-docker-service \
            bin/v-update-sys-rrd-docker
    } | sort -u
)

mapfile -t compose_helpers < <(
    find func/vx/compose -type f -name '*.sh' -print | sort
)

run_shellcheck() {
    local scope="$1" timeout_seconds="$2" status
    shift 2
    printf 'ShellCheck %s\n' "$scope" >&2
    set +e
    timeout --signal=TERM --kill-after=5 "$timeout_seconds" \
        shellcheck "$@"
    status=$?
    set -e
    if (( status == 124 || status == 137 )); then
        printf 'FAIL: ShellCheck %s exceeded its %s-second resource bound\n' \
            "$scope" "$timeout_seconds" >&2
    elif (( status != 0 )); then
        printf 'FAIL: ShellCheck %s exited with status %s\n' \
            "$scope" "$status" >&2
    fi
    return "$status"
}

# Local analysis deliberately omits -x. Each adapter and helper is checked in
# its own bounded process so failures identify one file and constrained hosts
# do not retain a monolithic extended-analysis state.
for adapter in "${compose_adapters[@]}"; do
    run_shellcheck "adapter $adapter" 30 \
        -S warning -e SC1091 "$adapter"
done
for helper in "${compose_helpers[@]}"; do
    run_shellcheck "helper $helper" 30 \
        -S warning -e SC1091 "$helper"
done

# main.sh sources every Compose helper, so one source-following invocation
# validates the complete shared helper graph. Extended analysis is disabled for
# this redundant graph pass because every file already received a full local
# analysis above.
run_shellcheck 'shared Compose graph' 90 \
    --extended-analysis=false -x -S warning -e SC1091 \
    func/vx/compose/main.sh
