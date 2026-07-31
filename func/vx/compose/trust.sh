#!/usr/bin/env bash

VX_COMPOSE_TRUST_TIMEOUT_SECONDS="${VX_DOCKER_TRUST_TIMEOUT_SECONDS:-30}"
VX_COMPOSE_TRUST_VULNERABILITY_THRESHOLD="${VX_DOCKER_TRUST_VULNERABILITY_THRESHOLD:-high}"
[[ "$VX_COMPOSE_TRUST_TIMEOUT_SECONDS" =~ ^([1-9]|[1-5][0-9]|60)$ ]] \
    || VX_COMPOSE_TRUST_TIMEOUT_SECONDS=30
[[ "$VX_COMPOSE_TRUST_VULNERABILITY_THRESHOLD" \
    =~ ^(low|medium|high|critical)$ ]] \
    || VX_COMPOSE_TRUST_VULNERABILITY_THRESHOLD=high

vx_compose_trust_root() {
    printf '%s/data/vx/compose/image-trust\n' "$VESTA"
}

vx_compose_trust_lock_acquire() {
    local digest="$1" root lock_root lock_file

    vx_compose_trust_digest_is_valid "$digest" || return 1
    [[ -z "${VX_COMPOSE_TRUST_LOCK_FD:-}" ]] || return 1
    root="$(vx_compose_trust_root)"
    lock_root="$root/locks"
    install -d -m 0700 "$root" "$lock_root"
    [[ -d "$root" && ! -L "$root"
        && -d "$lock_root" && ! -L "$lock_root"
        && "$(stat -c '%a' "$root")" == 700
        && "$(stat -c '%a' "$lock_root")" == 700 ]] || return 1
    if [[ "$EUID" -eq 0
        && ( "$(stat -c '%u' "$root")" -ne 0
            || "$(stat -c '%u' "$lock_root")" -ne 0 ) ]]; then
        return 1
    fi
    lock_file="$lock_root/${digest#sha256:}.lock"
    exec {VX_COMPOSE_TRUST_LOCK_FD}>"$lock_file" || return 1
    chmod 0600 "$lock_file" || {
        exec {VX_COMPOSE_TRUST_LOCK_FD}>&-
        unset VX_COMPOSE_TRUST_LOCK_FD
        return 1
    }
    flock -x "$VX_COMPOSE_TRUST_LOCK_FD" || {
        exec {VX_COMPOSE_TRUST_LOCK_FD}>&-
        unset VX_COMPOSE_TRUST_LOCK_FD
        return 1
    }
}

vx_compose_trust_lock_release() {
    [[ -n "${VX_COMPOSE_TRUST_LOCK_FD:-}" ]] || return 0
    flock -u "$VX_COMPOSE_TRUST_LOCK_FD" || true
    exec {VX_COMPOSE_TRUST_LOCK_FD}>&-
    unset VX_COMPOSE_TRUST_LOCK_FD
}

vx_compose_trust_digest_is_valid() {
    [[ "$1" =~ ^sha256:[a-f0-9]{64}$ ]]
}

vx_compose_trust_mode_for_profile() {
    local profile="$1" variable mode

    [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1
    variable="VX_DOCKER_TRUST_MODE_${profile^^}"
    variable="${variable//-/_}"
    mode="${!variable:-${VX_DOCKER_TRUST_MODE:-disabled}}"
    [[ "$mode" == disabled || "$mode" == audit || "$mode" == enforce ]] \
        || {
            vx_compose_error 'Docker image trust mode is invalid'
            return 1
        }
    printf '%s\n' "$mode"
}

vx_compose_trust_evidence_dir() {
    local digest="$1"

    vx_compose_trust_digest_is_valid "$digest" || return 1
    printf '%s/evidence/%s\n' "$(vx_compose_trust_root)" "${digest#sha256:}"
}

vx_compose_trust_prepare_evidence() {
    local digest="$1" immutable_reference="$2" image_id="$3" labels="$4"
    local root evidence metadata temp_file

    vx_compose_trust_digest_is_valid "$digest" || return 1
    [[ "$immutable_reference" == *@sha256:${digest#sha256:}
        && "$image_id" =~ ^sha256:[a-f0-9]{12,64}$ ]] || return 1
    vx_compose_image_oci_labels_are_safe "$labels" || return 1
    root="$(vx_compose_trust_root)"
    evidence="$(vx_compose_trust_evidence_dir "$digest")" || return 1
    install -d -m 0700 "$root" "$root/evidence" "$evidence"
    [[ -d "$root" && ! -L "$root"
        && -d "$root/evidence" && ! -L "$root/evidence"
        && -d "$evidence" && ! -L "$evidence"
        && "$(stat -c '%a' "$root")" == 700
        && "$(stat -c '%a' "$root/evidence")" == 700
        && "$(stat -c '%a' "$evidence")" == 700 ]] || return 1
    if [[ "$EUID" -eq 0
        && ( "$(stat -c '%u' "$root")" -ne 0
            || "$(stat -c '%u' "$root/evidence")" -ne 0
            || "$(stat -c '%u' "$evidence")" -ne 0 ) ]]; then
        return 1
    fi
    metadata="$evidence/image.json"
    if [[ -f "$metadata" ]]; then
        [[ ! -L "$metadata" && "$(stat -c '%a' "$metadata")" == 600 ]] \
            || return 1
        if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$metadata")" -ne 0 ]]; then
            return 1
        fi
        jq -e --arg digest "$digest" --arg reference "$immutable_reference" \
            --arg image_id "$image_id" --argjson labels "$labels" \
            '.SCHEMA == 1 and .DIGEST == $digest
             and .IMMUTABLE_REFERENCE == $reference
             and .IMAGE_ID == $image_id
             and .OCI_LABELS == $labels' "$metadata" >/dev/null \
            || return 1
        printf '%s\n' "$evidence"
        return 0
    fi
    temp_file="$(mktemp "$evidence/.image.XXXXXX")" || return 1
    jq -n -S \
        --arg digest "$digest" \
        --arg reference "$immutable_reference" \
        --arg image_id "$image_id" \
        --arg created "$(vx_compose_now)" \
        --argjson labels "$labels" '{
            SCHEMA: 1,
            DIGEST: $digest,
            IMMUTABLE_REFERENCE: $reference,
            IMAGE_ID: $image_id,
            OCI_LABELS: $labels,
            RECORDED: $created
        }' >"$temp_file" || {
            rm -f -- "$temp_file"
            return 1
        }
    chmod 0600 "$temp_file"
    mv -- "$temp_file" "$metadata"
    printf '%s\n' "$evidence"
}

vx_compose_trust_attachment_add_locked() {
    local digest="$1" type="$2" document="$3" generator="$4"
    local verified="${5:-unverified}" evidence document_digest metadata
    local temp_file temp_document

    vx_compose_trust_digest_is_valid "$digest" || return 1
    [[ "$type" == sbom || "$type" == provenance ]] || return 1
    [[ "$generator" =~ ^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,127}$
        && "$verified" =~ ^(verified|unverified)$
        && -f "$document" && ! -L "$document"
        && "$(stat -c '%a' "$document")" =~ ^(600|400)$ ]] || return 1
    if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$document")" -ne 0 ]]; then
        vx_compose_error 'trust attachment is not root-controlled'
        return 1
    fi
    evidence="$(vx_compose_trust_evidence_dir "$digest")" || return 1
    [[ -f "$evidence/image.json" && ! -L "$evidence/image.json" ]] || return 1
    metadata="$evidence/$type.json"
    temp_file="$(mktemp "$evidence/.$type.XXXXXX")" || return 1
    temp_document="$(mktemp "$evidence/.$type-document.XXXXXX")" || {
        rm -f -- "$temp_file"
        return 1
    }
    install -m 0600 "$document" "$temp_document" || {
        rm -f -- "$temp_file" "$temp_document"
        return 1
    }
    document_digest="$(sha256sum "$temp_document" | awk '{print $1}')"
    jq -n -S \
        --arg type "$type" \
        --arg digest "sha256:$document_digest" \
        --arg generator "$generator" \
        --arg created "$(vx_compose_now)" \
        --arg state "$verified" '{
            TYPE: $type,
            DIGEST: $digest,
            GENERATOR: $generator,
            CREATED: $created,
            VERIFICATION_STATE: $state
        }' >"$temp_file" || {
            rm -f -- "$temp_file" "$temp_document"
            return 1
        }
    chmod 0600 "$temp_file"
    mv -- "$temp_document" "$evidence/$type.document"
    mv -- "$temp_file" "$metadata"
    cat "$metadata"
}

vx_compose_trust_attachment_add() {
    local digest="$1" result status

    vx_compose_trust_digest_is_valid "$digest" || return 1
    vx_compose_trust_lock_acquire "$digest" || return 1
    if result="$(vx_compose_trust_attachment_add_locked "$@")"; then
        status=0
    else
        status=$?
    fi
    vx_compose_trust_lock_release
    if (( status == 0 )); then
        printf '%s\n' "$result"
    fi
    return "$status"
}

vx_compose_trust_adapter_path() {
    local adapter="$1" root path

    [[ "$adapter" == signature || "$adapter" == vulnerability ]] || return 1
    root="${VX_DOCKER_TRUST_ADAPTER_ROOT:-$VESTA/func/vx/compose/trust-adapters}"
    path="$root/$adapter"
    [[ -x "$path" && -f "$path" && ! -L "$path" ]] || return 1
    if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$path")" -ne 0 ]]; then
        return 1
    fi
    printf '%s\n' "$path"
}

vx_compose_trust_run_adapter() {
    local adapter="$1" digest="$2" evidence="$3" threshold="$4"
    local path output status state root temp_output

    path="$(vx_compose_trust_adapter_path "$adapter")" || {
        jq -n --arg adapter "$adapter" \
            '{ADAPTER:$adapter,STATE:"unavailable",DETAIL:"adapter unavailable"}'
        return 0
    }
    root="$(vx_compose_trust_root)"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    temp_output="$(mktemp "$root/.adapter-output.XXXXXX")" || return 1
    chmod 0600 "$temp_output"
    if timeout --signal=KILL "$VX_COMPOSE_TRUST_TIMEOUT_SECONDS" \
        bash -c '
            fixed_root=$1
            shift
            cd "$fixed_root"
            for fd_path in /proc/self/fd/*; do
                fd=${fd_path##*/}
                case "$fd" in 0|1|2) ;; *[!0-9]*|"") ;; *)
                    eval "exec ${fd}>&-"
                esac
            done
            ulimit -f 16
            exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
        ' vx-trust-adapter "$root" \
        "$path" "$digest" "$evidence" "$threshold" \
        </dev/null >"$temp_output" 2>/dev/null; then
        status=0
    else
        status=$?
    fi
    output="$(head -c 8193 "$temp_output")"
    rm -f -- "$temp_output"
    if (( status == 124 || status == 137 )); then
        jq -n --arg adapter "$adapter" \
            '{ADAPTER:$adapter,STATE:"timeout",DETAIL:"adapter timed out"}'
        return 0
    fi
    if (( status != 0 )) || ! jq -e \
        --arg adapter "$adapter" '
            .SCHEMA == 1 and .ADAPTER == $adapter
            and (.STATE | IN("pass","fail","offline","unavailable"))
            and (.DETAIL | type == "string" and length <= 256)
            and (keys - ["SCHEMA","ADAPTER","STATE","DETAIL"] | length == 0)
        ' <<<"$output" >/dev/null 2>&1; then
        jq -n --arg adapter "$adapter" \
            '{ADAPTER:$adapter,STATE:"error",DETAIL:"adapter failed"}'
        return 0
    fi
    state="$(jq -r '.STATE' <<<"$output")"
    jq -n -c --arg adapter "$adapter" --arg state "$state" '{
        ADAPTER:$adapter,
        STATE:$state,
        DETAIL:(
            if $state == "pass" then "verification passed"
            elif $state == "fail" then "verification did not pass"
            elif $state == "offline" then "verification offline"
            else "adapter unavailable"
            end
        )
    }'
}

vx_compose_trust_exception_applies() {
    local digest="$1" profile="$2" profile_version="$3" policy_version="$4"
    local exception expires expires_epoch

    exception="$(vx_compose_trust_root)/exceptions/${digest#sha256:}.json"
    [[ -f "$exception" && ! -L "$exception"
        && "$(stat -c '%a' "$exception")" == 600 ]] || return 1
    if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$exception")" -ne 0 ]]; then
        return 1
    fi
    jq -e --arg digest "$digest" --arg profile "$profile" \
        --argjson profile_version "$profile_version" \
        --argjson policy_version "$policy_version" '
        .SCHEMA == 1 and .AUTHORITY == "root" and .DIGEST == $digest
        and .PROFILE == $profile and .PROFILE_VERSION == $profile_version
        and .POLICY_VERSION == $policy_version
        and (.EXPIRES | type == "string")
        and (.REASON | type == "string" and length > 0 and length <= 256)
        and (keys - ["SCHEMA","AUTHORITY","DIGEST","PROFILE",
                     "PROFILE_VERSION","POLICY_VERSION","EXPIRES","REASON"]
             | length == 0)
    ' "$exception" >/dev/null || return 1
    expires="$(jq -r '.EXPIRES' "$exception")"
    [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || return 1
    expires_epoch="$(date -u -d "$expires" +%s 2>/dev/null)" || return 1
    (( expires_epoch > $(date -u +%s) ))
}

vx_compose_verify_image_trust_locked() {
    local profile="$1" immutable_reference="$2" image_id="$3" labels="$4"
    local mode digest evidence profile_version policy_version signature
    local vulnerability decision exception=no record temp_file root

    mode="$(vx_compose_trust_mode_for_profile "$profile")" || return 1
    profile_version="$(vx_compose_profile_version "$profile")" || return 1
    policy_version="${VX_DOCKER_POLICY_VALIDATOR_VERSION:-0}"
    if [[ "$mode" == disabled ]]; then
        jq -n --arg mode "$mode" --arg profile "$profile" \
            --argjson profile_version "$profile_version" \
            --argjson policy_version "$policy_version" '{
                MODE:$mode,DECISION:"disabled",PROFILE:$profile,
                PROFILE_VERSION:$profile_version,POLICY_VERSION:$policy_version,
                SIGNATURE:{STATE:"not-run"},VULNERABILITY:{STATE:"not-run"},
                EXCEPTION:false
            }'
        return 0
    fi
    digest="${immutable_reference##*@}"
    if ! vx_compose_trust_digest_is_valid "$digest"; then
        vx_compose_error 'registry digest is required by Docker image trust policy'
        return 1
    fi
    evidence="$(vx_compose_trust_prepare_evidence \
        "$digest" "$immutable_reference" "$image_id" "$labels")" || return 1
    signature="$(vx_compose_trust_run_adapter \
        signature "$digest" "$evidence" none)" || return 1
    vulnerability="$(vx_compose_trust_run_adapter vulnerability "$digest" \
        "$evidence" "$VX_COMPOSE_TRUST_VULNERABILITY_THRESHOLD")" || return 1
    decision=pass
    if [[ "$(jq -r '.STATE' <<<"$signature")" != pass
        || "$(jq -r '.STATE' <<<"$vulnerability")" != pass ]]; then
        decision=fail
        if vx_compose_trust_exception_applies \
            "$digest" "$profile" "$profile_version" "$policy_version"; then
            decision=exception
            exception=yes
        fi
    fi
    root="$(vx_compose_trust_root)/decisions"
    install -d -m 0700 "$root"
    record="$root/${digest#sha256:}.json"
    temp_file="$(mktemp "$root/.decision.XXXXXX")" || return 1
    jq -n -S \
        --arg mode "$mode" --arg decision "$decision" --arg profile "$profile" \
        --argjson profile_version "$profile_version" \
        --argjson policy_version "$policy_version" \
        --arg threshold "$VX_COMPOSE_TRUST_VULNERABILITY_THRESHOLD" \
        --arg created "$(vx_compose_now)" \
        --argjson signature "$signature" \
        --argjson vulnerability "$vulnerability" \
        --argjson exception "$([[ "$exception" == yes ]] && echo true || echo false)" '{
            SCHEMA:1,MODE:$mode,DECISION:$decision,PROFILE:$profile,
            PROFILE_VERSION:$profile_version,POLICY_VERSION:$policy_version,
            VULNERABILITY_THRESHOLD:$threshold,CREATED:$created,
            SIGNATURE:$signature,VULNERABILITY:$vulnerability,
            EXCEPTION:$exception
        }' >"$temp_file"
    chmod 0600 "$temp_file"
    mv -- "$temp_file" "$record"
    if [[ "$mode" == enforce && "$decision" == fail ]]; then
        vx_compose_error 'Docker image trust verification failed'
        return 1
    fi
    cat "$record"
}

vx_compose_verify_image_trust() {
    local profile="$1" immutable_reference="$2"
    local mode digest result status

    mode="$(vx_compose_trust_mode_for_profile "$profile")" || return 1
    if [[ "$mode" == disabled ]]; then
        vx_compose_verify_image_trust_locked "$@"
        return
    fi
    digest="${immutable_reference##*@}"
    vx_compose_trust_digest_is_valid "$digest" || {
        vx_compose_error 'registry digest is required by Docker image trust policy'
        return 1
    }
    vx_compose_trust_lock_acquire "$digest" || return 1
    if result="$(vx_compose_verify_image_trust_locked "$@")"; then
        status=0
    else
        status=$?
    fi
    vx_compose_trust_lock_release
    if (( status == 0 )); then
        printf '%s\n' "$result"
    fi
    return "$status"
}
