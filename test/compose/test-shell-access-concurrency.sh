#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

line_of() { rg -n -m1 "$2" "$1" | cut -d: -f1; }
assert_order() {
    local file="$1" first="$2" second="$3" a b
    a="$(line_of "$file" "$first")"; b="$(line_of "$file" "$second")"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$a" -lt "$b" ]] || fail "$file ordering: $first before $second"
}

assert_order "$repo_root/bin/v-suspend-user" 'access_lock_acquire' 'SUSPENDED.*yes'
assert_order "$repo_root/bin/v-suspend-user" 'SUSPENDED.*yes' 'group_revoke'
assert_order "$repo_root/bin/v-suspend-user" 'group_revoke' 'vx_compose_suspend_owner'
assert_order "$repo_root/bin/v-unsuspend-user" 'access_lock_acquire' 'vx_compose_unsuspend_owner'
assert_order "$repo_root/bin/v-unsuspend-user" 'vx_compose_unsuspend_owner' 'SUSPENDED.*no'
assert_order "$repo_root/bin/v-unsuspend-user" 'SUSPENDED.*no' 'group_grant_if_eligible'
for command in v-change-user-package v-change-user-shell v-delete-user; do
    assert_order "$repo_root/bin/$command" 'access_lock_acquire' 'group_revoke'
done

grep -Fq 'vx_compose_shell_access_lock_acquire "$actor"' "$repo_root/bin/v-run-user-docker-command" || fail 'broker omits owner lock'
assert_order "$repo_root/bin/v-run-user-docker-command" 'access_lock_acquire' 'require_eligible'
grep -Fq 'vx_compose_shell_access_lock_close_child_copy' "$repo_root/bin/v-run-user-docker-command" || fail 'child inherits owner lock copy'
! rg -n 'eval |bash -c|sh -c' "$repo_root/func/vx/compose/shell-access.sh" "$repo_root/bin/v-run-user-docker-command" >/dev/null || fail 'dynamic shell execution present'

echo 'Compose shell access concurrency tests passed.'
