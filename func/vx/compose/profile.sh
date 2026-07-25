#!/usr/bin/env bash

vx_compose_profile_assignment_root() {
    printf '%s/data/users/%s/docker-profile-approvals\n' "$VESTA" "$1"
}

vx_compose_profile_assignment_path() {
    printf '%s/%s.json\n' "$(vx_compose_profile_assignment_root "$1")" "$2"
}

vx_compose_profile_is_admin_only() {
    local profile_path

    profile_path="$(vx_compose_profile_path "$1")" || return 1
    jq -e '.admin_only == true' "$profile_path" >/dev/null
}

vx_compose_profile_assignment_add() {
    local owner="$1"
    local project="$2"
    local profile="$3"
    local expires="$4"
    local expires_epoch now root assignment temp_file profile_version

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    if ! vx_compose_profile_is_available "$profile" \
        || ! vx_compose_profile_is_admin_only "$profile"; then
        vx_compose_error 'profile is not available for administrator assignment'
        return 1
    fi
    [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || {
            vx_compose_error 'profile expiry must be a UTC timestamp'
            return 1
        }
    expires_epoch="$(date -u -d "$expires" +%s 2>/dev/null)" \
        || {
            vx_compose_error 'profile expiry is invalid'
            return 1
        }
    now="$(date -u +%s)"
    (( expires_epoch > now && expires_epoch <= now + 31536000 )) \
        || {
            vx_compose_error 'profile expiry must be within the next year'
            return 1
        }
    root="$(vx_compose_profile_assignment_root "$owner")"
    assignment="$(vx_compose_profile_assignment_path "$owner" "$project")"
    profile_version="$(vx_compose_profile_version "$profile")" || return 1
    install -d -m 0700 "$root"
    temp_file="$(mktemp "$root/.approval.XXXXXX")"
    jq -n -S \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg profile "$profile" \
        --argjson profile_version "$profile_version" \
        --arg approved "$(vx_compose_now)" \
        --arg expires "$expires" \
        '{
            OWNER: $owner,
            PROJECT: $project,
            PROFILE: $profile,
            PROFILE_VERSION: $profile_version,
            ACTOR: "root",
            APPROVED: $approved,
            EXPIRES: $expires
        }' >"$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$assignment"
}

vx_compose_profile_assignment_delete() {
    local owner="$1"
    local project="$2"
    local root assignment expected

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    root="$(vx_compose_profile_assignment_root "$owner")"
    assignment="$(vx_compose_profile_assignment_path "$owner" "$project")"
    expected="$root/$project.json"
    [[ "$assignment" == "$expected" ]] || {
        vx_compose_error 'refusing to remove unresolved profile assignment'
        return 1
    }
    rm -f -- "$assignment"
    rmdir -- "$root" 2>/dev/null || true
}

vx_compose_profile_require_authorized() {
    local owner="$1"
    local project="$2"
    local profile="$3"
    local assignment expires expires_epoch profile_version

    vx_compose_profile_is_admin_only "$profile" || return 0
    assignment="$(vx_compose_profile_assignment_path "$owner" "$project")"
    [[ -f "$assignment" && ! -L "$assignment"
        && "$(stat -c '%a' "$assignment")" == 600 ]] \
        || {
            vx_compose_error 'administrator profile assignment is required'
            return 1
        }
    profile_version="$(vx_compose_profile_version "$profile")" || return 1
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg profile "$profile" \
        --argjson profile_version "$profile_version" '
            .OWNER == $owner
            and .PROJECT == $project
            and .PROFILE == $profile
            and .PROFILE_VERSION == $profile_version
            and .ACTOR == "root"
            and (.EXPIRES | type == "string")
        ' "$assignment" >/dev/null \
        || {
            vx_compose_error 'administrator profile assignment metadata is invalid'
            return 1
        }
    expires="$(jq -r '.EXPIRES' "$assignment")"
    expires_epoch="$(date -u -d "$expires" +%s 2>/dev/null)" || return 1
    (( expires_epoch > $(date -u +%s) )) \
        || {
            vx_compose_error 'administrator profile assignment has expired'
            return 1
        }
}

vx_compose_policy_check_host_network() {
    local canonical_json="$1"
    local profile="$2"
    local profile_path

    if jq -e 'all(.services[]; ((.network_mode // "") == ""))' \
        "$canonical_json" >/dev/null; then
        return 0
    fi
    profile_path="$(vx_compose_profile_path "$profile")" || return 1
    jq -e --argjson profile "$(cat "$profile_path")" '
        $profile.allow_host_namespaces == true
        and all(.services[];
            (.network_mode // "") == "host"
            and ((.ports // []) | length == 0)
            and ((.networks // {}) | length == 0)
        )
    ' "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                HOST_NETWORK \
                'host networking requires an assigned host-network profile without ports'
            return 1
        }
}
