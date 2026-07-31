#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
if (( EUID == 0 )); then
    owner=nobody
else
    owner="$(id -un)"
fi
mkdir -p "$VESTA/data/users/$owner" "$HOMEDIR/$owner"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

target="$test_root/target"
mkdir -m 0711 "$target"
target_identity="$(stat -Lc '%d:%i:%u:%a' "$target")"

assert_target_unchanged() {
    [[ "$(stat -Lc '%d:%i:%u:%a' "$target")" == "$target_identity" ]] \
        || fail "$1 symlink changed the target directory"
}

ln -s "$target" "$HOMEDIR/$owner/docker"
if vx_compose_prepare_project_data_roots "$owner" app 2>/dev/null; then
    fail 'owner data-root symlink was accepted'
fi
assert_target_unchanged owner-root
rm "$HOMEDIR/$owner/docker"

vx_compose_prepare_project_data_roots "$owner" || fail 'safe owner root failed'
ln -s "$target" "$HOMEDIR/$owner/docker/app"
if vx_compose_prepare_project_data_roots "$owner" app 2>/dev/null; then
    fail 'project-root symlink was accepted'
fi
assert_target_unchanged project-root
rm "$HOMEDIR/$owner/docker/app"

mkdir -m 0750 "$HOMEDIR/$owner/docker/app"
if (( EUID == 0 )); then
    chown "root:$owner" "$HOMEDIR/$owner/docker/app"
fi
ln -s "$target" "$HOMEDIR/$owner/docker/app/binds"
if vx_compose_prepare_project_data_roots "$owner" app 2>/dev/null; then
    fail 'bind-root symlink was accepted'
fi
assert_target_unchanged bind-root
rm "$HOMEDIR/$owner/docker/app/binds"

vx_compose_prepare_project_data_roots "$owner" app \
    || fail 'safe bind root failed'
ln -s "$target" "$HOMEDIR/$owner/docker/app/binds/data"
if vx_compose_managed_directory_prepare \
    "$owner" "$HOMEDIR/$owner/docker/app/binds/data" tenant 0750 \
    2>/dev/null; then
    fail 'bind-leaf symlink was accepted'
fi
assert_target_unchanged bind-leaf

echo 'Compose managed-directory symlink tests passed.'
