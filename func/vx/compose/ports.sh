#!/usr/bin/env bash

vx_compose_profile_allows_public_ports() {
    local profile_path

    profile_path="$(vx_compose_profile_path "$1")" || return 1
    jq -e '.allow_public_ports == true' "$profile_path" >/dev/null
}

vx_compose_policy_check_ports() {
    local canonical_json="$1"
    local profile="$2"
    local allow_public=false

    vx_compose_profile_allows_public_ports "$profile" && allow_public=true
    jq -e --argjson allow_public "$allow_public" '
        all(.services[];
            ((.ports // []) | type == "array")
            and all((.ports // [])[];
                (.host_ip | type == "string")
                and (
                    .host_ip == "127.0.0.1"
                    or ($allow_public and .host_ip == "0.0.0.0")
                )
                and ((.published | tostring) | test("^[0-9]+$"))
                and ((.published | tonumber) >= 1)
                and ((.published | tonumber) <= 65535)
                and ((.target | tonumber) >= 1)
                and ((.target | tonumber) <= 65535)
                and ((.protocol // "tcp") == "tcp"
                    or (.protocol // "tcp") == "udp")
                and ((.mode // "ingress") == "ingress")
            )
        )
        and (
            [
                .services[]
                | (.ports // [])[]
                | [(.protocol // "tcp"), (.published | tostring)]
                | join(":")
            ] as $ports
            | ($ports | length) == ($ports | unique | length)
        )
    ' "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                PUBLIC_PORT \
                'published ports must be unique approved TCP/UDP bindings'
            return 1
        }
}

vx_compose_ports_keys() {
    local canonical_json="$1"

    jq -r '
        .services[]
        | (.ports // [])[]
        | [(.protocol // "tcp"), (.published | tostring)]
        | join(":")
    ' "$canonical_json" | sort -u
}

vx_compose_ports_lock_acquire() {
    local lock_path="$VESTA/data/.vx-compose-ports.lock"

    install -d -m 0750 "$VESTA/data"
    exec {VX_COMPOSE_PORTS_LOCK_FD}>"$lock_path"
    chmod 0640 "$lock_path"
    flock -x "$VX_COMPOSE_PORTS_LOCK_FD"
}

vx_compose_ports_lock_release() {
    if [[ -n "${VX_COMPOSE_PORTS_LOCK_FD:-}" ]]; then
        flock -u "$VX_COMPOSE_PORTS_LOCK_FD"
        exec {VX_COMPOSE_PORTS_LOCK_FD}>&-
        unset VX_COMPOSE_PORTS_LOCK_FD
    fi
}

vx_compose_ports_current_runtime_keys() {
    local owner="$1"
    local project="$2"
    local docker_bin container_id
    local -a container_ids=()

    docker_bin="$(vx_compose_docker_bin 2>/dev/null)" || return 0
    [[ -x "$docker_bin" ]] || return 0
    while IFS= read -r container_id; do
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] \
            && container_ids+=("$container_id")
    done < <(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" "$docker_bin" ps -q \
            --filter 'label=vx.managed=yes' \
            --filter "label=vx.user=$owner" \
            --filter "label=vx.project=$project" 2>/dev/null || true
    )
    ((${#container_ids[@]} > 0)) || return 0
    env -i PATH="$VX_COMPOSE_SAFE_PATH" \
        "$docker_bin" inspect "${container_ids[@]}" 2>/dev/null \
        | jq -r '
            .[]
            | ((.NetworkSettings.Ports // {}) | to_entries[])
            | .key as $container_port
            | (.value // [])[]
            | [
                ($container_port | split("/")[1]),
                .HostPort
            ]
            | join(":")
        ' \
        | sort -u
}

vx_compose_ports_check_metadata_conflicts() {
    local owner="$1"
    local project="$2"
    local canonical_json="$3"
    local candidate_keys projects_owner_root project_root other_owner other_project
    local existing_key

    candidate_keys="$(mktemp)"
    vx_compose_ports_keys "$canonical_json" >"$candidate_keys" || {
        rm -f -- "$candidate_keys"
        return 1
    }
    [[ -s "$candidate_keys" ]] || {
        rm -f -- "$candidate_keys"
        return 0
    }
    for projects_owner_root in "$VESTA"/data/users/*/docker-projects; do
        [[ -d "$projects_owner_root" ]] || continue
        other_owner="$(basename -- "$(dirname -- "$projects_owner_root")")"
        for project_root in "$projects_owner_root"/*; do
            [[ -f "$project_root/runtime/canonical.json" ]] || continue
            other_project="$(basename -- "$project_root")"
            [[ "$other_owner" == "$owner" && "$other_project" == "$project" ]] \
                && continue
            while IFS= read -r existing_key; do
                if grep -Fxq "$existing_key" "$candidate_keys"; then
                    rm -f -- "$candidate_keys"
                    vx_compose_error 'Compose published port conflicts with managed metadata'
                    return 1
                fi
            done < <(vx_compose_ports_keys "$project_root/runtime/canonical.json")
        done
    done
    rm -f -- "$candidate_keys"
}

vx_compose_ports_check_live_conflicts() {
    local owner="$1"
    local project="$2"
    local canonical_json="$3"
    local ss_bin="${VX_COMPOSE_SS_BIN:-}"
    local protocol published key current_keys listeners

    jq -e 'any(.services[]; ((.ports // []) | length) > 0)' \
        "$canonical_json" >/dev/null || return 0
    [[ -n "$ss_bin" ]] || ss_bin="$(command -v ss)" || return 0
    current_keys="$(mktemp)"
    vx_compose_ports_current_runtime_keys "$owner" "$project" >"$current_keys"
    listeners="$(mktemp)"
    {
        "$ss_bin" -H -lnt 2>/dev/null \
            | awk '{ value=$4; sub(/^.*:/, "", value); if (value ~ /^[0-9]+$/) print "tcp:" value }'
        "$ss_bin" -H -lnu 2>/dev/null \
            | awk '{ value=$4; sub(/^.*:/, "", value); if (value ~ /^[0-9]+$/) print "udp:" value }'
    } | sort -u >"$listeners"
    while IFS=$'\t' read -r protocol published; do
        key="$protocol:$published"
        if [[ "$key" == "${VX_COMPOSE_ALLOWED_LIVE_PORT_KEY:-}" ]]; then
            continue
        fi
        if grep -Fxq "$key" "$listeners" \
            && ! grep -Fxq "$key" "$current_keys"; then
            rm -f -- "$listeners" "$current_keys"
            vx_compose_error 'Compose published port conflicts with a live listener'
            return 1
        fi
    done < <(jq -r '
        .services[]
        | (.ports // [])[]
        | [(.protocol // "tcp"), (.published | tostring)]
        | @tsv
    ' "$canonical_json")
    rm -f -- "$listeners" "$current_keys"
}

vx_compose_ports_check_conflicts() {
    vx_compose_ports_check_metadata_conflicts "$@" \
        && vx_compose_ports_check_live_conflicts "$@"
}
