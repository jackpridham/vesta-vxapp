#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/compose-one" \
    "$VESTA/data/users/alice/docker-projects/compose-two"
printf '%s\n' "NAME='legacy-one'" \
    >"$VESTA/data/users/alice/docker.conf"
touch \
    "$VESTA/data/users/alice/docker-projects/compose-one/project.conf" \
    "$VESTA/data/users/alice/docker-projects/compose-two/project.conf"
# shellcheck source=func/vx/docker.sh
source "$repo_root/func/vx/docker.sh"
[[ "$(vx_docker_count_owner_records alice)" == 3 ]] \
    || fail 'legacy container quota does not include Compose projects'

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

cmp -s \
    "$repo_root/conf/vx-docker-policy.conf" \
    "$repo_root/example-of-linux-root-folder/usr/local/vesta/conf/vx-docker-policy.conf" \
    || fail "runtime and synthetic policy defaults differ"

grep -Fq '/usr/local/vesta/bin/v-install-docker-compose-mount-guard' \
    "$repo_root/src/deb/vesta/postinst" \
    || fail 'Vesta package lifecycle omits the Compose mount guard'
guard_line="$(
    grep -n -m1 'v-install-docker-compose-mount-guard defer' \
        "$repo_root/src/deb/vesta/postinst" | cut -d: -f1
)"
fresh_exit_line="$(
    grep -n -m1 '^    exit$' \
        "$repo_root/src/deb/vesta/postinst" | cut -d: -f1
)"
[[ "$guard_line" -lt "$fresh_exit_line" ]] \
    || fail 'fresh-package early exit bypasses the Compose mount guard'
grep -Fq '$VESTA/bin/v-install-docker-compose-mount-guard' \
    "$repo_root/install/vst-install-debian.sh" \
    || fail 'fresh Vesta installer does not activate the Compose mount guard'
grep -Fq '"$VESTA/bin/v-install-docker-compose-mount-guard"' \
    "$repo_root/bin/v-install-docker-service" \
    || fail 'Docker installer omits the Compose mount guard'

while IFS= read -r package_file; do
    for field in "${quota_fields[@]}"; do
        grep -Eq "^${field}='(0|unlimited)'$" "$package_file" \
            || fail "$package_file is missing $field"
    done
done < <(
    find \
        "$repo_root/install/debian" \
        "$repo_root/example-of-linux-root-folder/usr/local/vesta/data/packages" \
        -path '*/packages/*.pkg' -type f -print
)

for command_name in \
    v-add-user \
    v-change-user-package \
    v-update-user-counters \
    v-list-user-package \
    v-list-user \
    v-list-users; do
    grep -Fq 'func/vx/compose/main.sh' "$repo_root/bin/$command_name" \
        || fail "$command_name does not use Compose package helpers"
done

for command_name in v-suspend-user v-unsuspend-user v-delete-user v-rebuild-user; do
    grep -Fq 'func/vx/compose/main.sh' "$repo_root/bin/$command_name" \
        || fail "$command_name does not load Compose owner lifecycle helpers"
done
grep -Fq 'vx_compose_suspend_owner' "$repo_root/bin/v-suspend-user" \
    || fail "user suspension omits Compose projects"
grep -Fq 'vx_compose_unsuspend_owner' "$repo_root/bin/v-unsuspend-user" \
    || fail "user restoration omits Compose projects"
grep -Fq 'vx_compose_remove_owner_runtime' "$repo_root/bin/v-delete-user" \
    || fail "user deletion omits Compose projects"
grep -Fq 'vx_compose_rebuild_owner' "$repo_root/bin/v-rebuild-user" \
    || fail "user rebuild omits Compose projects"

for field in "${quota_fields[@]}"; do
    grep -Fq "\"$field\"" "$repo_root/bin/v-list-user-package" \
        || fail "package JSON omits $field"
    grep -Fq "\"$field\"" "$repo_root/bin/v-list-user" \
        || fail "user JSON omits $field"
    grep -Fq "\"U_$field\"" "$repo_root/bin/v-list-user" \
        || fail "user JSON omits U_$field"
done

package_test_root="$test_root/package-validation"
export VESTA="$package_test_root/vesta"
package_source="$package_test_root/source"
mkdir -p \
    "$VESTA/conf" \
    "$VESTA/data/packages" \
    "$VESTA/func" \
    "$package_source" \
    "$package_test_root/templates/dns" \
    "$package_test_root/templates/web/nginx/php-fpm"

cp "$repo_root/func/domain.sh" "$VESTA/func/domain.sh"
cat >"$VESTA/func/main.sh" <<'EOF'
OK=0
E_EXISTS=4
E_NOTEXIST=5
ARGUMENTS=''

check_args() {
    :
}

is_format_valid() {
    :
}

is_package_valid() {
    :
}

is_int_format_valid() {
    :
}

is_format_valid_shell() {
    :
}

log_history() {
    :
}

log_event() {
    :
}

check_result() {
    local code="$1"
    local message="$2"

    printf '%s\n' "$message" >&2
    exit "$code"
}

parse_object_kv_list_non_eval() {
    local assignment key value

    for assignment in "$@"; do
        key="${assignment%%=*}"
        value="${assignment#*=}"
        value="${value#\'}"
        value="${value%\'}"
        printf -v "$key" '%s' "$value"
    done
}
EOF
cat >"$VESTA/conf/vesta.conf" <<EOF
WEB_SYSTEM='nginx'
WEB_BACKEND='php-fpm'
PROXY_SYSTEM='nginx'
WEBTPL='$package_test_root/templates/web'
DNSTPL='$package_test_root/templates/dns'
EOF

touch \
    "$package_test_root/templates/dns/default.tpl" \
    "$package_test_root/templates/web/nginx/default.tpl" \
    "$package_test_root/templates/web/nginx/default.stpl" \
    "$package_test_root/templates/web/nginx/php-fpm/default.tpl" \
    "$package_test_root/templates/web/nginx/php-fpm/default.stpl"

write_package_fixture() {
    local package_name="$1"

    cat >"$package_source/$package_name.pkg" <<'EOF'
WEB_DOMAINS='1'
WEB_ALIASES='1'
DNS_DOMAINS='1'
DNS_RECORDS='1'
MAIL_DOMAINS='1'
MAIL_ACCOUNTS='1'
DATABASES='1'
CRON_JOBS='1'
DISK_QUOTA='1'
BANDWIDTH='1'
BACKUPS='1'
SHELL='bash'
WEB_TEMPLATE='default'
DNS_TEMPLATE='default'
PROXY_TEMPLATE='default'
EOF
}

assert_invalid_template_blocks_package() {
    local package_name="$1"
    local missing_template="$2"
    local output

    write_package_fixture "$package_name"
    mv "$missing_template" "$missing_template.missing"
    if output="$(
        VESTA="$VESTA" \
            "$repo_root/bin/v-add-user-package" \
            "$package_source" "$package_name" 2>&1
    )"; then
        mv "$missing_template.missing" "$missing_template"
        fail "$package_name accepted a missing template"
    fi
    mv "$missing_template.missing" "$missing_template"
    [[ "$output" == *"template doesn't exist"* ]] \
        || fail "$package_name returned the wrong missing-template diagnostic"
    [[ ! -e "$VESTA/data/packages/$package_name.pkg" ]] \
        || fail "$package_name was copied after template validation failed"
}

assert_invalid_template_blocks_package \
    invalidweb \
    "$package_test_root/templates/web/nginx/php-fpm/default.tpl"
assert_invalid_template_blocks_package \
    invaliddns \
    "$package_test_root/templates/dns/default.tpl"
assert_invalid_template_blocks_package \
    invalidproxy \
    "$package_test_root/templates/web/nginx/default.tpl"

write_package_fixture validtemplates
VESTA="$VESTA" \
    "$repo_root/bin/v-add-user-package" \
    "$package_source" validtemplates
[[ -f "$VESTA/data/packages/validtemplates.pkg" ]] \
    || fail 'valid package was not copied after all template validators passed'

echo "Compose package integration tests passed."
