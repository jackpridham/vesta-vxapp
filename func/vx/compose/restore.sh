#!/usr/bin/env bash

VX_COMPOSE_BACKUP_MAX_BYTES="${VX_COMPOSE_BACKUP_MAX_BYTES:-10737418240}"
VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES="${VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES:-21474836480}"
VX_COMPOSE_BACKUP_MAX_MEMBERS="${VX_COMPOSE_BACKUP_MAX_MEMBERS:-100000}"

vx_compose_archive_member_is_safe() {
    local member="$1"
    local component

    while [[ "$member" == ./* ]]; do
        member="${member#./}"
    done
    [[ -n "$member" ]] || return 0
    [[ "$member" != /* && "$member" != *$'\n'* && "$member" != *$'\r'* ]] \
        || return 1
    IFS='/' read -r -a components <<<"$member"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] \
            || return 1
    done
}

vx_compose_backup_member_is_expected() {
    local member="$1"

    while [[ "$member" == ./* ]]; do
        member="${member#./}"
    done
    member="${member%/}"
    case "$member" in
        ''|manifest.json|manifest.sha256|encrypted-secrets.age|\
        control|control/compose.yaml|control/canonical.json|\
        control/project.conf|control/policy.conf|control/backup-policy.conf|control/variables.env|\
        control/images.json|control/secrets.json|\
        control/secret-integrity.json|control/audit.log|\
        control/routes.conf|control/simple.json|control/alerts.conf|\
        control/revisions|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/compose.yaml|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/canonical.json|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/manifest.sha256|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/policy.conf|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/images.json|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/routes.conf|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/alerts.conf|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/simple.json|\
        binds|binds/*|volumes|volumes/[a-z][a-z0-9_-]*.tar.gz)
            return 0
            ;;
    esac
    return 1
}

vx_compose_archive_structure_validate() {
    local archive="$1"
    local scope="$2"
    local listing verbose member member_count expanded_bytes member_error=''

    [[ -f "$archive" && ! -L "$archive" ]] \
        || {
            vx_compose_error 'restore archive must be a regular non-symlink file'
            return 1
        }
    [[ "$(stat -c '%s' "$archive")" -le "$VX_COMPOSE_BACKUP_MAX_BYTES" ]] \
        || {
            vx_compose_error 'restore archive exceeds the compressed size limit'
            return 1
        }
    listing="$(mktemp)"
    verbose="$(mktemp)"
    if ! tar -tzf "$archive" >"$listing" 2>/dev/null \
        || ! tar -tvzf "$archive" >"$verbose" 2>/dev/null; then
        rm -f -- "$listing" "$verbose"
        vx_compose_error 'restore archive is not a valid gzip tar archive'
        return 1
    fi
    member_count="$(wc -l <"$listing")"
    [[ "$member_count" -le "$VX_COMPOSE_BACKUP_MAX_MEMBERS" ]] \
        || {
            rm -f -- "$listing" "$verbose"
            vx_compose_error 'restore archive contains too many members'
            return 1
        }
    [[ "$(sort "$listing" | uniq -d | wc -l)" -eq 0 ]] \
        || {
            rm -f -- "$listing" "$verbose"
            vx_compose_error 'restore archive contains duplicate members'
            return 1
        }
    if awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { exit 1 }' \
        "$verbose"; then
        :
    else
        rm -f -- "$listing" "$verbose"
        vx_compose_error 'restore archive contains links or special files'
        return 1
    fi
    expanded_bytes="$(awk '{ total += $3 } END { printf "%.0f", total }' "$verbose")"
    [[ "$expanded_bytes" =~ ^[0-9]+$
        && "$expanded_bytes" -le "$VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES" ]] \
        || {
            rm -f -- "$listing" "$verbose"
            vx_compose_error 'restore archive exceeds the expanded size limit'
            return 1
        }
    while IFS= read -r member; do
        if ! vx_compose_archive_member_is_safe "$member"; then
            member_error='restore archive contains an unsafe path'
            break
        fi
        if [[ "$scope" == project ]]; then
            if ! vx_compose_backup_member_is_expected "$member"; then
                member_error='restore archive contains an unexpected member'
                break
            fi
        fi
    done <"$listing"
    rm -f -- "$listing" "$verbose"
    if [[ -n "$member_error" ]]; then
        vx_compose_error "$member_error"
        return 1
    fi
}

vx_compose_data_archive_validate() {
    vx_compose_archive_structure_validate "$1" data
}

vx_compose_restore_archive_validate() {
    local owner="$1"
    local project="$2"
    local archive="$3"
    local output_root="$4"
    local output_parent temp_root actual_manifest

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    [[ ! -e "$output_root" ]] \
        || {
            vx_compose_error 'restore validation output already exists'
            return 1
        }
    output_parent="$(realpath -e -- "$(dirname -- "$output_root")")" || return 1
    [[ -d "$output_parent" && ! -L "$(dirname -- "$output_root")" ]] || return 1
    vx_compose_archive_structure_validate "$archive" project || return 1

    temp_root="$(mktemp -d "$output_parent/.compose-restore.XXXXXX")" || return 1
    local -a ownership_args=(--no-same-owner)
    if [[ "$EUID" -eq 0 ]]; then
        ownership_args=(--numeric-owner --same-owner)
    fi
    if ! tar --extract --gzip \
        "${ownership_args[@]}" --no-same-permissions \
        --directory "$temp_root" --file "$archive" 2>/dev/null; then
        rm -rf -- "$temp_root"
        vx_compose_error 'restore archive extraction failed'
        return 1
    fi
    [[ -f "$temp_root/manifest.json"
        && ! -L "$temp_root/manifest.json"
        && -f "$temp_root/manifest.sha256"
        && ! -L "$temp_root/manifest.sha256" ]] \
        || {
            rm -rf -- "$temp_root"
            vx_compose_error 'restore archive manifest is incomplete'
            return 1
        }
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" '
            .SCHEMA == 1
            and .OWNER == $owner
            and .PROJECT == $project
            and (.REVISION | type == "number" and . >= 1)
            and (.STATE == "stopped" or .STATE == "running")
            and (.VOLUMES | type == "array")
            and (.SECRETS | type == "array")
        ' "$temp_root/manifest.json" >/dev/null \
        || {
            rm -rf -- "$temp_root"
            vx_compose_error 'restore archive metadata does not match the target'
            return 1
        }
    actual_manifest="$(mktemp "$output_parent/.compose-hashes.XXXXXX")"
    (
        cd "$temp_root" || exit 1
        find . -type f ! -path './manifest.sha256' -print0 \
            | sort -z \
            | xargs -0 sha256sum
    ) >"$actual_manifest" \
        || {
            rm -rf -- "$temp_root"
            rm -f -- "$actual_manifest"
            return 1
        }
    if ! cmp -s "$temp_root/manifest.sha256" "$actual_manifest" \
        || ! (
            cd "$temp_root" || exit 1
            sha256sum --strict -c manifest.sha256 >/dev/null
        ); then
        rm -rf -- "$temp_root"
        rm -f -- "$actual_manifest"
        vx_compose_error 'restore archive checksum verification failed'
        return 1
    fi
    rm -f -- "$actual_manifest"
    mv -- "$temp_root" "$output_root"
}

vx_compose_restore_verify_images() {
    local owner="$1"
    local canonical="$2"
    local images="$3"
    local service reference expected_id inspection

    [[ -f "$images" && ! -L "$images" ]] \
        || {
            vx_compose_error 'restore image identity manifest is missing'
            return 1
        }
    while IFS=$'\t' read -r service reference; do
        expected_id="$(jq -er \
            --arg service "$service" \
            --arg reference "$reference" '
                .[$service]
                | select(.REFERENCE == $reference)
                | .IMAGE_ID
                | select(type == "string" and length > 0)
            ' "$images")" \
            || {
                vx_compose_error 'restore image identity manifest is incomplete'
                return 1
            }
        inspection="$(vx_compose_image_inspect "$owner" "$reference")" || return 1
        [[ "$(jq -r '.Id' <<<"$inspection")" == "$expected_id" ]] \
            || {
                vx_compose_error 'restore image identity is unavailable'
                return 1
            }
    done < <(jq -r '.services | to_entries[] | [.key, .value.image] | @tsv' \
        "$canonical")
}

vx_compose_restore_storage_mb() {
    local extracted="$1"
    local bytes=0 volume_archive archive_bytes

    if [[ -d "$extracted/binds" ]]; then
        bytes="$(du -sb -- "$extracted/binds" | awk 'NR == 1 { print $1 }')" \
            || return 1
    fi
    for volume_archive in "$extracted"/volumes/*.tar.gz; do
        [[ -f "$volume_archive" && ! -L "$volume_archive" ]] || continue
        vx_compose_data_archive_validate "$volume_archive" || return 1
        archive_bytes="$(tar -tvzf "$volume_archive" \
            | awk '{ total += $3 } END { printf "%.0f", total }')" || return 1
        bytes=$((bytes + archive_bytes))
    done
    printf '%s\n' "$(( (bytes + 1048575) / 1048576 ))"
}

vx_compose_restore_prepare_secrets() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local output_root="$4"
    local metadata="$extracted/control/secrets.json"
    local integrity="$extracted/control/secret-integrity.json"
    local encrypted="$extracted/encrypted-secrets.age"
    local decrypted_tar secret source expected_sha actual_sha

    install -d -m 0700 "$output_root"
    [[ -f "$metadata" && ! -L "$metadata" ]] \
        || {
            vx_compose_error 'restore secret-name manifest is missing'
            return 1
        }
    jq -e 'type == "object"' "$metadata" >/dev/null \
        || {
            vx_compose_error 'restore secret-name manifest is invalid'
            return 1
        }
    if jq -e 'length == 0' "$metadata" >/dev/null; then
        return 0
    fi
    if [[ -f "$encrypted" && ! -L "$encrypted" ]]; then
        decrypted_tar="$(mktemp)"
        if ! vx_compose_age_decrypt "$encrypted" "$decrypted_tar" \
            || ! vx_compose_data_archive_validate "$decrypted_tar" \
            || ! tar --extract --gzip --file "$decrypted_tar" \
                --no-same-owner --directory "$output_root"; then
            rm -f -- "$decrypted_tar"
            return 1
        fi
        rm -f -- "$decrypted_tar"
    else
        while IFS= read -r secret; do
            source="$(vx_compose_secret_path "$owner" "$project" "$secret")"
            [[ -f "$source" && ! -L "$source"
                && "$(stat -c '%a' "$source")" == 600 ]] \
                || {
                    vx_compose_error \
                        'restore-required: managed secrets must be re-provisioned'
                    return 1
                }
            install -m 0600 "$source" "$output_root/$secret"
        done < <(jq -r 'keys[]' "$metadata")
    fi
    if find "$output_root" -mindepth 2 -print -quit | grep -q . \
        || find "$output_root" -mindepth 1 -maxdepth 1 ! -type f \
            -print -quit | grep -q .; then
        vx_compose_error 'decrypted secret payload layout is invalid'
        return 1
    fi
    while IFS= read -r secret; do
        vx_compose_secret_name_is_valid "$secret" \
            || {
                vx_compose_error 'decrypted secret payload name is invalid'
                return 1
            }
        source="$output_root/$secret"
        [[ -f "$source" && ! -L "$source" ]] \
            || {
                vx_compose_error 'decrypted secret payload is incomplete'
                return 1
            }
        chmod 0600 "$source"
        expected_sha=''
        if [[ -f "$integrity" && ! -L "$integrity" ]]; then
            expected_sha="$(jq -er --arg secret "$secret" \
                '.[$secret].SHA256 | select(test("^[a-f0-9]{64}$"))' \
                "$integrity" 2>/dev/null)" || expected_sha=''
        fi
        if [[ -z "$expected_sha" ]]; then
            expected_sha="$(jq -er --arg secret "$secret" \
                '.[$secret].SHA256 | select(test("^[a-f0-9]{64}$"))' \
                "$metadata")" || return 1
        fi
        actual_sha="$(sha256sum "$source" | awk '{print $1}')"
        [[ "$actual_sha" == "$expected_sha" ]] \
            || {
                vx_compose_error 'decrypted secret payload checksum mismatch'
                return 1
            }
    done < <(jq -r 'keys[]' "$metadata")
    [[ "$(find "$output_root" -maxdepth 1 -type f | wc -l)" \
        -eq "$(jq 'length' "$metadata")" ]] \
        || {
            vx_compose_error 'decrypted secret payload contains unexpected files'
            return 1
        }
}

vx_compose_restore_install_secrets() {
    local root="$1"
    local secret_source="$2"
    local metadata="$3"
    local integrity="${4:-}"
    local new_root="$root/.secrets.restore"
    local old_root="$root/.secrets.before-restore"
    local secret

    [[ ! -e "$new_root" && ! -e "$old_root" ]] || return 1
    install -d -m 0700 "$new_root" || return 1
    for secret in "$secret_source"/*; do
        [[ -f "$secret" && ! -L "$secret" ]] || continue
        install -m 0600 "$secret" "$new_root/$(basename -- "$secret")" \
            || {
                rm -rf -- "$new_root"
                return 1
            }
    done
    mv -- "$root/secrets" "$old_root" || {
        rm -rf -- "$new_root"
        return 1
    }
    if ! mv -- "$new_root" "$root/secrets"; then
        mv -- "$old_root" "$root/secrets" || :
        return 1
    fi
    if ! install -m 0600 "$metadata" "$root/secrets.json"; then
        rm -rf -- "$root/secrets"
        mv -- "$old_root" "$root/secrets" || :
        return 1
    fi
    if [[ -n "$integrity" && -f "$integrity" && ! -L "$integrity" ]]; then
        jq -S --slurpfile legacy "$metadata" '
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
        ' "$integrity" >"$root/secret-integrity.json" || return 1
    else
        jq -S 'with_entries(
            .value = if ((.value.SHA256 // "") | test("^[a-f0-9]{64}$"))
                then {SHA256: .value.SHA256}
                else {}
                end
        )' "$metadata" >"$root/secret-integrity.json" || return 1
    fi
    chmod 0600 "$root/secret-integrity.json" || return 1
    if jq -e 'any(.[]?; has("SHA256"))' "$root/secrets.json" >/dev/null; then
        jq -S 'with_entries(.value |= del(.SHA256))' "$root/secrets.json" \
            >"$root/.secrets.public.restore" || return 1
        chmod 0600 "$root/.secrets.public.restore" || return 1
        mv -f -- "$root/.secrets.public.restore" "$root/secrets.json" || return 1
    fi
}

vx_compose_restore_prepare() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local candidate="$4"
    local profile archived_owner archived_project
    local normalized_archived normalized_candidate mode restored_storage
    local measured_storage current_project_storage=0 projected_storage path size
    local validation_secrets="$extracted/restore-secrets"

    archived_owner="$(vx_compose_meta_get "$extracted/control/project.conf" OWNER)" \
        || return 1
    archived_project="$(vx_compose_meta_get "$extracted/control/project.conf" PROJECT)" \
        || return 1
    if [[ -f "$extracted/control/backup-policy.conf" ]]; then
        vx_compose_backup_policy_file_validate \
            "$extracted/control/backup-policy.conf" \
            || {
                vx_compose_error 'restore backup policy metadata is invalid'
                return 1
            }
    fi
    profile="$(vx_compose_meta_get "$extracted/control/project.conf" PROFILE)" \
        || return 1
    [[ "$archived_owner" == "$owner" && "$archived_project" == "$project" ]] \
        || {
            vx_compose_error 'restore control metadata does not match the target'
            return 1
        }
    if [[ -f "$extracted/control/simple.json" ]]; then
        jq -e \
            --arg owner "$owner" \
            --arg project "$project" \
            --arg image "$(jq -r '.IMAGE' "$extracted/control/simple.json")" \
            --argjson canonical \
                "$(cat "$extracted/control/canonical.json")" '
                .GENERATED == true
                and .OWNER == $owner
                and .NAME == $project
                and (
                    [
                        .IMAGE, .COMMAND, .ENV, .MOUNTS, .HOST_PORT,
                        .CONTAINER_PORT, .DOMAIN, .ROUTE_PATH, .AUTO_START,
                        .RESTART_POLICY, .HEALTHCHECK_TYPE,
                        .HEALTHCHECK_TARGET, .HEALTHCHECK_INTERVAL,
                        .CPU_ALERT_PCT, .MEM_ALERT_MB, .NET_ALERT_MBPS,
                        .ALERT_EMAIL
                    ]
                    | all(type == "string")
                )
                and ($canonical.services | length) == 1
                and any($canonical.services[]; .image == $image)
            ' "$extracted/control/simple.json" >/dev/null 2>&1 \
            || {
                vx_compose_error 'restore simple-form metadata is invalid'
                return 1
            }
    fi
    vx_compose_profile_is_available "$profile" \
        || {
            vx_compose_error 'restore profile is not currently available'
            return 1
        }
    vx_compose_restore_prepare_secrets \
        "$owner" "$project" "$extracted" "$validation_secrets" || return 1
    # Stored compose.yaml excludes reserved ownership labels. Regenerate them
    # from owner/project authority, then require the archived canonical form
    # to reproduce exactly below.
    vx_compose_prepare_candidate \
        "$owner" "$project" "$extracted/control/compose.yaml" \
        "$candidate" "$profile" no "$extracted/binds" "$validation_secrets" \
        || return 1
    if [[ -f "$extracted/control/backup-policy.conf" ]] \
        && ! vx_compose_backup_policy_sanitize_to \
            "$extracted/control/backup-policy.conf" \
            "$candidate/backup-policy.conf"; then
        return 1
    fi
    if [[ -f "$extracted/control/simple.json" ]]; then
        install -m 0600 "$extracted/control/simple.json" "$candidate/simple.json"
    fi
    if [[ -f "$extracted/control/alerts.conf"
        && ! -L "$extracted/control/alerts.conf" ]]; then
        jq -e 'type == "object"' "$extracted/control/alerts.conf" \
            >/dev/null || return 1
        install -m 0640 \
            "$extracted/control/alerts.conf" "$candidate/alerts.conf" \
            || return 1
    fi
    normalized_archived="$(mktemp)"
    normalized_candidate="$(mktemp)"
    if ! jq -S . "$extracted/control/canonical.json" >"$normalized_archived" \
        || ! jq -S . "$candidate/canonical.json" >"$normalized_candidate"; then
        rm -f -- "$normalized_archived" "$normalized_candidate"
        return 1
    fi
    if ! cmp -s "$normalized_archived" "$normalized_candidate"; then
        rm -f -- "$normalized_archived" "$normalized_candidate"
        vx_compose_error 'restore canonical definition does not reproduce exactly'
        return 1
    fi
    rm -f -- "$normalized_archived" "$normalized_candidate"
    if [[ -f "$extracted/control/routes.conf" ]]; then
        vx_compose_routes_validate_file \
            "$owner" "$project" "$candidate/canonical.json" \
            "$extracted/control/routes.conf" || return 1
    fi
    vx_compose_restore_verify_images \
        "$owner" "$candidate/canonical.json" "$extracted/control/images.json" \
        || return 1
    install -m 0640 \
        "$extracted/control/images.json" "$candidate/images.json" || return 1
    if [[ -f "$extracted/control/routes.conf"
        && ! -L "$extracted/control/routes.conf" ]]; then
        install -m 0640 \
            "$extracted/control/routes.conf" "$candidate/routes.conf" || return 1
    else
        printf '{}\n' >"$candidate/routes.conf" || return 1
        chmod 0640 "$candidate/routes.conf" || return 1
    fi
    if [[ -f "$extracted/control/variables.env"
        && ! -L "$extracted/control/variables.env" ]]; then
        install -m 0600 \
            "$extracted/control/variables.env" "$candidate/variables.env" \
            || return 1
    else
        : >"$candidate/variables.env" || return 1
        chmod 0600 "$candidate/variables.env" || return 1
    fi
    if [[ -d "$(vx_compose_project_root "$owner" "$project")" ]]; then
        mode=update
    else
        mode=create
    fi
    vx_compose_quota_check_candidate \
        "$owner" "$project" "$candidate/policy.conf" "$mode" || return 1
    restored_storage="$(vx_compose_restore_storage_mb "$extracted")" || return 1
    measured_storage="$(vx_compose_measured_storage_mb "$owner")" || return 1
    if [[ "$mode" == update ]]; then
        for path in \
            "$(vx_compose_project_root "$owner" "$project")" \
            "$(vx_compose_project_data_root "$owner" "$project")"; do
            [[ -d "$path" ]] || continue
            size="$(du -sm -- "$path" | awk 'NR == 1 { print $1 }')" \
                || return 1
            current_project_storage=$((current_project_storage + size))
        done
        size="$(vx_compose_project_volume_storage_mb "$owner" "$project")" \
            || return 1
        current_project_storage=$((current_project_storage + size))
    fi
    projected_storage=$((measured_storage - current_project_storage + restored_storage))
    (( projected_storage >= 0 )) || projected_storage=0
    vx_compose_quota_compare \
        "$owner" DOCKER_STORAGE_MB "$projected_storage"
}

vx_compose_restore_install_backup_policy() {
    local root="$1" candidate="$2" temp
    [[ -f "$candidate/backup-policy.conf" \
        && ! -L "$candidate/backup-policy.conf" ]] || return 0
    temp="$root/.backup-policy.conf.restore"
    rm -f -- "$temp"
    install -m 0600 "$candidate/backup-policy.conf" "$temp" || return 1
    vx_compose_backup_policy_file_validate "$temp" || {
        rm -f -- "$temp"
        return 1
    }
    [[ "${VX_COMPOSE_TEST_RESTORE_BACKUP_POLICY_FAIL:-no}" != yes ]] || {
        rm -f -- "$temp"
        return 1
    }
    mv -f -- "$temp" "$root/backup-policy.conf"
}

vx_compose_restore_next_revision() {
    local owner="$1"
    local project="$2"
    local root next_revision revision_root revision_value

    root="$(vx_compose_project_root "$owner" "$project")"
    next_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    for revision_root in \
        "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$revision_root" && ! -L "$revision_root" ]] || continue
        revision_value="$(basename -- "$revision_root")"
        revision_value=$((10#$revision_value))
        (( revision_value > next_revision )) \
            && next_revision="$revision_value"
    done
    printf '%s\n' "$((next_revision + 1))"
}

vx_compose_restore_install_active() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local _extracted="$4"
    local transaction_root="${5:-}"
    local next_revision="${6:-}"
    local state="${7:-stopped}"
    local root own_transaction=no

    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -n "$next_revision" ]] \
        || next_revision="$(vx_compose_restore_next_revision \
            "$owner" "$project")" || return 1
    if [[ -z "$transaction_root" ]]; then
        transaction_root="$root/runtime/.restore-commit.$BASHPID"
        own_transaction=yes
        vx_compose_stage_candidate_revision \
            "$owner" "$project" "$candidate" "$transaction_root" \
            "$candidate/routes.conf" || return 1
    fi
    if ! vx_compose_commit_staged_revision \
        "$owner" "$project" "$transaction_root" "$next_revision" "$state"; then
        [[ "$own_transaction" != yes ]] || rm -rf -- "$transaction_root"
        return 1
    fi
    [[ "$own_transaction" != yes ]] || rm -rf -- "$transaction_root"
}

vx_compose_restore_candidate_binds_secure() {
    local owner="$1"
    local project="$2"
    local candidate="$3"

    vx_compose_bind_root_secure "$owner" "$project" || return 1
    [[ ! -f "$candidate/simple.json" ]] \
        || vx_compose_simple_bind_leaves_normalize \
            "$owner" "$project" "$candidate/canonical.json"
}

vx_compose_restore_project_existing() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local candidate="$4"
    local desired_state="$5"
    local root data_root bind_root work_root snapshot_root new_binds
    local transaction_root previous_state next_revision
    local volume candidate_only volume_archive result=1 recovery_ok=yes
    local prior_stopped=no runtime_touched=no binds_swapped=no secrets_swapped=no
    local volumes_mutated=no candidate_converged=no revision_committed=no
    local setup_failed=no

    root="$(vx_compose_project_root "$owner" "$project")"
    data_root="$(vx_compose_project_data_root "$owner" "$project")"
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    work_root="$(mktemp -d "$data_root/.restore.XXXXXX")" || return 1
    snapshot_root="$work_root/snapshot"
    new_binds="$work_root/new-binds"
    transaction_root="$root/runtime/.restore-candidate.$BASHPID"
    install -d -m 0700 \
        "$snapshot_root/control" "$snapshot_root/volumes" "$new_binds" \
        || setup_failed=yes
    if [[ "$setup_failed" != yes && -d "$extracted/binds" ]]; then
        cp -a -- "$extracted/binds/." "$new_binds/" || setup_failed=yes
    fi
    if [[ "$setup_failed" == yes ]]; then
        rm -rf -- "$work_root"
        return 1
    fi

    vx_compose_lock_acquire "$owner" "$project" || {
        rm -rf -- "$work_root"
        return 1
    }
    if ! vx_compose_active_revision_verify "$owner" "$project"; then
        vx_compose_lock_release
        rm -rf -- "$work_root"
        return 1
    fi
    previous_state="$(vx_compose_meta_get "$root/project.conf" STATE)" \
        || setup_failed=yes
    next_revision="$(vx_compose_restore_next_revision "$owner" "$project")" \
        || setup_failed=yes
    if [[ "$setup_failed" != yes ]]; then
        cp -a -- \
            "$root/compose.yaml" "$root/project.conf" "$root/policy.conf" \
            "$root/variables.env" "$root/runtime/canonical.json" \
            "$snapshot_root/control/" || setup_failed=yes
    fi
    for volume in \
        routes.conf images.json simple.json secrets.json secret-integrity.json \
        alerts.conf backup-policy.conf; do
        [[ "$setup_failed" == yes || ! -f "$root/$volume" ]] \
            || cp -a -- "$root/$volume" "$snapshot_root/control/" \
            || setup_failed=yes
    done
    [[ "$setup_failed" == yes || ! -f "$root/runtime/routes.pending.json" ]] \
        || cp -a -- "$root/runtime/routes.pending.json" \
            "$snapshot_root/control/" || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || cp -a -- "$root/secrets" "$snapshot_root/control/secrets" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || vx_compose_stage_candidate_revision \
            "$owner" "$project" "$candidate" "$transaction_root" \
            "$candidate/routes.conf" || setup_failed=yes
    if [[ "$setup_failed" != yes ]] \
        && {
            ! vx_compose_network_verify_runtime \
                "$owner" "$project" "$root/runtime/canonical.json" no \
            || ! vx_compose_volume_verify_runtime \
                "$owner" "$project" "$root/runtime/canonical.json" no \
            || ! vx_compose_network_verify_runtime \
                "$owner" "$project" "$transaction_root/canonical.json" no \
            || ! vx_compose_volume_verify_runtime \
                "$owner" "$project" "$transaction_root/canonical.json" no
        }; then
        setup_failed=yes
    fi
    if [[ "$setup_failed" == yes ]]; then
        rm -rf -- "$transaction_root" "$work_root"
        vx_compose_lock_release
        return 1
    fi
    if ! vx_compose_runtime_identity_preflight \
        "$owner" "$project" "$root/runtime/canonical.json" \
        "$root/images.json" \
        "$(vx_compose_meta_get "$root/project.conf" REVISION)" >/dev/null; then
        rm -rf -- "$transaction_root" "$work_root"
        vx_compose_lock_release
        return 1
    fi

    if [[ "$previous_state" == running ]]; then
        runtime_touched=yes
        if vx_compose_stop "$owner" "$project"; then
            prior_stopped=yes
        else
            setup_failed=yes
        fi
    fi
    if [[ "$setup_failed" != yes ]]; then
        while IFS= read -r volume; do
            if ! vx_compose_volume_export \
                "$owner" "$project" "$volume" \
                "$snapshot_root/volumes/$volume.tar.gz"; then
                setup_failed=yes
                break
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' \
            "$root/runtime/canonical.json")
    fi
    if [[ "$setup_failed" != yes ]]; then
        runtime_touched=yes
        if ! vx_compose_runtime_identity_preflight \
            "$owner" "$project" "$root/runtime/canonical.json" \
            "$root/images.json" \
            "$(vx_compose_meta_get "$root/project.conf" REVISION)" >/dev/null \
            || ! vx_compose_invoke \
                "$owner" "$project" down --remove-orphans; then
            setup_failed=yes
        fi
    fi

    if [[ "$setup_failed" != yes ]]; then
        if [[ -d "$bind_root" && ! -L "$bind_root" ]]; then
            mv -- "$bind_root" "$snapshot_root/binds" \
                || setup_failed=yes
        else
            install -d -m 0750 "$snapshot_root/binds" \
                || setup_failed=yes
        fi
    fi
    if [[ "$setup_failed" != yes ]]; then
        mv -- "$new_binds" "$bind_root" || setup_failed=yes
        [[ "$setup_failed" == yes ]] || binds_swapped=yes
    fi
    if [[ "$setup_failed" != yes ]] \
        && ! vx_compose_restore_candidate_binds_secure \
            "$owner" "$project" "$candidate"; then
        setup_failed=yes
    fi
    if [[ "$setup_failed" != yes ]]; then
        if vx_compose_restore_install_secrets \
            "$root" "$extracted/restore-secrets" \
            "$extracted/control/secrets.json" \
            "$extracted/control/secret-integrity.json"; then
            secrets_swapped=yes
        else
            setup_failed=yes
        fi
    fi

    if [[ "$setup_failed" != yes ]]; then
        while IFS= read -r volume; do
            volumes_mutated=yes
            if ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                vx_compose_volume_create "$owner" "$project" "$volume" \
                || ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                    vx_compose_volume_clear "$owner" "$project" "$volume" \
                || ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                    vx_compose_volume_import \
                        "$owner" "$project" "$volume" \
                        "$extracted/volumes/$volume.tar.gz"; then
                setup_failed=yes
                break
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' \
            "$transaction_root/canonical.json")
    fi

    if [[ "$setup_failed" != yes ]] \
        && VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
            VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
            VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
            VX_COMPOSE_INVOKE_ENV_OVERRIDE="$candidate/variables.env" \
            VX_COMPOSE_POLICY_OVERRIDE="$transaction_root/policy.conf" \
            VX_COMPOSE_ROUTES_FILE_OVERRIDE="$transaction_root/routes.conf" \
            VX_COMPOSE_ROUTES_DEFER_COMMIT=yes \
            VX_COMPOSE_LIFECYCLE_DEFER_COMMIT=yes \
            vx_compose_deploy "$owner" "$project"; then
        candidate_converged=yes
    else
        setup_failed=yes
    fi
    if [[ "$setup_failed" != yes && "$desired_state" == stopped ]] \
        && ! VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
            VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
            VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
            VX_COMPOSE_INVOKE_ENV_OVERRIDE="$candidate/variables.env" \
            VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE=yes \
            vx_compose_stop "$owner" "$project"; then
        setup_failed=yes
    fi
    if [[ "$setup_failed" != yes \
        && -f "$candidate/backup-policy.conf" ]]; then
        if ! vx_compose_restore_install_backup_policy "$root" "$candidate"; then
            setup_failed=yes
        fi
    fi
    if [[ "$setup_failed" != yes ]] \
        && vx_compose_restore_install_active \
            "$owner" "$project" "$candidate" "$extracted" \
            "$transaction_root" "$next_revision" "$desired_state"; then
        revision_committed=yes
        if install -m 0600 \
            "$candidate/variables.env" "$root/.variables.env.restore" \
            && mv -- "$root/.variables.env.restore" "$root/variables.env"; then
            result=0
        else
            setup_failed=yes
        fi
    else
        setup_failed=yes
    fi
    if [[ "$result" -eq 0 ]] \
        && ! vx_compose_audit "$root" restore succeeded; then
        result=1
        setup_failed=yes
    fi

    if [[ "$result" -ne 0 ]]; then
        if [[ "$candidate_converged" == yes || "$secrets_swapped" == yes
            || "$volumes_mutated" == yes ]]; then
            VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$transaction_root/images.json" \
                VX_COMPOSE_INVOKE_REVISION_OVERRIDE="$next_revision" \
                VX_COMPOSE_INVOKE_ENV_OVERRIDE="$candidate/variables.env" \
                vx_compose_invoke "$owner" "$project" down --remove-orphans \
                >/dev/null 2>&1 || recovery_ok=no
        fi
        if [[ "$binds_swapped" == yes ]]; then
            rm -rf -- "$bind_root"
            mv -- "$snapshot_root/binds" "$bind_root" || recovery_ok=no
            vx_compose_bind_root_secure "$owner" "$project" || recovery_ok=no
        fi
        if [[ "$secrets_swapped" == yes ]]; then
            rm -rf -- "$root/secrets"
            if [[ -d "$root/.secrets.before-restore" ]]; then
                mv -- "$root/.secrets.before-restore" "$root/secrets" \
                    || recovery_ok=no
            else
                cp -a -- "$snapshot_root/control/secrets" "$root/secrets" \
                    || recovery_ok=no
            fi
        fi
        rm -rf -- "$root/.secrets.restore" "$root/.secrets.before-restore"
        for volume in compose.yaml project.conf policy.conf variables.env; do
            cp -a -- "$snapshot_root/control/$volume" "$root/$volume" \
                || recovery_ok=no
        done
        cp -a -- "$snapshot_root/control/canonical.json" \
            "$root/runtime/canonical.json" || recovery_ok=no
        rm -f -- \
            "$root/routes.conf" "$root/images.json" "$root/simple.json" \
            "$root/secrets.json" "$root/secret-integrity.json" \
            "$root/alerts.conf" "$root/backup-policy.conf" \
            "$root/runtime/routes.pending.json" "$root/.variables.env.restore"
        for volume in \
            routes.conf images.json simple.json secrets.json \
            secret-integrity.json alerts.conf backup-policy.conf; do
            [[ ! -f "$snapshot_root/control/$volume" ]] \
                || cp -a -- "$snapshot_root/control/$volume" "$root/$volume" \
                || recovery_ok=no
        done
        [[ ! -f "$snapshot_root/control/routes.pending.json" ]] \
            || cp -a -- "$snapshot_root/control/routes.pending.json" \
                "$root/runtime/routes.pending.json" || recovery_ok=no
        if [[ "$revision_committed" == yes ]]; then
            rm -rf -- "$root/revisions/$(
                printf '%06d' "$next_revision"
            )" || recovery_ok=no
        fi
        candidate_only="$(
            jq -nr \
                --slurpfile prior "$snapshot_root/control/canonical.json" \
                --slurpfile candidate "$transaction_root/canonical.json" '
                    (($candidate[0].volumes // {}) | keys)
                    - (($prior[0].volumes // {}) | keys)
                    | .[]
                '
        )" || recovery_ok=no
        while IFS= read -r volume; do
            [[ -n "$volume" ]] || continue
            if VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$transaction_root/canonical.json" \
                vx_compose_volume_inspect \
                    "$owner" "$project" "$volume" \
                    "$transaction_root/canonical.json" >/dev/null 2>&1; then
                vx_compose_volume_remove \
                    "$owner" "$project" "$volume" \
                    "$transaction_root/canonical.json" >/dev/null 2>&1 \
                    || recovery_ok=no
            fi
        done <<<"$candidate_only"
        if [[ "$volumes_mutated" == yes ]]; then
            for volume_archive in "$snapshot_root"/volumes/*.tar.gz; do
                [[ -f "$volume_archive" ]] || continue
                volume="$(basename -- "$volume_archive" .tar.gz)"
                vx_compose_volume_clear "$owner" "$project" "$volume" \
                    && vx_compose_volume_import \
                        "$owner" "$project" "$volume" "$volume_archive" \
                    || recovery_ok=no
            done
        fi
        if [[ "$previous_state" == running ]]; then
            vx_compose_deploy "$owner" "$project" || recovery_ok=no
        elif [[ "$runtime_touched" == yes || "$prior_stopped" == yes
            || "$candidate_converged" == yes ]]; then
            vx_compose_deploy "$owner" "$project" \
                && vx_compose_stop "$owner" "$project" || recovery_ok=no
        fi
        if [[ "$recovery_ok" == yes ]]; then
            cp -a -- "$snapshot_root/control/project.conf" \
                "$root/project.conf" || recovery_ok=no
        fi
        if [[ "$recovery_ok" != yes ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
            vx_compose_audit "$root" restore failed \
                'pre-restore state recovery failed; operator action required' \
                || :
        else
            vx_compose_audit "$root" restore failed \
                'candidate rejected; exact prior state restored' || :
        fi
    else
        rm -rf -- "$root/.secrets.before-restore" "$root/.secrets.restore"
    fi
    rm -rf -- "$transaction_root" "$work_root"
    vx_compose_lock_release
    return "$result"
}

vx_compose_restore_project_new() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local candidate="$4"
    local desired_state="$5"
    local profile root data_root bind_root volume result=0 work_root
    local data_root_existed=no bind_root_existed=no runtime_name docker_bin
    local runtime_identity bind_mutated=no recovery_ok=yes

    profile="$(vx_compose_meta_get "$extracted/control/project.conf" PROFILE)" \
        || return 1
    data_root="$(vx_compose_project_data_root "$owner" "$project")"
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    if [[ -e "$data_root" || -L "$data_root" ]]; then
        [[ -d "$data_root" && ! -L "$data_root" ]] || return 1
        data_root_existed=yes
    fi
    if [[ -e "$bind_root" || -L "$bind_root" ]]; then
        [[ -d "$bind_root" && ! -L "$bind_root" ]] || return 1
        bind_root_existed=yes
    fi
    work_root="$(mktemp -d)" || return 1
    install -d -m 0700 "$work_root/volumes" || {
        rm -rf -- "$work_root"
        return 1
    }
    if ! vx_compose_store_new "$owner" "$project" "$profile" "$candidate"; then
        rm -rf -- "$work_root"
        return 1
    fi
    root="$(vx_compose_project_root "$owner" "$project")"
    if ! install -m 0600 "$candidate/variables.env" "$root/variables.env"; then
        result=1
    fi
    if [[ "$result" -eq 0 && -f "$candidate/backup-policy.conf" ]] \
        && ! vx_compose_restore_install_backup_policy "$root" "$candidate"; then
        result=1
    fi
    if [[ "$result" -eq 0 ]]; then
        bind_mutated=yes
        if [[ "$bind_root_existed" == yes ]]; then
            mv -- "$bind_root" "$work_root/binds" || result=1
        else
            rm -rf -- "$bind_root" || result=1
        fi
    fi
    if [[ "$result" -eq 0 ]] \
        && {
            ! install -d -m 0750 "$bind_root" \
            || ! cp -a -- "$extracted/binds/." "$bind_root/" \
            || ! vx_compose_bind_root_secure "$owner" "$project"
        }; then
        result=1
    fi
    if [[ "$result" -eq 0 ]] \
        && ! vx_compose_restore_install_secrets \
            "$root" "$extracted/restore-secrets" \
            "$extracted/control/secrets.json" \
            "$extracted/control/secret-integrity.json"; then
        result=1
    fi
    [[ "$result" -ne 0 ]] || rm -rf -- "$root/.secrets.before-restore"
    docker_bin="$(vx_compose_docker_bin)" || result=1
    if [[ "$result" -eq 0 ]]; then
        while IFS= read -r volume; do
            runtime_name="$(vx_compose_volume_runtime_name \
                "$owner" "$project" "$volume")" || {
                    result=1
                    break
                }
            if "$docker_bin" volume inspect "$runtime_name" >/dev/null 2>&1; then
                if ! vx_compose_volume_export \
                    "$owner" "$project" "$volume" \
                    "$work_root/volumes/$volume.tar.gz"; then
                    result=1
                    break
                fi
            fi
            if ! vx_compose_volume_create "$owner" "$project" "$volume" \
                || ! vx_compose_volume_clear "$owner" "$project" "$volume" \
                || ! vx_compose_volume_import \
                    "$owner" "$project" "$volume" \
                    "$extracted/volumes/$volume.tar.gz"; then
                result=1
                break
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' "$candidate/canonical.json")
    fi
    if [[ "$result" -eq 0 ]]; then
        vx_compose_deploy "$owner" "$project" || result=1
        if [[ "$result" -eq 0 && "$desired_state" == stopped ]]; then
            vx_compose_stop "$owner" "$project" || result=1
        fi
    fi
    if [[ "$result" -eq 0 ]] \
        && ! vx_compose_audit "$root" restore succeeded; then
        result=1
    fi
    if [[ "$result" -ne 0 ]]; then
        runtime_identity="$(
            vx_compose_runtime_identity_preflight \
                "$owner" "$project" "$root/runtime/canonical.json" \
                "$root/images.json" 1
        )" || runtime_identity=
        if [[ -n "$runtime_identity" ]]; then
            vx_compose_invoke "$owner" "$project" down --remove-orphans \
                >/dev/null 2>&1 || recovery_ok=no
        else
            recovery_ok=no
        fi
        while IFS= read -r volume; do
            runtime_name="$(vx_compose_volume_runtime_name \
                "$owner" "$project" "$volume")" || continue
            if [[ -f "$work_root/volumes/$volume.tar.gz" ]]; then
                vx_compose_volume_clear "$owner" "$project" "$volume" \
                    && vx_compose_volume_import \
                        "$owner" "$project" "$volume" \
                        "$work_root/volumes/$volume.tar.gz" || recovery_ok=no
            elif vx_compose_volume_inspect \
                "$owner" "$project" "$volume" >/dev/null 2>&1; then
                vx_compose_volume_remove \
                    "$owner" "$project" "$volume" >/dev/null 2>&1 \
                    || recovery_ok=no
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' "$candidate/canonical.json")
        if [[ "$bind_mutated" == yes ]]; then
            rm -rf -- "$bind_root" || recovery_ok=no
            if [[ "$bind_root_existed" == yes && -d "$work_root/binds" ]]; then
                mv -- "$work_root/binds" "$bind_root" || recovery_ok=no
                vx_compose_bind_root_secure "$owner" "$project" \
                    || recovery_ok=no
            fi
        fi
        if [[ "$recovery_ok" == yes ]]; then
            vx_compose_remove_control_root "$owner" "$project" \
                || recovery_ok=no
        fi
        if [[ "$recovery_ok" == yes && "$data_root_existed" != yes ]]; then
            rm -rf -- "$data_root" || recovery_ok=no
        fi
        if [[ "$recovery_ok" != yes ]]; then
            vx_compose_update_state "$owner" "$project" restore-required || :
            vx_compose_audit "$root" restore failed \
                'new-project restore recovery failed; operator action required' \
                || :
        fi
        rm -rf -- "$work_root"
        return 1
    fi
    rm -rf -- "$work_root"
}

vx_compose_restore_project() {
    local owner="$1"
    local project="$2"
    local archive="$3"
    local mode="${4:-validate}"
    local work_root extracted candidate desired_state result
    local apply_locked=no ports_locked=no quota_locked=no route_locked=no

    [[ "$mode" == validate || "$mode" == apply ]] \
        || {
            vx_compose_error 'restore mode must be validate or apply'
            return 1
        }
    work_root="$(mktemp -d)"
    extracted="$work_root/extracted"
    candidate="$work_root/candidate"
    if ! vx_compose_restore_archive_validate \
        "$owner" "$project" "$archive" "$extracted"; then
        rm -rf -- "$work_root"
        return 1
    fi
    desired_state="$(jq -r '.STATE' "$extracted/manifest.json")"
    if [[ "$mode" == validate ]]; then
        if ! vx_compose_restore_prepare \
            "$owner" "$project" "$extracted" "$candidate"; then
            rm -rf -- "$work_root"
            return 1
        fi
        jq -n \
            --arg owner "$owner" \
            --arg project "$project" \
            --arg state "$desired_state" \
            '{OWNER: $owner, PROJECT: $project, STATE: $state, VALID: true}'
        rm -rf -- "$work_root"
        return
    fi
    vx_compose_lock_acquire "$owner" "$project" || {
        rm -rf -- "$work_root"
        return 1
    }
    apply_locked=yes
    vx_compose_ports_lock_acquire || {
        vx_compose_lock_release
        rm -rf -- "$work_root"
        return 1
    }
    ports_locked=yes
    vx_compose_owner_quota_lock_acquire "$owner" || {
        vx_compose_ports_lock_release
        vx_compose_lock_release
        rm -rf -- "$work_root"
        return 1
    }
    quota_locked=yes
    vx_compose_routes_lock_acquire "$owner" || {
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        rm -rf -- "$work_root"
        return 1
    }
    route_locked=yes
    if ! vx_compose_restore_prepare \
        "$owner" "$project" "$extracted" "$candidate"; then
        vx_compose_routes_lock_release
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        rm -rf -- "$work_root"
        return 1
    fi
    if [[ -d "$(vx_compose_project_root "$owner" "$project")" ]]; then
        vx_compose_restore_project_existing \
            "$owner" "$project" "$extracted" "$candidate" "$desired_state"
        result=$?
    else
        vx_compose_restore_project_new \
            "$owner" "$project" "$extracted" "$candidate" "$desired_state"
        result=$?
    fi
    rm -rf -- "$work_root"
    [[ "$route_locked" != yes ]] || vx_compose_routes_lock_release
    [[ "$quota_locked" != yes ]] || vx_compose_owner_quota_lock_release
    [[ "$ports_locked" != yes ]] || vx_compose_ports_lock_release
    [[ "$apply_locked" != yes ]] || vx_compose_lock_release
    [[ "$result" -eq 0 ]] && vx_compose_refresh_counters "$owner"
    return "$result"
}

vx_compose_restore_user_projects() {
    local owner="$1"
    local source_root="$2"
    local archive project

    vx_compose_require_owner "$owner" || return 1
    [[ -d "$source_root" && ! -L "$source_root" ]] || return 0
    for archive in "$source_root"/*.tar.gz; do
        [[ -f "$archive" && ! -L "$archive" ]] || continue
        project="$(basename -- "$archive" .tar.gz)"
        vx_compose_require_project_key "$project" || return 1
        vx_compose_restore_project "$owner" "$project" "$archive" apply \
            || return 1
    done
}

vx_compose_restore_user_data_roots_prepare() {
    local owner="$1"
    local source_root="$2"
    local archive project data_root work_root result=0 index
    local -a archives=() projects=() transitioned=()

    vx_compose_require_owner "$owner" || return 1
    [[ ! -e "$source_root" && ! -L "$source_root" ]] && return 0
    [[ -d "$source_root" && ! -L "$source_root" ]] || return 1
    for archive in "$source_root"/*.tar.gz; do
        [[ ! -e "$archive" && ! -L "$archive" ]] && continue
        [[ -f "$archive" && ! -L "$archive" ]] || return 1
        project="$(basename -- "$archive" .tar.gz)"
        vx_compose_require_project_key "$project" || return 1
        archives+=("$archive")
        projects+=("$project")
    done
    ((${#archives[@]} > 0)) || return 0
    work_root="$(mktemp -d)" || return 1
    chmod 0700 "$work_root" || {
        rm -rf -- "$work_root"
        return 1
    }
    for index in "${!archives[@]}"; do
        vx_compose_restore_archive_validate \
            "$owner" "${projects[$index]}" "${archives[$index]}" \
            "$work_root/${projects[$index]}" || {
            rm -rf -- "$work_root"
            return 1
        }
    done
    for project in "${projects[@]}"; do
        data_root="$(vx_compose_project_data_root "$owner" "$project")"
        [[ ! -e "$data_root" && ! -L "$data_root" ]] && continue
        if [[ ! -d "$data_root" || -L "$data_root" ]] \
            || ! vx_compose_prepare_legacy_project_data_roots \
                "$owner" "$project" restore; then
            result=1
            break
        fi
        transitioned+=("$project")
    done
    if [[ "$result" -ne 0 ]]; then
        for ((index = ${#transitioned[@]} - 1; index >= 0; index--)); do
            vx_compose_rollback_legacy_project_data_roots \
                "$owner" "${transitioned[$index]}" || :
        done
    fi
    rm -rf -- "$work_root"
    return "$result"
}
