#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"

shell_tests=(
    "$test_dir/test-fixtures.sh"
    "$test_dir/test-state.sh"
    "$test_dir/test-status.sh"
    "$test_dir/test-package-quota.sh"
    "$test_dir/test-release-verification.sh"
    "$test_dir/test-install.sh"
    "$test_dir/test-ingress.sh"
    "$test_dir/test-host-boundary.sh"
    "$test_dir/test-api.sh"
    "$test_dir/test-owner-reconcile.sh"
    "$test_dir/test-credentials.sh"
    "$test_dir/test-publisher.sh"
    "$test_dir/test-discovery.sh"
    "$test_dir/test-revocation.sh"
    "$test_dir/test-health.sh"
    "$test_dir/test-backup.sh"
    "$test_dir/test-disable.sh"
    "$test_dir/test-doc-contract.sh"
)

php_tests=(
    "$test_dir/../test_harbor_panel.php"
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
