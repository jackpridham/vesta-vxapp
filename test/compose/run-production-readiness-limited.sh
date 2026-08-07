#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readiness_gate="$repo_root/test/compose/run-production-readiness.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

resolve_command() {
    local candidate=$1

    if [[ "$candidate" == */* ]]; then
        [[ -x "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi
    command -v "$candidate"
}

validate_cpu_quota() {
    [[ "$1" =~ ^([1-9]|[1-9][0-9]|100)%$ ]]
}

validate_memory_limit() {
    [[ "$1" =~ ^[1-9][0-9]*(K|M|G|T)$ ]]
}

validate_swap_limit() {
    [[ "$1" == 0 ]] || validate_memory_limit "$1"
}

validate_tasks_max() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]] && ((10#$1 <= 1024))
}

validate_nice_level() {
    [[ "$1" =~ ^([0-9]|1[0-9])$ ]]
}

[[ $# -eq 0 ]] || fail "resource-limited readiness accepts no arguments"
[[ -x "$readiness_gate" ]] || fail "canonical readiness gate is not executable"

cpu_quota=${VX_READINESS_CPU_QUOTA:-50%}
memory_high=${VX_READINESS_MEMORY_HIGH:-2G}
memory_max=${VX_READINESS_MEMORY_MAX:-3G}
memory_swap_max=${VX_READINESS_MEMORY_SWAP_MAX:-512M}
tasks_max=${VX_READINESS_TASKS_MAX:-32}
nice_level=${VX_READINESS_NICE:-19}
allow_unlimited=${VX_READINESS_ALLOW_UNLIMITED:-no}
systemd_run_candidate=${VX_READINESS_SYSTEMD_RUN:-systemd-run}

validate_cpu_quota "$cpu_quota" \
    || fail "invalid VX_READINESS_CPU_QUOTA: $cpu_quota"
validate_memory_limit "$memory_high" \
    || fail "invalid VX_READINESS_MEMORY_HIGH: $memory_high"
validate_memory_limit "$memory_max" \
    || fail "invalid VX_READINESS_MEMORY_MAX: $memory_max"
validate_swap_limit "$memory_swap_max" \
    || fail "invalid VX_READINESS_MEMORY_SWAP_MAX: $memory_swap_max"
validate_tasks_max "$tasks_max" \
    || fail "invalid VX_READINESS_TASKS_MAX: $tasks_max"
validate_nice_level "$nice_level" \
    || fail "invalid VX_READINESS_NICE: $nice_level"
[[ "$allow_unlimited" == no || "$allow_unlimited" == yes ]] \
    || fail "VX_READINESS_ALLOW_UNLIMITED must be yes or no"

systemd_run=''
systemd_run="$(resolve_command "$systemd_run_candidate" 2>/dev/null || true)"
nice_command="$(resolve_command nice 2>/dev/null || true)"
[[ -n "$nice_command" ]] || fail "nice is required for readiness execution"
if [[ -n "$systemd_run" ]]; then
    scope=(
        "$systemd_run" --user --scope --quiet
        -p "CPUQuota=$cpu_quota"
        -p "MemoryHigh=$memory_high"
        -p "MemoryMax=$memory_max"
        -p "MemorySwapMax=$memory_swap_max"
        -p "TasksMax=$tasks_max"
        --
    )
    if "${scope[@]}" /usr/bin/true >/dev/null 2>&1; then
        exec "${scope[@]}" "$nice_command" -n "$nice_level" "$readiness_gate"
    fi
fi

if [[ "$allow_unlimited" != yes ]]; then
    fail "resource-limited readiness is unavailable; set VX_READINESS_ALLOW_UNLIMITED=yes only on an approved unconstrained host"
fi

echo "WARNING: running readiness without cgroup limits" >&2
exec "$nice_command" -n "$nice_level" "$readiness_gate"
