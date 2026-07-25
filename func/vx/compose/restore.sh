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
        control/project.conf|control/policy.conf|control/variables.env|\
        control/images.json|control/secrets.json|control/audit.log|\
        control/routes.conf|control/revisions|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/compose.yaml|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/canonical.json|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/manifest.sha256|\
        control/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]/policy.conf|\
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
        expected_sha="$(jq -er --arg secret "$secret" \
            '.[$secret].SHA256 | select(test("^[a-f0-9]{64}$"))' "$metadata")" \
            || return 1
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
    local new_root="$root/.secrets.restore"
    local old_root="$root/.secrets.before-restore"
    local secret

    [[ ! -e "$new_root" && ! -e "$old_root" ]] || return 1
    install -d -m 0700 "$new_root"
    for secret in "$secret_source"/*; do
        [[ -f "$secret" && ! -L "$secret" ]] || continue
        install -m 0600 "$secret" "$new_root/$(basename -- "$secret")"
    done
    mv -- "$root/secrets" "$old_root"
    mv -- "$new_root" "$root/secrets"
    install -m 0600 "$metadata" "$root/secrets.json"
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
    profile="$(vx_compose_meta_get "$extracted/control/project.conf" PROFILE)" \
        || return 1
    [[ "$archived_owner" == "$owner" && "$archived_project" == "$project" ]] \
        || {
            vx_compose_error 'restore control metadata does not match the target'
            return 1
        }
    vx_compose_profile_is_available "$profile" \
        || {
            vx_compose_error 'restore profile is not currently available'
            return 1
        }
    vx_compose_restore_prepare_secrets \
        "$owner" "$project" "$extracted" "$validation_secrets" || return 1
    vx_compose_prepare_candidate \
        "$owner" "$project" "$extracted/control/compose.yaml" \
        "$candidate" "$profile" yes "$extracted/binds" "$validation_secrets" \
        || return 1
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
    vx_compose_restore_verify_images \
        "$owner" "$candidate/canonical.json" "$extracted/control/images.json" \
        || return 1
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

vx_compose_restore_install_active() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local extracted="$4"
    local root metadata revision next_revision revision_name temp_revision
    local profile created canonical_sha name

    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    revision="$(vx_compose_meta_get "$metadata" REVISION)"
    next_revision=$((revision + 1))
    printf -v revision_name '%06d' "$next_revision"
    temp_revision="$root/revisions/.${revision_name}.restore"
    vx_compose_install_revision_files "$candidate" "$temp_revision" || return 1
    if [[ -f "$extracted/control/images.json" ]]; then
        install -m 0640 \
            "$extracted/control/images.json" "$temp_revision/images.json"
    fi
    mv -- "$temp_revision" "$root/revisions/$revision_name" || return 1
    install -m 0640 "$candidate/compose.yaml" "$root/compose.yaml"
    install -m 0640 "$candidate/canonical.json" "$root/runtime/canonical.json"
    install -m 0640 "$candidate/policy.conf" "$root/policy.conf"
    for name in variables.env routes.conf; do
        if [[ -f "$extracted/control/$name" ]]; then
            install -m 0600 "$extracted/control/$name" "$root/$name"
        else
            rm -f -- "$root/$name"
        fi
    done
    rm -f -- "$root/images.json"
    vx_compose_restore_install_secrets \
        "$root" "$extracted/restore-secrets" \
        "$extracted/control/secrets.json" || return 1
    profile="$(vx_compose_meta_get "$metadata" PROFILE)"
    created="$(vx_compose_meta_get "$metadata" CREATED)"
    canonical_sha="$(vx_compose_candidate_sha "$candidate")"
    vx_compose_write_metadata \
        "$root" "$owner" "$project" "$profile" stopped "$next_revision" \
        "$created" "$(vx_compose_now)" "$canonical_sha"
}

vx_compose_restore_project_existing() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local candidate="$4"
    local desired_state="$5"
    local root data_root bind_root transaction_root snapshot_root new_binds
    local previous_state volume result=1 revision

    root="$(vx_compose_project_root "$owner" "$project")"
    data_root="$(vx_compose_project_data_root "$owner" "$project")"
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    transaction_root="$(mktemp -d "$data_root/.restore.XXXXXX")" || return 1
    snapshot_root="$transaction_root/snapshot"
    new_binds="$transaction_root/new-binds"
    install -d -m 0700 \
        "$snapshot_root/control" "$snapshot_root/volumes" "$new_binds"
    cp -a -- "$extracted/binds/." "$new_binds/"

    vx_compose_lock_acquire "$owner" "$project"
    previous_state="$(vx_compose_meta_get "$root/project.conf" STATE)" || {
        vx_compose_lock_release
        rm -rf -- "$transaction_root"
        return 1
    }
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)"
    cp -a -- \
        "$root/compose.yaml" "$root/project.conf" "$root/policy.conf" \
        "$root/variables.env" "$root/runtime/canonical.json" \
        "$snapshot_root/control/"
    [[ -f "$root/routes.conf" ]] \
        && cp -a -- "$root/routes.conf" "$snapshot_root/control/"
    [[ -f "$root/images.json" ]] \
        && cp -a -- "$root/images.json" "$snapshot_root/control/"
    cp -a -- "$root/secrets" "$snapshot_root/control/secrets"
    [[ -f "$root/secrets.json" ]] \
        && cp -a -- "$root/secrets.json" "$snapshot_root/control/"
    if [[ "$previous_state" == running ]]; then
        vx_compose_invoke "$owner" "$project" stop --timeout 30 || {
            vx_compose_lock_release
            rm -rf -- "$transaction_root"
            return 1
        }
        vx_compose_update_state "$owner" "$project" stopped
    fi
    while IFS= read -r volume; do
        vx_compose_volume_export \
            "$owner" "$project" "$volume" \
            "$snapshot_root/volumes/$volume.tar.gz" || {
                vx_compose_lock_release
                rm -rf -- "$transaction_root"
                return 1
            }
    done < <(jq -r '(.volumes // {}) | keys[]' "$root/runtime/canonical.json")

    vx_compose_invoke "$owner" "$project" down --remove-orphans || {
        vx_compose_lock_release
        rm -rf -- "$transaction_root"
        return 1
    }
    if [[ -d "$bind_root" && ! -L "$bind_root" ]]; then
        mv -- "$bind_root" "$snapshot_root/binds"
    else
        install -d -m 0750 "$snapshot_root/binds"
    fi
    mv -- "$new_binds" "$bind_root"
    if vx_compose_restore_install_active \
        "$owner" "$project" "$candidate" "$extracted"; then
        result=0
        while IFS= read -r volume; do
            if ! vx_compose_volume_create "$owner" "$project" "$volume" \
                || ! vx_compose_volume_clear "$owner" "$project" "$volume" \
                || ! vx_compose_volume_import \
                    "$owner" "$project" "$volume" \
                    "$extracted/volumes/$volume.tar.gz"; then
                result=1
                break
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' \
            "$candidate/canonical.json")
        if [[ "$result" -eq 0 ]]; then
            vx_compose_project_resolve_images "$owner" "$project" \
                && vx_compose_invoke "$owner" "$project" \
                    up -d --remove-orphans --wait \
                    --wait-timeout "$VX_COMPOSE_WAIT_TIMEOUT" \
                || result=1
            if [[ "$result" -eq 0 && "$desired_state" == stopped ]]; then
                vx_compose_invoke "$owner" "$project" stop --timeout 30 \
                    || result=1
            fi
            if [[ "$result" -eq 0 ]]; then
                vx_compose_update_state "$owner" "$project" "$desired_state"
            fi
        fi
    fi

    if [[ "$result" -ne 0 ]]; then
        vx_compose_invoke "$owner" "$project" down --remove-orphans \
            >/dev/null 2>&1 || true
        rm -rf -- "$bind_root"
        mv -- "$snapshot_root/binds" "$bind_root"
        cp -a -- "$snapshot_root/control/compose.yaml" "$root/compose.yaml"
        cp -a -- "$snapshot_root/control/project.conf" "$root/project.conf"
        cp -a -- "$snapshot_root/control/policy.conf" "$root/policy.conf"
        cp -a -- "$snapshot_root/control/variables.env" "$root/variables.env"
        cp -a -- \
            "$snapshot_root/control/canonical.json" "$root/runtime/canonical.json"
        rm -f -- "$root/routes.conf" "$root/images.json"
        [[ -f "$snapshot_root/control/routes.conf" ]] \
            && cp -a -- "$snapshot_root/control/routes.conf" "$root/routes.conf"
        [[ -f "$snapshot_root/control/images.json" ]] \
            && cp -a -- "$snapshot_root/control/images.json" "$root/images.json"
        rm -rf -- "$root/secrets"
        cp -a -- "$snapshot_root/control/secrets" "$root/secrets"
        rm -f -- "$root/secrets.json"
        [[ -f "$snapshot_root/control/secrets.json" ]] \
            && cp -a -- "$snapshot_root/control/secrets.json" "$root/secrets.json"
        rm -rf -- "$root/.secrets.before-restore" "$root/.secrets.restore"
        for volume in "$snapshot_root"/volumes/*.tar.gz; do
            [[ -f "$volume" ]] || continue
            volume="$(basename -- "$volume" .tar.gz)"
            vx_compose_volume_clear "$owner" "$project" "$volume" \
                && vx_compose_volume_import \
                    "$owner" "$project" "$volume" \
                    "$snapshot_root/volumes/$volume.tar.gz" || true
        done
        rm -rf -- "$root/revisions/$(printf '%06d' "$((revision + 1))")"
        vx_compose_project_resolve_images "$owner" "$project" \
            && vx_compose_invoke "$owner" "$project" \
                up -d --wait --wait-timeout "$VX_COMPOSE_WAIT_TIMEOUT" \
            && {
                if [[ "$previous_state" == stopped ]]; then
                    vx_compose_invoke "$owner" "$project" stop --timeout 30
                fi
                vx_compose_update_state \
                    "$owner" "$project" "$previous_state"
            } || true
        vx_compose_audit "$root" restore failed
    else
        rm -rf -- "$root/.secrets.before-restore"
        vx_compose_audit "$root" restore succeeded
    fi
    vx_compose_lock_release
    rm -rf -- "$transaction_root"
    return "$result"
}

vx_compose_restore_project_new() {
    local owner="$1"
    local project="$2"
    local extracted="$3"
    local candidate="$4"
    local desired_state="$5"
    local profile root bind_root volume result=0

    profile="$(vx_compose_meta_get "$extracted/control/project.conf" PROFILE)" \
        || return 1
    vx_compose_store_new "$owner" "$project" "$profile" "$candidate" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    if ! vx_compose_restore_install_secrets \
        "$root" "$extracted/restore-secrets" \
        "$extracted/control/secrets.json"; then
        vx_compose_remove_control_root "$owner" "$project"
        rm -rf -- "$(vx_compose_project_data_root "$owner" "$project")"
        return 1
    fi
    rm -rf -- "$root/.secrets.before-restore"
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    rm -rf -- "$bind_root"
    install -d -m 0750 "$bind_root"
    cp -a -- "$extracted/binds/." "$bind_root/"
    while IFS= read -r volume; do
        if ! vx_compose_volume_create "$owner" "$project" "$volume" \
            || ! vx_compose_volume_import \
                "$owner" "$project" "$volume" \
                "$extracted/volumes/$volume.tar.gz"; then
            result=1
            break
        fi
    done < <(jq -r '(.volumes // {}) | keys[]' "$candidate/canonical.json")
    if [[ "$result" -eq 0 ]]; then
        vx_compose_deploy "$owner" "$project" || result=1
        if [[ "$result" -eq 0 && "$desired_state" == stopped ]]; then
            vx_compose_stop "$owner" "$project" || result=1
        fi
    fi
    if [[ "$result" -ne 0 ]]; then
        vx_compose_invoke "$owner" "$project" down --remove-orphans \
            >/dev/null 2>&1 || true
        while IFS= read -r volume; do
            if vx_compose_volume_inspect \
                "$owner" "$project" "$volume" >/dev/null 2>&1; then
                "$(vx_compose_docker_bin)" volume rm \
                    "$(vx_compose_volume_runtime_name \
                        "$owner" "$project" "$volume")" >/dev/null 2>&1 || true
            fi
        done < <(jq -r '(.volumes // {}) | keys[]' "$candidate/canonical.json")
        vx_compose_remove_control_root "$owner" "$project"
        rm -rf -- "$(vx_compose_project_data_root "$owner" "$project")"
        return 1
    fi
    vx_compose_audit "$root" restore succeeded
}

vx_compose_restore_project() {
    local owner="$1"
    local project="$2"
    local archive="$3"
    local mode="${4:-validate}"
    local work_root extracted candidate desired_state result

    [[ "$mode" == validate || "$mode" == apply ]] \
        || {
            vx_compose_error 'restore mode must be validate or apply'
            return 1
        }
    work_root="$(mktemp -d)"
    extracted="$work_root/extracted"
    candidate="$work_root/candidate"
    if ! vx_compose_restore_archive_validate \
        "$owner" "$project" "$archive" "$extracted" \
        || ! vx_compose_restore_prepare \
            "$owner" "$project" "$extracted" "$candidate"; then
        rm -rf -- "$work_root"
        return 1
    fi
    desired_state="$(jq -r '.STATE' "$extracted/manifest.json")"
    if [[ "$mode" == validate ]]; then
        jq -n \
            --arg owner "$owner" \
            --arg project "$project" \
            --arg state "$desired_state" \
            '{OWNER: $owner, PROJECT: $project, STATE: $state, VALID: true}'
        rm -rf -- "$work_root"
        return
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
