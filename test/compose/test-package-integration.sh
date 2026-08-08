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
    DOCKER_REGISTRY_MB
    DOCKER_PORTS
    DOCKER_SECRETS
    DOCKER_VOLUMES
)

# shellcheck source=func/vx/compose/package.sh
source "$repo_root/func/vx/compose/quota.sh"
source "$repo_root/func/vx/compose/package.sh"
grep -Fq 'source "$_vx_compose_dir/package.sh"' \
    "$repo_root/func/vx/compose/main.sh" \
    || fail 'Compose consumers do not source package.sh'

if vx_compose_package_docker_is_enabled 0; then
    fail 'zero Compose projects incorrectly enables Docker access'
fi
if ! vx_compose_package_docker_is_enabled 3; then
    fail 'positive Compose projects does not enable Docker access'
fi
if ! vx_compose_package_docker_is_enabled unlimited; then
    fail 'unlimited Compose projects does not enable Docker access'
fi
if ! vx_compose_package_docker_is_enabled 09; then
    fail 'leading-zero Compose project limit was not treated as base 10'
fi
for malformed_limit in -1 1.5 malformed 2147483648 999999999999999999999999999999; do
    if vx_compose_package_docker_is_enabled "$malformed_limit"; then
        fail "malformed Compose project limit was enabled: $malformed_limit"
    fi
done

[[ "$(vx_compose_package_integer_normalize 0009)" == 9 ]] \
    || fail 'leading-zero quota did not normalize canonically'
[[ "$(vx_compose_package_integer_normalize 2147483647)" == 2147483647 ]] \
    || fail 'maximum bounded quota was rejected'
if vx_compose_package_integer_normalize 2147483648 >/dev/null; then
    fail 'above-maximum quota was accepted'
fi

legacy_zero="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='0'")"
for field in "${quota_fields[@]}"; do
    grep -Eq "^${field}='0'$" <<<"$legacy_zero" \
        || fail "zero legacy limit did not derive $field=0"
done

grep -Fq 'U_DOCKER_REGISTRY_MB' "$repo_root/bin/v-add-user" \
    || fail 'new users do not persist measured registry usage'
grep -Fq 'U_DOCKER_REGISTRY_MB' "$repo_root/bin/v-change-user-package" \
    || fail 'package changes do not preserve measured registry usage'

legacy_positive="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='3'")"
grep -Eq "^DOCKER_PROJECTS='3'$" <<<"$legacy_positive" \
    || fail 'positive legacy limit did not derive projects'
grep -Eq "^DOCKER_CPUS='3\\.000'$" <<<"$legacy_positive" \
    || fail 'positive legacy limit did not derive CPUs'
grep -Eq "^DOCKER_MEMORY_MB='3072'$" <<<"$legacy_positive" \
    || fail 'positive legacy limit did not derive memory'
grep -Eq "^DOCKER_PIDS='384'$" <<<"$legacy_positive" \
    || fail 'positive legacy limit did not derive PIDs'

legacy_leading_zero="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='09'")"
grep -Eq "^DOCKER_PROJECTS='9'$" <<<"$legacy_leading_zero" \
    || fail 'leading-zero legacy limit was not derived in base 10'
grep -Eq "^DOCKER_MEMORY_MB='9216'$" <<<"$legacy_leading_zero" \
    || fail 'leading-zero legacy arithmetic was not canonical base 10'

legacy_oversized="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='2147483648'")"
for field in "${quota_fields[@]}"; do
    grep -Eq "^${field}='0'$" <<<"$legacy_oversized" \
        || fail "oversized legacy limit did not fail closed for $field"
done

legacy_multiplication_oversized="$(
    vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='2097152'"
)"
for field in "${quota_fields[@]}"; do
    grep -Eq "^${field}='0'$" <<<"$legacy_multiplication_oversized" \
        || fail "multiplication-oversized legacy limit did not fail closed for $field"
done
legacy_multiplication_max="$(
    vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='2097151'"
)"
grep -Eq "^DOCKER_MEMORY_MB='2147482624'$" <<<"$legacy_multiplication_max" \
    || fail 'largest safely derivable legacy memory limit was rejected'

explicit_oversized=$'DOCKER_CONTAINERS=\'1\'\nDOCKER_MEMORY_MB=\'2147483648\''
if vx_compose_package_data_with_defaults "$explicit_oversized" >/dev/null; then
    fail 'oversized explicit Compose package limit was accepted'
fi

for field in "${quota_fields[@]}"; do
    printf -v "$field" '%s' 10
    printf -v "U_$field" '%s' 10
done
# Values below are consumed through indirect expansion by the package helper.
# shellcheck disable=SC2034
DOCKER_CPUS=10.000
# shellcheck disable=SC2034
U_DOCKER_CPUS=10.000
vx_compose_package_usage_is_covered \
    || fail 'usage equal to bounded package limits was rejected'
U_DOCKER_PROJECTS=11
if vx_compose_package_usage_is_covered; then
    fail 'usage above a bounded package limit was accepted'
fi
[[ "$VX_COMPOSE_PACKAGE_OVERAGE_FIELD" == DOCKER_PROJECTS ]] \
    || fail 'above-limit package field was not reported'
U_DOCKER_PROJECTS=09
# shellcheck disable=SC2034
DOCKER_PROJECTS=10
vx_compose_package_usage_is_covered \
    || fail 'leading-zero usage was not compared as base 10'
U_DOCKER_PROJECTS=2147483648
if vx_compose_package_usage_is_covered; then
    fail 'oversized usage failed open'
fi
# shellcheck disable=SC2034
U_DOCKER_PROJECTS=10
# shellcheck disable=SC2034
U_DOCKER_CPUS=2147483648.000
if vx_compose_package_usage_is_covered; then
    fail 'oversized CPU usage failed open'
fi

legacy_unlimited="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='unlimited'")"
for field in "${quota_fields[@]}"; do
    if [[ "$field" == DOCKER_REGISTRY_MB ]]; then
        grep -Eq "^${field}='0'$" <<<"$legacy_unlimited" \
            || fail "registry entitlement did not retain its independent default"
        continue
    fi
    grep -Eq "^${field}='unlimited'$" <<<"$legacy_unlimited" \
        || fail "unlimited legacy limit did not derive $field"
done

legacy_malformed="$(vx_compose_package_data_with_defaults "DOCKER_CONTAINERS='malformed'")"
for field in "${quota_fields[@]}"; do
    grep -Eq "^${field}='0'$" <<<"$legacy_malformed" \
        || fail "malformed legacy limit did not default $field"
done

explicit_fields=$'DOCKER_CONTAINERS=\'3\'\nDOCKER_PROJECTS=\'9\''
explicit_data="$(vx_compose_package_data_with_defaults "$explicit_fields")"
[[ "$(grep -Ec '^DOCKER_PROJECTS=' <<<"$explicit_data")" == 1 ]] \
    || fail 'legacy-derived values overwrite an explicit Compose field'
grep -Eq "^DOCKER_PROJECTS='9'$" <<<"$explicit_data" \
    || fail 'explicit Compose project value did not survive legacy compatibility'

for package_template in \
    "$repo_root/web/templates/admin/add_package.html" \
    "$repo_root/web/templates/admin/edit_package.html"; do
    for field in "${VX_COMPOSE_PACKAGE_FIELDS[@]}"; do
        form_field="v_${field,,}"
        grep -Fq "name=\"$form_field\"" "$package_template" \
            || fail "$package_template does not expose $form_field"
    done
done

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
for lifecycle_file in \
    src/deb/vesta/postinst \
    src/rpm/specs/vesta.spec \
    install/vst-install-debian.sh \
    install/vst-install-ubuntu.sh \
    install/vst-install-rhel.sh \
    install/vst-install-amazon.sh \
    bin/v-install-docker-service; do
    grep -Fq 'v-install-docker-shell-access' "$repo_root/$lifecycle_file" \
        || fail "$lifecycle_file omits Docker shell-access installation"
done

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
grep -Fq 'DOCKER REGISTRY:' "$repo_root/bin/v-list-user-package" \
    || fail 'package shell output omits registry entitlement'
grep -Fq 'DOCKER REGISTRY:' "$repo_root/bin/v-list-user" \
    || fail 'user shell output omits registry entitlement and usage'
grep -Fq 'U_REGISTRY' "$repo_root/bin/v-list-users" \
    || fail 'users shell output omits measured registry usage'

list_root="$test_root/list-surfaces/vesta"
mkdir -p "$list_root/func/vx/compose" "$list_root/data/packages" \
    "$list_root/data/users/alice"
cat >"$list_root/func/main.sh" <<'EOF'
HOMEDIR='/home'
check_args() { :; }
is_format_valid() { :; }
is_package_valid() { :; }
is_object_valid() { :; }
EOF
cat >"$list_root/func/vx/compose/main.sh" <<'EOF'
source "$VX_TEST_REPO_ROOT/func/vx/compose/package.sh"
EOF
cat >"$list_root/data/packages/registry.pkg" <<'EOF'
DOCKER_CONTAINERS='1'
DOCKER_REGISTRY_MB='25'
EOF
cat >"$list_root/data/users/alice/user.conf" <<'EOF'
PACKAGE='registry'
DOCKER_CONTAINERS='1'
DOCKER_REGISTRY_MB='25'
U_DOCKER_REGISTRY_MB='7'
EOF
package_json="$(VESTA="$list_root" VX_TEST_REPO_ROOT="$repo_root" \
    "$repo_root/bin/v-list-user-package" registry json)"
[[ "$(jq -r '.registry.DOCKER_REGISTRY_MB' <<<"$package_json")" == 25 ]] \
    || fail 'package JSON registry entitlement format changed'
package_shell="$(VESTA="$list_root" VX_TEST_REPO_ROOT="$repo_root" \
    "$repo_root/bin/v-list-user-package" registry shell)"
grep -Fxq 'DOCKER REGISTRY: 25 MB' <<<"$package_shell" \
    || fail 'package shell registry entitlement format changed'
user_json="$(VESTA="$list_root" VX_TEST_REPO_ROOT="$repo_root" \
    "$repo_root/bin/v-list-user" alice json)"
[[ "$(jq -r '.alice.DOCKER_REGISTRY_MB,.alice.U_DOCKER_REGISTRY_MB' \
    <<<"$user_json")" == $'25\n7' ]] \
    || fail 'user JSON registry entitlement/usage format changed'
user_shell="$(VESTA="$list_root" VX_TEST_REPO_ROOT="$repo_root" \
    "$repo_root/bin/v-list-user" alice shell)"
grep -Fxq 'DOCKER REGISTRY: 7/25 MB' <<<"$user_shell" \
    || fail 'user shell registry entitlement/usage format changed'
user_plain="$(VESTA="$list_root" VX_TEST_REPO_ROOT="$repo_root" \
    "$repo_root/bin/v-list-user" alice plain)"
[[ "$(awk -F '\t' '{print $(NF-1) ":" $NF}' <<<"$user_plain")" == 25:7 ]] \
    || fail 'user plain registry fields are not appended in exact order'

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

change_root="$test_root/change-package"
export VESTA="$change_root/vesta"
mkdir -p \
    "$VESTA/conf" \
    "$VESTA/data/packages" \
    "$VESTA/data/users/alice" \
    "$VESTA/bin" \
    "$VESTA/func/vx/compose" \
    "$VESTA/func/vx/harbor"
cat >"$VESTA/func/main.sh" <<'EOF'
OK=0
E_INVALID=3
E_LIMIT=4
ARGUMENTS=''
USER_DATA="$VESTA/data/users/$user"
BIN="$VESTA/bin"
check_args() { :; }
is_format_valid() { :; }
is_object_valid() { :; }
is_package_valid() { :; }
is_web_template_valid() { :; }
is_dns_template_valid() { :; }
is_proxy_template_valid() { :; }
log_history() { :; }
log_event() { :; }
check_result() {
    local code="$1" message="$2"
    (( code == 0 )) && return 0
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
: >"$VESTA/func/domain.sh"
cat >"$VESTA/func/vx/compose/main.sh" <<'EOF'
source "$VX_TEST_REPO_ROOT/func/vx/compose/quota.sh"
source "$VX_TEST_REPO_ROOT/func/vx/compose/package.sh"
vx_compose_shell_access_lock_acquire() {
    VX_COMPOSE_ACCESS_LOCK_OWNER="$1"
    printf 'lock\n' >>"$VX_TEST_MUTATIONS"
}
vx_compose_shell_access_lock_release() { :; }
vx_compose_shell_access_deny_establish() {
    printf 'yes\n' >"$VX_TEST_DENY_STATE"
    printf 'deny\n' >>"$VX_TEST_MUTATIONS"
}
vx_compose_shell_access_deny_is_clear() { [[ "$(<"$VX_TEST_DENY_STATE")" == no ]]; }
vx_compose_shell_group_revoke() {
    printf 'no\n' >"$VX_TEST_GROUP_STATE"
    printf 'revoke\n' >>"$VX_TEST_MUTATIONS"
}
vx_compose_shell_group_state() { [[ "$(<"$VX_TEST_GROUP_STATE")" == yes ]]; }
vx_compose_shell_passwd_by_name() {
    printf '%s:x:1:1::/home/%s:%s\n' "$1" "$1" "$(<"$VX_TEST_SHELL_STATE")"
}
vx_compose_shell_access_transition_complete() {
    printf 'yes\n' >"$VX_TEST_GROUP_STATE"
    printf 'no\n' >"$VX_TEST_DENY_STATE"
    printf 'complete\n' >>"$VX_TEST_MUTATIONS"
}
EOF
cat >"$VESTA/func/vx/harbor/main.sh" <<'EOF'
vx_harbor_provider_prepare() { :; }
vx_harbor_provider_lock_acquire() { printf 'provider-lock\n' >>"$VX_TEST_MUTATIONS"; }
vx_harbor_provider_lock_release() { :; }
_vx_harbor_fsync() { :; }
_vx_harbor_transition_shell_set() {
    printf '%s\n' "$2" >"$VX_TEST_SHELL_STATE"
    printf 'shell:%s\n' "$2" >>"$VX_TEST_MUTATIONS"
}
vx_harbor_package_transition_prepare() {
    printf 'prepare:%s:%s\n' "$2" "$3" >>"$VX_TEST_MUTATIONS"
    printf '%s\n' "$5" >"$VX_TEST_OLD_SHELL"
    printf '%s\n' "$6" >"$VX_TEST_OLD_GROUP"
    printf '%s\n' "$7" >"$VX_TEST_OLD_DENY"
    cp -p "$USER_DATA/user.conf" "$VX_TEST_CONF_SNAPSHOT"
    printf 'prepared\n' >"$VX_TEST_TRANSITION_STATE"
    printf 'disabled.token\n'
}
vx_harbor_package_transition_recover() {
    printf 'recover\n' >>"$VX_TEST_MUTATIONS"
    if [[ "$(<"$VX_TEST_TRANSITION_STATE")" == committed ]]; then
        printf 'yes\n' >"$VX_TEST_GROUP_STATE"
        printf 'no\n' >"$VX_TEST_DENY_STATE"
    else
        [[ ! -f "$VX_TEST_CONF_SNAPSHOT" ]] \
            || cp -p "$VX_TEST_CONF_SNAPSHOT" "$USER_DATA/user.conf"
        printf '%s\n' "$(<"$VX_TEST_OLD_SHELL")" >"$VX_TEST_SHELL_STATE"
        printf '%s\n' "$(<"$VX_TEST_OLD_GROUP")" >"$VX_TEST_GROUP_STATE"
        printf '%s\n' "$(<"$VX_TEST_OLD_DENY")" >"$VX_TEST_DENY_STATE"
    fi
    if [[ "$(<"$VX_TEST_TRIGGER_PENDING")" == yes ]]; then
        printf 'trigger:old\n' >>"$VX_TEST_MUTATIONS"
        [[ "${VX_TEST_COMPENSATE_FAIL:-no}" != yes ]] || return 1
        printf 'no\n' >"$VX_TEST_TRIGGER_PENDING"
    fi
    if [[ "$(<"$VX_TEST_DISK_PENDING")" == yes ]]; then
        "$VESTA/bin/v-update-user-quota" alice || return 1
        printf 'no\n' >"$VX_TEST_DISK_PENDING"
    fi
}
vx_harbor_package_transition_user_conf_applied() { printf 'conf-applied\n' >>"$VX_TEST_MUTATIONS"; }
vx_harbor_package_transition_user_conf_apply() {
    cp -p "$3" "$USER_DATA/user.conf"
    printf 'user-conf-applied\n' >"$VX_TEST_TRANSITION_STATE"
    printf 'conf-applied\n' >>"$VX_TEST_MUTATIONS"
}
vx_harbor_package_transition_disk_quota_pending() {
    printf 'yes\n' >"$VX_TEST_DISK_PENDING"
    printf 'quota-pending\n' >>"$VX_TEST_MUTATIONS"
}
vx_harbor_package_transition_trigger_pending() {
    printf 'yes\n' >"$VX_TEST_TRIGGER_PENDING"
    printf 'trigger-pending\n' >>"$VX_TEST_MUTATIONS"
}
vx_harbor_package_transition_side_effects_applied() {
    printf 'side-effects\n' >"$VX_TEST_TRANSITION_STATE"
    printf 'side-effects\n' >>"$VX_TEST_MUTATIONS"
}
vx_harbor_package_transition_commit() {
    printf 'commit\n' >>"$VX_TEST_MUTATIONS"
    [[ "${VX_TEST_COMMIT_FAIL:-no}" != yes ]] || return 1
    printf 'committed\n' >"$VX_TEST_TRANSITION_STATE"
}
vx_harbor_package_transition_access_complete() {
    printf 'access-complete\n' >>"$VX_TEST_MUTATIONS"
    [[ "${VX_TEST_ACCESS_FAIL:-no}" != yes ]] || return 1
    printf 'yes\n' >"$VX_TEST_GROUP_STATE"
    printf 'no\n' >"$VX_TEST_DENY_STATE"
}
vx_harbor_package_transition_finalize() { printf 'finalize\n' >>"$VX_TEST_MUTATIONS"; }
vx_harbor_package_transition_rollback() {
    printf 'rollback\n' >>"$VX_TEST_MUTATIONS"
}
EOF
printf "DISK_QUOTA='no'\n" >"$VESTA/conf/vesta.conf"
cat >"$VESTA/data/users/alice/user.conf" <<'EOF'
PACKAGE='current'
U_DOCKER_PROJECTS='2'
U_DOCKER_SERVICES='0'
U_DOCKER_CPUS='0.000'
U_DOCKER_MEMORY_MB='0'
U_DOCKER_PIDS='0'
U_DOCKER_STORAGE_MB='0'
U_DOCKER_REGISTRY_MB='0'
U_DOCKER_PORTS='0'
U_DOCKER_SECRETS='0'
U_DOCKER_VOLUMES='0'
EOF
change_user_before="$(sha256sum "$VESTA/data/users/alice/user.conf")"
mutations="$change_root/mutations"
: >"$mutations"
export VX_TEST_SHELL_STATE="$change_root/shell.state"
export VX_TEST_GROUP_STATE="$change_root/group.state"
export VX_TEST_DENY_STATE="$change_root/deny.state"
export VX_TEST_OLD_SHELL="$change_root/old-shell.state"
export VX_TEST_OLD_GROUP="$change_root/old-group.state"
export VX_TEST_OLD_DENY="$change_root/old-deny.state"
export VX_TEST_CONF_SNAPSHOT="$change_root/user.conf.before"
export VX_TEST_TRANSITION_STATE="$change_root/transition.state"
export VX_TEST_TRIGGER_PENDING="$change_root/trigger-pending.state"
export VX_TEST_DISK_PENDING="$change_root/disk-pending.state"
printf '/bin/bash\n' >"$VX_TEST_SHELL_STATE"
printf 'yes\n' >"$VX_TEST_GROUP_STATE"
printf 'no\n' >"$VX_TEST_DENY_STATE"
printf 'idle\n' >"$VX_TEST_TRANSITION_STATE"
printf 'no\n' >"$VX_TEST_TRIGGER_PENDING"
printf 'no\n' >"$VX_TEST_DISK_PENDING"
cat >"$VESTA/bin/v-update-user-quota" <<'EOF'
#!/usr/bin/env bash
printf 'disk-quota\n' >>"$VX_TEST_MUTATIONS"
[[ "${VX_TEST_DISK_FAIL:-no}" != yes ]]
EOF
chmod +x "$VESTA/bin/v-update-user-quota"
cat >"$VESTA/data/packages/under.pkg" <<'EOF'
DOCKER_CONTAINERS='1'
DOCKER_PROJECTS='1'
EOF
if VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
    "$repo_root/bin/v-change-user-package" alice under yes \
    >"$change_root/under.out" 2>&1; then
    fail 'forced package update bypassed Compose usage coverage'
fi
grep -Fq "Package doesn't cover DOCKER_PROJECTS usage" "$change_root/under.out" \
    || fail 'forced under-coverage returned the wrong diagnostic'
[[ ! -s "$mutations" ]] || fail 'forced under-coverage reached package mutation'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf")" == "$change_user_before" ]] \
    || fail 'forced under-coverage changed user.conf'

cat >"$VESTA/data/packages/oversized.pkg" <<'EOF'
DOCKER_CONTAINERS='1'
DOCKER_MEMORY_MB='2147483648'
EOF
if VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
    "$repo_root/bin/v-change-user-package" alice oversized yes \
    >"$change_root/oversized.out" 2>&1; then
    fail 'forced package update propagated an oversized Compose limit'
fi
grep -Fq 'Docker package limits are invalid' "$change_root/oversized.out" \
    || fail 'forced oversized update returned the wrong diagnostic'
[[ ! -s "$mutations" ]] || fail 'forced oversized update reached package mutation'
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf")" == "$change_user_before" ]] \
    || fail 'forced oversized update changed user.conf'

cat >"$VESTA/data/packages/registry.pkg" <<'EOF'
DOCKER_CONTAINERS='1'
DOCKER_PROJECTS='2'
DOCKER_REGISTRY_MB='10'
SHELL='sh'
EOF
: >"$mutations"
printf "DISK_QUOTA='yes'\n" >"$VESTA/conf/vesta.conf"
if VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
    VX_TEST_COMMIT_FAIL=yes \
    "$repo_root/bin/v-change-user-package" alice registry yes \
    >"$change_root/registry-rollback.out" 2>&1; then
    fail 'package transition succeeded after Harbor commit failure'
fi
printf "DISK_QUOTA='no'\n" >"$VESTA/conf/vesta.conf"
[[ "$(sha256sum "$VESTA/data/users/alice/user.conf")" == "$change_user_before" ]] \
    || fail 'Harbor transition failure did not restore exact user.conf content'
[[ "$(<"$VX_TEST_SHELL_STATE")" == /bin/bash ]] \
    || fail 'Harbor transition failure did not restore the login shell'
[[ "$(<"$VX_TEST_GROUP_STATE")" == yes ]] \
    || fail 'Harbor transition failure did not restore Compose group membership'
[[ "$(<"$VX_TEST_DENY_STATE")" == no ]] \
    || fail 'Harbor transition failure did not restore the deny marker state'
grep -Fq 'recover' "$mutations" \
    || fail 'Harbor transition failure did not restore the previous quota'
[[ "$(grep -c '^disk-quota$' "$mutations")" == 2 ]] \
    || fail 'later package failure did not reapply the old disk quota'
[[ "$(sed -n '1p' "$mutations")" == provider-lock ]] \
    || fail 'package transition did not take the provider lock first'
[[ "$(sed -n '2p' "$mutations")" == lock ]] \
    || fail 'package transition did not take the owner lock second'

cat >"$VESTA/data/packages/registry.sh" <<'EOF'
#!/usr/bin/env bash
printf 'trigger:new\n' >>"$VX_TEST_MUTATIONS"
[[ "${VX_TEST_TRIGGER_FAIL:-no}" != yes ]]
EOF
chmod +x "$VESTA/data/packages/registry.sh"
cat >"$VESTA/data/packages/current.sh" <<'EOF'
#!/usr/bin/env bash
printf 'trigger:old-direct\n' >>"$VX_TEST_MUTATIONS"
EOF
chmod +x "$VESTA/data/packages/current.sh"
for failure in trigger disk; do
    cp -p "$VX_TEST_CONF_SNAPSHOT" "$VESTA/data/users/alice/user.conf"
    printf '/bin/bash\n' >"$VX_TEST_SHELL_STATE"
    printf 'yes\n' >"$VX_TEST_GROUP_STATE"
    printf 'no\n' >"$VX_TEST_DENY_STATE"
    : >"$mutations"
    if [[ "$failure" == disk ]]; then
        printf "DISK_QUOTA='yes'\n" >"$VESTA/conf/vesta.conf"
        failure_env=VX_TEST_DISK_FAIL=yes
    else
        failure_env=VX_TEST_TRIGGER_FAIL=yes
    fi
    if env VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
        "$failure_env" "$repo_root/bin/v-change-user-package" alice registry yes \
        >"$change_root/$failure.out" 2>&1; then
        fail "$failure failure incorrectly reported package success"
    fi
    [[ "$(sha256sum "$VESTA/data/users/alice/user.conf")" == "$change_user_before" ]] \
        || fail "$failure failure did not restore user.conf"
    [[ "$(<"$VX_TEST_SHELL_STATE")" == /bin/bash \
        && "$(<"$VX_TEST_GROUP_STATE")" == yes \
        && "$(<"$VX_TEST_DENY_STATE")" == no ]] \
        || fail "$failure failure did not restore shell access authority"
    grep -Fq 'trigger:old' "$mutations" \
        || fail "$failure failure did not compensate the old package trigger"
    printf "DISK_QUOTA='no'\n" >"$VESTA/conf/vesta.conf"
done

cp -p "$VX_TEST_CONF_SNAPSHOT" "$VESTA/data/users/alice/user.conf"
printf 'no\n' >"$VX_TEST_TRIGGER_PENDING"
: >"$mutations"
printf "DISK_QUOTA='yes'\n" >"$VESTA/conf/vesta.conf"
if env VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
    VX_TEST_DISK_FAIL=yes VX_TEST_COMPENSATE_FAIL=yes \
    "$repo_root/bin/v-change-user-package" alice registry yes \
    >"$change_root/compensation-failure.out" 2>&1; then
    fail 'failed old-package compensation reported package success'
fi
[[ "$(<"$VX_TEST_TRIGGER_PENDING")" == yes ]] \
    || fail 'failed trigger compensation discarded durable retry state'
grep -Fq 'trigger:old' "$mutations" \
    || fail 'failed trigger compensation was not attempted'
printf "DISK_QUOTA='no'\n" >"$VESTA/conf/vesta.conf"

cp -p "$VX_TEST_CONF_SNAPSHOT" "$VESTA/data/users/alice/user.conf"
printf '/bin/bash\n' >"$VX_TEST_SHELL_STATE"
printf 'yes\n' >"$VX_TEST_GROUP_STATE"
printf 'no\n' >"$VX_TEST_DENY_STATE"
: >"$mutations"
VX_TEST_REPO_ROOT="$repo_root" VX_TEST_MUTATIONS="$mutations" \
    VX_TEST_ACCESS_FAIL=yes \
    "$repo_root/bin/v-change-user-package" alice registry yes \
    >"$change_root/access-warning.out" 2>&1 \
    || fail 'recoverable post-commit access failure reported package failure'
grep -Fq "PACKAGE='registry'" "$VESTA/data/users/alice/user.conf" \
    || fail 'post-commit access recovery rolled back new user.conf'
[[ "$(<"$VX_TEST_GROUP_STATE")" == yes && "$(<"$VX_TEST_DENY_STATE")" == no ]] \
    || fail 'post-commit access recovery did not converge group/deny state'
grep -Fq 'Warning: package changed' "$change_root/access-warning.out" \
    || fail 'recovered post-commit access failure omitted its warning'

echo "Compose package integration tests passed."
