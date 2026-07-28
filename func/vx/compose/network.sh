#!/usr/bin/env bash

vx_compose_network_runtime_name() {
    local owner="$1"
    local project="$2"
    local network="$3"

    [[ "$network" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || return 1
    printf '%s_%s\n' "$(vx_compose_runtime_name "$owner" "$project")" "$network"
}

vx_compose_policy_check_reserved_network_labels() {
    local canonical_json="$1"

    jq -e '
        all((.networks // {})[];
            ((.labels // {}) | type == "object")
            and (
                (.labels // {})
                | with_entries(select(.key | startswith("vx.")))
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
    local network expected_name

    while IFS= read -r network; do
        expected_name="$(vx_compose_network_runtime_name \
            "$owner" "$project" "$network")" || return 1
        jq -e \
            --arg network "$network" \
            --arg expected "$expected_name" \
            --arg owner "$owner" \
            --arg project "$project" '
                .networks[$network].name == $expected
                and .networks[$network].labels["vx.managed"] == "yes"
                and .networks[$network].labels["vx.user"] == $owner
                and .networks[$network].labels["vx.project"] == $project
                and .networks[$network].labels["vx.network"] == $network
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
    local runtime_name docker_bin inspection root

    runtime_name="$(vx_compose_network_runtime_name \
        "$owner" "$project" "$network")" || return 1
    docker_bin="$(vx_compose_docker_bin)" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
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

vx_compose_network_verify_runtime() {
    local owner="$1"
    local project="$2"
    local canonical network

    canonical="$(vx_compose_project_root "$owner" "$project")/runtime/canonical.json"
    while IFS= read -r network; do
        vx_compose_network_inspect \
            "$owner" "$project" "$network" >/dev/null || return 1
    done < <(jq -r '(.networks // {}) | keys[]' "$canonical")
}
