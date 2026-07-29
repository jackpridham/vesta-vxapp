#!/usr/bin/env bash

vx_compose_network_runtime_name() {
    local owner="$1"
    local project="$2"
    local network="$3"

    [[ "$network" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || return 1
    printf '%s_%s\n' "$(vx_compose_runtime_name "$owner" "$project")" "$network"
}

vx_compose_network_legacy_runtime_name() {
    local owner="$1" project="$2" network="$3"

    [[ "$network" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || return 1
    printf 'vx_%s_%s_%s\n' "$owner" "$project" "$network"
}

vx_compose_network_canonical_runtime_name() {
    local owner="$1" project="$2" network="$3" canonical="$4"
    local stored fresh legacy

    stored="$(jq -er --arg network "$network" \
        '.networks[$network].name | select(type == "string")' \
        "$canonical")" || return 1
    fresh="$(vx_compose_network_runtime_name "$owner" "$project" "$network")" \
        || return 1
    legacy="$(vx_compose_network_legacy_runtime_name \
        "$owner" "$project" "$network")" || return 1
    [[ "$stored" == "$fresh" || "$stored" == "$legacy" ]] || return 1
    printf '%s\n' "$stored"
}

vx_compose_policy_check_reserved_network_labels() {
    local canonical_json="$1"

    jq -e '
        all((.networks // {})[];
            ((.labels // {}) | type == "object")
            and (
                (.labels // {})
                | with_entries(select(
                    (.key | startswith("vx."))
                    or (.key | startswith("com.docker.compose."))
                ))
                | length == 0
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            NETWORK_OWNERSHIP \
            'network definitions may not set managed ownership labels'
}

vx_compose_policy_check_existing_network_labels() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"
    local network expected_name legacy_name

    while IFS= read -r network; do
        expected_name="$(vx_compose_network_runtime_name \
            "$owner" "$project" "$network")" || return 1
        legacy_name="$(vx_compose_network_legacy_runtime_name \
            "$owner" "$project" "$network")" || return 1
        jq -e \
            --arg network "$network" \
            --arg expected "$expected_name" \
            --arg legacy "$legacy_name" \
            --arg owner "$owner" \
            --arg project "$project" '
                (.networks[$network].name == $expected
                    or .networks[$network].name == $legacy)
                and .networks[$network].labels["vx.managed"] == "yes"
                and .networks[$network].labels["vx.user"] == $owner
                and .networks[$network].labels["vx.project"] == $project
                and .networks[$network].labels["vx.network"] == $network
                and all(
                    (.networks[$network].labels // {}) | to_entries[];
                    if (.key | startswith("vx.")) then
                        (.key == "vx.managed" and .value == "yes")
                        or (.key == "vx.user" and .value == $owner)
                        or (.key == "vx.project" and .value == $project)
                        or (.key == "vx.network" and .value == $network)
                    else
                        (.key | startswith("com.docker.compose.") | not)
                    end
                )
            ' "$canonical_json" >/dev/null \
            || {
                vx_compose_policy_reject \
                    NETWORK_OWNERSHIP \
                    'stored network ownership does not match project metadata'
                return 1
            }
    done < <(jq -r '(.networks // {}) | keys[]' "$canonical_json")
}

vx_compose_policy_check_networks() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"
    jq -e 'all((.networks // {})[]; (.external // false) == false)' \
        "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                EXTERNAL_NETWORK \
                'external networks are not permitted'
            return 1
        }
    jq -e '
        ((.networks // {}) | type == "object")
        and all((.networks // {})[];
            ((.driver // "bridge") == "bridge")
            and ((.attachable // false) == false)
            and (((.ipam // {}).config // []) | length == 0)
        )
        and (. as $root | all(.services[];
            all((.networks // {}) | keys[];
                $root.networks[.] != null
            )
        ))
    ' "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                NETWORK \
                'only project-owned bridge networks are permitted'
            return 1
        }
    vx_compose_policy_check_existing_network_labels \
        "$canonical_json" "$owner" "$project"
}

vx_compose_network_inspect() {
    local owner="$1"
    local project="$2"
    local network="$3"
    local canonical="${4:-}"
    local runtime_name docker_bin inspection root

    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -n "$canonical" ]] \
        || canonical="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"
    runtime_name="$(vx_compose_network_canonical_runtime_name \
        "$owner" "$project" "$network" "$canonical")" \
        || {
            vx_compose_error 'stored managed project network name is invalid'
            return 1
        }
    docker_bin="$(vx_compose_docker_bin)" || return 1
    inspection="$(
        env -i \
            PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" network inspect "$runtime_name"
    )" \
        || {
            vx_compose_error 'managed project network does not exist'
            return 1
        }
    jq -e \
        --arg runtime "$runtime_name" \
        --arg compose_project "$(vx_compose_runtime_name "$owner" "$project")" \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg network "$network" '
            .[0].Name == $runtime
            and .[0].Driver == "bridge"
            and .[0].Labels["com.docker.compose.project"] == $compose_project
            and .[0].Labels["com.docker.compose.network"] == $network
            and .[0].Labels["vx.managed"] == "yes"
            and .[0].Labels["vx.user"] == $owner
            and .[0].Labels["vx.project"] == $project
            and .[0].Labels["vx.network"] == $network
        ' <<<"$inspection" >/dev/null \
        || {
            vx_compose_error 'managed project network ownership labels do not match'
            return 1
        }
    printf '%s\n' "$inspection"
}

vx_compose_network_cleanup_replaced() {
    local owner="$1" project="$2" prior_canonical="$3" current_canonical="$4"
    local network prior_name current_name docker_bin root inspection

    [[ -f "$prior_canonical" && ! -L "$prior_canonical"
        && -f "$current_canonical" && ! -L "$current_canonical" ]] || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    while IFS= read -r network; do
        prior_name="$(vx_compose_network_canonical_runtime_name \
            "$owner" "$project" "$network" "$prior_canonical")" || return 1
        current_name="$(jq -r --arg network "$network" \
            '.networks[$network].name // empty' "$current_canonical")" \
            || return 1
        [[ "$prior_name" != "$current_name" ]] || continue
        docker_bin="$(vx_compose_docker_bin)" || return 1
        inspection="$(
            env -i PATH="$VX_COMPOSE_SAFE_PATH" \
                HOME="$root/runtime/home" \
                DOCKER_CONFIG="$root/runtime/docker-config" \
                "$docker_bin" network inspect "$prior_name"
        )" || continue
        jq -e --arg runtime "$prior_name" \
            --arg compose_project "$(vx_compose_runtime_name "$owner" "$project")" \
            --arg owner "$owner" --arg project "$project" \
            --arg network "$network" '
                .[0].Name == $runtime
                and .[0].Labels["com.docker.compose.project"] == $compose_project
                and .[0].Labels["vx.managed"] == "yes"
                and .[0].Labels["vx.user"] == $owner
                and .[0].Labels["vx.project"] == $project
                and .[0].Labels["vx.network"] == $network
            ' <<<"$inspection" >/dev/null || return 1
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" network rm "$prior_name" >/dev/null || return 1
    done < <(jq -r '(.networks // {}) | keys[]' "$prior_canonical")
}

vx_compose_network_verify_runtime() {
    local owner="$1"
    local project="$2"
    local canonical="${3:-}"
    local require_present="${4:-yes}"
    local network runtime_name docker_bin root

    [[ -n "$canonical" ]] \
        || canonical="$(vx_compose_project_root "$owner" "$project")/runtime/canonical.json"
    [[ -f "$canonical" && ! -L "$canonical"
        && ( "$require_present" == yes || "$require_present" == no ) ]] \
        || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    while IFS= read -r network; do
        runtime_name="$(vx_compose_network_canonical_runtime_name \
            "$owner" "$project" "$network" "$canonical")" || return 1
        if ! env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" network inspect "$runtime_name" \
            >/dev/null 2>&1; then
            if [[ "$require_present" == yes ]]; then
                vx_compose_error 'managed project network does not exist'
                return 1
            fi
            continue
        fi
        vx_compose_network_inspect \
            "$owner" "$project" "$network" "$canonical" >/dev/null \
            || return 1
    done < <(jq -r '(.networks // {}) | keys[]' "$canonical")
}
