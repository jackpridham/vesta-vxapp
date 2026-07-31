#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
if (( EUID == 0 )); then
    owner=
    while IFS=: read -r candidate _ candidate_uid _ _ _ _; do
        (( candidate_uid >= 1000 )) || continue
        if [[ "$(id -gn "$candidate" 2>/dev/null)" == "$candidate" ]]; then
            owner="$candidate"
            break
        fi
    done < <(getent passwd)
    [[ -n "$owner" ]] || {
        printf 'SKIP: no same-name non-root user/group fixture is available\n'
        exit 0
    }
else
    owner="$(id -un)"
fi
mkdir -p "$VESTA/data/users/$owner" "$HOMEDIR/$owner"
if (( EUID == 0 )); then
    chown "$owner:$owner" "$HOMEDIR/$owner"
fi

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
vx_compose_prepare_project_data_roots "$owner" app \
    || fail 'safe project root failed'
rmdir "$HOMEDIR/$owner/docker/app/binds"
ln -s "$target" "$HOMEDIR/$owner/docker/app/binds"
if vx_compose_prepare_project_data_roots "$owner" app 2>/dev/null; then
    fail 'bind-root symlink was accepted'
fi
assert_target_unchanged bind-root
rm "$HOMEDIR/$owner/docker/app/binds"

vx_compose_prepare_project_data_roots "$owner" app \
    || fail 'safe bind root failed'
ln -s "$target" "$HOMEDIR/$owner/docker/app/binds/data"
if vx_compose_managed_bind_leaf_prepare "$owner" app data 2>/dev/null; then
    fail 'bind-leaf symlink was accepted'
fi
assert_target_unchanged bind-leaf
rm "$HOMEDIR/$owner/docker/app/binds/data"

# A rename after the docker descriptor is open must not redirect project or
# bind creation through a replacement symlink.
rm -rf -- "$HOMEDIR/$owner/docker/app"
pause="/tmp/vx-managed-directory-pause.$$"
VX_COMPOSE_TEST_MODE=yes \
VX_COMPOSE_TEST_MANAGED_DIRECTORY_PAUSE="$pause" \
    vx_compose_prepare_project_data_roots "$owner" raced \
    >"$test_root/race.out" 2>"$test_root/race.error" &
race_pid=$!
for _ in {1..500}; do
    [[ -f "$pause.ready" ]] && break
    sleep 0.01
done
[[ -f "$pause.ready" ]] || fail 'parent-swap test hook did not become ready'
mv "$HOMEDIR/$owner/docker" "$HOMEDIR/$owner/docker.protected"
ln -s "$target" "$HOMEDIR/$owner/docker"
touch "$pause.continue"
if wait "$race_pid"; then
    fail 'parent swap was accepted'
fi
[[ ! -e "$target/raced" ]] || fail 'parent swap redirected root creation'
assert_target_unchanged parent-swap
rm "$HOMEDIR/$owner/docker"
mv "$HOMEDIR/$owner/docker.protected" "$HOMEDIR/$owner/docker"

# Real legacy roots begin tenant-owned. The explicit migration transition may
# claim them once, but its protected marker prevents a second owner-to-root
# transition after replacement.
rmdir "$HOMEDIR/$owner/docker/raced/binds" \
    "$HOMEDIR/$owner/docker/raced"
mkdir -p "$HOMEDIR/$owner/docker/legacy/source"
if (( EUID == 0 )); then
    chown -R "$owner:$owner" "$HOMEDIR/$owner/docker"
fi
vx_compose_prepare_legacy_project_data_roots "$owner" legacy \
    || fail 'owner-owned legacy root did not transition'
authority_uid="$EUID"
[[ "$(stat -c %u "$HOMEDIR/$owner/docker")" == "$authority_uid"
    && "$(stat -c %u "$HOMEDIR/$owner/docker/legacy")" == "$authority_uid"
    && "$(cat "$VESTA/data/users/$owner/docker-projects/.legacy-data-authority/legacy.conf")" \
        == "STATE='complete'" ]] \
    || fail 'legacy transition did not establish protected authority'
mv "$HOMEDIR/$owner/docker" "$HOMEDIR/$owner/docker.transitioned"
mkdir -p "$HOMEDIR/$owner/docker/legacy"
if (( EUID == 0 )); then
    chown -R "$owner:$owner" "$HOMEDIR/$owner/docker"
    if vx_compose_prepare_legacy_project_data_roots "$owner" legacy \
        2>/dev/null; then
        fail 'completed legacy transition was reopened for an owner replacement'
    fi
    [[ "$(stat -c %u "$HOMEDIR/$owner/docker")" == "$(id -u "$owner")" ]] \
        || fail 'rejected replacement legacy root was mutated'
fi

echo 'Compose managed-directory symlink tests passed.'
