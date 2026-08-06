#!/usr/bin/env bash

VX_COMPOSE_PROBE_TRANSPORT_GRACE_SECONDS=2

vx_compose_probe_engine_call() {
    if [[ -n "${VX_COMPOSE_PROBE_ENGINE_HELPER:-}" ]]; then
        env -i PATH="$VX_COMPOSE_SAFE_PATH" "$VX_COMPOSE_PROBE_ENGINE_HELPER" "$@"
    else
        env -i PATH="$VX_COMPOSE_SAFE_PATH" /usr/bin/python3 \
            "$VX_COMPOSE_LIB_DIR/probe-exec.py" "$@"
    fi
}

vx_compose_probe_name_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

vx_compose_probe_revision_root() {
    local root="$1" revision="$2"

    printf '%s/revisions/%06d\n' "$root" "$revision"
}

vx_compose_probe_lock_authorize() {
    local actor="$1" owner="$2" project="$3" capability="$4" lock_path

    [[ -z "${VX_COMPOSE_LOCK_FD:-}" ]] || {
        vx_compose_error 'Compose project probe cannot reuse a mutation lock'
        return 1
    }
    vx_compose_authorize "$actor" "$owner" "$project" "$capability" \
        || return 1
    vx_compose_prepare_owner_roots "$owner" || return 1
    lock_path="$(vx_compose_lock_path "$owner" "$project")" || return 1
    exec {VX_COMPOSE_LOCK_FD}>"$lock_path" || return 1
    if ! flock -s -w 5 "$VX_COMPOSE_LOCK_FD"; then
        exec {VX_COMPOSE_LOCK_FD}>&-
        unset VX_COMPOSE_LOCK_FD
        vx_compose_error 'Compose project probe revision lock is unavailable'
        return 1
    fi
    VX_COMPOSE_LOCK_KEY="$owner/$project"
    VX_COMPOSE_LOCK_DEPTH=1
}

vx_compose_probe_workload_validate() {
    local workload="$1" probe="$2" owner="$3" project="$4"
    local root="$5" profile profile_version policy_schema validator_version
    local image_id

    vx_compose_control_file_is_secure "$workload" 600 || return 1
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || return 1
    profile_version="$(vx_compose_meta_get \
        "$root/policy.conf" PROFILE_VERSION)" || return 1
    policy_schema="$(vx_compose_meta_get \
        "$root/policy.conf" POLICY_SCHEMA)" || return 1
    validator_version="$(vx_compose_meta_get \
        "$root/policy.conf" VALIDATOR_VERSION)" || return 1
    image_id="$(jq -er '.image.id' "$workload" 2>/dev/null)" || return 1

    jq -e \
        --arg probe "$probe" \
        --arg profile "$profile" \
        --arg image_id "$image_id" \
        --argjson profile_version "$profile_version" \
        --argjson policy_schema "$policy_schema" \
        --argjson validator_version "$validator_version" '
        . as $workload_root
        | type == "object"
        and (keys | sort) == ([
            "compatibility", "health_timeout_seconds", "image", "ports",
            "probes", "profile", "resources", "schema", "secrets",
            "services", "volumes", "workload"
        ] | sort)
        and .schema == 1
        and .profile == {name:$profile, version:$profile_version}
        and .compatibility.orchestrator_api == 1
        and .compatibility.policy_schema == $policy_schema
        and (.compatibility.validator_min <= $validator_version)
        and (.compatibility.validator_max >= $validator_version)
        and (.image.id == $image_id)
        and ($image_id | test("^sha256:[a-f0-9]{64}$"))
        and (.services | type == "array" and length > 0)
        and all(.services[];
            (keys | sort) == ["image", "name"]
            and (.name | test("^[a-z0-9][a-z0-9-]{0,62}$"))
            and .image == $workload_root.image.reference
        )
        and (.probes | type == "object" and has($probe))
        and (.probes[$probe] as $p
            | ($p | keys | sort)
                == ["argv", "max_output_bytes", "service", "timeout_seconds"]
            and ($p.service | type == "string")
            and any($workload_root.services[]; .name == $p.service)
            and ($p.argv | type == "array"
                and length >= 1 and length <= 16
                and all(.[]; type == "string"
                    and (utf8bytelength >= 1 and utf8bytelength <= 256)
                    and (test("[\u0000-\u001f\u007f]") | not))
                and (map(utf8bytelength) | add) <= 2048
                and (.[0] | startswith("/")))
            and ($p.timeout_seconds | type == "number"
                and . == floor and . >= 1 and . <= 60)
            and ($p.max_output_bytes | type == "number"
                and . == floor and . >= 256 and . <= 8192))
    ' "$workload" >/dev/null 2>&1
}

vx_compose_probe_runtime_container() {
    local owner="$1" project="$2" service="$3" revision="$4" image_id="$5"
    local root docker_bin runtime raw_ids raw container_id
    local -a container_ids=()

    root="$(vx_compose_project_root "$owner" "$project")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    runtime="$(vx_compose_runtime_name "$owner" "$project")"
    raw_ids="$(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" ps -aq --no-trunc \
            --filter "label=com.docker.compose.project=$runtime" \
            --filter "label=com.docker.compose.service=$service" \
            --filter 'label=vx.managed=yes' \
            --filter "label=vx.user=$owner" \
            --filter "label=vx.project=$project"
    )" || return 1
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] || return 1
        container_ids+=("$container_id")
    done <<<"$raw_ids"
    ((${#container_ids[@]} == 1)) || return 1
    raw="$(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" inspect "${container_ids[0]}"
    )" || return 1
    jq -ce \
        --arg id "${container_ids[0]}" \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg runtime "$runtime" \
        --arg service "$service" \
        --arg revision "$revision" \
        --arg image_id "$image_id" '
        select(type == "array" and length == 1)
        | .[0]
        | select(
            .Id == $id
            and .State.Status == "running"
            and .Image == $image_id
            and .Config.Labels["com.docker.compose.project"] == $runtime
            and .Config.Labels["com.docker.compose.service"] == $service
            and .Config.Labels["vx.managed"] == "yes"
            and .Config.Labels["vx.user"] == $owner
            and .Config.Labels["vx.project"] == $project
            and .Config.Labels["vx.revision"] == $revision
            and .Config.Labels["vx.image-id"] == $image_id)
        | {ID:.Id, STARTED_AT:.State.StartedAt, IMAGE_ID:.Image}
    ' <<<"$raw" 2>/dev/null
}

vx_compose_probe_contains_protected_bytes() {
    local root="$1" output="$2" protected file
    local -a protected_roots=(
        "$root/secrets"
        "$root/runtime/secret-redaction"
    )

    for protected in "${protected_roots[@]}"; do
        [[ -d "$protected" && ! -L "$protected" ]] || continue
        for file in "$protected"/*; do
            [[ -f "$file" && ! -L "$file" && -s "$file" ]] || continue
            if jq -e -Rs --rawfile protected "$file" \
                'contains($protected)' "$output" >/dev/null 2>&1; then
                return 0
            fi
        done
    done
    return 1
}

vx_compose_probe_output_validate() {
    local root="$1" output="$2" max_bytes="$3" canary_file="${4:-}" duplicate_path strings
    local parsed redacted

    [[ "$(stat -c '%s' "$output" 2>/dev/null)" -le "$max_bytes"
        && "$(stat -c '%s' "$output" 2>/dev/null)" -le 4096 ]] || return 1
    iconv -f UTF-8 -t UTF-8 "$output" >/dev/null 2>&1 || return 1
    [[ "$(tail -c 1 "$output" 2>/dev/null | od -An -tuC | tr -d ' ')" == 10 ]] \
        || return 1
    duplicate_path="$(jq --stream -c \
        'select(length == 2) | .[0] | @json' "$output" 2>/dev/null \
        | LC_ALL=C sort | uniq -d | head -n 1)"
    [[ -z "$duplicate_path" ]] || return 1
    parsed="$(jq -ce '
        select(type == "object")
        | select((keys | sort)
            == ["observations", "schema", "state", "summary"])
        | select(.schema == 1)
        | select(.state == "pass" or .state == "fail"
            or .state == "unavailable")
        | select(.summary | type == "string"
            and utf8bytelength <= 256
            and (test("[\u0000-\u001f\u007f]") | not))
        | select(.observations | type == "object" and length <= 16)
        | select(all(.observations | to_entries[];
            (.key | test("^[a-z][a-z0-9-]{0,62}$"))
            and (.value | type == "string" and utf8bytelength <= 256
                and (test("[\u0000-\u001f\u007f]") | not))))
    ' "$output" 2>/dev/null)" || return 1
    [[ "$(printf '%s\n' "$parsed" | wc -c)" -le 4096 ]] || return 1
    vx_compose_probe_contains_protected_bytes "$root" "$output" && return 1
    if [[ -n "$canary_file" && -f "$canary_file" ]] \
        && jq -e -Rs --rawfile canary "$canary_file" 'contains($canary)' \
            "$output" >/dev/null 2>&1; then
        return 1
    fi
    strings="$(jq -r '
        .summary,
        (.observations | to_entries[] | .key, .value)
    ' "$output" 2>/dev/null)" || return 1
    if LC_ALL=C grep -Eiq \
        '(^|[^a-z0-9])(password|passwd|secret|token|auth|authorization|bearer|private[ _-]*key|access[ _-]*key|api[ _-]*key|session|cookie|credential)([^a-z0-9]|$)|[a-z][a-z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@|(^|[[:space:]])/(home|root|tmp|etc)(/|$)|(^|[[:space:]])/usr/local/vesta(/|$)|(^|[[:space:]])/var/lib/docker(/|$)' \
        <<<"$strings"; then
        return 1
    fi
    redacted="$(vx_compose_redact_text "$root" "$strings")" || return 1
    [[ "$redacted" == "$strings" ]] || return 1
    printf '%s\n' "$parsed"
}

vx_compose_probe_result_json() {
    local owner="$1" project="$2" probe="$3" service="$4" revision="$5"
    local workload_sha="$6" state="$7" summary="$8" observations="$9"
    local exit_code="${10}" duration_ms="${11}" observed_at="${12}"
    local exit_json=null

    [[ "$exit_code" =~ ^([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]] \
        && exit_json="$exit_code"
    jq -cnS \
        --arg owner "$owner" --arg project "$project" --arg probe "$probe" \
        --arg service "$service" --arg workload_sha "$workload_sha" \
        --arg state "$state" --arg summary "$summary" \
        --arg observed_at "$observed_at" \
        --argjson revision "$revision" --argjson observations "$observations" \
        --argjson exit_code "$exit_json" --argjson duration_ms "$duration_ms" '{
            SCHEMA:1, OWNER:$owner, PROJECT:$project, PROBE:$probe,
            SERVICE:$service, REVISION:$revision,
            WORKLOAD_SHA256:$workload_sha, STATE:$state, SUMMARY:$summary,
            OBSERVATIONS:$observations, EXIT_CODE:$exit_code,
            DURATION_MS:$duration_ms, OBSERVED_AT:$observed_at
        }'
}

vx_compose_probe_run() {
    local actor="$1" owner="$2" project="$3" probe="$4"
    local root revision revision_root workload workload_sha profile service
    local timeout_seconds max_output image_id image_reference image_os
    local image_architecture profile_version before after engine_helper
    local capture_root stdout_file stderr_file request_file engine_result canary_file start_ms end_ms duration_ms
    local execution_status state summary observations parsed exit_code category
    local global_lock owner_lock project_probe_lock result result_temp
    local observed_at
    local -a argv=()

    vx_compose_probe_name_is_valid "$probe" || {
        vx_compose_error 'invalid Compose project probe name'
        return 1
    }
    vx_compose_probe_lock_authorize "$actor" "$owner" "$project" view \
        || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || {
        vx_compose_lock_release
        return 1
    }
    [[ "$revision" =~ ^[1-9][0-9]*$ ]] || {
        vx_compose_lock_release
        return 1
    }
    revision_root="$(vx_compose_probe_revision_root "$root" "$revision")"
    workload="$revision_root/workload.json"
    if ! vx_compose_active_revision_verify "$owner" "$project" \
        || ! grep -Eq '^[a-f0-9]{64}  workload\.json$' \
            "$revision_root/manifest.sha256" \
        || ! vx_compose_probe_workload_validate \
            "$workload" "$probe" "$owner" "$project" "$root"; then
        vx_compose_lock_release
        vx_compose_error 'Compose project probe authority is invalid'
        return 1
    fi
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || {
        vx_compose_lock_release
        return 1
    }
    vx_compose_profile_require_authorized "$owner" "$project" "$profile" || {
        vx_compose_lock_release
        return 1
    }
    workload_sha="$(sha256sum "$workload" | awk '{print $1}')" || {
        vx_compose_lock_release
        return 1
    }
    service="$(jq -er --arg probe "$probe" \
        '.probes[$probe].service' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    timeout_seconds="$(jq -er --arg probe "$probe" \
        '.probes[$probe].timeout_seconds' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    max_output="$(jq -er --arg probe "$probe" \
        '.probes[$probe].max_output_bytes' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    image_id="$(jq -er '.image.id' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    image_reference="$(jq -er '.image.reference' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    image_os="$(jq -er '.image.os' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    image_architecture="$(jq -er '.image.architecture' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    profile_version="$(jq -er '.profile.version' "$workload")" || {
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_image_approval_require \
            "$owner" "$image_reference" "$image_id" "$image_os" \
            "$image_architecture" "$profile" "$profile_version" \
        || [[ "$(vx_compose_runtime_identity_preflight \
            "$owner" "$project")" != complete ]]; then
        vx_compose_lock_release
        vx_compose_error 'Compose project probe image authority is invalid'
        return 1
    fi
    mapfile -d '' -t argv < <(jq -j --arg probe "$probe" \
        '.probes[$probe].argv[] | ., "\u0000"' "$workload")
    ((${#argv[@]} >= 1)) || {
        vx_compose_lock_release
        return 1
    }

    if [[ -e "$root/runtime/probes" || -L "$root/runtime/probes" ]]; then
        [[ -d "$root/runtime/probes" && ! -L "$root/runtime/probes" ]] || {
            vx_compose_lock_release
            vx_compose_error 'Compose project probe runtime authority is invalid'
            return 1
        }
    fi
    install -d -m 0700 "$root/runtime/probes" || {
        vx_compose_lock_release
        return 1
    }
    [[ "$(stat -c '%u:%g:%a:%F' "$root/runtime/probes" 2>/dev/null)" \
        == "$(vx_compose_authority_uid):$(vx_compose_authority_gid):700:directory" ]] \
        || {
            vx_compose_lock_release
            vx_compose_error 'Compose project probe runtime authority is invalid'
            return 1
        }
    exec {global_lock}>"$VESTA/data/.compose-probes.lock" || {
        vx_compose_lock_release
        return 1
    }
    exec {owner_lock}>"$(vx_compose_projects_root "$owner")/.locks/.probes.lock" \
        || {
            exec {global_lock}>&-
            vx_compose_lock_release
            return 1
        }
    exec {project_probe_lock}>"$root/runtime/probes/.lock" || {
        exec {owner_lock}>&- {global_lock}>&-
        vx_compose_lock_release
        return 1
    }
    if ! flock -n "$global_lock" || ! flock -n "$owner_lock" \
        || ! flock -n "$project_probe_lock"; then
        exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
        vx_compose_lock_release
        vx_compose_error 'Compose project probe capacity is unavailable'
        return 1
    fi
    before="$(vx_compose_probe_runtime_container \
        "$owner" "$project" "$service" "$revision" "$image_id")" || {
        exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
        vx_compose_lock_release
        vx_compose_error 'Compose project probe service is unavailable'
        return 1
    }
    if [[ -f "$root/runtime/probes/unavailable.json" ]]; then
        vx_compose_control_file_is_secure \
            "$root/runtime/probes/unavailable.json" 600 || {
            exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
            vx_compose_lock_release
            vx_compose_error 'Compose project probe latch authority is invalid'
            return 1
        }
        jq -e --arg revision "$revision" --arg workload "$workload_sha" '
            keys == ["CONTAINER_ID","EXEC_ID","OBSERVED_AT","REVISION","STARTED_AT","WORKLOAD_SHA256"]
            and (.EXEC_ID|test("^[a-f0-9]{64}$"))
            and (.CONTAINER_ID|test("^[a-f0-9]{12,64}$"))
            and .REVISION == ($revision|tonumber)
            and .WORKLOAD_SHA256 == $workload
        ' "$root/runtime/probes/unavailable.json" >/dev/null 2>&1 || {
            exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
            vx_compose_lock_release
            vx_compose_error 'Compose project probe latch authority is invalid'
            return 1
        }
        if jq -e --arg id "$(jq -r '.ID' <<<"$before")" \
            --arg started "$(jq -r '.STARTED_AT // ""' <<<"$before")" \
            '.CONTAINER_ID == $id and .STARTED_AT == $started' \
            "$root/runtime/probes/unavailable.json" >/dev/null 2>&1; then
            engine_helper="${VX_COMPOSE_PROBE_ENGINE_HELPER:-$VX_COMPOSE_LIB_DIR/probe-exec.py}"
            engine_result="$(mktemp -u "$root/runtime/probes/.inspect.XXXXXX")"
            if ! vx_compose_probe_engine_call inspect \
                    "$(jq -r '.EXEC_ID' "$root/runtime/probes/unavailable.json")" \
                    "$engine_result" \
                || ! vx_compose_control_file_is_secure "$engine_result" 600 \
                || jq -e '.RUNNING == true' "$engine_result" >/dev/null 2>&1; then
                [[ ! -f "$engine_result" ]] || rm -f -- "$engine_result"
                exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
                vx_compose_lock_release
                vx_compose_error 'Compose project probes are latched unavailable'
                return 1
            fi
            rm -f -- "$engine_result"
        fi
        rm -f -- "$root/runtime/probes/unavailable.json"
    fi

    capture_root="$(mktemp -d "$root/runtime/probes/.capture.XXXXXX")" || {
        exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
        vx_compose_lock_release
        return 1
    }
    chmod 0700 "$capture_root"
    stdout_file="$capture_root/stdout"
    stderr_file="$capture_root/stderr"
    request_file="$capture_root/request.json"
    engine_result="$capture_root/engine-result.json"
    canary_file="$capture_root/disclosure-canary"
    : >"$stdout_file"
    : >"$stderr_file"
    chmod 0600 "$stdout_file" "$stderr_file"
    printf 'VX-PROBE-CANARY-%s' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" \
        >"$canary_file"
    chmod 0600 "$canary_file"
    engine_helper="${VX_COMPOSE_PROBE_ENGINE_HELPER:-$VX_COMPOSE_LIB_DIR/probe-exec.py}"
    jq -nS --arg container_id "$(jq -r '.ID' <<<"$before")" \
        --argjson argv "$(printf '%s\0' "${argv[@]}" | jq -Rs 'split("\u0000")[:-1]')" \
        --argjson timeout "$timeout_seconds" \
        --argjson grace "$VX_COMPOSE_PROBE_TRANSPORT_GRACE_SECONDS" \
        --argjson max_output "$max_output" '{container_id:$container_id,argv:$argv,
          timeout_seconds:$timeout,transport_grace_seconds:$grace,max_output_bytes:$max_output}' \
        >"$request_file" || execution_status=125
    chmod 0600 "$request_file"
    start_ms="$(date +%s%3N)"
    vx_compose_probe_engine_call \
        "$request_file" "$stdout_file" "$stderr_file" "$engine_result" \
        >/dev/null 2>>"$stderr_file"
    execution_status=$?
    end_ms="$(date +%s%3N)"
    duration_ms=$((end_ms - start_ms))
    observed_at="$(vx_compose_now)"
    state=invalid-output
    summary='Probe output was rejected'
    observations='{}'
    exit_code=
    category=invalid-output

    if (( execution_status != 0 )) \
        || ! vx_compose_control_file_is_secure "$engine_result" 600; then
        state=unavailable
        summary='Probe engine execution was unavailable'
        observations='{}'
        category=engine-unavailable
    else
        exit_code="$(jq -r '.EXIT_CODE // empty' "$engine_result")"
    fi
    if [[ -f "$engine_result" ]] \
        && jq -e '.TRANSPORT_TIMEOUT == true and .RUNNING == true' \
            "$engine_result" >/dev/null 2>&1; then
        state=unavailable
        summary='Probe execution did not stop at the transport deadline'
        observations='{}'; exit_code=; category=transport-deadline
        jq -nS --arg exec_id "$(jq -r '.EXEC_ID' "$engine_result")" \
            --arg container_id "$(jq -r '.ID' <<<"$before")" \
            --arg started_at "$(jq -r '.STARTED_AT // ""' <<<"$before")" \
            --arg revision "$revision" --arg workload "$workload_sha" \
            --arg observed_at "$observed_at" '{EXEC_ID:$exec_id,
                CONTAINER_ID:$container_id,STARTED_AT:$started_at,
                REVISION:($revision|tonumber),WORKLOAD_SHA256:$workload,
                OBSERVED_AT:$observed_at
            }' >"$root/runtime/probes/unavailable.json"
        vx_compose_control_file_protect \
            "$root/runtime/probes/unavailable.json" 600 || :
    elif [[ -f "$engine_result" ]] \
        && jq -e '.DECLARED_TIMEOUT == true' "$engine_result" >/dev/null 2>&1; then
        state=timeout
        summary='Probe exceeded its declared deadline'
        observations='{}'
        category=declared-timeout
    elif { [[ -f "$engine_result" ]] \
            && jq -e '.TRUNCATED == true' "$engine_result" >/dev/null 2>&1; } \
        || [[ "$(stat -c '%s' "$stdout_file")" -gt "$max_output" \
        || "$(stat -c '%s' "$stderr_file")" -gt "$max_output" ]]; then
        category=truncated-output
    elif parsed="$(vx_compose_probe_output_validate \
        "$root" "$stdout_file" "$max_output" "$canary_file")"; then
        state="$(jq -r '.state' <<<"$parsed")"
        summary="$(jq -r '.summary' <<<"$parsed")"
        observations="$(jq -cS '.observations' <<<"$parsed")"
        category=application-result
        if [[ -n "$exit_code" && "$exit_code" -ne 0 && "$state" == pass ]]; then
            state=unavailable
            summary='Probe process failed'
            observations='{}'
            category=process-failure
        fi
    elif [[ -n "$exit_code" && "$exit_code" -ne 0 ]]; then
        state=unavailable
        summary='Probe process failed'
        observations='{}'
        category=process-failure
    fi

    after="$(vx_compose_probe_runtime_container \
        "$owner" "$project" "$service" "$revision" "$image_id")" || after=
    if [[ -z "$after" \
        || "$(jq -r '.ID + ":" + (.STARTED_AT // "")' <<<"$after")" \
            != "$(jq -r '.ID + ":" + (.STARTED_AT // "")' <<<"$before")" ]]; then
        state=unavailable
        summary='Probe service identity changed during execution'
        observations='{}'
        exit_code=
        category=identity-drift
    fi
    result="$(vx_compose_probe_result_json \
        "$owner" "$project" "$probe" "$service" "$revision" \
        "$workload_sha" "$state" "$summary" "$observations" \
        "$exit_code" "$duration_ms" "$observed_at")" || result=
    if [[ -n "$result" ]]; then
        result_temp="$(mktemp "$root/runtime/.last-probe.XXXXXX")" || result=
    fi
    if [[ -n "$result" ]] \
        && printf '%s\n' "$result" >"$result_temp" \
        && vx_compose_control_file_protect "$result_temp" 600 \
        && mv -f -- "$result_temp" "$root/runtime/last-probe.json"; then
        result_temp=
    else
        [[ -z "${result_temp:-}" ]] || rm -f -- "$result_temp"
        result=
    fi
    VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$revision" \
        vx_compose_audit "$root" probe succeeded \
        "probe=$probe workload_sha256=$workload_sha state=$state exit_code=${exit_code:-null} category=$category" \
        "$duration_ms" "[\"$service\"]" "$actor" >/dev/null 2>&1 || :
    rm -f -- "$stdout_file" "$stderr_file" "$request_file" "$engine_result" "$canary_file"
    rmdir -- "$capture_root" 2>/dev/null || :
    exec {project_probe_lock}>&- {owner_lock}>&- {global_lock}>&-
    vx_compose_lock_release
    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}
