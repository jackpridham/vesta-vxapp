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
    [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 4 ]] \
        && ((10#$1 <= 1024))
}

validate_nice_level() {
    [[ "$1" =~ ^([0-9]|1[0-9])$ ]]
}

validate_memory_mib() {
    [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 7 ]]
}

detect_available_memory_mib() {
    local host_available_kib available_mib cgroup_path cgroup_dir
    local cgroup_max cgroup_current cgroup_available_mib

    host_available_kib="$(awk '/^MemAvailable:/ { print $2; exit }' \
        /proc/meminfo)"
    [[ "$host_available_kib" =~ ^[1-9][0-9]*$ ]] || return 1
    available_mib=$((host_available_kib / 1024))

    cgroup_path="$(awk -F: '$1 == "0" { print $3; exit }' \
        /proc/self/cgroup 2>/dev/null || true)"
    if [[ "$cgroup_path" == /* ]]; then
        cgroup_dir="/sys/fs/cgroup${cgroup_path%/}"
        [[ -n "$cgroup_dir" ]] || cgroup_dir=/sys/fs/cgroup
        if [[ -r "$cgroup_dir/memory.max"
            && -r "$cgroup_dir/memory.current" ]]; then
            cgroup_max="$(<"$cgroup_dir/memory.max")"
            cgroup_current="$(<"$cgroup_dir/memory.current")"
            if [[ "$cgroup_max" =~ ^[1-9][0-9]*$
                && "$cgroup_current" =~ ^[0-9]+$
                && "$cgroup_max" -gt "$cgroup_current" ]]; then
                cgroup_available_mib=$(((cgroup_max - cgroup_current) / 1048576))
                if ((cgroup_available_mib < available_mib)); then
                    available_mib=$cgroup_available_mib
                fi
            fi
        fi
    fi

    printf '%s\n' "$available_mib"
}

[[ $# -eq 0 ]] || fail "resource-limited readiness accepts no arguments"
[[ -x "$readiness_gate" ]] || fail "canonical readiness gate is not executable"

cpu_quota=${VX_READINESS_CPU_QUOTA:-50%}
memory_high=${VX_READINESS_MEMORY_HIGH:-}
memory_max=${VX_READINESS_MEMORY_MAX:-}
memory_swap_max=${VX_READINESS_MEMORY_SWAP_MAX:-512M}
memory_reserve_mib=${VX_READINESS_MEMORY_RESERVE_MB:-2048}
# Deterministic input for the focused launcher test; production leaves it unset.
available_memory_mib=${VX_READINESS_TEST_AVAILABLE_MEMORY_MB:-}
tasks_max=${VX_READINESS_TASKS_MAX:-64}
nice_level=${VX_READINESS_NICE:-19}
allow_unlimited=${VX_READINESS_ALLOW_UNLIMITED:-no}
systemd_run_candidate=${VX_READINESS_SYSTEMD_RUN:-systemd-run}

validate_cpu_quota "$cpu_quota" \
    || fail "invalid VX_READINESS_CPU_QUOTA: $cpu_quota"
validate_memory_mib "$memory_reserve_mib" \
    || fail "invalid VX_READINESS_MEMORY_RESERVE_MB: $memory_reserve_mib"
if [[ -n "$available_memory_mib" ]]; then
    validate_memory_mib "$available_memory_mib" \
        || fail "invalid VX_READINESS_TEST_AVAILABLE_MEMORY_MB: $available_memory_mib"
fi
if [[ -z "$memory_max" ]]; then
    if [[ -z "$available_memory_mib" ]]; then
        available_memory_mib="$(detect_available_memory_mib)" \
            || fail "could not determine available memory"
    fi
    ((available_memory_mib > memory_reserve_mib + 512)) \
        || fail "available memory cannot preserve the ${memory_reserve_mib} MiB host reserve"
    scope_memory_mib=$((available_memory_mib - memory_reserve_mib))
    memory_max="${scope_memory_mib}M"
    if [[ -z "$memory_high" ]]; then
        if ((scope_memory_mib > 1536)); then
            memory_high="$((scope_memory_mib - 1024))M"
        else
            memory_high="$((scope_memory_mib * 3 / 4))M"
        fi
    fi
elif [[ -z "$memory_high" ]]; then
    memory_high=2G
fi
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

printf 'Readiness limits: CPU=%s MemoryHigh=%s MemoryMax=%s MemorySwapMax=%s TasksMax=%s Nice=%s\n' \
    "$cpu_quota" "$memory_high" "$memory_max" "$memory_swap_max" \
    "$tasks_max" "$nice_level" >&2

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
