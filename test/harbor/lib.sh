#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HARBOR_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_REPO_ROOT="$(cd "$HARBOR_TEST_DIR/../.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

new_vesta_root() {
    local test_root
    test_root="$(mktemp -d "${TMPDIR:-/tmp}/vesta-harbor-test.XXXXXX")"
    export HARBOR_TEST_ROOT="$test_root"
    export VESTA="$test_root/vesta"
    mkdir -p "$VESTA/data/harbor" "$VESTA/data/users" "$VESTA/func/vx"
    chmod 0700 "$VESTA/data/harbor"
}

cleanup_vesta_root() {
    if [[ -n "${HARBOR_TEST_ROOT:-}" && -d "$HARBOR_TEST_ROOT" ]]; then
        rm -rf -- "$HARBOR_TEST_ROOT"
    fi
}

install_harbor_helpers() {
    mkdir -p "$VESTA/func/vx/harbor"
    cp "$HARBOR_REPO_ROOT"/func/vx/harbor/*.sh "$VESTA/func/vx/harbor/"
    cp "$HARBOR_REPO_ROOT"/func/vx/harbor/authority-schema.py "$VESTA/func/vx/harbor/"
}
