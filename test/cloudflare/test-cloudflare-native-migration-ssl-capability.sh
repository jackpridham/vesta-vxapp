#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

build_verification_runner() {
    local adapter="$1"
    local runner="$2"

    {
        sed -n '1,35p' <<'RUNNER'
#!/usr/bin/env bash

user='test'
domain='example.test'
ssl_dir='/tmp'
WEB_SYSTEM='nginx'
WEB_SSL='yes'
E_FORBIDEN=4

check_args() { :; }
is_format_valid() { :; }
is_system_enabled() { :; }
is_object_valid() { :; }
is_object_unsuspended() { printf '%s\n' "$1" >>"$CALL_LOG"; }
is_object_value_empty() { :; }
is_object_value_exist() { :; }
is_web_domain_cert_valid() { :; }
vx_cf_record_path() { printf '/does/not/exist/record\n'; }
vx_cf_certificate_path() { printf '/does/not/exist/certificate\n'; }
vx_cf_metadata_exists() { [ "${MANAGED:-no}" = yes ]; }
vx_cf_certificate_metadata_exists() { return 1; }
check_result() { exit 42; }
RUNNER
        awk '
            /# *Verifications/ { in_verifications = 1; next }
            in_verifications && /# *Action/ { exit }
            in_verifications { print }
        ' "$adapter"
    } >"$runner"
    chmod 0700 "$runner"
}

run_case() {
    local runner="$1"
    local argument_count="$2"
    local origin_ssl="$3"
    local migration="$4"
    local managed="$5"
    local expected_status="$6"
    local expected_calls="$7"
    local call_log="$tmp_root/calls"
    local status actual_calls
    local -a command=(
        env
        -u VX_CLOUDFLARE_INTERNAL_ORIGIN_SSL
        -u VX_CLOUDFLARE_INTERNAL_MIGRATION
        "CALL_LOG=$call_log"
        "MANAGED=$managed"
    )

    [ "$origin_ssl" = yes ] \
        && command+=(VX_CLOUDFLARE_INTERNAL_ORIGIN_SSL=1)
    [ "$migration" = yes ] \
        && command+=(VX_CLOUDFLARE_INTERNAL_MIGRATION=1)
    command+=("$runner")
    if [ "$argument_count" -eq 2 ]; then
        command+=(test example.test)
    else
        command+=(test example.test /tmp)
    fi

    : >"$call_log"
    set +e
    "${command[@]}" >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq "$expected_status" ] \
        || fail "unexpected status $status for $(basename "$runner")"
    actual_calls="$(cat "$call_log")"
    [ "$actual_calls" = "$expected_calls" ] \
        || fail "unexpected suspension checks for $(basename "$runner")"
}

for adapter_name in \
    v-add-web-domain-ssl \
    v-change-web-domain-sslcert \
    v-delete-web-domain-ssl; do
    adapter="$repo_root/bin/$adapter_name"
    runner="$tmp_root/$adapter_name"
    argument_count=3
    [ "$adapter_name" = v-delete-web-domain-ssl ] && argument_count=2
    build_verification_runner "$adapter" "$runner"

    run_case "$runner" "$argument_count" no no no 0 $'user\nweb'
    run_case "$runner" "$argument_count" yes no no 0 $'user\nweb'
    run_case "$runner" "$argument_count" no yes no 0 $'user\nweb'
    run_case "$runner" "$argument_count" yes yes no 0 ''

    # Migration alone neither bypasses suspension checks nor the managed guard.
    run_case "$runner" "$argument_count" no yes yes 42 $'user\nweb'
    # Origin authority alone retains its existing managed guard bypass, but it
    # cannot bypass suspension checks without the migration capability.
    run_case "$runner" "$argument_count" yes no yes 0 $'user\nweb'
    run_case "$runner" "$argument_count" yes yes yes 0 ''
done

printf 'PASS: native SSL migration suspension capability\n'
