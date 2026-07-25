#!/usr/bin/env bash

vx_compose_adopt_runtime_json() {
    local owner="$1"
    local project="$2"
    local docker_bin id raw
    local -a ids=()

    docker_bin="$(vx_compose_docker_bin)" || return 1
    while IFS= read -r id; do
        [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] && ids+=("$id")
    done < <(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            "$docker_bin" ps -aq \
            --filter \
            "label=com.docker.compose.project=$(vx_compose_runtime_name "$owner" "$project")"
    )
    ((${#ids[@]} > 0)) || {
        printf '[]\n'
        return
    }
    raw="$(env -i PATH="$VX_COMPOSE_SAFE_PATH" \
        "$docker_bin" inspect "${ids[@]}")" || return 1
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg runtime "$(vx_compose_runtime_name "$owner" "$project")" '
        type == "array"
        and all(.[];
            .Config.Labels["com.docker.compose.project"] == $runtime
            and .Config.Labels["vx.managed"] == "yes"
            and .Config.Labels["vx.user"] == $owner
            and .Config.Labels["vx.project"] == $project
            and (
                .Config.Labels["com.docker.compose.service"]
                | type == "string" and length > 0
            )
        )
    ' <<<"$raw" >/dev/null \
        || {
            vx_compose_error 'existing Compose runtime ownership is ambiguous'
            return 1
        }
    jq -c . <<<"$raw"
}

vx_compose_adopt() {
    local owner="$1"
    local project="$2"
    local source_file="$3"
    local mode="$4"
    local profile="${5:-standard}"
    local candidate_parent candidate report root runtime

    [[ "$mode" == dry-run || "$mode" == apply ]] \
        || {
            vx_compose_error 'Compose adoption mode must be dry-run or apply'
            return 1
        }
    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    [[ ! -e "$(vx_compose_project_root "$owner" "$project")" ]] \
        || {
            vx_compose_error "Compose project already exists: $owner/$project"
            return 1
        }
    candidate_parent="$(mktemp -d)"
    candidate="$candidate_parent/candidate"
    if ! vx_compose_prepare_candidate \
        "$owner" "$project" "$source_file" "$candidate" "$profile"; then
        rm -rf -- "$candidate_parent"
        return 1
    fi
    runtime="$(vx_compose_adopt_runtime_json "$owner" "$project")" || {
        rm -rf -- "$candidate_parent"
        return 1
    }
    report="$(jq -n \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg mode "$mode" \
        --arg profile "$profile" \
        --argjson runtime "$runtime" \
        --argjson services "$(jq '.services | keys' "$candidate/canonical.json")" \
        '{
            OWNER: $owner,
            PROJECT: $project,
            MODE: $mode,
            PROFILE: $profile,
            MUTATED: false,
            SERVICES: $services,
            RUNTIME_CONTAINERS: ($runtime | length)
        }')"
    if [[ "$mode" == dry-run ]]; then
        rm -rf -- "$candidate_parent"
        printf '%s\n' "$report"
        return
    fi
    vx_compose_store_new "$owner" "$project" "$profile" "$candidate" || {
        rm -rf -- "$candidate_parent"
        return 1
    }
    rm -rf -- "$candidate_parent"
    root="$(vx_compose_project_root "$owner" "$project")"
    vx_compose_audit "$root" adopt started
    if vx_compose_deploy "$owner" "$project"; then
        vx_compose_audit "$root" adopt succeeded
        jq '.MUTATED = true' <<<"$report"
        return
    fi
    vx_compose_audit "$root" adopt failed 'adopted workload failed convergence'
    vx_compose_remove "$owner" "$project" >/dev/null 2>&1 || true
    return 1
}
