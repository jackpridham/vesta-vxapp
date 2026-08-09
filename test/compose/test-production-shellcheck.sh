#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/test/compose/run-production-shellcheck.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir -p "$fixture/bin"
cat >"$fixture/bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
call=0
if [[ -n "${VX_TEST_SHELLCHECK_COUNT:-}" ]]; then
    call="$(<"$VX_TEST_SHELLCHECK_COUNT")"
    call=$((call + 1))
    printf '%s\n' "$call" >"$VX_TEST_SHELLCHECK_COUNT"
fi
{
    echo BEGIN
    printf '%s\n' "$@"
    echo END
} >>"$VX_TEST_SHELLCHECK_LOG"
if [[ -n "${VX_TEST_SHELLCHECK_FAIL_CALL:-}"
    && "$call" -eq "$VX_TEST_SHELLCHECK_FAIL_CALL" ]]; then
    exit "${VX_TEST_SHELLCHECK_FAIL_STATUS:-41}"
fi
EOF
chmod 755 "$fixture/bin/shellcheck"

shellcheck_log="$fixture/shellcheck.log"
PATH="$fixture/bin:$PATH" VX_TEST_SHELLCHECK_LOG="$shellcheck_log" \
    "$runner" >"$fixture/success.out" 2>"$fixture/success.err"

mapfile -t expected_adapters < <(
    {
        find "$repo_root/bin" -maxdepth 1 -type f -name 'v-*docker*' \
            -printf 'bin/%f\n'
        printf '%s\n' \
            bin/v-check-docker-engine \
            bin/v-install-docker-service \
            bin/v-update-sys-rrd-docker
    } | sort -u
)
for adapter in "${expected_adapters[@]}"; do
    [[ "$(grep -Fxc "$adapter" "$shellcheck_log")" -eq 1 ]] \
        || fail "adapter was not analyzed exactly once: ${adapter##*/}"
done

mapfile -t expected_helpers < <(
    find "$repo_root/func/vx/compose" -type f -name '*.sh' \
        -printf 'func/vx/compose/%f\n' | sort
)
for helper in "${expected_helpers[@]}"; do
    helper_name=${helper##*/}
    expected_occurrences=1
    if [[ "$helper_name" == main.sh ]]; then
        expected_occurrences=2
    else
        grep -Fq "source \"\$_vx_compose_dir/$helper_name\"" \
            "$repo_root/func/vx/compose/main.sh" \
            || fail "Compose graph root does not source helper: $helper_name"
    fi
    [[ "$(grep -Fxc "$helper" "$shellcheck_log")" -eq "$expected_occurrences" ]] \
        || fail "helper analysis count is wrong: $helper_name"
done

expected_calls=$((${#expected_adapters[@]} + ${#expected_helpers[@]} + 1))
[[ "$(grep -c '^BEGIN$' "$shellcheck_log")" -eq "$expected_calls" ]] \
    || fail 'production ShellCheck invocation count is not locally scoped'
[[ "$(grep -c '^-x$' "$shellcheck_log")" -eq 1 ]] \
    || fail 'source following must occur exactly once'
[[ "$(grep -c '^--extended-analysis=false$' "$shellcheck_log")" -eq 1 ]] \
    || fail 'bounded graph scan must disable redundant extended analysis once'
[[ "$(grep -c '^ShellCheck ' "$fixture/success.err")" -eq "$expected_calls" ]] \
    || fail 'ShellCheck progress did not name every bounded scope'

first_call="$fixture/first-call"
last_call="$fixture/last-call"
awk '/^BEGIN$/ { call++; next } /^END$/ { next } call == 1 { print }' \
    "$shellcheck_log" >"$first_call"
awk -v wanted="$expected_calls" \
    '/^BEGIN$/ { call++; next } /^END$/ { next } call == wanted { print }' \
    "$shellcheck_log" >"$last_call"
grep -Fxq -- '-S' "$first_call" \
    || fail 'adapter-local scan omitted warning severity'
if grep -Fxq -- '-x' "$first_call"; then
    fail 'adapter-local scan unexpectedly followed shared sources'
fi
grep -Fxq -- '-x' "$last_call" \
    || fail 'final shared graph scan did not follow sources'
grep -Fxq -- '--extended-analysis=false' "$last_call" \
    || fail 'final shared graph scan retained redundant extended analysis'

grep -Fq 'bash test/compose/run-production-shellcheck.sh' \
    "$repo_root/test/compose/run-production-readiness.sh" \
    || fail 'production readiness gate does not use optimized ShellCheck'
if grep -Eq 'xargs.*shellcheck|shellcheck.*xargs' \
    "$repo_root/test/compose/run-production-readiness.sh"; then
    fail 'production readiness gate retains per-file ShellCheck expansion'
fi

count_file="$fixture/call-count"
printf '0\n' >"$count_file"
set +e
PATH="$fixture/bin:$PATH" \
VX_TEST_SHELLCHECK_LOG="$fixture/failure.log" \
VX_TEST_SHELLCHECK_COUNT="$count_file" \
VX_TEST_SHELLCHECK_FAIL_CALL=2 \
    "$runner" >"$fixture/failure.out" 2>"$fixture/failure.err"
status=$?
set -e
[[ $status -eq 41 ]] || fail 'local ShellCheck failure status was not preserved'
[[ "$(<"$count_file")" -eq 2 ]] \
    || fail 'ShellCheck strategy did not stop at the local failure'
grep -Fq "FAIL: ShellCheck adapter ${expected_adapters[1]} exited with status 41" \
    "$fixture/failure.err" \
    || fail 'local ShellCheck failure did not identify its file'

printf '0\n' >"$count_file"
set +e
PATH="$fixture/bin:$PATH" \
VX_TEST_SHELLCHECK_LOG="$fixture/timeout.log" \
VX_TEST_SHELLCHECK_COUNT="$count_file" \
VX_TEST_SHELLCHECK_FAIL_CALL=1 \
VX_TEST_SHELLCHECK_FAIL_STATUS=124 \
    "$runner" >"$fixture/timeout.out" 2>"$fixture/timeout.err"
status=$?
set -e
[[ $status -eq 124 ]] || fail 'ShellCheck timeout status was not preserved'
[[ "$(<"$count_file")" -eq 1 ]] \
    || fail 'ShellCheck strategy did not stop at the timed-out scope'
grep -Fq "FAIL: ShellCheck adapter ${expected_adapters[0]} exceeded its 30-second resource bound" \
    "$fixture/timeout.err" \
    || fail 'ShellCheck timeout did not identify its file and bound'

echo "Production ShellCheck strategy tests passed."
