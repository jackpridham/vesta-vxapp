#!/usr/bin/env bash

vx_compose_redact_text() {
    local root="$1"
    local text="$2"
    local secret_file secret_line redaction_root
    local -a redaction_roots=("$root/secrets" "$root/runtime/secret-redaction")

    for redaction_root in "${redaction_roots[@]}"; do
        [[ -d "$redaction_root" && ! -L "$redaction_root" ]] || continue
        for secret_file in "$redaction_root"/*; do
            [[ -f "$secret_file" && ! -L "$secret_file" ]] || continue
            while IFS= read -r secret_line || [[ -n "$secret_line" ]]; do
                [[ -n "$secret_line" ]] || continue
                text="${text//"$secret_line"/[REDACTED]}"
            done <"$secret_file"
        done
    done
    text="${text:0:4096}"
    printf '%s' "$text"
}

vx_compose_audit_append() {
    local path="$1"
    local mode="$2"
    local event="$3"
    local lock_path="${path}.lock"
    local lock_fd

    install -d -m 0750 "$(dirname -- "$path")" || return 1
    exec {lock_fd}>>"$lock_path" || return 1
    chmod "$mode" "$lock_path" || {
        exec {lock_fd}>&-
        return 1
    }
    flock -x "$lock_fd" || {
        exec {lock_fd}>&-
        return 1
    }
    if ! printf '%s\n' "$event" >>"$path" \
        || ! chmod "$mode" "$path"; then
        flock -u "$lock_fd" || :
        exec {lock_fd}>&-
        return 1
    fi
    flock -u "$lock_fd" || {
        exec {lock_fd}>&-
        return 1
    }
    exec {lock_fd}>&-
}

vx_compose_last_operation_write() {
    local root="$1"
    local event="$2"
    local runtime="$root/runtime"
    local temp_file

    install -d -m 0750 "$runtime" || return 1
    # A typed long-running operation owns this record until it reaches a
    # terminal state. Nested lifecycle/audit events must not destroy its
    # opaque identifier or make the final progress update impossible.
    if [[ -f "$runtime/last-operation.json"
        && ! -L "$runtime/last-operation.json" ]] \
        && jq -e '
            ((.OPERATION_ID // "") | test("^[a-f0-9]{32}$"))
            and .RESULT == "running"
        ' "$runtime/last-operation.json" >/dev/null 2>&1; then
        return 0
    fi
    temp_file="$(mktemp "$runtime/.last-operation.XXXXXX")" || return 1
    jq -S . <<<"$event" >"$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }
    chmod 0600 "$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }
    mv -f -- "$temp_file" "$runtime/last-operation.json"
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
    local policy_file="${VX_COMPOSE_POLICY_OVERRIDE:-$root/policy.conf}"
    local images_file="${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-$root/images.json}"
    local canonical_file="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"
    local owner project revision event owner_audit profile policy_schema
    local profile_version validator_version canonical_sha image_ids

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
    revision="${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
    [[ -n "$revision" ]] \
        || revision="$(vx_compose_meta_get "$metadata" REVISION 2>/dev/null)" \
        || revision=0
    profile="$(vx_compose_meta_get "$metadata" PROFILE 2>/dev/null)" \
        || profile=unknown
    policy_schema="$(vx_compose_meta_get \
        "$policy_file" POLICY_SCHEMA 2>/dev/null)" || policy_schema=0
    profile_version="$(vx_compose_meta_get \
        "$policy_file" PROFILE_VERSION 2>/dev/null)" || profile_version=0
    validator_version="$(vx_compose_meta_get \
        "$policy_file" VALIDATOR_VERSION 2>/dev/null)" \
        || validator_version=0
    if [[ -n "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-}"
        && -f "$canonical_file" && ! -L "$canonical_file" ]]; then
        canonical_sha="$(sha256sum "$canonical_file" | awk '{print $1}')" \
            || canonical_sha=''
    else
        canonical_sha="$(vx_compose_meta_get \
            "$metadata" CANONICAL_SHA256 2>/dev/null)" || canonical_sha=''
    fi
    if [[ -f "$images_file" && ! -L "$images_file" ]]; then
        image_ids="$(jq -c \
            'with_entries(.value = (.value.IMAGE_ID // ""))' \
            "$images_file" 2>/dev/null)" || image_ids='{}'
    else
        image_ids='{}'
    fi
    details="$(vx_compose_redact_text "$root" "$details")"
    event="$(jq -cn \
        --arg timestamp "$(vx_compose_now)" \
        --arg actor "$actor" \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg action "$action" \
        --arg result "$result" \
        --arg details "$details" \
        --arg profile "$profile" \
        --arg canonical_sha "$canonical_sha" \
        --argjson revision "$revision" \
        --argjson policy_schema "$policy_schema" \
        --argjson profile_version "$profile_version" \
        --argjson validator_version "$validator_version" \
        --argjson image_ids "$image_ids" \
        --argjson duration_ms "$duration_ms" \
        --argjson services "$services" '{
            TIMESTAMP: $timestamp,
            ACTOR: $actor,
            OWNER: $owner,
            PROJECT: $project,
            REVISION: $revision,
            PROFILE: $profile,
            POLICY_SCHEMA: $policy_schema,
            PROFILE_VERSION: $profile_version,
            VALIDATOR_VERSION: $validator_version,
            CANONICAL_SHA256: $canonical_sha,
            IMAGE_IDS: $image_ids,
            ACTION: $action,
            RESULT: $result,
            DURATION_MS: $duration_ms,
            SERVICES: $services,
            DETAILS: $details
        }')" || return 1
    vx_compose_audit_append "$root/audit.log" 0640 "$event" || return 1
    owner_audit="$VESTA/data/users/$owner/docker-audit.log"
    vx_compose_audit_append "$owner_audit" 0600 "$event" || return 1
    vx_compose_last_operation_write "$root" "$event"
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
