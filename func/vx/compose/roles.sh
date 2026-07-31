#!/usr/bin/env bash

vx_compose_roles_path() {
    printf '%s/roles.json\n' "$(vx_compose_project_root "$1" "$2")"
}

vx_compose_role_is_valid() {
    case "$1" in
        viewer|operator|deployer|backup-operator|secret-manager) return 0 ;;
        *) return 1 ;;
    esac
}

vx_compose_actor_is_active() {
    local actor="$1" user_conf suspended

    [[ "$actor" == admin ]] && return 0
    vx_compose_require_owner "$actor" || return 1
    user_conf="$VESTA/data/users/$actor/user.conf"
    [[ -f "$user_conf" && ! -L "$user_conf" ]] || return 0
    suspended="$(vx_compose_meta_get "$user_conf" SUSPENDED 2>/dev/null)" \
        || suspended=no
    [[ "$suspended" != yes ]]
}

vx_compose_role_capability() {
    local role="$1" capability="$2"

    case "$role:$capability" in
        viewer:view) return 0 ;;
        operator:view|operator:lifecycle|operator:reconcile) return 0 ;;
        deployer:view|deployer:preview|deployer:deploy|deployer:rollback) return 0 ;;
        backup-operator:view|backup-operator:backup|backup-operator:restore) return 0 ;;
        secret-manager:view|secret-manager:secret) return 0 ;;
        *) return 1 ;;
    esac
}

vx_compose_role_for_actor() {
    local owner="$1" project="$2" actor="$3" path role

    [[ "$actor" == admin || "$actor" == "$owner" ]] && {
        printf 'owner\n'
        return 0
    }
    path="$(vx_compose_roles_path "$owner" "$project")"
    [[ -f "$path" && ! -L "$path"
        && "$(stat -c '%a' "$path" 2>/dev/null)" == 600 ]] || return 1
    role="$(jq -er --arg actor "$actor" '
        select(type == "object" and .SCHEMA == 1)
        | .ASSIGNMENTS[$actor].ROLE
        | select(type == "string")
    ' "$path" 2>/dev/null)" || return 1
    vx_compose_role_is_valid "$role" || return 1
    printf '%s\n' "$role"
}

vx_compose_authorize() {
    local actor="$1" owner="$2" project="$3" capability="$4"
    local root profile role

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_actor_is_active "$actor" || {
        vx_compose_error 'Compose actor is unavailable or suspended'
        return 1
    }
    root="$(vx_compose_project_root "$owner" "$project")"
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || return 1
    if [[ "$actor" == admin || "$actor" == "$owner" ]]; then
        return 0
    fi
    [[ "$profile" == standard ]] || {
        vx_compose_error 'delegated Compose roles are limited to standard projects'
        return 1
    }
    role="$(vx_compose_role_for_actor "$owner" "$project" "$actor")" || {
        vx_compose_error 'Compose capability denied'
        return 1
    }
    vx_compose_role_capability "$role" "$capability" || {
        vx_compose_error 'Compose capability denied'
        return 1
    }
}

vx_compose_role_write() {
    local path="$1" payload="$2" root temp

    root="$(dirname -- "$path")"
    temp="$(mktemp "$root/.roles.XXXXXX")" || return 1
    if ! jq -S . <<<"$payload" >"$temp" \
        || ! chmod 0600 "$temp" \
        || ! mv -f -- "$temp" "$path"; then
        rm -f -- "$temp"
        return 1
    fi
}

vx_compose_role_set() {
    local manager="$1" owner="$2" project="$3" actor="$4" role="$5"
    local root path old updated now existed=no

    vx_compose_require_project "$owner" "$project" || return 1
    [[ "$manager" == admin || "$manager" == "$owner" ]] || {
        vx_compose_error 'only the project owner or admin may manage roles'
        return 1
    }
    vx_compose_actor_is_active "$manager" \
        && vx_compose_actor_is_active "$actor" || return 1
    [[ "$actor" != admin && "$actor" != "$owner" ]] || {
        vx_compose_error 'owner and admin authority is implicit'
        return 1
    }
    vx_compose_role_is_valid "$role" || {
        vx_compose_error 'invalid Compose project role'
        return 1
    }
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ "$(vx_compose_meta_get "$root/project.conf" PROFILE)" == standard ]] \
        || {
            vx_compose_error 'delegated roles are limited to standard projects'
            return 1
        }
    vx_compose_lock_acquire "$owner" "$project" || return 1
    path="$(vx_compose_roles_path "$owner" "$project")"
    old='{"SCHEMA":1,"ASSIGNMENTS":{}}'
    if [[ -f "$path" ]]; then
        existed=yes
        old="$(jq -c '
            select(type == "object" and .SCHEMA == 1
                and (.ASSIGNMENTS | type == "object"))
        ' "$path" 2>/dev/null)" || old=
    fi
    if [[ -z "$old" ]]; then
        vx_compose_lock_release
        vx_compose_error 'stored Compose role metadata is invalid'
        return 1
    fi
    now="$(vx_compose_now)"
    updated="$(jq -c --arg actor "$actor" --arg role "$role" \
        --arg manager "$manager" --arg now "$now" '
        .ASSIGNMENTS[$actor] = {
            ROLE: $role, GRANTED_BY: $manager, UPDATED: $now
        }
    ' <<<"$old")" || {
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_role_write "$path" "$updated"; then
        vx_compose_lock_release
        return 1
    fi
    if VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$(
            vx_compose_meta_get "$root/project.conf" REVISION
        )" vx_compose_audit "$root" role-grant succeeded \
            "actor=$actor role=$role" 0 '[]' "$manager"; then
        vx_compose_lock_release
        return 0
    fi
    if [[ "$existed" == yes ]]; then
        vx_compose_role_write "$path" "$old" || :
    else
        rm -f -- "$path" || :
    fi
    vx_compose_lock_release
    return 1
}

vx_compose_role_delete() {
    local manager="$1" owner="$2" project="$3" actor="$4"
    local root path old updated

    vx_compose_require_project "$owner" "$project" || return 1
    [[ "$manager" == admin || "$manager" == "$owner" ]] || return 1
    vx_compose_actor_is_active "$manager" || return 1
    vx_compose_owner_is_valid "$actor" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    path="$(vx_compose_roles_path "$owner" "$project")"
    [[ -f "$path" && ! -L "$path" ]] || {
        vx_compose_lock_release
        return 1
    }
    old="$(jq -c 'select(type=="object" and .SCHEMA==1
        and (.ASSIGNMENTS|type=="object"))' "$path" 2>/dev/null)" || old=
    [[ -n "$old" ]] || {
        vx_compose_lock_release
        return 1
    }
    jq -e --arg actor "$actor" '.ASSIGNMENTS | has($actor)' \
        <<<"$old" >/dev/null || {
        vx_compose_lock_release
        return 1
    }
    updated="$(jq -c --arg actor "$actor" 'del(.ASSIGNMENTS[$actor])' \
        <<<"$old")" || {
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_role_write "$path" "$updated"; then
        vx_compose_lock_release
        return 1
    fi
    if vx_compose_audit "$root" role-revoke succeeded \
        "actor=$actor" 0 '[]' "$manager"; then
        vx_compose_lock_release
        return 0
    fi
    vx_compose_role_write "$path" "$old" || :
    vx_compose_lock_release
    return 1
}

vx_compose_roles_list_json() {
    local actor="$1" owner="$2" project="$3" path payload

    vx_compose_authorize "$actor" "$owner" "$project" view || return 1
    path="$(vx_compose_roles_path "$owner" "$project")"
    payload='{"SCHEMA":1,"ASSIGNMENTS":{}}'
    [[ ! -f "$path" ]] || payload="$(jq -c '
        select(type=="object" and .SCHEMA==1
            and (.ASSIGNMENTS|type=="object"))
    ' "$path" 2>/dev/null)" || return 1
    jq -S --arg owner "$owner" --arg project "$project" \
        '{OWNER:$owner,PROJECT:$project,ASSIGNMENTS:.ASSIGNMENTS}' \
        <<<"$payload"
}
