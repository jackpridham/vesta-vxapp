#!/usr/bin/env bash

vx_compose_backup_root() {
    printf '%s/data/users/%s/docker-project-backups/%s\n' \
        "$VESTA" "$1" "$2"
}

vx_compose_backup_recovery_path() {
    printf '%s/runtime/backup-recovery.conf\n' \
        "$(vx_compose_project_root "$1" "$2")"
}

vx_compose_backup_recovery_lock_require() {
    local owner="$1" project="$2"

    [[ "${VX_COMPOSE_LOCK_KEY:-}" == "$owner/$project"
        && "${VX_COMPOSE_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || {
        vx_compose_error 'Compose backup recovery requires the exact project lock'
        return 1
    }
}

vx_compose_backup_runtime_is_healthy() {
    local owner="$1" project="$2" root revision observation

    root="$(vx_compose_project_root "$owner" "$project")"
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || return 1
    [[ "$(vx_compose_meta_get "$root/project.conf" STATE)" == running
        && "$(vx_compose_runtime_identity_preflight \
            "$owner" "$project" "$root/runtime/canonical.json" \
            "$root/images.json" "$revision")" == complete ]] || return 1
    vx_compose_network_verify_runtime \
        "$owner" "$project" "$root/runtime/canonical.json" yes || return 1
    vx_compose_volume_verify_runtime \
        "$owner" "$project" "$root/runtime/canonical.json" yes || return 1
    observation="$(vx_compose_health_collect "$owner" "$project")" || return 1
    jq -e '
        .STATUS == "healthy" and .FRESHNESS == "fresh"
        and (.SERVICES | length > 0)
        and all(.SERVICES[];
            .RUNTIME_STATE == "running" and .HEALTH == "healthy")
    ' <<<"$observation" >/dev/null || return 1
    vx_compose_routes_apply "$owner" "$project" || return 1
}

vx_compose_backup_image_identity_sha256() {
    local evidence="$1" projection

    vx_compose_image_evidence_current_validate "$evidence" || return 1
    projection="$(vx_compose_image_evidence_current_projection "$evidence")" \
        || return 1
    printf '%s\n' "$projection" | sha256sum | awk '{print $1}'
}

vx_compose_backup_recovery_marker_keys_verify() {
    local path="$1" actual expected

    expected=$'CANONICAL_SHA256\nIMAGE_AUTHORITY\nIMAGE_IDENTITY_SHA256\nMIGRATION_MANIFEST_SHA256\nOWNER\nPRIOR_STATE\nPROJECT\nREVISION\nREVISION_IMAGES_SHA256\nREVISION_MANIFEST_SHA256\nSCHEMA'
    actual="$(sed -n "s/^\([A-Z][A-Z0-9_]*\)='[^']*'$/\1/p" "$path" \
        | LC_ALL=C sort)" || return 1
    [[ "$(wc -l <"$path")" -eq 11 && "$actual" == "$expected" ]]
}

vx_compose_backup_recovery_write() {
    local owner="$1" project="$2" path root temp revision revision_name
    local revision_root canonical_sha manifest_sha images_sha identity_sha
    local authority migration_sha='-'

    vx_compose_backup_recovery_lock_require "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    path="$(vx_compose_backup_recovery_path "$owner" "$project")"
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    [[ "$(vx_compose_meta_get "$root/project.conf" STATE)" == running ]] \
        || return 1
    if vx_compose_active_legacy_image_migration_is_needed "$owner" "$project"; then
        vx_compose_project_resolve_images "$owner" "$project" || return 1
    fi
    vx_compose_active_revision_verify "$owner" "$project" || return 1
    vx_compose_backup_runtime_is_healthy "$owner" "$project" || return 1
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || return 1
    canonical_sha="$(vx_compose_meta_get \
        "$root/project.conf" CANONICAL_SHA256)" || return 1
    [[ "$revision" =~ ^[1-9][0-9]*$
        && "$canonical_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf -v revision_name '%06d' "$revision"
    revision_root="$root/revisions/$revision_name"
    manifest_sha="$(sha256sum "$revision_root/manifest.sha256" \
        | awk '{print $1}')" || return 1
    images_sha="$(sha256sum "$revision_root/images.json" \
        | awk '{print $1}')" || return 1
    identity_sha="$(vx_compose_backup_image_identity_sha256 \
        "$root/images.json")" || return 1
    if vx_compose_revision_manifest_binds_images "$revision_root"; then
        authority='revision-manifest'
    else
        vx_compose_image_evidence_migration_authority_verify \
            "$owner" "$project" "$root" "$revision" \
            "$root/images.json" || return 1
        authority='legacy-migration-v1'
        migration_sha="$(sha256sum \
            "$(vx_compose_image_evidence_migration_root \
                "$root")/manifest.sha256" | awk '{print $1}')" || return 1
    fi
    temp="$(mktemp "$root/runtime/.backup-recovery.XXXXXX")" || return 1
    {
        printf "SCHEMA='2'\n"
        printf "OWNER='%s'\n" "$owner"
        printf "PROJECT='%s'\n" "$project"
        printf "PRIOR_STATE='running'\n"
        printf "REVISION='%s'\n" "$revision"
        printf "CANONICAL_SHA256='%s'\n" "$canonical_sha"
        printf "REVISION_MANIFEST_SHA256='%s'\n" "$manifest_sha"
        printf "REVISION_IMAGES_SHA256='%s'\n" "$images_sha"
        printf "IMAGE_IDENTITY_SHA256='%s'\n" "$identity_sha"
        printf "IMAGE_AUTHORITY='%s'\n" "$authority"
        printf "MIGRATION_MANIFEST_SHA256='%s'\n" "$migration_sha"
    } >"$temp"
    if ! vx_compose_control_file_protect "$temp" 600 \
        || ! vx_compose_fsync_path "$temp" \
        || ! mv -- "$temp" "$path" \
        || ! vx_compose_fsync_path "$root/runtime"; then
        rm -f -- "$temp"
        return 1
    fi
}

vx_compose_backup_recovery_authority_verify() {
    local owner="$1" project="$2" path="$3" root revision revision_name
    local revision_root canonical_sha manifest_sha images_sha identity_sha
    local authority migration_sha migration_path

    vx_compose_backup_recovery_lock_require "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    vx_compose_control_file_is_secure "$path" 600 \
        && vx_compose_backup_recovery_marker_keys_verify "$path" || return 1
    [[ "$(vx_compose_meta_get "$path" SCHEMA)" == 2
        && "$(vx_compose_meta_get "$path" OWNER)" == "$owner"
        && "$(vx_compose_meta_get "$path" PROJECT)" == "$project"
        && "$(vx_compose_meta_get "$path" PRIOR_STATE)" == running ]] \
        || return 1
    revision="$(vx_compose_meta_get "$path" REVISION)" || return 1
    canonical_sha="$(vx_compose_meta_get "$path" CANONICAL_SHA256)" || return 1
    manifest_sha="$(vx_compose_meta_get \
        "$path" REVISION_MANIFEST_SHA256)" || return 1
    images_sha="$(vx_compose_meta_get \
        "$path" REVISION_IMAGES_SHA256)" || return 1
    identity_sha="$(vx_compose_meta_get \
        "$path" IMAGE_IDENTITY_SHA256)" || return 1
    authority="$(vx_compose_meta_get "$path" IMAGE_AUTHORITY)" || return 1
    migration_sha="$(vx_compose_meta_get \
        "$path" MIGRATION_MANIFEST_SHA256)" || return 1
    [[ "$revision" =~ ^[1-9][0-9]*$
        && "$canonical_sha" =~ ^[a-f0-9]{64}$
        && "$manifest_sha" =~ ^[a-f0-9]{64}$
        && "$images_sha" =~ ^[a-f0-9]{64}$
        && "$identity_sha" =~ ^[a-f0-9]{64}$
        && "$(vx_compose_meta_get "$root/project.conf" REVISION)" \
            == "$revision"
        && "$(vx_compose_meta_get \
            "$root/project.conf" CANONICAL_SHA256)" == "$canonical_sha"
        && "$(sha256sum "$root/runtime/canonical.json" | awk '{print $1}')" \
            == "$canonical_sha" ]] || return 1
    printf -v revision_name '%06d' "$revision"
    revision_root="$root/revisions/$revision_name"
    [[ "$(sha256sum "$revision_root/manifest.sha256" | awk '{print $1}')" \
            == "$manifest_sha"
        && "$(sha256sum "$revision_root/images.json" | awk '{print $1}')" \
            == "$images_sha"
        && "$(vx_compose_backup_image_identity_sha256 \
            "$root/images.json")" == "$identity_sha" ]] || return 1
    case "$authority" in
        revision-manifest)
            [[ "$migration_sha" == - ]] \
                && vx_compose_revision_manifest_binds_images "$revision_root" \
                || return 1
            ;;
        legacy-migration-v1)
            [[ "$migration_sha" =~ ^[a-f0-9]{64}$ ]] || return 1
            migration_path="$(vx_compose_image_evidence_migration_root \
                "$root")/manifest.sha256"
            [[ "$(sha256sum "$migration_path" | awk '{print $1}')" \
                == "$migration_sha" ]] || return 1
            vx_compose_image_evidence_migration_authority_verify \
                "$owner" "$project" "$root" "$revision" \
                "$root/images.json" || return 1
            ;;
        *) return 1 ;;
    esac
    vx_compose_active_revision_verify "$owner" "$project"
}

vx_compose_backup_recover() {
    local owner="$1" project="$2" path root revision details
    local audit_ok=yes

    vx_compose_backup_recovery_lock_require "$owner" "$project" || return 1
    path="$(vx_compose_backup_recovery_path "$owner" "$project")"
    [[ -e "$path" || -L "$path" ]] || return 0
    root="$(vx_compose_project_root "$owner" "$project")"
    if ! vx_compose_backup_recovery_authority_verify \
        "$owner" "$project" "$path"; then
        vx_compose_audit "$root" backup-recovery failed \
            authority-verification-failed || :
        return 1
    fi
    revision="$(vx_compose_meta_get "$path" REVISION)" || return 1
    details="revision=$revision authority=$(vx_compose_meta_get \
        "$path" IMAGE_AUTHORITY)"
    vx_compose_audit "$root" backup-recovery started "$details" || audit_ok=no
    if ! vx_compose_backup_runtime_is_healthy "$owner" "$project"; then
        VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$root/images.json" \
            vx_compose_deploy "$owner" "$project" || :
        if ! vx_compose_backup_recovery_authority_verify \
                "$owner" "$project" "$path" \
            || ! vx_compose_backup_runtime_is_healthy "$owner" "$project"; then
            vx_compose_audit "$root" backup-recovery failed \
                "revision=$revision automatic-runtime-recovery-failed" || :
            return 1
        fi
    fi
    if ! vx_compose_backup_recovery_authority_verify \
        "$owner" "$project" "$path" \
        || ! vx_compose_backup_runtime_is_healthy "$owner" "$project"; then
        vx_compose_audit "$root" backup-recovery failed \
            "revision=$revision post-recovery-verification-failed" || :
        return 1
    fi
    if ! vx_compose_audit "$root" backup-recovery succeeded "$details"; then
        return 2
    fi
    [[ "$audit_ok" == yes ]] || return 2
    rm -f -- "$path" || return 2
    vx_compose_fsync_path "$root/runtime" || return 2
}

vx_compose_backup_orphan_cleanup() {
    local owner="$1" project="$2" backup_root root orphan recovery_result=0
    backup_root="$(vx_compose_backup_root "$owner" "$project")"
    root="$(vx_compose_project_root "$owner" "$project")"
    if vx_compose_backup_recover "$owner" "$project"; then
        recovery_result=0
    else
        recovery_result=$?
    fi
    if [[ "$recovery_result" -ne 0 ]]; then
        if [[ "$recovery_result" -eq 1 ]]; then
            vx_compose_update_state "$owner" "$project" \
                restore-required || :
        fi
        return "$recovery_result"
    fi
    if [[ -d "$backup_root" && ! -L "$backup_root" ]]; then
        while IFS= read -r -d '' orphan; do
            rm -rf -- "$orphan" || return 1
        done < <(find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
            -name '.compose-backup.*' -print0)
    fi
    rm -rf -- "$root/runtime"/.backup-validation.* \
        "$root/runtime"/.backup-replication.* \
        "$root/runtime"/.restore-drill.*
}

vx_compose_backup_signal_cleanup() {
    local owner="${_VX_COMPOSE_BACKUP_OWNER:-}"
    local project="${_VX_COMPOSE_BACKUP_PROJECT:-}"
    local work_root="${_VX_COMPOSE_BACKUP_WORK_ROOT:-}"
    local output_file="${_VX_COMPOSE_BACKUP_OUTPUT:-}"
    local recovery_result=0
    [[ -z "$work_root" || "$work_root" != *'/.compose-backup.'* ]] \
        || rm -rf -- "$work_root"
    [[ -z "$output_file" ]] || rm -f -- "$output_file"
    if [[ -n "$owner" && -n "$project" ]]; then
        if vx_compose_backup_recover "$owner" "$project"; then
            recovery_result=0
        else
            recovery_result=$?
        fi
        if [[ "$recovery_result" -eq 1 ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
        fi
    fi
    vx_compose_lock_release || :
}

vx_compose_backup_traps_restore() {
    local saved
    for saved in \
        "${_VX_COMPOSE_BACKUP_TRAP_HUP:-}" \
        "${_VX_COMPOSE_BACKUP_TRAP_INT:-}" \
        "${_VX_COMPOSE_BACKUP_TRAP_TERM:-}"; do
        [[ -z "$saved" ]] || eval "$saved"
    done
    [[ -n "${_VX_COMPOSE_BACKUP_TRAP_HUP:-}" ]] || trap - HUP
    [[ -n "${_VX_COMPOSE_BACKUP_TRAP_INT:-}" ]] || trap - INT
    [[ -n "${_VX_COMPOSE_BACKUP_TRAP_TERM:-}" ]] || trap - TERM
    unset _VX_COMPOSE_BACKUP_TRAP_HUP _VX_COMPOSE_BACKUP_TRAP_INT \
        _VX_COMPOSE_BACKUP_TRAP_TERM _VX_COMPOSE_BACKUP_OWNER \
        _VX_COMPOSE_BACKUP_PROJECT _VX_COMPOSE_BACKUP_WORK_ROOT \
        _VX_COMPOSE_BACKUP_OUTPUT
}

vx_compose_backup_allocate_path() {
    local owner="$1"
    local project="$2"
    local backup_root timestamp output_file

    vx_compose_require_project "$owner" "$project" || return 1
    backup_root="$(vx_compose_backup_root "$owner" "$project")"
    install -d -m 0700 "$backup_root"
    timestamp="$(date -u +%Y%m%dT%H%M%S.%NZ)"
    output_file="$backup_root/$project-$timestamp.tar.gz"
    [[ ! -e "$output_file" ]] || {
        vx_compose_error 'unable to allocate a unique Compose backup name'
        return 1
    }
    printf '%s\n' "$output_file"
}

vx_compose_backup_list_json() {
    local owner="$1"
    local project="$2"
    local backup_root archive inventory

    vx_compose_require_project "$owner" "$project" || return 1
    backup_root="$(vx_compose_backup_root "$owner" "$project")"
    [[ -d "$backup_root" && ! -L "$backup_root" ]] || {
        printf '[]\n'
        return
    }
    inventory='[]'
    while IFS= read -r -d '' archive; do
        inventory="$(jq -c \
            --arg archive "$(basename -- "$archive")" \
            --arg created "$(date -u -r "$archive" +%Y-%m-%dT%H:%M:%SZ)" \
            --argjson bytes "$(stat -c '%s' "$archive")" \
            '. + [{
                ARCHIVE: $archive,
                CREATED: $created,
                BYTES: $bytes
            }]' <<<"$inventory")"
    done < <(
        find "$backup_root" -maxdepth 1 -type f \
            -name '*.tar.gz' -print0 | sort -z
    )
    printf '%s\n' "$inventory"
}

vx_compose_backup_resolve_managed() {
    local owner="$1"
    local project="$2"
    local archive_name="$3"
    local backup_root archive_path

    [[ "$archive_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[.]tar[.]gz$ ]] \
        || {
            vx_compose_error 'invalid managed Compose backup name'
            return 1
        }
    vx_compose_require_project "$owner" "$project" || return 1
    backup_root="$(realpath -e -- "$(vx_compose_backup_root "$owner" "$project")")" \
        || return 1
    archive_path="$backup_root/$archive_name"
    [[ -f "$archive_path" && ! -L "$archive_path"
        && "$(realpath -e -- "$(dirname -- "$archive_path")")" == "$backup_root" ]] \
        || {
            vx_compose_error 'managed Compose backup does not exist'
            return 1
        }
    printf '%s\n' "$archive_path"
}

vx_compose_backup_copy_control() {
    local root="$1"
    local destination="$2"
    local name revision source_revision destination_revision
    local public_metadata legacy_metadata

    install -d -m 0700 "$destination" "$destination/revisions"
    for name in \
        compose.yaml project.conf policy.conf backup-policy.conf variables.env images.json \
        audit.log routes.conf simple.json alerts.conf workload.json workload-evidence.json workload-manifest.sha256; do
        [[ -f "$root/$name" && ! -L "$root/$name" ]] || continue
        install -m 0600 "$root/$name" "$destination/$name"
    done
    public_metadata="$root/secrets.json"
    if [[ -f "$public_metadata" && ! -L "$public_metadata" ]]; then
        jq -S 'with_entries(.value |= del(.SHA256))' \
            "$public_metadata" >"$destination/secrets.json" || return 1
    else
        printf '{}\n' >"$destination/secrets.json"
    fi
    chmod 0600 "$destination/secrets.json"
    legacy_metadata="$destination/secrets.json"
    [[ -f "$public_metadata" && ! -L "$public_metadata" ]] \
        && legacy_metadata="$public_metadata"
    if [[ -f "$root/secret-integrity.json"
        && ! -L "$root/secret-integrity.json" ]]; then
        jq -S --slurpfile legacy "$legacy_metadata" '
            reduce ($legacy[0] | to_entries[]) as $entry (.;
                if ((.[$entry.key].SHA256 // "")
                    | test("^[a-f0-9]{64}$"))
                then .
                elif (($entry.value.SHA256 // "")
                    | test("^[a-f0-9]{64}$"))
                then .[$entry.key] = {SHA256: $entry.value.SHA256}
                else .
                end
            )
        ' "$root/secret-integrity.json" \
            >"$destination/secret-integrity.json" || return 1
    elif [[ -f "$public_metadata" && ! -L "$public_metadata" ]]; then
        jq -S 'with_entries(
            .value = if ((.value.SHA256 // "") | test("^[a-f0-9]{64}$"))
                then {SHA256: .value.SHA256}
                else {}
                end
        )' "$public_metadata" >"$destination/secret-integrity.json" || return 1
    else
        printf '{}\n' >"$destination/secret-integrity.json"
    fi
    chmod 0600 "$destination/secret-integrity.json"
    install -m 0600 "$root/runtime/canonical.json" "$destination/canonical.json"
    for source_revision in "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$source_revision" && ! -L "$source_revision" ]] || continue
        revision="$(basename -- "$source_revision")"
        destination_revision="$destination/revisions/$revision"
        install -d -m 0700 "$destination_revision"
        for name in \
            compose.yaml canonical.json manifest.sha256 policy.conf \
            images.json routes.conf simple.json alerts.conf workload.json workload-evidence.json workload-manifest.sha256; do
            [[ -f "$source_revision/$name" && ! -L "$source_revision/$name" ]] \
                || continue
            install -m 0600 \
                "$source_revision/$name" "$destination_revision/$name"
        done
    done
}

vx_compose_backup_copy_binds() {
    local bind_root="$1"
    local destination="$2"

    install -d -m 0700 "$destination"
    [[ -d "$bind_root" && ! -L "$bind_root" ]] || return 0
    if find "$bind_root" \
        \( -type l -o -type b -o -type c -o -type p -o -type s \) \
        -print -quit | grep -q .; then
        vx_compose_error 'managed bind data contains an unsupported file type'
        return 1
    fi
    cp -a -- "$bind_root/." "$destination/"
}

vx_compose_backup_secret_payload() {
    local root="$1"
    local destination="$2"
    local secret_count secret_tar

    secret_count="$(find "$root/secrets" -maxdepth 1 -type f ! -name '.*' \
        2>/dev/null | wc -l)"
    [[ "$secret_count" -gt 0 && -n "${VX_DOCKER_AGE_RECIPIENT:-}" ]] || return 0
    secret_tar="$(mktemp)"
    chmod 0600 "$secret_tar"
    if ! tar --create --gzip --file "$secret_tar" \
        --numeric-owner --owner=0 --group=0 \
        --directory "$root/secrets" . \
        || ! vx_compose_age_encrypt \
            "$secret_tar" "$destination/encrypted-secrets.age"; then
        rm -f -- "$secret_tar"
        return 1
    fi
    rm -f -- "$secret_tar"
}

vx_compose_backup_project() {
    local owner="$1"
    local project="$2"
    local output_file="$3"
    local root state revision output_parent work_root stage archive_temp
    local volume result=1 was_running=no recovery_result=0 recovery_detail

    vx_compose_require_project "$owner" "$project" || return 1
    [[ ! -e "$output_file"
        && "$(basename -- "$output_file")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[.]tar[.]gz$ ]] \
        || {
            vx_compose_error 'invalid Compose backup output path'
            return 1
        }
    output_parent="$(realpath -e -- "$(dirname -- "$output_file")")" || return 1
    [[ -d "$output_parent" && ! -L "$(dirname -- "$output_file")" ]] || return 1

    vx_compose_lock_acquire "$owner" "$project" || return 1
    vx_compose_backup_orphan_cleanup "$owner" "$project" || {
        vx_compose_lock_release
        return 1
    }
    root="$(vx_compose_project_root "$owner" "$project")"
    state="$(vx_compose_meta_get "$root/project.conf" STATE)" || state=stopped
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || revision=0
    if [[ "$state" == running ]]; then
        vx_compose_backup_recovery_write "$owner" "$project" || {
            vx_compose_lock_release
            return 1
        }
        _VX_COMPOSE_BACKUP_TRAP_HUP="$(trap -p HUP)"
        _VX_COMPOSE_BACKUP_TRAP_INT="$(trap -p INT)"
        _VX_COMPOSE_BACKUP_TRAP_TERM="$(trap -p TERM)"
        _VX_COMPOSE_BACKUP_OWNER="$owner"
        _VX_COMPOSE_BACKUP_PROJECT="$project"
        _VX_COMPOSE_BACKUP_OUTPUT="$output_file"
        trap 'vx_compose_backup_signal_cleanup; exit 129' HUP
        trap 'vx_compose_backup_signal_cleanup; exit 130' INT
        trap 'vx_compose_backup_signal_cleanup; exit 143' TERM
        vx_compose_audit "$root" backup-stop started
        if ! vx_compose_stop "$owner" "$project"; then
            if vx_compose_backup_recover "$owner" "$project"; then
                recovery_result=0
            else
                recovery_result=$?
            fi
            if [[ "$recovery_result" -eq 1 ]]; then
                vx_compose_update_state \
                    "$owner" "$project" restore-required || :
            fi
            vx_compose_backup_traps_restore
            vx_compose_audit "$root" backup-stop failed \
                "recovery=$(if [[ "$recovery_result" -eq 0 ]]; then
                    printf succeeded
                elif [[ "$recovery_result" -eq 2 ]]; then
                    printf evidence-incomplete
                else
                    printf failed
                fi)" || :
            vx_compose_lock_release
            return 1
        fi
        was_running=yes
    fi

    work_root="$(mktemp -d "$output_parent/.compose-backup.XXXXXX")" || {
        if [[ "$was_running" == yes ]]; then
            if vx_compose_backup_recover "$owner" "$project"; then
                recovery_result=0
            else
                recovery_result=$?
            fi
            if [[ "$recovery_result" -eq 1 ]]; then
                vx_compose_update_state "$owner" "$project" restore-required || :
            fi
            vx_compose_backup_traps_restore
        fi
        vx_compose_lock_release
        return 1
    }
    _VX_COMPOSE_BACKUP_WORK_ROOT="$work_root"
    stage="$work_root/stage"
    install -d -m 0700 "$stage" "$stage/volumes"
    if vx_compose_backup_copy_control "$root" "$stage/control" \
        && vx_compose_backup_copy_binds \
            "$(vx_compose_bind_root "$owner" "$project")" "$stage/binds"; then
        result=0
        while IFS= read -r volume; do
            vx_compose_volume_export \
                "$owner" "$project" "$volume" "$stage/volumes/$volume.tar.gz" \
                || {
                    result=1
                    break
                }
        done < <(jq -r '(.volumes // {}) | keys[]' "$root/runtime/canonical.json")
        if [[ "${result:-0}" -ne 1 ]] \
            && vx_compose_backup_secret_payload "$root" "$stage"; then
            jq -n -S \
                --arg owner "$owner" \
                --arg project "$project" \
                --arg state "$state" \
                --arg created "$(vx_compose_now)" \
                --argjson revision "$revision" \
                --argjson volumes \
                    "$(jq -c '(.volumes // {}) | keys' "$root/runtime/canonical.json")" \
                --argjson secrets \
                    "$(if [[ -f "$root/secrets.json" ]]; then
                        jq -c 'keys' "$root/secrets.json"
                    else
                        printf '[]\n'
                    fi)" \
                '{
                    SCHEMA: 1,
                    OWNER: $owner,
                    PROJECT: $project,
                    REVISION: $revision,
                    STATE: $state,
                    CREATED: $created,
                    VOLUMES: $volumes,
                    SECRETS: $secrets
                }' >"$stage/manifest.json" \
                && chmod 0600 "$stage/manifest.json" \
                && (
                    cd "$stage" || exit 1
                    find . -type f ! -path './manifest.sha256' -print0 \
                        | sort -z \
                        | xargs -0 sha256sum >manifest.sha256
                    chmod 0600 manifest.sha256
                )
            archive_temp="$work_root/backup.tar.gz"
            if tar --create --gzip --file "$archive_temp" \
                --numeric-owner \
                --directory "$stage" . \
                && vx_compose_archive_structure_validate \
                    "$archive_temp" project; then
                chmod 0600 "$archive_temp"
                mv -- "$archive_temp" "$output_file"
                result=0
            else
                result=1
            fi
        fi
    fi

    if [[ "$was_running" == yes ]]; then
        if vx_compose_backup_recover "$owner" "$project"; then
            recovery_result=0
        else
            recovery_result=$?
        fi
        if [[ "$recovery_result" -ne 0 ]]; then
            result=1
        fi
        if [[ "$recovery_result" -eq 1 ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
        fi
        vx_compose_backup_traps_restore
    fi
    recovery_detail='not-required'
    if [[ "$was_running" == yes ]]; then
        case "$recovery_result" in
            0) recovery_detail='succeeded' ;;
            2) recovery_detail='evidence-incomplete' ;;
            *) recovery_detail='failed' ;;
        esac
    fi
    if [[ "$result" -eq 0 ]]; then
        if ! vx_compose_audit "$root" backup succeeded \
            "recovery=$recovery_detail revision=$revision"; then
            result=1
            rm -f -- "$output_file"
            vx_compose_audit "$root" backup failed \
                "recovery=$recovery_detail revision=$revision terminal-evidence-failed" \
                || :
        fi
    else
        rm -f -- "$output_file"
        vx_compose_audit "$root" backup failed \
            "recovery=$recovery_detail revision=$revision" || :
    fi
    rm -rf -- "$work_root"
    vx_compose_lock_release
    return "$result"
}

vx_compose_backup_user_projects() {
    local owner="$1"
    local destination="$2"
    local project

    vx_compose_require_owner "$owner" || return 1
    install -d -m 0700 "$destination"
    while IFS= read -r project; do
        vx_compose_backup_project \
            "$owner" "$project" "$destination/$project.tar.gz" || return 1
    done < <(vx_compose_owner_project_keys "$owner")
}
