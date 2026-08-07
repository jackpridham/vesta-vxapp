#!/usr/bin/env bash

VX_COMPOSE_PACKAGE_MAX_VALUE=2147483647

VX_COMPOSE_PACKAGE_FIELDS=(
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

vx_compose_package_integer_normalize() {
    local value="$1"

    [[ "${#value}" -le "${#VX_COMPOSE_PACKAGE_MAX_VALUE}"
        && "$value" =~ ^[0-9]+$ ]] || return 1
    while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
        value="${value#0}"
    done
    if [[ "${#value}" -gt "${#VX_COMPOSE_PACKAGE_MAX_VALUE}" ]] \
        || (( 10#$value > 10#$VX_COMPOSE_PACKAGE_MAX_VALUE )); then
        return 1
    fi
    printf '%s\n' "$value"
}

vx_compose_package_cpu_normalize() {
    local value="$1" integer fraction

    [[ "${#value}" -le $((${#VX_COMPOSE_PACKAGE_MAX_VALUE} + 4))
        && "$value" =~ ^([0-9]+)([.]([0-9]{1,3}))?$ ]] || return 1
    integer="$(vx_compose_package_integer_normalize "${BASH_REMATCH[1]}")" \
        || return 1
    fraction="${BASH_REMATCH[3]}"
    printf '%s%s\n' "$integer" "${fraction:+.$fraction}"
}

vx_compose_package_docker_is_enabled() {
    local limit

    [[ "$1" == unlimited ]] && return 0
    limit="$(vx_compose_package_integer_normalize "$1")" || return 1
    [[ "$limit" != 0 ]]
}

vx_compose_package_unset_values() {
    local field

    for field in "${VX_COMPOSE_PACKAGE_FIELDS[@]}"; do
        unset "$field" "U_$field"
    done
}

vx_compose_package_data_with_defaults() {
    local package_data="$1"
    local field legacy_limit default_value normalized_legacy_limit

    legacy_limit="$(sed -n "s/^DOCKER_CONTAINERS='\\([^']*\\)'$/\\1/p" \
        <<<"$package_data")"

    for field in "${VX_COMPOSE_PACKAGE_FIELDS[@]}"; do
        if ! grep -q "^${field}=" <<<"$package_data"; then
            default_value=0
            if [[ "$legacy_limit" == unlimited ]]; then
                default_value=unlimited
            elif normalized_legacy_limit="$(
                vx_compose_package_integer_normalize "$legacy_limit"
            )" && [[ "$normalized_legacy_limit" != 0 ]]; then
                case "$field" in
                    DOCKER_PROJECTS|DOCKER_SERVICES|DOCKER_PORTS)
                        default_value="$normalized_legacy_limit"
                        ;;
                    DOCKER_CPUS) default_value="$normalized_legacy_limit.000" ;;
                    DOCKER_MEMORY_MB) default_value=$((10#$normalized_legacy_limit * 1024)) ;;
                    DOCKER_PIDS) default_value=$((10#$normalized_legacy_limit * 128)) ;;
                    DOCKER_STORAGE_MB) default_value=$((10#$normalized_legacy_limit * 1024)) ;;
                esac
            fi
            package_data="${package_data}
${field}='${default_value}'"
        fi
    done
    printf '%s\n' "$package_data"
}

vx_compose_package_apply_defaults() {
    local field counter

    for field in "${VX_COMPOSE_PACKAGE_FIELDS[@]}"; do
        if [[ -z "${!field+x}" ]]; then
            printf -v "$field" '%s' 0
        fi
        counter="U_$field"
        if [[ -z "${!counter+x}" ]]; then
            printf -v "$counter" '%s' 0
        fi
    done
}

vx_compose_package_usage_is_covered() {
    local field limit counter usage normalized_limit normalized_usage

    for field in "${VX_COMPOSE_PACKAGE_FIELDS[@]}"; do
        limit="${!field}"
        counter="U_$field"
        usage="${!counter}"
        [[ "$limit" == unlimited ]] && continue
        if [[ "$field" == DOCKER_CPUS ]]; then
            limit="$(vx_compose_package_cpu_normalize "$limit")" || return 1
            usage="$(vx_compose_package_cpu_normalize "$usage")" || return 1
            normalized_limit="$(vx_compose_cpu_to_milli "$limit")" || return 1
            normalized_usage="$(vx_compose_cpu_to_milli "$usage")" || return 1
        else
            normalized_limit="$(vx_compose_package_integer_normalize "$limit")" \
                || return 1
            normalized_usage="$(vx_compose_package_integer_normalize "$usage")" \
                || return 1
        fi
        if (( 10#$normalized_usage > 10#$normalized_limit )); then
            # Read by v-change-user-package after this helper returns.
            # shellcheck disable=SC2034
            VX_COMPOSE_PACKAGE_OVERAGE_FIELD="$field"
            return 1
        fi
    done
}
