#!/usr/bin/env bash

vx_compose_rollback_snapshot_active() {
    local root="$1"
    local snapshot_root="$2"
    local name

    install -d -m 0700 "$snapshot_root" || return 1
    install -m 0640 "$root/compose.yaml" "$snapshot_root/compose.yaml" \
        && install -m 0640 "$root/policy.conf" "$snapshot_root/policy.conf" \
        && install -m 0640 "$root/project.conf" "$snapshot_root/project.conf" \
        && install -m 0640 "$root/runtime/canonical.json" \
            "$snapshot_root/canonical.json" \
        || return 1
    for name in images.json routes.conf alerts.conf; do
        [[ ! -f "$root/$name" ]] \
            || install -m 0640 "$root/$name" "$snapshot_root/$name" \
            || return 1
    done
    [[ ! -f "$root/simple.json" ]] \
        || install -m 0600 "$root/simple.json" "$snapshot_root/simple.json" \
        || return 1
    for name in workload.json workload-evidence.json workload-manifest.sha256; do
        [[ ! -f "$root/$name" ]] \
            || install -m 0600 "$root/$name" "$snapshot_root/$name" \
            || return 1
    done
    [[ ! -f "$root/runtime/routes.pending.json" ]] \
        || install -m 0640 "$root/runtime/routes.pending.json" \
            "$snapshot_root/routes.pending.json"
}

vx_compose_rollback_restore_active() {
    local root="$1"
    local snapshot_root="$2"
    local name

    install -m 0640 "$snapshot_root/compose.yaml" "$root/compose.yaml" \
        && install -m 0640 "$snapshot_root/policy.conf" "$root/policy.conf" \
        && install -m 0640 "$snapshot_root/project.conf" "$root/project.conf" \
        && install -m 0640 "$snapshot_root/canonical.json" \
            "$root/runtime/canonical.json" \
        || return 1
    for name in images.json routes.conf alerts.conf; do
        if [[ -f "$snapshot_root/$name" ]]; then
            install -m 0640 "$snapshot_root/$name" "$root/$name" || return 1
        else
            rm -f -- "$root/$name" || return 1
        fi
    done
    if [[ -f "$snapshot_root/simple.json" ]]; then
        install -m 0600 "$snapshot_root/simple.json" "$root/simple.json" \
            || return 1
    else
        rm -f -- "$root/simple.json" || return 1
    fi
    for name in workload.json workload-evidence.json workload-manifest.sha256; do
        if [[ -f "$snapshot_root/$name" ]]; then
            install -m 0600 "$snapshot_root/$name" "$root/$name" || return 1
        else
            rm -f -- "$root/$name" || return 1
        fi
    done
    rm -f -- "$root/runtime/routes.pending.json"
}

vx_compose_rollback_activate() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local revision_root="$4"
    local revision="$5"
    local root metadata profile created sha name switch_failed=no

    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    profile="$(vx_compose_meta_get "$metadata" PROFILE)" || return 1
    created="$(vx_compose_meta_get "$metadata" CREATED)" || return 1
    sha="$(sha256sum "$candidate/canonical.json" | awk '{print $1}')" \
        || return 1
    install -m 0640 "$candidate/compose.yaml" "$root/.compose.yaml.rollback" \
        && install -m 0640 \
            "$candidate/policy.conf" "$root/.policy.conf.rollback" \
        && install -m 0640 \
            "$candidate/images.json" "$root/.images.json.rollback" \
        && install -m 0640 \
            "$candidate/alerts.conf" "$root/.alerts.conf.rollback" \
        && install -m 0640 "$candidate/canonical.json" \
            "$root/runtime/.canonical.json.rollback" \
        || switch_failed=yes
    if [[ "$switch_failed" != yes && -f "$revision_root/routes.conf" ]]; then
        install -m 0640 \
            "$candidate/routes.conf" "$root/.routes.conf.rollback" \
            || switch_failed=yes
    fi
    if [[ "$switch_failed" != yes && -f "$candidate/simple.json" ]]; then
        install -m 0600 \
            "$candidate/simple.json" "$root/.simple.json.rollback" \
            || switch_failed=yes
    fi
    if [[ "$switch_failed" != yes ]]; then
        for name in workload.json workload-evidence.json workload-manifest.sha256; do
            if [[ -f "$candidate/$name" && ! -L "$candidate/$name" ]]; then
                install -m 0600 "$candidate/$name" "$root/.$name.rollback" \
                    || switch_failed=yes
            fi
        done
    fi
    [[ "$switch_failed" == yes ]] \
        || mv -f -- "$root/.compose.yaml.rollback" "$root/compose.yaml" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -f -- "$root/.policy.conf.rollback" "$root/policy.conf" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -f -- "$root/.images.json.rollback" "$root/images.json" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -f -- "$root/.alerts.conf.rollback" "$root/alerts.conf" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -f -- "$root/runtime/.canonical.json.rollback" \
            "$root/runtime/canonical.json" || switch_failed=yes
    if [[ "$switch_failed" != yes ]]; then
        if [[ -f "$revision_root/routes.conf" ]]; then
            mv -f -- "$root/.routes.conf.rollback" "$root/routes.conf" \
                || switch_failed=yes
        else
            rm -f -- "$root/routes.conf" || switch_failed=yes
        fi
    fi
    if [[ "$switch_failed" != yes ]]; then
        for name in workload.json workload-evidence.json workload-manifest.sha256; do
            if [[ -f "$candidate/$name" ]]; then
                mv -f -- "$root/.$name.rollback" "$root/$name" \
                    || switch_failed=yes
            else
                rm -f -- "$root/$name" || switch_failed=yes
            fi
        done
    fi
    if [[ "$switch_failed" != yes ]]; then
        if [[ -f "$candidate/simple.json" ]]; then
            mv -f -- "$root/.simple.json.rollback" "$root/simple.json" \
                || switch_failed=yes
        else
            rm -f -- "$root/simple.json" || switch_failed=yes
        fi
    fi
    [[ "${VX_COMPOSE_TEST_ROLLBACK_COMMIT_FAIL:-no}" != yes ]] \
        || switch_failed=yes
    if [[ "$switch_failed" != yes ]]; then
        vx_compose_write_metadata \
            "$root" "$owner" "$project" "$profile" running "$revision" \
            "$created" "$(vx_compose_now)" "$sha" || switch_failed=yes
    fi
    if [[ "$switch_failed" != yes ]]; then
        for name in \
            compose.yaml policy.conf images.json alerts.conf \
            runtime/canonical.json project.conf; do
            vx_compose_fsync_path "$root/$name" || switch_failed=yes
        done
        [[ ! -f "$root/routes.conf" ]] \
            || vx_compose_fsync_path "$root/routes.conf" \
            || switch_failed=yes
        [[ ! -f "$root/simple.json" ]] \
            || vx_compose_fsync_path "$root/simple.json" \
            || switch_failed=yes
        vx_compose_fsync_path "$root/runtime" || switch_failed=yes
        vx_compose_fsync_path "$root" || switch_failed=yes
    fi
    rm -f -- \
        "$root/.compose.yaml.rollback" "$root/.policy.conf.rollback" \
        "$root/.images.json.rollback" "$root/.alerts.conf.rollback" \
        "$root/.routes.conf.rollback" "$root/.simple.json.rollback" \
        "$root/.workload.json.rollback" "$root/.workload-evidence.json.rollback" \
        "$root/.workload-manifest.sha256.rollback" \
        "$root/runtime/.canonical.json.rollback"
    [[ "$switch_failed" != yes ]] || return 1
    vx_compose_active_revision_verify "$owner" "$project"
}

vx_compose_rollback() {
    local owner="$1"
    local project="$2"
    local revision="${3:-}"
    local root metadata revision_root profile prior_state optional_member
    local image_evidence_kind
    local rollback_root snapshot_root route_candidate
    local recovery_ok=yes runtime_attempted=no
    local ports_locked=no quota_locked=no routes_locked=no result=1

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    if [[ -z "$revision" ]]; then
        revision=$(( $(vx_compose_meta_get "$metadata" REVISION) - 1 ))
    fi
    [[ "$revision" =~ ^[1-9][0-9]*$ ]] \
        || {
            vx_compose_error 'invalid Compose rollback revision'
            vx_compose_lock_release
            return 1
        }
    printf -v revision_root '%s/revisions/%06d' "$root" "$revision"
    [[ -f "$revision_root/compose.yaml"
        && ! -L "$revision_root/compose.yaml"
        && -f "$revision_root/canonical.json"
        && ! -L "$revision_root/canonical.json"
        && -f "$revision_root/policy.conf"
        && ! -L "$revision_root/policy.conf" ]] \
        || {
            vx_compose_error "Compose rollback revision does not exist: $revision"
            vx_compose_lock_release
            return 1
        }
    if ! vx_compose_revision_manifest_verify "$revision_root"; then
        vx_compose_error 'Compose rollback revision manifest is invalid'
        vx_compose_lock_release
        return 1
    fi
    for optional_member in \
        images.json routes.conf alerts.conf simple.json; do
        if [[ -L "$revision_root/$optional_member" ]]; then
            vx_compose_error 'Compose rollback revision contains a linked control file'
            vx_compose_lock_release
            return 1
        fi
    done
    if [[ -f "$revision_root/images.json" ]]; then
        if ! vx_compose_image_evidence_directory_is_secure \
                "$revision_root" 750 \
            || ! vx_compose_image_evidence_file_is_secure \
                "$revision_root/images.json" 640 \
            || ! image_evidence_kind="$(vx_compose_image_evidence_kind \
                "$revision_root/images.json")"; then
            vx_compose_error 'Compose rollback image evidence is invalid'
            vx_compose_lock_release
            return 1
        fi
        if [[ "$image_evidence_kind" == legacy-production-five-field ]] \
            && ! vx_compose_revision_manifest_binds_images "$revision_root" \
            && ! vx_compose_image_evidence_migration_authority_verify \
                "$owner" "$project" "$root" "$revision" \
                "$revision_root/images.json"; then
            vx_compose_error 'Compose rollback image migration authority is unavailable'
            vx_compose_lock_release
            return 1
        fi
    fi
    profile="$(vx_compose_meta_get "$metadata" PROFILE)" || {
        vx_compose_lock_release
        return 1
    }
    prior_state="$(vx_compose_meta_get "$metadata" STATE)" || {
        vx_compose_lock_release
        return 1
    }
    vx_compose_ports_lock_acquire || {
        vx_compose_lock_release
        return 1
    }
    ports_locked=yes
    vx_compose_owner_quota_lock_acquire "$owner" || {
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    quota_locked=yes
    vx_compose_routes_lock_acquire "$owner" || {
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    routes_locked=yes
    rollback_root="$(mktemp -d "$root/runtime/.rollback.XXXXXX")" || :
    snapshot_root="$(mktemp -d "$root/runtime/.rollback-snapshot.XXXXXX")" || :
    if [[ -z "${rollback_root:-}" || -z "${snapshot_root:-}" ]]; then
        :
    elif ! install -m 0640 \
        "$revision_root/compose.yaml" "$rollback_root/compose.yaml" \
        || ! install -m 0640 \
            "$revision_root/canonical.json" "$rollback_root/canonical.json" \
        || ! install -m 0640 \
            "$revision_root/policy.conf" "$rollback_root/policy.conf"; then
        :
    elif [[ -f "$revision_root/images.json"
        && ! -L "$revision_root/images.json" ]] \
        && ! install -m 0640 \
            "$revision_root/images.json" "$rollback_root/images.json"; then
        :
    elif [[ ! -f "$revision_root/images.json" ]] \
        && ! vx_compose_resolve_images_to_file \
            "$owner" "$revision_root/canonical.json" "$profile" \
            "$rollback_root/images.json"; then
        :
    elif ! {
        if [[ -f "$revision_root/routes.conf"
            && ! -L "$revision_root/routes.conf" ]]; then
            install -m 0640 \
                "$revision_root/routes.conf" "$rollback_root/routes.conf"
        else
            printf '{}\n' >"$rollback_root/routes.conf" \
                && chmod 0640 "$rollback_root/routes.conf"
        fi
    }; then
        :
    elif ! {
        for optional_member in workload.json workload-evidence.json workload-manifest.sha256; do
            [[ ! -f "$revision_root/$optional_member" ]] \
                || install -m 0600 "$revision_root/$optional_member" \
                    "$rollback_root/$optional_member" || return 1
        done
    }; then
        :
    elif ! {
        if [[ -f "$revision_root/alerts.conf"
            && ! -L "$revision_root/alerts.conf" ]]; then
            install -m 0640 \
                "$revision_root/alerts.conf" "$rollback_root/alerts.conf"
        else
            printf '%s\n' '{
  "CPU_PCT": 90,
  "MEMORY_PCT": 90,
  "NETWORK_MBPS": 100,
  "NOTIFY": true
}' >"$rollback_root/alerts.conf" \
                && chmod 0640 "$rollback_root/alerts.conf"
        fi
    }; then
        :
    elif [[ -f "$revision_root/simple.json"
        && ! -L "$revision_root/simple.json" ]] \
        && ! install -m 0600 \
            "$revision_root/simple.json" "$rollback_root/simple.json"; then
        :
    elif ! vx_compose_routes_validate_reservations \
        "$owner" "$project" "$rollback_root/routes.conf"; then
        :
    elif [[ -f "$rollback_root/workload.json" ]] \
        && ! vx_compose_workload_image_approval_require_files \
            "$owner" "$rollback_root/workload.json" \
            "$rollback_root/canonical.json"; then
        :
    elif ! vx_compose_rollback_snapshot_active "$root" "$snapshot_root"; then
        :
    elif ! vx_compose_audit "$root" rollback started \
        "target_revision=$revision"; then
        :
    else
        runtime_attempted=yes
        if VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$rollback_root/canonical.json" \
            VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$rollback_root/images.json" \
            VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$revision" \
            VX_COMPOSE_WORKLOAD_OVERRIDE="$rollback_root/workload.json" \
            VX_COMPOSE_POLICY_OVERRIDE="$rollback_root/policy.conf" \
            VX_COMPOSE_ROUTES_FILE_OVERRIDE="$rollback_root/routes.conf" \
            VX_COMPOSE_ROUTES_DEFER_COMMIT=yes \
            VX_COMPOSE_LIFECYCLE_DEFER_COMMIT=yes \
            vx_compose_deploy "$owner" "$project" \
            && vx_compose_network_cleanup_replaced \
                "$owner" "$project" \
                "$snapshot_root/canonical.json" "$rollback_root/canonical.json" \
            && vx_compose_rollback_activate \
                "$owner" "$project" "$rollback_root" "$revision_root" \
                "$revision"; then
            route_candidate="$(
                vx_compose_routes_candidate_path "$owner" "$project"
            )"
            if rm -f -- "$route_candidate" \
                && vx_compose_audit "$root" rollback succeeded \
                    "target_revision=$revision"; then
                result=0
            fi
        fi
    fi
    if [[ "$result" -ne 0 && "$runtime_attempted" == yes ]]; then
        if ! vx_compose_runtime_identity_preflight \
            "$owner" "$project" "$rollback_root/canonical.json" \
            "$rollback_root/images.json" "$revision" >/dev/null \
            || ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$rollback_root/canonical.json" \
                VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$rollback_root/images.json" \
                VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$revision" \
                vx_compose_invoke \
                    "$owner" "$project" down --remove-orphans \
                    >/dev/null 2>&1; then
            recovery_ok=no
        fi
        vx_compose_rollback_restore_active "$root" "$snapshot_root" \
            || recovery_ok=no
        if [[ "$recovery_ok" == yes ]] \
            && ! vx_compose_active_revision_verify "$owner" "$project"; then
            recovery_ok=no
        fi
        if [[ "$recovery_ok" == yes ]] \
            && ! vx_compose_deploy "$owner" "$project"; then
            recovery_ok=no
        fi
        if [[ "$recovery_ok" == yes && "$prior_state" == stopped ]] \
            && ! vx_compose_stop "$owner" "$project"; then
            recovery_ok=no
        fi
        if [[ "$recovery_ok" == yes ]]; then
            vx_compose_rollback_restore_active "$root" "$snapshot_root" \
                || recovery_ok=no
            if [[ -f "$snapshot_root/routes.pending.json" ]]; then
                install -m 0640 "$snapshot_root/routes.pending.json" \
                    "$root/runtime/routes.pending.json" || recovery_ok=no
            fi
        fi
        if [[ "$recovery_ok" != yes ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
            vx_compose_audit "$root" rollback failed \
                'prior runtime recovery failed' || :
        else
            vx_compose_audit "$root" rollback failed \
                'candidate rejected; exact prior state restored' || :
        fi
    fi
    rm -rf -- "${rollback_root:-}" "${snapshot_root:-}"
    [[ "$routes_locked" != yes ]] || vx_compose_routes_lock_release
    [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
    [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
    vx_compose_lock_release
    return "$result"
}

vx_compose_transaction_update() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local expected_revision="${4:-}"
    local final_state="${5:-running}"
    local root prior_revision prior_canonical prior_state profile result=1
    local next_revision
    local transaction_root route_candidate route_source recovery_result recovery_env
    local quota_locked=no ports_locked=no routes_locked=no
    local revision_root revision_value

    vx_compose_lock_acquire "$owner" "$project" || return 1
    [[ "$final_state" == running || "$final_state" == stopped ]] \
        || {
            vx_compose_error 'invalid Compose transaction final state'
            vx_compose_lock_release
            return 1
        }
    root="$(vx_compose_project_root "$owner" "$project")"
    if ! vx_compose_require_project "$owner" "$project"; then
        :
    elif ! prior_revision="$(
        vx_compose_meta_get "$root/project.conf" REVISION
    )"; then
        :
    elif ! prior_state="$(
        vx_compose_meta_get "$root/project.conf" STATE
    )"; then
        :
    elif ! profile="$(
        vx_compose_meta_get "$root/project.conf" PROFILE
    )"; then
        :
    else
        [[ -n "$expected_revision" ]] || expected_revision="$prior_revision"
    fi
    if [[ -n "${prior_revision:-}"
        && ( ! "$expected_revision" =~ ^[1-9][0-9]*$
            || "$expected_revision" != "$prior_revision" ) ]]; then
        vx_compose_error 'Compose project revision changed'
    elif [[ -n "${prior_revision:-}" ]]; then
        vx_compose_audit "$root" transaction-update started
        printf -v prior_canonical \
            '%s/revisions/%06d/canonical.json' "$root" "$prior_revision"
        next_revision="$prior_revision"
        for revision_root in \
            "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]; do
            [[ -d "$revision_root" ]] || continue
            revision_value="$(basename -- "$revision_root")"
            revision_value=$((10#$revision_value))
            (( revision_value > next_revision )) \
                && next_revision="$revision_value"
        done
        next_revision=$((next_revision + 1))
        route_candidate="$(vx_compose_routes_candidate_path "$owner" "$project")"
        route_source="$root/routes.conf"
        [[ ! -f "$route_candidate" ]] || route_source="$route_candidate"
        [[ ! -f "$candidate/routes.conf" ]] \
            || route_source="$candidate/routes.conf"
        transaction_root="$root/runtime/.transaction.$BASHPID"
        vx_compose_ports_lock_acquire || {
            vx_compose_lock_release
            return 1
        }
        ports_locked=yes
        if ! vx_compose_ports_check_conflicts \
            "$owner" "$project" "$candidate/canonical.json"; then
            vx_compose_ports_lock_release
            vx_compose_lock_release
            return 1
        fi
        vx_compose_owner_quota_lock_acquire "$owner" || {
            vx_compose_ports_lock_release
            vx_compose_lock_release
            return 1
        }
        quota_locked=yes
        vx_compose_routes_lock_acquire "$owner" || {
            vx_compose_owner_quota_lock_release
            vx_compose_ports_lock_release
            vx_compose_lock_release
            return 1
        }
        routes_locked=yes
        if ! vx_compose_quota_check_candidate \
            "$owner" "$project" "$candidate/policy.conf" update; then
            vx_compose_audit "$root" transaction-update failed \
                'candidate quota revalidation failed'
        elif ! vx_compose_routes_validate_reservations \
            "$owner" "$project" "$route_source"; then
            vx_compose_audit "$root" transaction-update failed \
                'candidate route reservation revalidation failed'
        elif [[ ! -f "$candidate/images.json" ]] \
            && ! vx_compose_resolve_images_to_file \
                "$owner" "$candidate/canonical.json" "$profile" \
                "$candidate/images.json"; then
            vx_compose_audit "$root" transaction-update failed \
                'candidate image resolution failed'
        elif ! vx_compose_stage_candidate_revision \
            "$owner" "$project" "$candidate" "$transaction_root" \
            "$route_source"; then
            vx_compose_audit "$root" transaction-update failed \
                'candidate staging failed'
        elif VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
            VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
            VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
            VX_COMPOSE_WORKLOAD_OVERRIDE="$transaction_root/workload.json" \
            VX_COMPOSE_POLICY_OVERRIDE="$transaction_root/policy.conf" \
            VX_COMPOSE_ROUTES_FILE_OVERRIDE="$transaction_root/routes.conf" \
            VX_COMPOSE_ROUTES_DEFER_COMMIT=yes \
            VX_COMPOSE_LIFECYCLE_DEFER_COMMIT=yes \
            VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE=yes \
            vx_compose_deploy "$owner" "$project" \
            && {
                [[ "$final_state" != stopped ]] \
                    || VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                        VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
                        VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
                        VX_COMPOSE_WORKLOAD_OVERRIDE="$transaction_root/workload.json" \
                        VX_COMPOSE_POLICY_OVERRIDE="$transaction_root/policy.conf" \
                        VX_COMPOSE_ROUTES_FILE_OVERRIDE="$transaction_root/routes.conf" \
                        VX_COMPOSE_ROUTES_DEFER_COMMIT=yes \
                        VX_COMPOSE_LIFECYCLE_DEFER_COMMIT=yes \
                        VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE=yes \
                        vx_compose_stop "$owner" "$project"
            } \
            && vx_compose_network_cleanup_replaced \
                "$owner" "$project" "$prior_canonical" \
                "$transaction_root/canonical.json"; then
            if vx_compose_commit_staged_revision \
                "$owner" "$project" "$transaction_root" \
                "$next_revision" "$final_state"; then
                rm -f -- "$route_candidate"
                vx_compose_audit "$root" transaction-update succeeded
                result=0
            else
                vx_compose_audit "$root" transaction-update failed \
                    'candidate finalization failed; restoring prior runtime'
            fi
        else
            vx_compose_audit "$root" transaction-update failed \
                'candidate convergence failed; rolling back'
        fi
        if [[ "$result" -ne 0 && -d "${transaction_root:-}" ]]; then
            rm -f -- "$route_candidate"
            recovery_result=0
            recovery_env="$root/variables.env"
            [[ -f "$recovery_env" && ! -L "$recovery_env" ]] \
                || recovery_env=/dev/null
            runtime_identity="$(
                vx_compose_runtime_identity_preflight \
                    "$owner" "$project" "$root/runtime/canonical.json" \
                    "$root/images.json" "$prior_revision"
            )" || runtime_identity=
            if [[ "$runtime_identity" != complete ]]; then
                if vx_compose_runtime_identity_preflight \
                    "$owner" "$project" "$transaction_root/canonical.json" \
                    "$transaction_root/images.json" "$next_revision" >/dev/null; then
                    if ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                        VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
                        VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
                        VX_COMPOSE_INVOKE_ENV_OVERRIDE="$recovery_env" \
                        vx_compose_invoke \
                            "$owner" "$project" down --remove-orphans; then
                        recovery_result=1
                    fi
                fi
            fi
            if [[ "$recovery_result" -eq 0 ]]; then
                VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$root/runtime/canonical.json" \
                VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$root/images.json" \
                VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$prior_revision" \
                    vx_compose_deploy "$owner" "$project" \
                    || recovery_result=$?
            fi
            if [[ "$recovery_result" -eq 0 && "$prior_state" == stopped ]]; then
                vx_compose_stop "$owner" "$project" || recovery_result=$?
            fi
            if [[ "$recovery_result" -ne 0 ]]; then
                vx_compose_update_state "$owner" "$project" restore-required
                vx_compose_audit "$root" transaction-update failed \
                    'prior runtime recovery failed'
            else
                vx_compose_audit "$root" transaction-update failed \
                    'prior runtime restored'
            fi
        fi
        if [[ -d "${transaction_root:-}"
            && "$transaction_root" == "$root/runtime/.transaction."* ]]; then
            rm -rf -- "$transaction_root"
        fi
    fi
    [[ "$routes_locked" != yes ]] || vx_compose_routes_lock_release
    [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
    [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
    vx_compose_lock_release
    return "$result"
}
