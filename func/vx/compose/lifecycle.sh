#!/usr/bin/env bash

vx_compose_convergence_timeout() {
    local owner="$1" project="$2" workload
    workload="${VX_COMPOSE_WORKLOAD_OVERRIDE:-$(vx_compose_project_root "$owner" "$project")/workload.json}"
    if [[ -f "$workload" && ! -L "$workload" ]]; then
        jq -er '.health_timeout_seconds | select(type=="number" and floor==. and .>=1 and .<=900)' \
            "$workload" && return
    fi
    printf '%s\n' "$VX_COMPOSE_WAIT_TIMEOUT"
}

vx_compose_runtime_definition_prepare() {
    local owner="$1"
    local project="$2"
    local canonical="$3"
    local images="$4"
    local revision="$5"
    local output_file="$6"

    jq -S \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg revision "$revision" \
        --slurpfile images "$images" '
        .services |= with_entries(
            .key as $service
            | .value.image = ($images[0][$service].IMAGE_ID // "")
            | .value.labels = (
                (.value.labels // {})
                + {
                    "vx.managed": "yes",
                    "vx.user": $owner,
                    "vx.project": $project,
                    "vx.revision": $revision,
                    "vx.image-id": ($images[0][$service].IMAGE_ID // "")
                }
            )
        )
    ' "$canonical" >"$output_file"
}

vx_compose_runtime_identity_preflight() {
    local owner="$1"
    local project="$2"
    local canonical="${3:-}"
    local images="${4:-}"
    local revision="${5:-}"
    local root docker_bin runtime container_id raw
    local complete
    local -a container_ids=()

    root="$(vx_compose_project_root "$owner" "$project")"
    runtime="$(vx_compose_runtime_name "$owner" "$project")"
    [[ -n "$canonical" ]] \
        || canonical="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"
    [[ -n "$images" ]] \
        || images="${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-$root/images.json}"
    [[ -n "$revision" ]] \
        || revision="${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
    [[ -n "$revision" ]] \
        || revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    [[ -f "$canonical" && ! -L "$canonical"
        && "$revision" =~ ^[1-9][0-9]*$ ]] || return 1
    docker_bin="$(vx_compose_docker_bin)" || return 1
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] || {
            vx_compose_error 'Compose runtime returned an invalid container id'
            return 1
        }
        container_ids+=("$container_id")
    done < <(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" ps -aq \
            --filter "label=com.docker.compose.project=$runtime"
    )
    if ((${#container_ids[@]} == 0)); then
        printf '%s\n' incomplete
        return
    fi
    raw="$(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" inspect "${container_ids[@]}"
    )" || return 1
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg runtime "$runtime" \
        --arg root "$root" \
        --slurpfile canonical "$canonical" '
        type == "array"
        and all(.[];
            .Config.Labels["com.docker.compose.project"] == $runtime
            and .Config.Labels["vx.managed"] == "yes"
            and .Config.Labels["vx.user"] == $owner
            and .Config.Labels["vx.project"] == $project
            and (
                .Config.Labels["com.docker.compose.service"] as $service
                | $service != null
                and $canonical[0].services[$service] != null
                and (. as $container
                    | ([($canonical[0].services[$service].secrets // [])[]
                        | . as $secret
                        | ($secret.source // $secret) as $name
                        | {SOURCE:$canonical[0].secrets[$name].file,
                           TARGET:($secret.target // ("/run/secrets/"+$name)),
                           READ_ONLY:true}] | sort_by(.TARGET,.SOURCE)) as $desired
                    | $desired
                      == ([($container.Mounts // [])[]
                        | . as $mount
                        | select(
                            ((.Source // "")
                                | startswith($root+"/runtime/workload-secrets/"))
                            or any($desired[];
                                .TARGET == ($mount.Destination // "")))
                        | {SOURCE:(.Source//""),TARGET:(.Destination//""),
                           READ_ONLY:(.RW == false)}]
                          | sort_by(.TARGET,.SOURCE)))
            )
        )
        and (
            [.[].Config.Labels["com.docker.compose.service"]]
            | length == (unique | length)
        )
    ' <<<"$raw" >/dev/null || {
        vx_compose_error 'Compose runtime container ownership mismatch'
        return 1
    }
    if [[ ! -f "$images" || -L "$images" ]]; then
        printf '%s\n' incomplete
        return
    fi
    complete="$(jq -r \
        --arg revision "$revision" \
        --slurpfile canonical "$canonical" \
        --slurpfile images "$images" '
        (
            [.[].Config.Labels["com.docker.compose.service"]] | sort
        ) == ($canonical[0].services | keys | sort)
        and all(.[];
            .Config.Labels["com.docker.compose.service"] as $service
            | .Config.Labels["vx.revision"] == $revision
            and .Config.Labels["vx.image-id"]
                == ($images[0][$service].IMAGE_ID // "")
            and .Image == ($images[0][$service].IMAGE_ID // "")
        )
    ' <<<"$raw")" || return 1
    [[ "$complete" == true ]] \
        && printf '%s\n' complete \
        || printf '%s\n' incomplete
}

vx_compose_invoke() {
    local owner="$1"
    local project="$2"
    shift 2
    local root docker_bin profile operation revision canonical images
    local runtime_definition result generated_definition=no argument env_file

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    operation=
    for argument in "$@"; do
        case "$argument" in
            up|start|restart|stop|down)
                operation="$argument"
                break
                ;;
        esac
    done
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE 2>/dev/null \
        || printf '%s\n' standard)"
    canonical="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"
    images="${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-$root/images.json}"
    env_file="${VX_COMPOSE_INVOKE_ENV_OVERRIDE:-$root/variables.env}"
    revision="${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
    if [[ -z "$revision" && "$operation" =~ ^(up|start|restart)$ ]]; then
        revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
            || return 1
    fi
    case "$operation" in
        up|start|restart)
            vx_compose_managed_binds_verify \
                "$canonical" "$owner" "$project" || return 1
            ;;
    esac
    install -d -m 0700 "$root/runtime/home" "$root/runtime/docker-config"
    runtime_definition="$canonical"
    if [[ "$operation" =~ ^(up|start|restart)$ ]]; then
        runtime_definition="$(mktemp "$root/runtime/.invoke.XXXXXX")" || return 1
        generated_definition=yes
        if ! vx_compose_runtime_definition_prepare \
            "$owner" "$project" "$canonical" "$images" "$revision" \
            "$runtime_definition"; then
            rm -f -- "$runtime_definition"
            return 1
        fi
    fi
    if env -i \
        PATH="$VX_COMPOSE_SAFE_PATH" \
        HOME="$root/runtime/home" \
        DOCKER_CONFIG="$root/runtime/docker-config" \
        "$docker_bin" compose \
        --project-name "$(vx_compose_runtime_name "$owner" "$project")" \
        --project-directory "$root" \
        --env-file "$env_file" \
        --file "$runtime_definition" \
        "$@"; then
        result=0
    else
        result=$?
    fi
    [[ "$generated_definition" != yes ]] || rm -f -- "$runtime_definition"
    return "$result"
}

vx_compose_active_legacy_image_migration_is_needed() {
    local owner="$1" project="$2" root revision revision_name revision_root
    local current_images revision_images authority

    [[ -z "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-}"
        && -z "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}"
        && -z "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
        && -z "${VX_COMPOSE_INVOKE_ENV_OVERRIDE:-}"
        && -z "${VX_COMPOSE_POLICY_OVERRIDE:-}"
        && -z "${VX_COMPOSE_ROUTES_FILE_OVERRIDE:-}" ]] || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    authority="$(vx_compose_image_evidence_migration_root "$root")"
    [[ ! -e "$authority" ]] || return 1
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    [[ "$revision" =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v revision_name '%06d' "$revision"
    revision_root="$root/revisions/$revision_name"
    current_images="$root/images.json"
    revision_images="$revision_root/images.json"
    vx_compose_image_evidence_directory_is_secure "$root" 750 \
        && vx_compose_image_evidence_directory_is_secure \
            "$root/revisions" 750 \
        && vx_compose_image_evidence_directory_is_secure \
            "$revision_root" 750 \
        && vx_compose_image_evidence_file_is_secure "$current_images" 640 \
        && vx_compose_image_evidence_file_is_secure "$revision_images" 640 \
        && vx_compose_image_evidence_file_is_secure \
            "$revision_root/manifest.sha256" 640 \
        && vx_compose_revision_manifest_verify "$revision_root" \
        && ! vx_compose_revision_manifest_binds_images "$revision_root" \
        && [[ "$(vx_compose_image_evidence_kind "$current_images")" \
            == legacy-production-five-field ]] \
        && [[ "$(vx_compose_image_evidence_kind "$revision_images")" \
            == legacy-production-five-field ]] \
        && cmp -s "$current_images" "$revision_images"
}

vx_compose_run_lifecycle() {
    local owner="$1"
    local project="$2"
    local action="$3"
    local success_state="$4"
    shift 4
    local root result profile ports_locked=no quota_locked=no
    local started_ms finished_ms duration_ms timeout index
    local services runtime_identity error_file diagnostic invoke_result
    local canonical active_canonical active_images active_revision
    local prior_state evidence_ok=yes candidate_authority=no
    local runtime_recovery_ok=yes legacy_images_resolved=no
    local -a lifecycle_args=("$@")

    unset VX_COMPOSE_RUNTIME_SECRETS_REFRESHED

    vx_compose_require_project "$owner" "$project" || return 1
    case "$action" in
        deploy|start|restart|recreate)
            root="$(vx_compose_project_root "$owner" "$project")"
            profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" \
                || return 1
            vx_compose_profile_require_authorized \
                "$owner" "$project" "$profile" || return 1
            vx_compose_quota_check_current "$owner" || return 1
            ;;
    esac
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    if vx_compose_active_legacy_image_migration_is_needed \
        "$owner" "$project"; then
        if ! vx_compose_project_resolve_images "$owner" "$project"; then
            vx_compose_lock_release
            return 1
        fi
        legacy_images_resolved=yes
    fi
    if ! vx_compose_active_revision_verify "$owner" "$project"; then
        vx_compose_lock_release
        return 1
    fi
    if [[ "$action" =~ ^(deploy|start|restart|recreate)$ ]] \
        && ! vx_compose_current_workload_image_approval_require \
            "$owner" "$project"; then
        vx_compose_lock_release
        vx_compose_error 'current workload image approval is unavailable'
        return 1
    fi
    if [[ "$action" =~ ^(deploy|start|restart|recreate)$ ]] \
        && ! vx_compose_runtime_secrets_materialize "$owner" "$project"; then
        vx_compose_lock_release
        vx_compose_error 'runtime workload secrets are unavailable'
        return 1
    fi
    if [[ "$action" =~ ^(deploy|start|restart|recreate)$ ]]; then
        timeout="$(vx_compose_convergence_timeout "$owner" "$project")" || {
            vx_compose_lock_release
            return 1
        }
        for index in "${!lifecycle_args[@]}"; do
            [[ "${lifecycle_args[$index]}" \
                != __VX_COMPOSE_WAIT_TIMEOUT__ ]] \
                || lifecycle_args[$index]="$timeout"
        done
    fi
    active_canonical="$root/runtime/canonical.json"
    active_images="$root/images.json"
    active_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || {
        vx_compose_lock_release
        return 1
    }
    prior_state="$(vx_compose_meta_get "$root/project.conf" STATE)" || {
        vx_compose_lock_release
        return 1
    }
    canonical="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$active_canonical}"
    if [[ "$canonical" != "$active_canonical"
        || ( -n "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}"
            && "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE}" != "$active_images" )
        || ( -n "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
            && "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE}" != "$active_revision" ) ]]; then
        candidate_authority=yes
    fi
    services="$(jq -c '.services | keys' \
        "$canonical")" || {
        vx_compose_lock_release
        return 1
    }
    case "$action" in
        deploy|start|restart|recreate)
            profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" \
                || {
                    vx_compose_lock_release
                    return 1
                }
            if ! vx_compose_profile_require_authorized \
                "$owner" "$project" "$profile"; then
                vx_compose_lock_release
                return 1
            fi
            vx_compose_ports_lock_acquire || {
                vx_compose_lock_release
                return 1
            }
            ports_locked=yes
            if ! vx_compose_ports_check_conflicts \
                "$owner" "$project" \
                "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"; then
                [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
                vx_compose_lock_release
                return 1
            fi
            vx_compose_owner_quota_lock_acquire "$owner" || {
                vx_compose_ports_lock_release
                vx_compose_lock_release
                return 1
            }
            quota_locked=yes
            if ! vx_compose_quota_check_current "$owner"; then
                vx_compose_owner_quota_lock_release
                vx_compose_ports_lock_release
                vx_compose_lock_release
                return 1
            fi
            if [[ "$legacy_images_resolved" != yes
                && -z "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}" ]] \
                && ! vx_compose_project_resolve_images "$owner" "$project"; then
                vx_compose_owner_quota_lock_release
                [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
                vx_compose_lock_release
                return 1
            fi
            ;;
    esac
    if ! vx_compose_network_verify_runtime \
        "$owner" "$project" "$active_canonical" no \
        || ! vx_compose_volume_verify_runtime \
            "$owner" "$project" "$active_canonical" no; then
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "$canonical" != "$active_canonical" ]] \
        && {
            ! vx_compose_network_verify_runtime \
                "$owner" "$project" "$canonical" no \
            || ! vx_compose_volume_verify_runtime \
                "$owner" "$project" "$canonical" no
        }; then
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "${VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE:-no}" == yes ]]; then
        runtime_identity="$(
            vx_compose_runtime_identity_preflight \
                "$owner" "$project" "$canonical" \
                "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-$active_images}" \
                "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-$active_revision}"
        )" || runtime_identity=
    else
        runtime_identity="$(
            vx_compose_runtime_identity_preflight \
                "$owner" "$project" "$active_canonical" \
                "$active_images" "$active_revision"
        )" || runtime_identity=
    fi
    if [[ -z "$runtime_identity" ]]; then
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "$action" == start && "$runtime_identity" != complete ]]; then
        lifecycle_args=(
            up -d --remove-orphans --wait
            --wait-timeout "$(vx_compose_convergence_timeout "$owner" "$project")"
        )
    fi
    if [[ "${VX_COMPOSE_RUNTIME_SECRETS_REFRESHED:-no}" == yes ]]; then
        case "$action" in
            deploy)
                lifecycle_args=(
                    up -d --remove-orphans --force-recreate --wait
                    --wait-timeout "$timeout"
                )
                ;;
            start|restart)
                lifecycle_args=(
                    up -d --remove-orphans --force-recreate --wait
                    --wait-timeout "$timeout"
                )
                ;;
            recreate)
                # The caller already supplies `up --force-recreate` and any
                # validated service scope; preserve that exact scope.
                ;;
        esac
    fi
    started_ms="$(date +%s%3N)"
    if ! vx_compose_audit "$root" "$action" started '' 0 "$services"; then
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    error_file="$(mktemp "$root/runtime/.lifecycle-error.XXXXXX")" || {
        [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
        [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    if vx_compose_invoke \
        "$owner" "$project" "${lifecycle_args[@]}" 2>"$error_file"; then
        invoke_result=0
    else
        invoke_result=$?
    fi
    diagnostic="$(vx_compose_redact_text "$root" "$(cat "$error_file")")"
    rm -f -- "$error_file"
    [[ -z "$diagnostic" ]] || printf '%s\n' "$diagnostic" >&2
    if [[ "$invoke_result" -eq 0 ]]; then
        result=0
        case "$action" in
            deploy|start|restart|recreate)
                if [[ "$(vx_compose_runtime_identity_preflight \
                    "$owner" "$project" "$canonical" \
                    "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-$active_images}" \
                    "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-$active_revision}")" \
                    != complete ]] \
                    || ! vx_compose_network_verify_runtime \
                    "$owner" "$project" \
                    "$canonical" yes \
                    || ! vx_compose_volume_verify_runtime \
                        "$owner" "$project" "$canonical" yes \
                    || ! vx_compose_routes_apply "$owner" "$project"; then
                    result=1
                    vx_compose_invoke \
                        "$owner" "$project" stop --timeout 30 \
                        >/dev/null 2>&1 || true
                fi
                ;;
        esac
        if [[ "$result" -eq 0 ]]; then
            if [[ "${VX_COMPOSE_LIFECYCLE_DEFER_COMMIT:-no}" != yes ]]; then
                vx_compose_update_state "$owner" "$project" "$success_state" \
                    || evidence_ok=no
            fi
            finished_ms="$(date +%s%3N)"
            duration_ms=$((finished_ms - started_ms))
            if ! vx_compose_audit \
                "$root" "$action" succeeded '' "$duration_ms" "$services"; then
                evidence_ok=no
            fi
            if [[ "$evidence_ok" != yes ]]; then
                result=1
                if [[ "$candidate_authority" == yes ]]; then
                    vx_compose_invoke \
                        "$owner" "$project" stop --timeout 30 \
                        >/dev/null 2>&1 || runtime_recovery_ok=no
                    runtime_recovery_ok=no
                elif [[ "$prior_state" == running ]]; then
                    if [[ "$action" == stop || "$action" == remove ]]; then
                        if ! vx_compose_invoke \
                            "$owner" "$project" \
                            up -d --remove-orphans --wait \
                            --wait-timeout "$(vx_compose_convergence_timeout "$owner" "$project")" \
                            >/dev/null 2>&1 \
                            || [[ "$(vx_compose_runtime_identity_preflight \
                                "$owner" "$project" "$active_canonical" \
                                "$active_images" "$active_revision")" \
                                != complete ]]; then
                            runtime_recovery_ok=no
                        fi
                    fi
                elif [[ "$action" =~ ^(deploy|start|restart|recreate)$ ]]; then
                    vx_compose_invoke \
                        "$owner" "$project" stop --timeout 30 \
                        >/dev/null 2>&1 || runtime_recovery_ok=no
                fi
                if [[ "$runtime_recovery_ok" != yes ]] \
                    || ! vx_compose_update_state \
                        "$owner" "$project" "$prior_state"; then
                    vx_compose_update_state \
                        "$owner" "$project" restore-required || :
                fi
            fi
            case "${VX_COMPOSE_LIFECYCLE_DEFER_COMMIT:-no}:$action" in
                yes:*) ;;
                no:remove) ;;
                *)
                    vx_compose_monitor_project "$owner" "$project" \
                        >/dev/null 2>&1 || true
                    ;;
            esac
        else
            finished_ms="$(date +%s%3N)"
            duration_ms=$((finished_ms - started_ms))
            vx_compose_update_state \
                "$owner" "$project" restore-required || :
            vx_compose_audit \
                "$root" "$action" failed \
                "${diagnostic:-post-start verification failed}" \
                "$duration_ms" "$services" || :
        fi
    else
        finished_ms="$(date +%s%3N)"
        duration_ms=$((finished_ms - started_ms))
        vx_compose_audit \
            "$root" "$action" failed \
            "${diagnostic:-Compose invocation failed}" \
            "$duration_ms" "$services" || :
        result=1
    fi
    if [[ "$quota_locked" == yes ]]; then
        vx_compose_owner_quota_lock_release
    fi
    if [[ "$ports_locked" == yes ]]; then
        vx_compose_ports_lock_release
    fi
    vx_compose_lock_release
    return "$result"
}

vx_compose_deploy() {
    vx_compose_run_lifecycle \
        "$1" "$2" deploy running \
        up -d --remove-orphans --wait --wait-timeout __VX_COMPOSE_WAIT_TIMEOUT__
}

vx_compose_start() {
    vx_compose_run_lifecycle "$1" "$2" start running start
}

vx_compose_stop() {
    vx_compose_run_lifecycle "$1" "$2" stop stopped stop --timeout 30
}

vx_compose_restart() {
    vx_compose_run_lifecycle "$1" "$2" restart running restart --timeout 30
}

vx_compose_recreate() {
    local owner="$1"
    local project="$2"
    local service="${3:-}"
    local root
    local -a args

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    args=(up -d --force-recreate --wait --wait-timeout __VX_COMPOSE_WAIT_TIMEOUT__)
    if [[ -n "$service" ]]; then
        jq -e --arg service "$service" '.services[$service] != null' \
            "$root/runtime/canonical.json" >/dev/null \
            || {
                vx_compose_error "Compose service does not exist: $service"
                return 1
            }
        args+=("$service")
    fi
    vx_compose_run_lifecycle "$owner" "$project" recreate running "${args[@]}"
}

vx_compose_remove() {
    local owner="$1"
    local project="$2"
    local root projects_root tombstone

    vx_compose_lock_acquire "$owner" "$project" || return 1
    if ! vx_compose_run_lifecycle \
        "$owner" "$project" remove removed \
        down --remove-orphans \
        || ! vx_compose_routes_clear "$owner" "$project" \
        || ! vx_compose_profile_assignment_delete "$owner" "$project"; then
        vx_compose_lock_release
        return 1
    fi
    projects_root="$(vx_compose_projects_root "$owner")"
    root="$(vx_compose_project_root "$owner" "$project")"
    tombstone="$projects_root/.removing-$project-$$"
    if [[ "$root" != "$projects_root/$project"
        || ! -d "$root" || -L "$root"
        || -e "$tombstone" || -L "$tombstone" ]]; then
        vx_compose_lock_release
        return 1
    fi
    if ! mv -- "$root" "$tombstone"; then
        vx_compose_lock_release
        return 1
    fi
    if ! vx_compose_refresh_counters "$owner"; then
        mv -- "$tombstone" "$root" || :
        vx_compose_lock_release
        return 1
    fi
    if ! rm -rf -- "$tombstone"; then
        if [[ ! -e "$root" && ! -L "$root" ]] \
            && mv -- "$tombstone" "$root"; then
            vx_compose_update_state \
                "$owner" "$project" cleanup-required || :
            vx_compose_audit "$root" remove-cleanup failed \
                'control-root tombstone deletion failed; normal root restored' \
                || :
        else
            if [[ -d "$tombstone" && ! -L "$tombstone" ]]; then
                printf '%s\n' \
                    'cleanup-required: tombstone deletion and normal-root restoration failed' \
                    >"$tombstone/RECOVERY_REQUIRED" || :
                chmod 0640 "$tombstone/RECOVERY_REQUIRED" 2>/dev/null || :
                vx_compose_audit "$tombstone" remove-cleanup failed \
                    'control-root tombstone retained; administrator recovery required' \
                    || :
            fi
            vx_compose_owner_audit "$owner" remove-cleanup failed \
                "retained Compose recovery tombstone for project $project" \
                || :
        fi
        vx_compose_lock_release
        return 1
    fi
    vx_compose_lock_release
}

vx_compose_inspect_json() {
    local owner="$1"
    local project="$2"
    local root metadata services service_summary images image_identities
    local routes health health_observation resources
    local simple last_operation drift workload last_probe current_revision
    local revisions revision_root revision

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    current_revision="$(vx_compose_meta_get "$metadata" REVISION)" || return 1
    services="$(jq -c '.services | keys' "$root/runtime/canonical.json")"
    service_summary="$(jq -c '
        .services
        | with_entries(.value = {
            IMAGE: (.value.image // ""),
            PORTS: [
                .value.ports[]?
                | if type == "string" then .
                  else
                    ((.host_ip // "0.0.0.0") + ":"
                    + ((.published // "") | tostring) + ":"
                    + ((.target // "") | tostring) + "/"
                    + (.protocol // "tcp"))
                  end
            ],
            DEPENDS_ON: (
                if (.value.depends_on // null) == null then []
                elif (.value.depends_on | type) == "array"
                    then .value.depends_on
                else (.value.depends_on | keys)
                end
            ),
            HAS_HEALTHCHECK: ((.value.healthcheck // null) != null)
        })
    ' "$root/runtime/canonical.json")"
    images="$(jq -c '[.services[].image] | unique' \
        "$root/runtime/canonical.json")"
    image_identities='{}'
    if [[ -f "$root/images.json" && ! -L "$root/images.json" ]]; then
        image_identities="$(jq -c '
            with_entries(.value = {
                REFERENCE: (.value.REFERENCE // ""),
                IMAGE_ID: (.value.IMAGE_ID // ""),
                REPO_DIGESTS: (.value.REPO_DIGESTS // []),
                OS: (.value.OS // ""),
                ARCHITECTURE: (.value.ARCHITECTURE // "")
            })
        ' "$root/images.json")" || image_identities='{}'
    fi
    revisions='[]'
    for revision_root in "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$revision_root" ]] || continue
        revision="$(basename "$revision_root")"
        revisions="$(jq -c --argjson revision "$((10#$revision))" \
            '. + [$revision]' <<<"$revisions")"
    done
    routes='{}'
    [[ ! -f "$root/routes.conf" ]] || routes="$(jq -c . "$root/routes.conf")"
    health=unknown
    health_observation='{}'
    if [[ -f "$root/runtime/last-health.json" ]]; then
        health_observation="$(
            vx_compose_health_observation_json "$owner" "$project"
        )" || health_observation='{}'
        health="$(jq -r '.STATUS // "unknown"' <<<"$health_observation")"
        health_observation="$(jq -c '{
            STATUS: (.STATUS // "unknown"),
            OBSERVED_AT: (.OBSERVED_AT // .UPDATED // ""),
            SOURCE: (.SOURCE // "legacy-snapshot"),
            AGE_SECONDS: (.AGE_SECONDS // 0),
            FRESHNESS: (.FRESHNESS // "stale")
        }' <<<"$health_observation")"
    fi
    simple=null
    if [[ -f "$root/simple.json" && ! -L "$root/simple.json" ]]; then
        simple="$(jq -ce \
            --arg owner "$owner" \
            --arg project "$project" '
                .IMAGE as $image
                | select(
                    .GENERATED == true
                    and .OWNER == $owner
                    and .NAME == $project
                    and ($canonical.services | length) == 1
                    and any($canonical.services[]; .image == $image)
                )
            ' --argjson canonical \
                "$(cat "$root/runtime/canonical.json")" \
            "$root/simple.json")" || simple=null
    fi
    last_operation='{}'
    if [[ -f "$root/runtime/last-operation.json"
        && ! -L "$root/runtime/last-operation.json" ]]; then
        last_operation="$(jq -c . "$root/runtime/last-operation.json" \
            2>/dev/null)" || last_operation='{}'
    fi
    workload='null'
    if [[ -f "$root/workload.json" && ! -L "$root/workload.json"
        && -f "$root/workload-evidence.json"
        && ! -L "$root/workload-evidence.json" ]]; then
        workload="$(jq -c --slurpfile evidence "$root/workload-evidence.json" \
            --slurpfile images "$root/images.json" '{
            SCHEMA:.schema,ID:.workload.id,RELEASE:.workload.release,
            WORKLOAD_SHA256:$evidence[0].WORKLOAD_SHA256,
            ARCHIVE_SHA256:$evidence[0].ARCHIVE_SHA256,
            CANONICAL_SHA256:$evidence[0].CANONICAL_SHA256,
            IMAGE_TRUST:{STATE:"accepted-revision",IMAGE_ID:.image.id,
              PROFILE:.profile.name,PROFILE_VERSION:.profile.version,
              EVIDENCE:([$images[0][]?.TRUST|{MODE,DECISION,EXCEPTION}]|unique)},
            PROBES:(.probes|keys),LAST_PROBE_RESULT:null
        }' "$root/workload.json" 2>/dev/null)" || workload=null
        if [[ "$workload" != null && -f "$root/runtime/last-probe.json"
            && ! -L "$root/runtime/last-probe.json" ]] \
            && vx_compose_control_file_is_secure \
                "$root/runtime/last-probe.json" 600; then
            last_probe="$(jq -ce \
                --argjson revision "$current_revision" \
                --arg owner "$owner" --arg project "$project" \
                --arg workload_sha "$(jq -r '.WORKLOAD_SHA256' <<<"$workload")" '
                select(type == "object")
                | select((keys | sort) == [
                    "DURATION_MS", "EXIT_CODE", "OBSERVATIONS", "OBSERVED_AT",
                    "OWNER", "PROBE", "PROJECT", "REVISION", "SCHEMA",
                    "SERVICE", "STATE", "SUMMARY", "WORKLOAD_SHA256"
                ])
                | select(.SCHEMA == 1 and .OWNER == $owner
                    and .PROJECT == $project and .REVISION == $revision
                    and .WORKLOAD_SHA256 == $workload_sha)
            ' "$root/runtime/last-probe.json" 2>/dev/null)" || last_probe=
            if [[ -n "$last_probe" ]]; then
                workload="$(jq -c --argjson result "$last_probe" \
                    '.LAST_PROBE_RESULT=$result' <<<"$workload")" \
                    || workload=null
            fi
        fi
    fi
    drift="$(vx_compose_drift_observe_json \
        "$owner" "$project" 2>/dev/null)" \
        || drift='{"STATUS":"unavailable","MATCH":false}'
    resources="$(jq -n \
        --arg services "$(vx_compose_meta_get "$root/policy.conf" SERVICES)" \
        --arg cpus "$(vx_compose_meta_get "$root/policy.conf" CPUS_MILLI)" \
        --arg memory "$(vx_compose_meta_get "$root/policy.conf" MEMORY_MB)" \
        --arg pids "$(vx_compose_meta_get "$root/policy.conf" PIDS)" \
        --arg storage "$(vx_compose_meta_get "$root/policy.conf" STORAGE_MB)" '{
            SERVICES: ($services | tonumber),
            CPUS_MILLI: ($cpus | tonumber),
            MEMORY_MB: ($memory | tonumber),
            PIDS: ($pids | tonumber),
            STORAGE_MB: ($storage | tonumber)
        }')"
    jq -n \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg compose_project "$(vx_compose_meta_get "$metadata" COMPOSE_PROJECT)" \
        --arg profile "$(vx_compose_meta_get "$metadata" PROFILE)" \
        --arg state "$(vx_compose_meta_get "$metadata" STATE)" \
        --arg revision "$(vx_compose_meta_get "$metadata" REVISION)" \
        --arg sha "$(vx_compose_meta_get "$metadata" CANONICAL_SHA256)" \
        --arg created "$(vx_compose_meta_get "$metadata" CREATED)" \
        --arg updated "$(vx_compose_meta_get "$metadata" UPDATED)" \
        --arg health "$health" \
        --argjson health_observation "$health_observation" \
        --argjson services "$services" \
        --argjson service_summary "$service_summary" \
        --argjson images "$images" \
        --argjson image_identities "$image_identities" \
        --argjson revisions "$revisions" \
        --argjson routes "$routes" \
        --argjson resources "$resources" \
        --argjson simple "$simple" \
        --argjson last_operation "$last_operation" \
        --argjson drift "$drift" \
        --argjson workload "$workload" \
        '{
            OWNER: $owner,
            PROJECT: $project,
            COMPOSE_PROJECT: $compose_project,
            PROFILE: $profile,
            STATE: $state,
            REVISION: ($revision | tonumber),
            CANONICAL_SHA256: $sha,
            CREATED: $created,
            UPDATED: $updated,
            HEALTH: $health,
            HEALTH_OBSERVATION: $health_observation,
            SERVICES: $services,
            SERVICE_COUNT: ($services | length),
            SERVICE_SUMMARY: $service_summary,
            IMAGES: $images,
            IMAGE_IDENTITIES: $image_identities,
            REVISIONS: $revisions,
            ROUTES: $routes,
            RESOURCES: $resources,
            SIMPLE: $simple,
            LAST_OPERATION: $last_operation,
            DRIFT: $drift,
            WORKLOAD: $workload
        }'
}

vx_compose_list_json() {
    local owner="$1"
    local projects_root project_root project runtime_name

    vx_compose_require_owner "$owner" || return 1
    projects_root="$(vx_compose_projects_root "$owner")"
    if [[ ! -d "$projects_root" ]]; then
        printf '%s\n' '{}'
        return
    fi
    {
        for project_root in "$projects_root"/*; do
            [[ -d "$project_root" && -f "$project_root/project.conf" ]] || continue
            project="$(basename "$project_root")"
            runtime_name="$(vx_compose_meta_get "$project_root/project.conf" COMPOSE_PROJECT)"
            vx_compose_inspect_json "$owner" "$project" \
                | jq --arg key "$runtime_name" '{($key): .}'
        done
    } | jq -s 'reduce .[] as $item ({}; . * $item)'
}
