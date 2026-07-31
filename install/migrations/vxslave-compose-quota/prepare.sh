#!/usr/bin/env bash
set -Eeuo pipefail

migration_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
quota_file="$migration_root/docker-quota.conf"
source_package="${1:-}"
source_user="${2:-}"
output_dir="${3:-}"
original_package="${4:-}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

[[ -n "$source_package" && -n "$source_user" && -n "$output_dir" \
    && -n "$original_package" ]] \
    || fail \
        'usage: prepare.sh SOURCE_PACKAGE SOURCE_USER OUTPUT_DIR ORIGINAL_PACKAGE'
[[ "$original_package" =~ ^[A-Za-z0-9._-]+$ ]] \
    || fail 'invalid original package name'
[[ "$output_dir" =~ ^/[A-Za-z0-9._/-]+$ && "$output_dir" != *'/../'* ]] \
    || fail 'output directory must be an absolute shell-safe path'
[[ "$(basename -- "$source_package")" != default.pkg ]] \
    || fail 'the shared default package must not be a migration source'
[[ -f "$source_package" && ! -L "$source_package" ]] \
    || fail 'source package must be a regular non-symlink file'
[[ -f "$source_user" && ! -L "$source_user" ]] \
    || fail 'source user configuration must be a regular non-symlink file'
[[ ! -e "$output_dir" ]] || fail 'output directory already exists'

mkdir -m 0700 -- "$output_dir"
cp -- "$source_package" "$output_dir/rollback.pkg"
cp -- "$source_user" "$output_dir/rollback-user.conf"
chmod 0600 "$output_dir/rollback.pkg"
chmod 0600 "$output_dir/rollback-user.conf"

awk -v quota_file="$quota_file" '
    BEGIN {
        while ((getline line < quota_file) > 0) {
            key = line
            sub(/=.*/, "", key)
            quota[key] = line
            order[++count] = key
        }
        close(quota_file)
    }
    {
        key = $0
        sub(/=.*/, "", key)
        if (key in quota) {
            if (!written[key]++) {
                print quota[key]
            }
            next
        }
        print
    }
    END {
        for (i = 1; i <= count; i++) {
            key = order[i]
            if (!written[key]) {
                print quota[key]
            }
        }
    }
' "$source_package" >"$output_dir/vxslave-compose.pkg"
chmod 0600 "$output_dir/vxslave-compose.pkg"

source_sha="$(sha256sum "$source_package" | awk '{print $1}')"
candidate_sha="$(
    sha256sum "$output_dir/vxslave-compose.pkg" | awk '{print $1}'
)"
rollback_sha="$(sha256sum "$output_dir/rollback.pkg" | awk '{print $1}')"
user_sha="$(sha256sum "$source_user" | awk '{print $1}')"
rollback_user_sha="$(
    sha256sum "$output_dir/rollback-user.conf" | awk '{print $1}'
)"
[[ "$source_sha" == "$rollback_sha" ]] \
    || fail 'rollback bytes differ from the source package'
[[ "$user_sha" == "$rollback_user_sha" ]] \
    || fail 'rollback bytes differ from the source user configuration'

cat >"$output_dir/preview.sha256" <<EOF
$source_sha  source-package
$candidate_sha  vxslave-compose.pkg
$rollback_sha  rollback.pkg
$rollback_user_sha  rollback-user.conf
EOF
cat >"$output_dir/rollback.sha256" <<EOF
$rollback_sha  rollback.pkg
$rollback_user_sha  rollback-user.conf
EOF
cat >"$output_dir/apply-and-rollback.txt" <<EOF
PRECONDITION: production remains read-only until separately authorized.
PRECONDITION: verify current owner slave uses package $original_package.
PRECONDITION: verify source-package SHA-256 is $source_sha.
PRECONDITION: verify vxslave-compose.pkg SHA-256 is $candidate_sha.
PRECONDITION: verify rollback-user.conf SHA-256 is $rollback_user_sha.

APPLY:
sudo /usr/local/vesta/bin/v-add-user-package '$output_dir' vxslave-compose
sudo /usr/local/vesta/bin/v-change-user-package slave vxslave-compose
sudo /usr/local/vesta/bin/v-update-user-counters slave
sudo /usr/local/vesta/bin/v-list-docker-compose-quota slave json

ASSERT:
sudo /usr/local/vesta/bin/v-list-docker-compose-quota slave json | jq -e '.PACKAGE == "vxslave-compose" and [.QUOTAS[].EFFECTIVE_VALUE] == ["1","1","1.000","1024","256","1024","1","1","2"] and [.QUOTAS[].USED] == ["1","1","1.000","1024","256","1024","1","1","2"]'

ROLLBACK:
sudo /usr/local/vesta/install/migrations/vxslave-compose-quota/rollback.sh '$output_dir' slave '$original_package' /usr/local/vesta
sudo cmp '$output_dir/rollback.pkg' '/usr/local/vesta/data/packages/$original_package.pkg'
sudo cmp '$output_dir/rollback-user.conf' /usr/local/vesta/data/users/slave/user.conf
sudo test ! -e /usr/local/vesta/data/packages/vxslave-compose.pkg
EOF
chmod 0600 "$output_dir/preview.sha256" \
    "$output_dir/rollback.sha256" "$output_dir/apply-and-rollback.txt"

printf 'SOURCE_SHA256=%s\n' "$source_sha"
printf 'CANDIDATE_SHA256=%s\n' "$candidate_sha"
printf 'ROLLBACK_SHA256=%s\n' "$rollback_sha"
printf 'ROLLBACK_USER_SHA256=%s\n' "$rollback_user_sha"
printf 'PROCEDURE=%s\n' "$output_dir/apply-and-rollback.txt"
