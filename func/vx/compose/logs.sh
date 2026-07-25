#!/usr/bin/env bash

VX_COMPOSE_LOG_MAX_LINES="${VX_COMPOSE_LOG_MAX_LINES:-2000}"
VX_COMPOSE_LOG_MAX_BYTES="${VX_COMPOSE_LOG_MAX_BYTES:-1048576}"

vx_compose_logs() {
    local owner="$1"
    local project="$2"
    local service="${3:-}"
    local lines="${4:-200}"
    local root raw_file redacted_file line result=0
    local -a args

    vx_compose_require_project "$owner" "$project" || return 1
    [[ "$lines" =~ ^[1-9][0-9]*$
        && "$lines" -le "$VX_COMPOSE_LOG_MAX_LINES" ]] \
        || {
            vx_compose_error 'Compose log line count is outside the bounded range'
            return 1
        }
    root="$(vx_compose_project_root "$owner" "$project")"
    if [[ -n "$service" ]]; then
        [[ "$service" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
            && jq -e --arg service "$service" \
                '.services[$service] != null' \
                "$root/runtime/canonical.json" >/dev/null \
            || {
                vx_compose_error 'Compose log service is invalid or unavailable'
                return 1
            }
    fi
    args=(--ansi never logs --no-color --timestamps --tail "$lines")
    [[ -n "$service" ]] && args+=("$service")
    raw_file="$(mktemp)"
    redacted_file="$(mktemp)"
    if ! vx_compose_invoke "$owner" "$project" "${args[@]}" \
        >"$raw_file" 2>&1; then
        result=1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(
            printf '%s' "$line" \
                | sed $'s/\033\\[[0-9;]*[[:alpha:]]//g' \
                | tr -d '\000-\010\013\014\016-\037\177'
        )"
        vx_compose_redact_text "$root" "$line"
        printf '\n'
    done <"$raw_file" >"$redacted_file"
    head -c "$VX_COMPOSE_LOG_MAX_BYTES" "$redacted_file"
    rm -f -- "$raw_file" "$redacted_file"
    return "$result"
}
