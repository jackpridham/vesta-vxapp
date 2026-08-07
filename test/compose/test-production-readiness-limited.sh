#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
launcher="$repo_root/test/compose/run-production-readiness-limited.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

mkdir -p "$fixture/bin"

cat >"$fixture/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >>"$VX_TEST_SYSTEMD_LOG"
printf '\n' >>"$VX_TEST_SYSTEMD_LOG"
for argument in "$@"; do
    if [[ "$argument" == /usr/bin/true ]]; then
        exit 0
    fi
done
exit "${VX_TEST_GATE_EXIT:-0}"
EOF
chmod 755 "$fixture/bin/systemd-run"

cat >"$fixture/bin/nice" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "$@" >"$VX_TEST_NICE_LOG"
printf '\n' >>"$VX_TEST_NICE_LOG"
exit "${VX_TEST_GATE_EXIT:-0}"
EOF
chmod 755 "$fixture/bin/nice"

systemd_log="$fixture/systemd.log"
set +e
PATH="$fixture/bin:$PATH" \
VX_TEST_SYSTEMD_LOG="$systemd_log" \
VX_TEST_GATE_EXIT=37 \
VX_READINESS_TEST_AVAILABLE_MEMORY_MB=8192 \
    "$launcher" >"$fixture/default.out" 2>"$fixture/default.err"
status=$?
set -e
[[ $status -eq 37 ]] || fail "limited launcher did not preserve gate exit 37"
[[ "$(wc -l <"$systemd_log")" -eq 2 ]] \
    || fail "limited launcher did not probe before execution"
grep -Fq 'CPUQuota=50%' "$systemd_log" \
    || fail "default CPU quota was not passed to systemd"
grep -Fq 'MemoryHigh=5120M' "$systemd_log" \
    || fail "default memory high watermark was not passed to systemd"
grep -Fq 'MemoryMax=6144M' "$systemd_log" \
    || fail "default memory maximum was not passed to systemd"
grep -Fq 'MemoryHigh=5120M MemoryMax=6144M' "$fixture/default.err" \
    || fail "calculated dynamic memory limits were not reported"
grep -Fq 'MemorySwapMax=512M' "$systemd_log" \
    || fail "default swap maximum was not passed to systemd"
grep -Fq 'TasksMax=32' "$systemd_log" \
    || fail "default task maximum was not passed to systemd"
grep -Fq -- '-n 19' "$systemd_log" \
    || fail "default nice level was not passed to the scoped command"
grep -Fq "$repo_root/test/compose/run-production-readiness.sh" "$systemd_log" \
    || fail "canonical readiness gate was not executed"

: >"$systemd_log"
set +e
PATH="$fixture/bin:$PATH" \
VX_TEST_SYSTEMD_LOG="$systemd_log" \
VX_TEST_GATE_EXIT=23 \
VX_READINESS_CPU_QUOTA=25% \
VX_READINESS_MEMORY_HIGH=1G \
VX_READINESS_MEMORY_MAX=2G \
VX_READINESS_MEMORY_SWAP_MAX=0 \
VX_READINESS_TASKS_MAX=12 \
VX_READINESS_NICE=10 \
    "$launcher" >"$fixture/custom.out" 2>"$fixture/custom.err"
status=$?
set -e
[[ $status -eq 23 ]] || fail "custom limited launcher exit changed"
for property in \
    CPUQuota=25% MemoryHigh=1G MemoryMax=2G MemorySwapMax=0 \
    TasksMax=12; do
    grep -Fq "$property" "$systemd_log" \
        || fail "custom property $property was not passed to systemd"
done
grep -Fq -- '-n 10' "$systemd_log" \
    || fail "custom nice level was not passed to the scoped command"

set +e
VX_READINESS_TEST_AVAILABLE_MEMORY_MB=2300 \
    "$launcher" >"$fixture/low-memory.out" 2>"$fixture/low-memory.err"
status=$?
set -e
[[ $status -eq 1 ]] || fail "insufficient host reserve was accepted"
grep -Fq 'available memory cannot preserve the 2048 MiB host reserve' \
    "$fixture/low-memory.err" \
    || fail "insufficient memory error omitted the host reserve"

set +e
VX_READINESS_CPU_QUOTA=0% \
    "$launcher" >"$fixture/invalid.out" 2>"$fixture/invalid.err"
status=$?
set -e
[[ $status -eq 1 ]] || fail "invalid CPU quota was accepted"
grep -Fq 'invalid VX_READINESS_CPU_QUOTA' "$fixture/invalid.err" \
    || fail "invalid CPU quota error was not explicit"

set +e
VX_READINESS_SYSTEMD_RUN="$fixture/missing-systemd-run" \
    "$launcher" >"$fixture/unsupported.out" 2>"$fixture/unsupported.err"
status=$?
set -e
[[ $status -eq 1 ]] || fail "unsupported environment did not fail closed"
grep -Fq 'resource-limited readiness is unavailable' "$fixture/unsupported.err" \
    || fail "unsupported environment error was not explicit"

nice_log="$fixture/nice.log"
set +e
PATH="$fixture/bin:$PATH" \
VX_TEST_NICE_LOG="$nice_log" \
VX_TEST_GATE_EXIT=29 \
VX_READINESS_SYSTEMD_RUN="$fixture/missing-systemd-run" \
VX_READINESS_ALLOW_UNLIMITED=yes \
    "$launcher" >"$fixture/unlimited.out" 2>"$fixture/unlimited.err"
status=$?
set -e
[[ $status -eq 29 ]] || fail "explicit unlimited fallback exit changed"
grep -Fq 'WARNING: running readiness without cgroup limits' \
    "$fixture/unlimited.err" \
    || fail "unlimited fallback warning was omitted"
grep -Fq -- '-n 19' "$nice_log" \
    || fail "unlimited fallback did not retain nice priority"

set +e
"$launcher" unexpected >"$fixture/args.out" 2>"$fixture/args.err"
status=$?
set -e
[[ $status -eq 1 ]] || fail "unexpected launcher arguments were accepted"

echo "Resource-limited production readiness launcher tests passed."
