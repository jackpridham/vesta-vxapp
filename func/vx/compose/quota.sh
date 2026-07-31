#!/usr/bin/env bash

vx_compose_policy_value() {
    local value

    value="$(vx_compose_meta_get "$1" "$2")" || return 1
    [[ "$value" =~ ^[0-9]+$ ]] \
        || {
            vx_compose_error "invalid numeric Compose policy fact: $2"
            return 1
        }
    printf '%s\n' "$value"
}

vx_compose_policy_file_validate() {
    local policy_file="$1"
    local schema validator profile profile_version expected_version field
    local -a numeric_fields=(
        SERVICES
        CPUS_MILLI
        MEMORY_MB
        PIDS
        STORAGE_MB
        PORTS
        SECRETS
        VOLUMES
    )

    [[ -f "$policy_file" ]] || {
        vx_compose_error 'Compose policy facts are missing'
        return 1
    }
    schema="$(vx_compose_meta_get "$policy_file" POLICY_SCHEMA)" || return 1
    validator="$(vx_compose_meta_get "$policy_file" VALIDATOR_VERSION)" || return 1
    profile="$(vx_compose_meta_get "$policy_file" PROFILE)" || return 1
    profile_version="$(vx_compose_meta_get "$policy_file" PROFILE_VERSION)" \
        || return 1
    expected_version="$(vx_compose_profile_version "$profile")" || return 1
    [[ "$schema" == "$VX_COMPOSE_POLICY_SCHEMA_VERSION"
        && "$validator" == "$VX_COMPOSE_POLICY_VALIDATOR_VERSION"
        && "$profile_version" == "$expected_version" ]] \
        || {
            vx_compose_error 'Compose policy facts use an unsupported version'
            return 1
        }
    for field in "${numeric_fields[@]}"; do
        vx_compose_policy_value "$policy_file" "$field" >/dev/null || return 1
    done
}

vx_compose_usage_collect() {
    local owner="$1"
    local exclude_project="${2:-}"
    local projects_root project_root project policy_file
    local projects=0 services=0 cpus=0 memory=0 pids=0
    local requested_storage=0 ports=0 secrets=0 volumes=0 value

    projects_root="$(vx_compose_projects_root "$owner")"
    if [[ -d "$projects_root" ]]; then
        for project_root in "$projects_root"/*; do
            [[ -d "$project_root" ]] || continue
            project="$(basename -- "$project_root")"
            [[ "$project" != "$exclude_project" ]] || continue
            policy_file="$project_root/policy.conf"
            [[ -f "$project_root/project.conf" ]] || continue
            vx_compose_policy_file_validate "$policy_file" || return 1
            projects=$((projects + 1))
            value="$(vx_compose_policy_value "$policy_file" SERVICES)" || return 1
            services=$((services + value))
            value="$(vx_compose_policy_value "$policy_file" CPUS_MILLI)" || return 1
            cpus=$((cpus + value))
            value="$(vx_compose_policy_value "$policy_file" MEMORY_MB)" || return 1
            memory=$((memory + value))
            value="$(vx_compose_policy_value "$policy_file" PIDS)" || return 1
            pids=$((pids + value))
            value="$(vx_compose_policy_value "$policy_file" STORAGE_MB)" || return 1
            requested_storage=$((requested_storage + value))
            value="$(vx_compose_policy_value "$policy_file" PORTS)" || return 1
            ports=$((ports + value))
            value="$(vx_compose_policy_value "$policy_file" SECRETS)" || return 1
            secrets=$((secrets + value))
            value="$(vx_compose_policy_value "$policy_file" VOLUMES)" || return 1
            volumes=$((volumes + value))
        done
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$projects" "$services" "$cpus" "$memory" "$pids" \
        "$requested_storage" "$ports" "$secrets" "$volumes"
}

vx_compose_measured_storage_mb() {
    local owner="$1"
    local projects_root data_root total=0 size path volume_size

    projects_root="$(vx_compose_projects_root "$owner")"
    data_root="$HOMEDIR/$owner/docker"
    for path in "$projects_root" "$data_root"; do
        [[ -d "$path" ]] || continue
        size="$(du -sm -- "$path" 2>/dev/null | awk 'NR == 1 { print $1 }')" \
            || return 1
        total=$((total + size))
    done
    if declare -F vx_compose_volume_storage_mb >/dev/null 2>&1; then
        volume_size="$(vx_compose_volume_storage_mb "$owner")" || return 1
        total=$((total + volume_size))
    fi
    printf '%s\n' "$total"
}

vx_compose_quota_limit() {
    local owner="$1"
    local field="$2"
    local user_conf="$VESTA/data/users/$owner/user.conf"

    [[ -f "$user_conf" ]] || {
        vx_compose_error "Vesta user configuration is missing: $owner"
        return 1
    }
    vx_compose_meta_get "$user_conf" "$field" 2>/dev/null \
        || printf '%s\n' 0
}

vx_compose_cpu_to_milli() {
    local value="$1"

    [[ "$value" =~ ^[0-9]+([.][0-9]{1,3})?$ ]] || return 1
    awk -v value="$value" 'BEGIN { printf "%.0f\n", value * 1000 }'
}

vx_compose_quota_data_value() {
    local data="$1"
    local field="$2"
    local value

    value="$(
        sed -n "s/^${field}='\\([^']*\\)'$/\\1/p" <<<"$data" | head -n 1
    )"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

vx_compose_quota_value_normalize() {
    local field="$1"
    local value="$2"
    local allow_unlimited="${3:-yes}"
    local milli

    if [[ "$allow_unlimited" == yes && "$value" == unlimited ]]; then
        printf '%s\n' "$value"
        return
    fi
    if [[ "$field" == DOCKER_CPUS ]]; then
        milli="$(vx_compose_cpu_to_milli "$value")" || return 1
        printf '%d.%03d\n' "$((milli / 1000))" "$((milli % 1000))"
        return
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

vx_compose_quota_field_label() {
    case "$1" in
        DOCKER_PROJECTS) printf '%s\n' Projects ;;
        DOCKER_SERVICES) printf '%s\n' Services ;;
        DOCKER_CPUS) printf '%s\n' CPUs ;;
        DOCKER_MEMORY_MB) printf '%s\n' Memory ;;
        DOCKER_PIDS) printf '%s\n' PIDs ;;
        DOCKER_STORAGE_MB) printf '%s\n' Storage ;;
        DOCKER_PORTS) printf '%s\n' Ports ;;
        DOCKER_SECRETS) printf '%s\n' Secrets ;;
        DOCKER_VOLUMES) printf '%s\n' Volumes ;;
        *) return 1 ;;
    esac
}

vx_compose_quota_field_unit() {
    case "$1" in
        DOCKER_CPUS) printf '%s\n' cores ;;
        DOCKER_MEMORY_MB|DOCKER_STORAGE_MB) printf '%s\n' MiB ;;
        DOCKER_PROJECTS|DOCKER_SERVICES|DOCKER_PIDS|DOCKER_PORTS|\
            DOCKER_SECRETS|DOCKER_VOLUMES)
            printf '%s\n' count
            ;;
        *) return 1 ;;
    esac
}

vx_compose_quota_diagnostic_json() {
    local owner="$1"
    local user_conf="$VESTA/data/users/$owner/user.conf"
    local package package_file package_data user_data quotas field
    local package_value effective_value used label unit
    local -a fields=(
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

    [[ -f "$user_conf" && ! -L "$user_conf" ]] || {
        vx_compose_error "Vesta user configuration is missing: $owner"
        return 1
    }
    package="$(vx_compose_meta_get "$user_conf" PACKAGE)" || return 1
    [[ "$package" =~ ^[A-Za-z0-9._-]+$ ]] || {
        vx_compose_error 'invalid Vesta package name'
        return 1
    }
    package_file="$VESTA/data/packages/$package.pkg"
    [[ -f "$package_file" && ! -L "$package_file" ]] || {
        vx_compose_error "Vesta package configuration is missing: $package"
        return 1
    }
    declare -F vx_compose_package_data_with_defaults >/dev/null 2>&1 || {
        vx_compose_error 'Compose package compatibility helpers are unavailable'
        return 1
    }
    package_data="$(vx_compose_package_data_with_defaults "$(<"$package_file")")" \
        || return 1
    user_data="$(vx_compose_package_data_with_defaults "$(<"$user_conf")")" \
        || return 1

    quotas="$(
        for field in "${fields[@]}"; do
            package_value="$(vx_compose_quota_data_value \
                "$package_data" "$field")" || return 1
            effective_value="$(vx_compose_quota_data_value \
                "$user_data" "$field")" || return 1
            used="$(vx_compose_quota_data_value \
                "$user_data" "U_$field" 2>/dev/null || printf '%s\n' 0)"
            package_value="$(vx_compose_quota_value_normalize \
                "$field" "$package_value")" || return 1
            effective_value="$(vx_compose_quota_value_normalize \
                "$field" "$effective_value")" || return 1
            used="$(vx_compose_quota_value_normalize \
                "$field" "$used" no)" || return 1
            label="$(vx_compose_quota_field_label "$field")" || return 1
            unit="$(vx_compose_quota_field_unit "$field")" || return 1
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$field" "$label" "$unit" \
                "$package_value" "$effective_value" "$used"
        done | jq -Rn '
            [
                inputs
                | split("\t")
                | {
                    FIELD: .[0],
                    LABEL: .[1],
                    UNIT: .[2],
                    PACKAGE_VALUE: .[3],
                    EFFECTIVE_VALUE: .[4],
                    USED: .[5]
                }
            ]
        '
    )" || return 1
    jq -cn \
        --arg user "$owner" \
        --arg package "$package" \
        --argjson quotas "$quotas" \
        '{USER:$user,PACKAGE:$package,QUOTAS:$quotas}'
}

vx_compose_quota_compare() {
    local owner="$1"
    local field="$2"
    local usage="$3"
    local limit

    limit="$(vx_compose_quota_limit "$owner" "$field")" || return 1
    [[ "$limit" == unlimited ]] && return 0
    if [[ "$field" == DOCKER_CPUS ]]; then
        limit="$(vx_compose_cpu_to_milli "$limit")" \
            || {
                vx_compose_error "invalid Compose quota value: $field"
                return 1
            }
    elif [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        vx_compose_error "invalid Compose quota value: $field"
        return 1
    fi
    (( usage <= limit )) \
        || vx_compose_error "Compose quota exceeded [$field]"
}

vx_compose_quota_check_values() {
    local owner="$1"
    local projects="$2"
    local services="$3"
    local cpus="$4"
    local memory="$5"
    local pids="$6"
    local storage="$7"
    local ports="$8"
    local secrets="$9"
    local volumes="${10}"

    vx_compose_quota_compare "$owner" DOCKER_PROJECTS "$projects" || return 1
    vx_compose_quota_compare "$owner" DOCKER_SERVICES "$services" || return 1
    vx_compose_quota_compare "$owner" DOCKER_CPUS "$cpus" || return 1
    vx_compose_quota_compare "$owner" DOCKER_MEMORY_MB "$memory" || return 1
    vx_compose_quota_compare "$owner" DOCKER_PIDS "$pids" || return 1
    vx_compose_quota_compare "$owner" DOCKER_STORAGE_MB "$storage" || return 1
    vx_compose_quota_compare "$owner" DOCKER_PORTS "$ports" || return 1
    vx_compose_quota_compare "$owner" DOCKER_SECRETS "$secrets" || return 1
    vx_compose_quota_compare "$owner" DOCKER_VOLUMES "$volumes"
}

vx_compose_quota_check_candidate() {
    local owner="$1"
    local project="$2"
    local candidate_policy="$3"
    local mode="$4"
    local exclude='' usage measured value
    local projects services cpus memory pids storage ports secrets volumes

    [[ "$mode" == create || "$mode" == update ]] \
        || {
            vx_compose_error 'invalid Compose quota check mode'
            return 1
        }
    vx_compose_policy_file_validate "$candidate_policy" || return 1
    [[ "$mode" == update ]] && exclude="$project"
    usage="$(vx_compose_usage_collect "$owner" "$exclude")" || return 1
    IFS=$'\t' read -r \
        projects services cpus memory pids storage ports secrets volumes \
        <<<"$usage"
    projects=$((projects + 1))
    value="$(vx_compose_policy_value "$candidate_policy" SERVICES)" || return 1
    services=$((services + value))
    value="$(vx_compose_policy_value "$candidate_policy" CPUS_MILLI)" || return 1
    cpus=$((cpus + value))
    value="$(vx_compose_policy_value "$candidate_policy" MEMORY_MB)" || return 1
    memory=$((memory + value))
    value="$(vx_compose_policy_value "$candidate_policy" PIDS)" || return 1
    pids=$((pids + value))
    value="$(vx_compose_policy_value "$candidate_policy" STORAGE_MB)" || return 1
    storage=$((storage + value))
    value="$(vx_compose_policy_value "$candidate_policy" PORTS)" || return 1
    ports=$((ports + value))
    value="$(vx_compose_policy_value "$candidate_policy" SECRETS)" || return 1
    secrets=$((secrets + value))
    if declare -F vx_compose_secret_count >/dev/null 2>&1; then
        value="$(vx_compose_secret_count "$owner")" || return 1
        (( value > secrets )) && secrets="$value"
    fi
    value="$(vx_compose_policy_value "$candidate_policy" VOLUMES)" || return 1
    volumes=$((volumes + value))
    measured="$(vx_compose_measured_storage_mb "$owner")" || return 1
    (( measured > storage )) && storage="$measured"
    vx_compose_quota_check_values \
        "$owner" "$projects" "$services" "$cpus" "$memory" "$pids" \
        "$storage" "$ports" "$secrets" "$volumes"
}

vx_compose_quota_check_current() {
    local owner="$1"
    local usage measured
    local projects services cpus memory pids storage ports secrets volumes

    usage="$(vx_compose_usage_collect "$owner")" || return 1
    IFS=$'\t' read -r \
        projects services cpus memory pids storage ports secrets volumes \
        <<<"$usage"
    measured="$(vx_compose_measured_storage_mb "$owner")" || return 1
    (( measured > storage )) && storage="$measured"
    if declare -F vx_compose_secret_count >/dev/null 2>&1; then
        secrets="$(vx_compose_secret_count "$owner")" || return 1
    fi
    vx_compose_quota_check_values \
        "$owner" "$projects" "$services" "$cpus" "$memory" "$pids" \
        "$storage" "$ports" "$secrets" "$volumes"
}

vx_compose_user_conf_set() {
    local user_conf="$1"
    local key="$2"
    local value="$3"
    local temp_file

    temp_file="$(mktemp "${user_conf}.XXXXXX")" || return 1
    awk -v key="$key" -v value="$value" '
        BEGIN { prefix = key "=" }
        index($0, prefix) == 1 {
            if (!written) {
                printf "%s=\047%s\047\n", key, value
                written = 1
            }
            next
        }
        { print }
        END {
            if (!written) {
                printf "%s=\047%s\047\n", key, value
            }
        }
    ' "$user_conf" >"$temp_file"
    chmod --reference="$user_conf" "$temp_file"
    chown --reference="$user_conf" "$temp_file" 2>/dev/null || true
    mv -f -- "$temp_file" "$user_conf"
}

vx_compose_refresh_counters() {
    local owner="$1"
    local user_conf="$VESTA/data/users/$owner/user.conf"
    local usage measured cpu_display
    local projects services cpus memory pids storage ports secrets volumes

    [[ -f "$user_conf" ]] || return 1
    usage="$(vx_compose_usage_collect "$owner")" || return 1
    IFS=$'\t' read -r \
        projects services cpus memory pids storage ports secrets volumes \
        <<<"$usage"
    measured="$(vx_compose_measured_storage_mb "$owner")" || return 1
    (( measured > storage )) && storage="$measured"
    if declare -F vx_compose_secret_count >/dev/null 2>&1; then
        secrets="$(vx_compose_secret_count "$owner")" || return 1
    fi
    printf -v cpu_display '%d.%03d' "$((cpus / 1000))" "$((cpus % 1000))"

    vx_compose_user_conf_set "$user_conf" U_DOCKER_PROJECTS "$projects"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_SERVICES "$services"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_CPUS "$cpu_display"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_MEMORY_MB "$memory"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_PIDS "$pids"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_STORAGE_MB "$storage"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_PORTS "$ports"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_SECRETS "$secrets"
    vx_compose_user_conf_set "$user_conf" U_DOCKER_VOLUMES "$volumes"
}
