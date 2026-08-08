#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/harbor/lib.sh
source "$test_dir/lib.sh"

if [[ -n "${HARBOR_TEST_RUN_ROOT:-}" ]]; then
    HARBOR_TEST_ROOT="$(dirname "$HARBOR_TEST_RUN_ROOT")"
    VESTA="$HARBOR_TEST_RUN_ROOT"
    export HARBOR_TEST_ROOT VESTA
    mkdir -p "$VESTA/data/harbor" "$VESTA/data/users" "$VESTA/func/vx"
    chmod 0700 "$VESTA/data/harbor"
else
    new_vesta_root
    trap cleanup_vesta_root EXIT
fi

python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$test_dir/fixtures/fake-harbor-api.py" "$HARBOR_TEST_ROOT/fake-harbor-api.pyc"
bash -n "$test_dir/fixtures/fake-docker.sh"
bash -n "$test_dir/fixtures/fake-systemctl.sh"

assert_file "$HARBOR_REPO_ROOT/.docs/contracts/harbor-provider.md"
assert_file "$HARBOR_REPO_ROOT/func/vx/harbor/main.sh"
install_harbor_helpers

# Task 2 will exercise provider state defaults, validation, and atomic writes
# after the production helper exists.
printf 'Harbor provider state tests passed.\n'
