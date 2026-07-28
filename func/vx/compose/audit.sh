#!/usr/bin/env bash

vx_compose_redact_text() {
    local root="$1"
    local text="$2"
    local secret_file secret_line

    if [[ -d "$root/secrets" ]]; then
        for secret_file in "$root"/secrets/*; do
            [[ -f "$secret_file" && ! -L "$secret_file" ]] || continue
            while IFS= read -r secret_line || [[ -n "$secret_line" ]]; do
                [[ -n "$secret_line" ]] || continue
                text="${text//"$secret_line"/[REDACTED]}"
            done <"$secret_file"
        done
    fi
    text="${text:0:4096}"
    printf '%s' "$text"
}

vx_compose_audit_append() {
    local path="$1"
    local mode="$2"
    local event="$3"
    local lock_path="${path}.lock"
    local lock_fd

    install -d -m 0750 "$(dirname -- "$path")"
    exec {lock_fd}>>"$lock_path"
    chmod "$mode" "$lock_path"
    flock -x "$lock_fd"
    printf '%s\n' "$event" >>"$path"
    chmod "$mode" "$path"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

vx_compose_audit() {
    local root="$1"
    local action="$2"
    local result="$3"
    local details="${4:-}"
    local duration_ms="${5:-0}"
    local services="${6:-[]}"
    local actor="${7:-${_VX_COMPOSE_AUDIT_ACTOR:-root}}"
    local metadata="$root/project.conf"
    local owner project revision event owner_audit

    [[ "$action" =~ ^[a-z][a-z0-9-]{0,63}$
        && "$result" =~ ^(started|succeeded|failed|opened|closed)$ ]] \
        || return 1
    [[ "$duration_ms" =~ ^[0-9]+$ ]] || duration_ms=0
    if [[ "$actor" != root && "$actor" != admin ]]; then
        vx_compose_require_owner "$actor" >/dev/null 2>&1 || actor=root
    fi
    jq -e 'type == "array" and all(.[]; type == "string")' \
        <<<"$services" >/dev/null 2>&1 || services='[]'
    owner="$(vx_compose_meta_get "$metadata" OWNER)" || return 1
    project="$(vx_compose_meta_get "$metadata" PROJECT)" || return 1
    revision="$(vx_compose_meta_get "$metadata" REVISION 2>/dev/null)" \
        || revision=0
    details="$(vx_compose_redact_text "$root" "$details")"
    event="$(jq -cn \
        --arg timestamp "$(vx_compose_now)" \
        --arg actor "$actor" \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg action "$action" \
        --arg result "$result" \
        --arg details "$details" \
        --argjson revision "$revision" \
        --argjson duration_ms "$duration_ms" \
        --argjson services "$services" '{
            TIMESTAMP: $timestamp,
            ACTOR: $actor,
            OWNER: $owner,
            PROJECT: $project,
            REVISION: $revision,
            ACTION: $action,
            RESULT: $result,
            DURATION_MS: $duration_ms,
            SERVICES: $services,
            DETAILS: $details
        }')" || return 1
    vx_compose_audit_append "$root/audit.log" 0640 "$event" || return 1
    owner_audit="$VESTA/data/users/$owner/docker-audit.log"
    vx_compose_audit_append "$owner_audit" 0600 "$event"
}

vx_compose_audit_actor_push() {
    local actor="$1"

    [[ -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]] || return 1
    if [[ "$actor" != admin ]]; then
        vx_compose_require_owner "$actor" || return 1
    fi
    _VX_COMPOSE_AUDIT_ACTOR="$actor"
}

vx_compose_audit_actor_pop() {
    unset _VX_COMPOSE_AUDIT_ACTOR
}

vx_compose_audit_list_json() {
    local owner="$1"
    local project="$2"
    local root line
    local -a events=()

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -f "$root/audit.log" ]] || {
        printf '[]\n'
        return
    }
    while IFS= read -r line; do
        jq -ce \
            --arg owner "$owner" \
            --arg project "$project" \
            'select(.OWNER == $owner and .PROJECT == $project)' \
            <<<"$line" >/dev/null 2>&1 || continue
        events+=("$line")
    done <"$root/audit.log"
    if ((${#events[@]} == 0)); then
        printf '[]\n'
    else
        printf '%s\n' "${events[@]}" | jq -s .
    fi
}

vx_compose_owner_audit() {
    local owner="$1"
    local action="$2"
    local result="$3"
    local details="${4:-}"
    local event

    vx_compose_require_owner "$owner" || return 1
    [[ "$action" =~ ^[a-z][a-z0-9-]{0,63}$
        && "$result" =~ ^(started|succeeded|failed)$ ]] || return 1
    details="${details:0:4096}"
    event="$(jq -cn \
        --arg timestamp "$(vx_compose_now)" \
        --arg owner "$owner" \
        --arg action "$action" \
        --arg result "$result" \
        --arg details "$details" '{
            TIMESTAMP: $timestamp,
            ACTOR: "root",
            OWNER: $owner,
            PROJECT: null,
            REVISION: 0,
            ACTION: $action,
            RESULT: $result,
            DURATION_MS: 0,
            SERVICES: [],
            DETAILS: $details
        }')" || return 1
    vx_compose_audit_append \
        "$VESTA/data/users/$owner/docker-audit.log" 0600 "$event"
}
