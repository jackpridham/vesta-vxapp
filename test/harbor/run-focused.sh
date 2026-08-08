#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"

shell_tests=(
    "$test_dir/test-fixtures.sh"
    "$test_dir/test-state.sh"
)

php_tests=(
)

run_isolated() {
    local test_root
    test_root="$(mktemp -d "${TMPDIR:-/tmp}/vesta-harbor-runner.XXXXXX")"
    if ! HARBOR_TEST_RUN_ROOT="$test_root/vesta" "$@"; then
        rm -rf -- "$test_root"
        return 1
    fi
    rm -rf -- "$test_root"
}

for test_file in "${shell_tests[@]}"; do
    run_isolated "$test_file"
done

for test_file in "${php_tests[@]}"; do
    run_isolated php "$test_file"
done
