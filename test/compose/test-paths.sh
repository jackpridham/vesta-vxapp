#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice" \
    "$HOMEDIR/alice/docker/app/data" \
    "$test_root/outside"
ln -s "$test_root/outside" "$HOMEDIR/alice/docker/app/escape"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

resolved="$(vx_compose_resolve_managed_path alice app "$HOMEDIR/alice/docker/app/data/file.db")"
[[ "$resolved" == "$HOMEDIR/alice/docker/app/data/file.db" ]] \
    || fail "valid managed path was not resolved"

if vx_compose_resolve_managed_path alice app "$HOMEDIR/alice/docker/app/escape/file" 2>/dev/null; then
    fail "symlink escape was accepted"
fi
if vx_compose_resolve_managed_path alice app "$HOMEDIR/alice/docker/app/missing/file" 2>/dev/null; then
    fail "missing parent was accepted"
fi
if vx_compose_resolve_managed_path alice app "$HOMEDIR/alice/docker/other/file" 2>/dev/null; then
    fail "cross-project path was accepted"
fi
if vx_compose_resolve_managed_path alice app "$test_root/outside/file" 2>/dev/null; then
    fail "host path was accepted"
fi

echo "Compose managed-path tests passed."
