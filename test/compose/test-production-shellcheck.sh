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
    exit 41
fi
EOF
chmod 755 "$fixture/bin/shellcheck"

shellcheck_log="$fixture/shellcheck.log"
PATH="$fixture/bin:$PATH" VX_TEST_SHELLCHECK_LOG="$shellcheck_log" \
    "$runner"

[[ "$(grep -c '^BEGIN$' "$shellcheck_log")" -eq 2 ]] \
    || fail 'production ShellCheck must use exactly two invocations'
[[ "$(grep -c '^-x$' "$shellcheck_log")" -eq 1 ]] \
    || fail 'source following must occur exactly once'
[[ "$(grep -Fxc 'func/vx/compose/main.sh' "$shellcheck_log")" -eq 1 ]] \
    || fail 'Compose helper graph root must be analyzed exactly once'

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

first_call="$fixture/first-call"
awk '/^BEGIN$/ { call++; next } /^END$/ { next } call == 1 { print }' \
    "$shellcheck_log" >"$first_call"
grep -Fxq -- '-S' "$first_call" \
    || fail 'adapter-local scan omitted warning severity'
if grep -Fxq -- '-x' "$first_call"; then
    fail 'adapter-local scan unexpectedly followed shared sources'
fi

while IFS= read -r helper; do
    helper_name=${helper##*/}
    [[ "$helper_name" == main.sh ]] && continue
    grep -Fq "source \"\$_vx_compose_dir/$helper_name\"" \
        "$repo_root/func/vx/compose/main.sh" \
        || fail "Compose graph root does not source helper: $helper_name"
done < <(find "$repo_root/func/vx/compose" -type f -name '*.sh' -print | sort)

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
[[ $status -eq 41 ]] || fail 'ShellCheck graph failure status was not preserved'
[[ "$(<"$count_file")" -eq 2 ]] \
    || fail 'ShellCheck strategy did not stop at the graph failure'

echo "Production ShellCheck strategy tests passed."
