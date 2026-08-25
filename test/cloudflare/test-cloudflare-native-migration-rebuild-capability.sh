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
        sed -n '1,30p' <<'RUNNER'
#!/usr/bin/env bash

user='test'
domain='example.test'
template='default'
WEB_SYSTEM='nginx'
WEB_BACKEND='php-fpm'

check_args() { :; }
is_format_valid() { :; }
is_system_enabled() { :; }
is_object_valid() { :; }
is_object_unsuspended() { printf '%s\n' "$1" >>"$CALL_LOG"; }
is_backend_template_valid() { :; }
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
    local migration_value="$3"
    local expected_calls="$4"
    local call_log="$tmp_root/calls"
    local actual_calls
    local -a command=(
        env
        -u VX_CLOUDFLARE_INTERNAL_MIGRATION
        "CALL_LOG=$call_log"
    )

    [ "$migration_value" = unset ] \
        || command+=("VX_CLOUDFLARE_INTERNAL_MIGRATION=$migration_value")
    command+=("$runner" test)
    [ "$argument_count" -eq 2 ] && command+=(example.test)

    : >"$call_log"
    "${command[@]}" >/dev/null 2>&1 \
        || fail "verification failed for $(basename "$runner")"
    actual_calls="$(cat "$call_log")"
    [ "$actual_calls" = "$expected_calls" ] \
        || fail "unexpected suspension checks for $(basename "$runner")"
}

for adapter_name in v-rebuild-web-domains v-add-web-domain-backend; do
    adapter="$repo_root/bin/$adapter_name"
    runner="$tmp_root/$adapter_name"
    argument_count=1
    [ "$adapter_name" = v-add-web-domain-backend ] && argument_count=2
    build_verification_runner "$adapter" "$runner"

    run_case "$runner" "$argument_count" unset user
    run_case "$runner" "$argument_count" 0 user
    run_case "$runner" "$argument_count" yes user
    run_case "$runner" "$argument_count" 1 ''

    if grep -F "is_object_unsuspended 'web'" "$adapter" >/dev/null; then
        fail "$adapter_name added a domain suspension gate"
    fi
    if grep -E 'update_object_value.*SUSPENDED' "$adapter" >/dev/null; then
        fail "$adapter_name mutates domain suspension state"
    fi
done

grep -F 'rebuild_web_domain_conf' "$repo_root/bin/v-rebuild-web-domains" \
    >/dev/null || fail 'per-domain rebuild call is missing'
grep -F 'if [ "${VX_CLOUDFLARE_INTERNAL_MIGRATION:-}" != 1 ]; then' \
    "$repo_root/bin/v-rebuild-web-domains" >/dev/null \
    || fail 'internal migration rebuild does not isolate unrelated counters'

counter_bin="$tmp_root/counter-bin"
counter_runner="$tmp_root/counter-runner"
mkdir -p "$counter_bin"
cat >"$counter_bin/v-update-user-counters" <<'COUNTER_STUB'
#!/usr/bin/env bash
printf 'updated\n' >>"$CALL_LOG"
COUNTER_STUB
chmod 0700 "$counter_bin/v-update-user-counters"
{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        "BIN='$counter_bin'" "user='test'"
    awk '
        /# Updating user counters/ { capture=1; next }
        capture && /# Restarting web server/ { exit }
        capture { print }
    ' "$repo_root/bin/v-rebuild-web-domains"
} >"$counter_runner"
chmod 0700 "$counter_runner"
for migration_value in unset 0 yes 1; do
    call_log="$tmp_root/counter-$migration_value"
    command=(env -u VX_CLOUDFLARE_INTERNAL_MIGRATION "CALL_LOG=$call_log")
    [ "$migration_value" = unset ] \
        || command+=("VX_CLOUDFLARE_INTERNAL_MIGRATION=$migration_value")
    command+=("$counter_runner")
    "${command[@]}" || fail "counter boundary failed for $migration_value"
    if [ "$migration_value" = 1 ]; then
        [ ! -e "$call_log" ] \
            || fail 'internal migration rebuild updated unrelated counters'
    else
        [ "$(cat "$call_log")" = updated ] \
            || fail "ordinary rebuild skipped counters for $migration_value"
    fi
done

printf 'PASS: native migration rebuild suspension capability\n'
