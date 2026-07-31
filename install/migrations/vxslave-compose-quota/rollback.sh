#!/usr/bin/env bash
set -Eeuo pipefail

rollback_dir="${1:-}"
owner="${2:-}"
original_package="${3:-}"
vesta_root="${4:-}"
package_temp=''
user_temp=''

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

cleanup() {
    [[ -z "$package_temp" || ! -e "$package_temp" ]] \
        || rm -- "$package_temp"
    [[ -z "$user_temp" || ! -e "$user_temp" ]] || rm -- "$user_temp"
}
trap cleanup EXIT

[[ -n "$rollback_dir" && -n "$owner" && -n "$original_package" \
    && -n "$vesta_root" ]] \
    || fail 'usage: rollback.sh ROLLBACK_DIR OWNER ORIGINAL_PACKAGE VESTA_ROOT'
[[ "$rollback_dir" =~ ^/[A-Za-z0-9._/-]+$ \
    && "$rollback_dir" != *'/../'* ]] \
    || fail 'rollback directory must be an absolute shell-safe path'
[[ "$vesta_root" =~ ^/[A-Za-z0-9._/-]+$ && "$vesta_root" != *'/../'* ]] \
    || fail 'Vesta root must be an absolute shell-safe path'
[[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] \
    || fail 'invalid owner'
[[ "$original_package" =~ ^[A-Za-z0-9._-]+$ \
    && "$original_package" != default ]] \
    || fail 'invalid or shared original package'
[[ -d "$rollback_dir" && ! -L "$rollback_dir" ]] \
    || fail 'rollback directory must be a regular directory'
[[ -d "$vesta_root/data/packages" \
    && ! -L "$vesta_root/data/packages" ]] \
    || fail 'Vesta package directory is unsafe'
[[ -d "$vesta_root/data/users/$owner" \
    && ! -L "$vesta_root/data/users/$owner" ]] \
    || fail 'Vesta user directory is unsafe'

rollback_package="$rollback_dir/rollback.pkg"
rollback_user="$rollback_dir/rollback-user.conf"
rollback_manifest="$rollback_dir/rollback.sha256"
target_package="$vesta_root/data/packages/$original_package.pkg"
target_user="$vesta_root/data/users/$owner/user.conf"
temporary_package="$vesta_root/data/packages/vxslave-compose.pkg"

for path in \
    "$rollback_package" \
    "$rollback_user" \
    "$rollback_manifest" \
    "$target_package" \
    "$target_user"; do
    [[ -f "$path" && ! -L "$path" ]] \
        || fail "required rollback path is unsafe: $path"
done
(cd -- "$rollback_dir" && sha256sum --strict -c rollback.sha256 >/dev/null) \
    || fail 'rollback bytes failed SHA-256 verification'
if [[ -e "$temporary_package" && ! -f "$temporary_package" ]] \
    || [[ -L "$temporary_package" ]]; then
    fail 'temporary vxslave-compose package path is unsafe'
fi

package_temp="$(
    mktemp "$vesta_root/data/packages/.vxslave-rollback-package.XXXXXX"
)"
user_temp="$(
    mktemp "$vesta_root/data/users/$owner/.vxslave-rollback-user.XXXXXX"
)"
cp -- "$rollback_package" "$package_temp"
cp -- "$rollback_user" "$user_temp"
chmod --reference="$target_package" "$package_temp"
chmod --reference="$target_user" "$user_temp"
chown --reference="$target_package" "$package_temp" 2>/dev/null || true
chown --reference="$target_user" "$user_temp" 2>/dev/null || true

mv -f -- "$package_temp" "$target_package"
package_temp=''
mv -f -- "$user_temp" "$target_user"
user_temp=''
[[ ! -e "$temporary_package" ]] || rm -- "$temporary_package"

cmp -- "$rollback_package" "$target_package"
cmp -- "$rollback_user" "$target_user"
[[ ! -e "$temporary_package" ]] \
    || fail 'temporary vxslave-compose package was not removed'
printf 'Rollback bytes restored for %s using package %s.\n' \
    "$owner" "$original_package"
