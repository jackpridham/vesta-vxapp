#!/usr/bin/env bash

vx_compose_operation_id() {
    openssl rand -hex 16
}

vx_compose_operation_write() {
    local root="$1" record="$2" runtime temp

    runtime="$root/runtime"
    install -d -m 0750 "$runtime" || return 1
    temp="$(mktemp "$runtime/.operation.XXXXXX")" || return 1
    if ! jq -S . <<<"$record" >"$temp" \
        || ! vx_compose_control_file_protect "$temp" 600 \
        || ! mv -f -- "$temp" "$runtime/last-operation.json"; then
        rm -f -- "$temp"
        return 1
    fi
}

vx_compose_operation_begin() {
    local root="$1" actor="$2" action="$3" target_revision="${4:-0}"
    local current_revision operation_id now record path owner project

    [[ "$action" =~ ^[a-z][a-z0-9-]{0,63}$
        && "$target_revision" =~ ^[0-9]+$ ]] || return 1
    owner="$(vx_compose_meta_get "$root/project.conf" OWNER)" || return 1
    project="$(vx_compose_meta_get "$root/project.conf" PROJECT)" || return 1
    [[ "${VX_COMPOSE_LOCK_KEY:-}" == "$owner/$project"
        && "${VX_COMPOSE_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || {
            vx_compose_error 'Compose operation requires the exact project lock'
            return 1
        }
    path="$root/runtime/last-operation.json"
    if [[ -e "$path" || -L "$path" ]]; then
        vx_compose_control_file_is_secure "$path" 600 || return 1
        jq -e 'type=="object" and (
            (
                (.OPERATION_ID|type=="string")
                and (.OPERATION_ID|test("^[a-f0-9]{32}$"))
                and (.RESULT=="running" or .RESULT=="succeeded"
                    or .RESULT=="failed")
            ) or (
                (.OPERATION_ID == null)
                and (.TIMESTAMP|type=="string")
                and (.ACTION|type=="string")
                and (.RESULT=="started" or .RESULT=="succeeded"
                    or .RESULT=="failed" or .RESULT=="opened"
                    or .RESULT=="closed")
                and .OWNER==$owner and .PROJECT==$project
            )
        )' --arg owner "$owner" --arg project "$project" \
            "$path" >/dev/null 2>&1 || {
            vx_compose_error 'stored Compose operation metadata is invalid'
            return 1
        }
        if jq -e '.RESULT=="running"' "$path" >/dev/null; then
            vx_compose_error 'another Compose operation is already running'
            return 1
        fi
    fi
    current_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    operation_id="$(vx_compose_operation_id)" || return 1
    now="$(vx_compose_now)"
    record="$(jq -cn --arg id "$operation_id" --arg actor "$actor" \
        --arg action "$action" --arg now "$now" \
        --argjson current "$current_revision" \
        --argjson target "$target_revision" '{
            OPERATION_ID:$id,ACTOR:$actor,ACTION:$action,
            STARTED:$now,UPDATED:$now,FINISHED:null,
            PHASE:"starting",PERCENT:0,RESULT:"running",
            CURRENT_REVISION:$current,TARGET_REVISION:$target,MESSAGE:""
        }')" || return 1
    vx_compose_operation_write "$root" "$record" || return 1
    printf '%s\n' "$operation_id"
}

vx_compose_operation_update() {
    local root="$1" operation_id="$2" phase="$3" percent="$4" message="${5:-}"
    local path record

    [[ "$operation_id" =~ ^[a-f0-9]{32}$
        && "$phase" =~ ^[a-z][a-z0-9-]{0,31}$
        && "$percent" =~ ^[0-9]+$ && "$percent" -le 100 ]] || return 1
    path="$root/runtime/last-operation.json"
    vx_compose_control_file_is_secure "$path" 600 || return 1
    message="$(vx_compose_redact_text "$root" "$message")"
    record="$(jq -c --arg id "$operation_id" --arg phase "$phase" \
        --arg now "$(vx_compose_now)" --arg message "$message" \
        --argjson percent "$percent" '
        select(.OPERATION_ID==$id and .RESULT=="running")
        | .UPDATED=$now | .PHASE=$phase | .PERCENT=$percent
        | .MESSAGE=$message
    ' "$path")" || return 1
    [[ -n "$record" ]] || return 1
    vx_compose_operation_write "$root" "$record"
}

vx_compose_operation_finish() {
    local root="$1" operation_id="$2" result="$3" message="${4:-}"
    local path record phase

    [[ "$result" == succeeded || "$result" == failed ]] || return 1
    path="$root/runtime/last-operation.json"
    vx_compose_control_file_is_secure "$path" 600 || return 1
    message="$(vx_compose_redact_text "$root" "$message")"
    phase=complete
    [[ "$result" == succeeded ]] || phase=failed
    record="$(jq -c --arg id "$operation_id" --arg result "$result" \
        --arg phase "$phase" --arg now "$(vx_compose_now)" \
        --arg message "$message" '
        select(.OPERATION_ID==$id and .RESULT=="running")
        | .UPDATED=$now | .FINISHED=$now | .PHASE=$phase
        | .PERCENT=100 | .RESULT=$result | .MESSAGE=$message
    ' "$path")" || return 1
    [[ -n "$record" ]] || return 1
    vx_compose_operation_write "$root" "$record"
}

vx_compose_operation_list_json() {
    local actor="$1" owner="$2" project="$3" path

    vx_compose_authorize "$actor" "$owner" "$project" view || return 1
    path="$(vx_compose_project_root "$owner" "$project")/runtime/last-operation.json"
    [[ ! -e "$path" && ! -L "$path" ]] || {
        vx_compose_control_file_is_secure "$path" 600 || return 1
        jq -S '{
            OPERATION_ID:(.OPERATION_ID // ""),
            ACTOR:(.ACTOR // ""),
            ACTION:(.ACTION // ""),
            STARTED:(.STARTED // .TIMESTAMP // ""),
            UPDATED:(.UPDATED // .TIMESTAMP // ""),
            FINISHED:(.FINISHED // null),
            PHASE:(.PHASE // "complete"),
            PERCENT:(.PERCENT // 100),
            RESULT:(.RESULT // "unknown"),
            CURRENT_REVISION:(.CURRENT_REVISION // .REVISION // 0),
            TARGET_REVISION:(.TARGET_REVISION // 0),
            MESSAGE:(.MESSAGE // .DETAILS // "")
        }' "$path"
        return
    }
    {
        printf '{}\n'
        return
    }
}
