#!/usr/bin/env bash

vx_compose_config_command() {
    local owner="$1"
    local project="$2"
    local work_root="$3"
    shift 3
    local docker_bin
    local -a compose_command

    docker_bin="$(vx_compose_docker_bin)" || return 1
    compose_command=(
        env -i
        PATH="$VX_COMPOSE_SAFE_PATH" \
        HOME="$work_root/home" \
        DOCKER_CONFIG="$work_root/docker-config" \
        "$docker_bin" compose \
        --project-name "$(vx_compose_runtime_name "$owner" "$project")" \
        --project-directory "$work_root" \
        --env-file "$work_root/variables.env" \
        "$@"
    )
    if [[ "$EUID" -eq 0 ]] && id -u "$owner" >/dev/null 2>&1; then
        runuser -u "$owner" -- "${compose_command[@]}"
    else
        "${compose_command[@]}"
    fi
}

vx_compose_write_ownership_override() {
    local owner="$1"
    local project="$2"
    local canonical_json="$3"
    local output_file="$4"
    local service

    printf '%s\n' 'services:' >"$output_file"
    while IFS= read -r service; do
        [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] \
            || {
                vx_compose_error "invalid canonical service name: $service"
                return 1
            }
        {
            printf '  %s:\n' "$service"
            printf '%s\n' '    labels:'
            printf '%s\n' '      vx.managed: "yes"'
            printf '      vx.user: "%s"\n' "$owner"
            printf '      vx.project: "%s"\n' "$project"
        } >>"$output_file"
    done < <(jq -r '.services | keys[]' "$canonical_json")
    if jq -e '((.volumes // {}) | length) > 0' "$canonical_json" >/dev/null; then
        printf '%s\n' 'volumes:' >>"$output_file"
        while IFS= read -r volume; do
            [[ "$volume" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] \
                || {
                    vx_compose_error "invalid canonical volume name: $volume"
                    return 1
                }
            {
                printf '  %s:\n' "$volume"
                printf '    name: "%s"\n' \
                    "$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")"
                printf '%s\n' '    labels:'
                printf '%s\n' '      vx.managed: "yes"'
                printf '      vx.user: "%s"\n' "$owner"
                printf '      vx.project: "%s"\n' "$project"
                printf '      vx.volume: "%s"\n' "$volume"
            } >>"$output_file"
        done < <(jq -r '(.volumes // {}) | keys[]' "$canonical_json")
    fi
    if jq -e '((.networks // {}) | length) > 0' "$canonical_json" >/dev/null; then
        printf '%s\n' 'networks:' >>"$output_file"
        while IFS= read -r network; do
            [[ "$network" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] \
                || {
                    vx_compose_error "invalid canonical network name: $network"
                    return 1
                }
            {
                printf '  %s:\n' "$network"
                printf '    name: "%s"\n' \
                    "$(vx_compose_network_runtime_name \
                        "$owner" "$project" "$network")"
                printf '%s\n' '    labels:'
                printf '%s\n' '      vx.managed: "yes"'
                printf '      vx.user: "%s"\n' "$owner"
                printf '      vx.project: "%s"\n' "$project"
                printf '      vx.network: "%s"\n' "$network"
            } >>"$output_file"
        done < <(jq -r '(.networks // {}) | keys[]' "$canonical_json")
    fi
}

vx_compose_baseline_policy_check() {
    local canonical_json="$1"

    vx_compose_policy_evaluate "$canonical_json" "$VX_COMPOSE_DEFAULT_PROFILE"
}

vx_compose_prepare_candidate() {
    local owner="$1"
    local project="$2"
    local input_file="$3"
    local output_root="$4"
    local profile="${5:-$VX_COMPOSE_DEFAULT_PROFILE}"
    local allow_existing_labels="${6:-no}"
    local validation_bind_root="${7:-}"
    local validation_secret_root="${8:-}"
    local work_root raw_json override_file
    local -a canonical_files

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    vx_compose_profile_require_authorized "$owner" "$project" "$profile" \
        || return 1
    [[ -f "$input_file" && ! -L "$input_file" ]] \
        || {
            vx_compose_error 'Compose input must be a regular non-symlink file'
            return 1
        }
    [[ "$(stat -c '%s' "$input_file")" -le 1048576 ]] \
        || {
            vx_compose_error 'Compose input exceeds the 1 MiB limit'
            return 1
        }
    [[ ! -e "$output_root" ]] \
        || {
            vx_compose_error "candidate output already exists: $output_root"
            return 1
        }
    vx_compose_require_runtime_tools || return 1

    work_root="$(mktemp -d)"
    trap 'rm -rf -- "$work_root"' RETURN
    install -d -m 0700 "$work_root/home" "$work_root/docker-config"
    : >"$work_root/variables.env"
    chmod 0600 "$work_root/variables.env"
    install -m 0600 "$input_file" "$work_root/input.compose.yaml"
    if [[ "$EUID" -eq 0 ]] && id -u "$owner" >/dev/null 2>&1; then
        chown -R "$owner:$owner" "$work_root"
    fi
    raw_json="$work_root/raw.json"
    override_file="$work_root/ownership.compose.yaml"

    vx_compose_config_command \
        "$owner" "$project" "$work_root" \
        --file "$work_root/input.compose.yaml" \
        config --format json >"$raw_json" \
        || vx_compose_error 'docker compose config failed'
    jq -e '.services | type == "object" and length > 0' "$raw_json" >/dev/null \
        || vx_compose_error 'Compose input must define at least one service'
    if [[ "$allow_existing_labels" == yes ]]; then
        vx_compose_policy_check_existing_labels \
            "$raw_json" "$owner" "$project" || return 1
        vx_compose_policy_check_existing_volume_labels \
            "$raw_json" "$owner" "$project" || return 1
        vx_compose_policy_check_existing_network_labels \
            "$raw_json" "$owner" "$project" || return 1
    else
        vx_compose_policy_check_reserved_labels "$raw_json" || return 1
        vx_compose_policy_check_reserved_volume_labels "$raw_json" || return 1
        vx_compose_policy_check_reserved_network_labels "$raw_json" || return 1
    fi
    canonical_files=(--file "$work_root/input.compose.yaml")
    if [[ "$allow_existing_labels" != yes ]]; then
        vx_compose_write_ownership_override \
            "$owner" "$project" "$raw_json" "$override_file"
        canonical_files+=(--file "$override_file")
    fi

    mkdir -m 0750 "$output_root"
    vx_compose_config_command \
        "$owner" "$project" "$work_root" \
        "${canonical_files[@]}" \
        config --format json \
        | jq -S . >"$output_root/canonical.json" \
        || vx_compose_error 'canonical Compose JSON generation failed'
    vx_compose_policy_check_existing_labels \
        "$output_root/canonical.json" "$owner" "$project" || return 1
    vx_compose_policy_check_existing_volume_labels \
        "$output_root/canonical.json" "$owner" "$project" || return 1
    vx_compose_policy_check_existing_network_labels \
        "$output_root/canonical.json" "$owner" "$project" || return 1
    vx_compose_policy_evaluate \
        "$output_root/canonical.json" "$profile" "$owner" "$project" \
        "$validation_bind_root" "$validation_secret_root" || return 1
    vx_compose_ports_check_conflicts \
        "$owner" "$project" "$output_root/canonical.json" || return 1
    vx_compose_write_policy_facts \
        "$output_root/canonical.json" "$profile" "$output_root/policy.conf" \
        || return 1
    vx_compose_config_command \
        "$owner" "$project" "$work_root" \
        "${canonical_files[@]}" \
        config >"$output_root/compose.yaml" \
        || vx_compose_error 'canonical Compose YAML generation failed'
    chmod 0640 \
        "$output_root/compose.yaml" \
        "$output_root/canonical.json" \
        "$output_root/policy.conf"
    (
        cd "$output_root" || exit 1
        sha256sum canonical.json >canonical.sha256
    )
    chmod 0640 "$output_root/canonical.sha256"
    rm -rf -- "$work_root"
    trap - RETURN
}

vx_compose_validate_existing() {
    local owner="$1"
    local project="$2"
    local root candidate profile

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || return 1
    candidate="$(mktemp -d)"
    rmdir "$candidate"
    if ! vx_compose_prepare_candidate \
        "$owner" "$project" "$root/compose.yaml" "$candidate" "$profile" yes; then
        rm -rf -- "$candidate"
        return 1
    fi
    cat "$candidate/canonical.json"
    rm -rf -- "$candidate"
}
