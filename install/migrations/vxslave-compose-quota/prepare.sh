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

quota_file_value() {
    local file="$1"
    local key="$2"
    local -a values=()

    mapfile -t values < <(
        sed -n "s/^${key}='\\([^']*\\)'$/\\1/p" "$file"
    )
    [[ "${#values[@]}" -eq 1 && -n "${values[0]}" ]] \
        || fail "missing or duplicate quota value: $key"
    printf '%s\n' "${values[0]}"
}

quota_value_normalize() {
    local field="$1"
    local value="$2"

    if [[ "$field" == DOCKER_CPUS ]]; then
        [[ "$value" =~ ^[0-9]+([.][0-9]{1,3})?$ ]] \
            || fail "invalid authoritative usage value: U_$field"
        awk -v value="$value" 'BEGIN { printf "%.3f\n", value }'
        return
    fi
    [[ "$value" =~ ^[0-9]+$ ]] \
        || fail "invalid authoritative usage value: U_$field"
    printf '%s\n' "$value"
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

quota_fields=(
    DOCKER_PROJECTS
    DOCKER_SERVICES
    DOCKER_CPUS
    DOCKER_MEMORY_MB
    DOCKER_PIDS
    DOCKER_STORAGE_MB
    DOCKER_PORTS
    DOCKER_SECRETS
    DOCKER_VOLUMES
)
declare -a expected_limits=()
declare -a expected_used=()
for field in "${quota_fields[@]}"; do
    limit="$(quota_file_value "$quota_file" "$field")"
    usage="$(quota_file_value "$source_user" "U_$field")"
    expected_limits+=("$(quota_value_normalize "$field" "$limit")")
    expected_used+=("$(quota_value_normalize "$field" "$usage")")
done
limits_json="$(
    jq -cn --args '$ARGS.positional' -- "${expected_limits[@]}"
)"
used_json="$(jq -cn --args '$ARGS.positional' -- "${expected_used[@]}")"
jq -cn \
    --argjson package_values "$limits_json" \
    --argjson effective_values "$limits_json" \
    --argjson used "$used_json" \
    '{
        PACKAGE_VALUES:$package_values,
        EFFECTIVE_VALUES:$effective_values,
        USED:$used
    }' >"$output_dir/expected-quota.json"
chmod 0600 "$output_dir/expected-quota.json"
expected_quota_sha="$(
    sha256sum "$output_dir/expected-quota.json" | awk '{print $1}'
)"

cat >"$output_dir/preview.sha256" <<EOF
$source_sha  source-package
$candidate_sha  vxslave-compose.pkg
$rollback_sha  rollback.pkg
$rollback_user_sha  rollback-user.conf
$expected_quota_sha  expected-quota.json
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
PRECONDITION: verify expected-quota.json SHA-256 is $expected_quota_sha.
PRECONDITION: authoritative source usage is $used_json.

APPLY:
sudo /usr/local/vesta/bin/v-add-user-package '$output_dir' vxslave-compose
sudo /usr/local/vesta/bin/v-change-user-package slave vxslave-compose
sudo /usr/local/vesta/bin/v-update-user-counters slave
sudo /usr/local/vesta/bin/v-list-docker-compose-quota slave json

ASSERT:
sudo /usr/local/vesta/bin/v-list-docker-compose-quota slave json | jq -e --argjson expected_limits '$limits_json' --argjson expected_used '$used_json' '.PACKAGE == "vxslave-compose" and [.QUOTAS[].PACKAGE_VALUE] == \$expected_limits and [.QUOTAS[].EFFECTIVE_VALUE] == \$expected_limits and [.QUOTAS[].USED] == \$expected_used'

ROLLBACK:
sudo /usr/local/vesta/install/migrations/vxslave-compose-quota/rollback.sh '$output_dir' slave '$original_package' /usr/local/vesta
sudo cmp '$output_dir/rollback.pkg' '/usr/local/vesta/data/packages/$original_package.pkg'
sudo cmp '$output_dir/rollback-user.conf' /usr/local/vesta/data/users/slave/user.conf
sudo test ! -e /usr/local/vesta/data/packages/vxslave-compose.pkg
EOF
chmod 0600 "$output_dir/preview.sha256" \
    "$output_dir/rollback.sha256" "$output_dir/apply-and-rollback.txt" \
    "$output_dir/expected-quota.json"

printf 'SOURCE_SHA256=%s\n' "$source_sha"
printf 'CANDIDATE_SHA256=%s\n' "$candidate_sha"
printf 'ROLLBACK_SHA256=%s\n' "$rollback_sha"
printf 'ROLLBACK_USER_SHA256=%s\n' "$rollback_user_sha"
printf 'EXPECTED_QUOTA_SHA256=%s\n' "$expected_quota_sha"
printf 'PROCEDURE=%s\n' "$output_dir/apply-and-rollback.txt"
