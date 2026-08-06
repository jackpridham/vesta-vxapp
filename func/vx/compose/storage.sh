#!/usr/bin/env bash

vx_compose_projects_root() {
    printf '%s/data/users/%s/docker-projects\n' "$VESTA" "$1"
}

vx_compose_project_root() {
    printf '%s/%s\n' "$(vx_compose_projects_root "$1")" "$2"
}

vx_compose_project_data_root() {
    printf '%s/%s/docker/%s\n' "$HOMEDIR" "$1" "$2"
}

vx_compose_prepare_project_data_roots() {
    local owner="$1"
    local project="${2:-}"
    local project_arg=-

    [[ -z "$project" ]] || project_arg="$project"
    perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
        "$owner" "$HOMEDIR" "$project_arg" - normal
}

vx_compose_prepare_legacy_project_data_roots() {
    local owner="$1"
    local project="$2"
    local transition="${3:-initial}"
    local marker_root marker lock_fd temp prior_state=absent authority_uid
    local snapshot_root="${4:-}"

    [[ "$transition" == initial || "$transition" == restore ]] || return 1
    [[ -z "$snapshot_root" || "$transition" == restore ]] || return 1
    authority_uid="$EUID"

    if [[ -n "$snapshot_root" ]]; then
        [[ -d "$snapshot_root" && ! -L "$snapshot_root"
            && "$(stat -c '%a' "$snapshot_root")" == 700
            && "$(stat -c '%u' "$snapshot_root")" == "$authority_uid"
            && -z "$(find "$snapshot_root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
            || return 1
    fi

    marker_root="$(vx_compose_projects_root "$owner")/.legacy-data-authority"
    if (( EUID == 0 )); then
        install -d -m 0700 -o root -g root "$marker_root" || return 1
    else
        install -d -m 0700 "$marker_root" || return 1
    fi
    marker="$marker_root/$project.conf"
    exec {lock_fd}>"$marker_root/$project.lock" || return 1
    flock -x "$lock_fd" || {
        exec {lock_fd}>&-
        return 1
    }
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker"
            && "$(stat -c '%a' "$marker")" == 600
            && "$(stat -c '%u' "$marker")" == "$authority_uid" ]] || {
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        }
        prior_state="$(cat "$marker")"
        [[ "$prior_state" == "STATE='complete'"
            || "$prior_state" == "STATE='pending'" ]] || {
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        }
        if [[ "$transition" == initial ]]; then
            if [[ "$prior_state" == "STATE='complete'" ]]; then
                local result=0
                vx_compose_prepare_project_data_roots "$owner" "$project" \
                    || result=$?
                flock -u "$lock_fd"
                exec {lock_fd}>&-
                return "$result"
            fi
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        fi
    fi
    if [[ -n "$snapshot_root" ]]; then
        if [[ "$prior_state" == absent ]]; then
            install -m 0600 /dev/null "$snapshot_root/absent" || {
                flock -u "$lock_fd"
                exec {lock_fd}>&-
                return 1
            }
        else
            cp -p -- "$marker" "$snapshot_root/marker" || {
                flock -u "$lock_fd"
                exec {lock_fd}>&-
                return 1
            }
        fi
    fi
    temp="$(mktemp "$marker_root/.legacy-transition.XXXXXX")" || {
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    }
    if ! printf '%s\n' "STATE='pending'" >"$temp" \
        || ! chmod 0600 "$temp" \
        || ! mv -f -- "$temp" "$marker"; then
        rm -f -- "$temp"
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    if perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
        "$owner" "$HOMEDIR" "$project" - legacy; then
        temp="$(mktemp "$marker_root/.legacy-transition.XXXXXX")" || {
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        }
        if ! printf '%s\n' "STATE='complete'" >"$temp" \
            || ! chmod 0600 "$temp" \
            || ! mv -f -- "$temp" "$marker"; then
            rm -f -- "$temp"
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        fi
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 0
    fi
    rm -f -- "$temp"
    [[ "$transition" != initial || "$prior_state" != absent ]] \
        || rm -f -- "$marker"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
}

vx_compose_rollback_legacy_project_data_roots() {
    local owner="$1"
    local project="$2"
    local marker_root marker lock_fd result=0

    marker_root="$(vx_compose_projects_root "$owner")/.legacy-data-authority"
    marker="$marker_root/$project.conf"
    [[ -d "$marker_root" && ! -L "$marker_root" ]] || return 1
    exec {lock_fd}>"$marker_root/$project.lock" || return 1
    flock -x "$lock_fd" || {
        exec {lock_fd}>&-
        return 1
    }
    [[ -f "$marker" && ! -L "$marker"
        && "$(cat "$marker")" == "STATE='complete'" ]] || result=1
    if [[ "$result" -eq 0 ]]; then
        perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
            "$owner" "$HOMEDIR" "$project" - rollback || result=$?
    fi
    [[ "$result" -ne 0 ]] || rm -f -- "$marker"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return "$result"
}

vx_compose_restore_rollback_legacy_project_data_roots() {
    local owner="$1"
    local project="$2"
    local snapshot_root="$3"
    local prior_marker
    local marker_root marker lock_fd result=0 temp authority_uid prior_state
    local current_state

    authority_uid="$EUID"
    [[ -d "$snapshot_root" && ! -L "$snapshot_root"
        && "$(stat -c '%a' "$snapshot_root")" == 700
        && "$(stat -c '%u' "$snapshot_root")" == "$authority_uid" ]] \
        || return 1
    if [[ -f "$snapshot_root/absent" && ! -L "$snapshot_root/absent"
        && "$(stat -c '%a' "$snapshot_root/absent")" == 600
        && "$(stat -c '%u' "$snapshot_root/absent")" == "$authority_uid"
        && ! -e "$snapshot_root/marker" && ! -L "$snapshot_root/marker" ]]; then
        prior_marker=-
    elif [[ -f "$snapshot_root/marker" && ! -L "$snapshot_root/marker"
        && ! -e "$snapshot_root/absent" && ! -L "$snapshot_root/absent" ]]; then
        prior_marker="$snapshot_root/marker"
    else
        return 1
    fi
    marker_root="$(vx_compose_projects_root "$owner")/.legacy-data-authority"
    marker="$marker_root/$project.conf"
    [[ -d "$marker_root" && ! -L "$marker_root" ]] || return 1
    if [[ "$prior_marker" != - ]]; then
        [[ -f "$prior_marker" && ! -L "$prior_marker"
            && "$(stat -c '%a' "$prior_marker")" == 600
            && "$(stat -c '%u' "$prior_marker")" == "$authority_uid" ]] \
            || return 1
        prior_state="$(cat "$prior_marker" 2>/dev/null)" || return 1
        [[ "$prior_state" == "STATE='complete'" \
            || "$prior_state" == "STATE='pending'" ]] || return 1
    fi
    exec {lock_fd}>"$marker_root/$project.lock" || return 1
    flock -x "$lock_fd" || {
        exec {lock_fd}>&-
        return 1
    }
    [[ -f "$marker" && ! -L "$marker"
        && "$(stat -c '%a' "$marker")" == 600
        && "$(stat -c '%u' "$marker")" == "$authority_uid" ]] || result=1
    if [[ "$result" -eq 0 ]]; then
        current_state="$(cat "$marker")" || result=1
        [[ "$current_state" == "STATE='complete'" \
            || "$current_state" == "STATE='pending'" ]] || result=1
    fi
    if [[ "$result" -eq 0 ]]; then
        perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
            "$owner" "$HOMEDIR" "$project" - restore-rollback || result=$?
    fi
    if [[ "$result" -eq 0 && "$prior_marker" == - ]]; then
        rm -f -- "$marker" || result=1
    elif [[ "$result" -eq 0 ]]; then
        temp="$(mktemp "$marker_root/.legacy-restore-rollback.XXXXXX")" \
            || result=1
        if [[ "$result" -eq 0 ]] \
            && {
                ! cp -- "$prior_marker" "$temp" \
                || ! chmod 0600 "$temp" \
                || { (( EUID != 0 )) || chown --reference="$prior_marker" "$temp"; } \
                || ! mv -f -- "$temp" "$marker"
            }; then
            result=1
        fi
        [[ "$result" -eq 0 ]] || rm -f -- "${temp:-}"
    fi
    if [[ "$result" -ne 0 && ! -f "$marker" ]]; then
        temp="$(mktemp "$marker_root/.legacy-restore-failed.XXXXXX")" || :
        if [[ -n "${temp:-}" ]]; then
            if ! printf '%s\n' "STATE='pending'" >"$temp" \
                || ! chmod 0600 "$temp" \
                || ! mv -f -- "$temp" "$marker"; then
                rm -f -- "$temp"
            fi
        fi
    fi
    if [[ "$result" -eq 0 && "$prior_marker" != - ]]; then
        cmp -s "$prior_marker" "$marker" \
            && [[ "$(stat -c '%u:%g:%a' "$marker")" \
                == "$(stat -c '%u:%g:%a' "$prior_marker")" ]] \
            || result=1
    fi
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return "$result"
}

vx_compose_restore_rollback_owner_data_root() {
    local owner="$1"

    perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
        "$owner" "$HOMEDIR" - - rollback
}

vx_compose_managed_bind_leaf_prepare() {
    local owner="$1"
    local project="$2"
    local leaf="$3"

    perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
        "$owner" "$HOMEDIR" "$project" "$leaf" normal
}

vx_compose_owner_data_unmount() {
    local owner="$1"

    [[ -d "$HOMEDIR/$owner/docker" && ! -L "$HOMEDIR/$owner/docker" ]] \
        || return 0
    id -u "$owner" >/dev/null 2>&1 || return 0
    perl "$VX_COMPOSE_LIB_DIR/managed-directory.pl" \
        "$owner" "$HOMEDIR" - - unmount
}

vx_compose_lock_path() {
    printf '%s/.locks/%s.lock\n' "$(vx_compose_projects_root "$1")" "$2"
}

vx_compose_meta_get() {
    local metadata_file="$1"
    local key="$2"

    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    awk -v prefix="$key='" '
        index($0, prefix) == 1 {
            value = substr($0, length(prefix) + 1)
            sub(/\047$/, "", value)
            print value
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$metadata_file"
}

vx_compose_require_project() {
    local owner="$1"
    local project="$2"
    local root

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -d "$root"
        && -f "$root/project.conf"
        && -f "$root/compose.yaml"
        && -f "$root/policy.conf"
        && -f "$root/runtime/canonical.json" ]] \
        || {
            vx_compose_error "Compose project does not exist: $owner/$project"
            return 1
        }
    [[ "$(vx_compose_meta_get "$root/project.conf" OWNER)" == "$owner" ]] \
        || {
            vx_compose_error "Compose project owner metadata mismatch: $owner/$project"
            return 1
        }
    [[ "$(vx_compose_meta_get "$root/project.conf" PROJECT)" == "$project" ]] \
        || {
            vx_compose_error "Compose project key metadata mismatch: $owner/$project"
            return 1
        }
}

vx_compose_prepare_owner_roots() {
    local owner="$1"
    local projects_root data_parent

    projects_root="$(vx_compose_projects_root "$owner")"
    data_parent="$HOMEDIR/$owner/docker"
    install -d -m 0750 "$projects_root" "$projects_root/.locks"
    if id -u "$owner" >/dev/null 2>&1; then
        vx_compose_prepare_project_data_roots "$owner" || return 1
    else
        install -d -m 0750 "$data_parent"
    fi
}

vx_compose_lock_acquire() {
    local owner="$1" project="$2" lock_key lock_path

    lock_key="$owner/$project"
    if [[ -n "${VX_COMPOSE_LOCK_FD:-}" ]]; then
        [[ "${VX_COMPOSE_LOCK_KEY:-}" == "$lock_key" ]] || {
            vx_compose_error 'nested Compose lock targets differ'
            return 1
        }
        VX_COMPOSE_LOCK_DEPTH=$((VX_COMPOSE_LOCK_DEPTH + 1))
        return
    fi
    vx_compose_prepare_owner_roots "$owner" || return 1
    lock_path="$(vx_compose_lock_path "$owner" "$project")"
    exec {VX_COMPOSE_LOCK_FD}>"$lock_path" || return 1
    flock -x "$VX_COMPOSE_LOCK_FD" || {
        exec {VX_COMPOSE_LOCK_FD}>&-
        unset VX_COMPOSE_LOCK_FD
        return 1
    }
    VX_COMPOSE_LOCK_KEY="$lock_key"
    VX_COMPOSE_LOCK_DEPTH=1
}

vx_compose_lock_release() {
    [[ -n "${VX_COMPOSE_LOCK_FD:-}" ]] || return 0
    if (( VX_COMPOSE_LOCK_DEPTH > 1 )); then
        VX_COMPOSE_LOCK_DEPTH=$((VX_COMPOSE_LOCK_DEPTH - 1))
        return
    fi
    flock -u "$VX_COMPOSE_LOCK_FD"
    exec {VX_COMPOSE_LOCK_FD}>&-
    unset VX_COMPOSE_LOCK_FD VX_COMPOSE_LOCK_KEY VX_COMPOSE_LOCK_DEPTH
}

vx_compose_owner_quota_lock_acquire() {
    local owner="$1"
    local lock_path

    if [[ -n "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]]; then
        [[ "${VX_COMPOSE_QUOTA_LOCK_OWNER:-}" == "$owner" ]] || {
            vx_compose_error 'nested Compose quota lock owners differ'
            return 1
        }
        VX_COMPOSE_QUOTA_LOCK_DEPTH=$((VX_COMPOSE_QUOTA_LOCK_DEPTH + 1))
        return
    fi

    vx_compose_prepare_owner_roots "$owner" || return 1
    lock_path="$(vx_compose_projects_root "$owner")/.locks/.quota.lock"
    exec {VX_COMPOSE_QUOTA_LOCK_FD}>"$lock_path" || return 1
    flock -x "$VX_COMPOSE_QUOTA_LOCK_FD" || {
        exec {VX_COMPOSE_QUOTA_LOCK_FD}>&-
        unset VX_COMPOSE_QUOTA_LOCK_FD
        return 1
    }
    VX_COMPOSE_QUOTA_LOCK_OWNER="$owner"
    VX_COMPOSE_QUOTA_LOCK_DEPTH=1
}

vx_compose_owner_quota_lock_release() {
    [[ -n "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]] || return 0
    if (( VX_COMPOSE_QUOTA_LOCK_DEPTH > 1 )); then
        VX_COMPOSE_QUOTA_LOCK_DEPTH=$((VX_COMPOSE_QUOTA_LOCK_DEPTH - 1))
        return
    fi
    flock -u "$VX_COMPOSE_QUOTA_LOCK_FD"
    exec {VX_COMPOSE_QUOTA_LOCK_FD}>&-
    unset VX_COMPOSE_QUOTA_LOCK_FD VX_COMPOSE_QUOTA_LOCK_OWNER \
        VX_COMPOSE_QUOTA_LOCK_DEPTH
}

vx_compose_write_metadata() {
    local root="$1"
    local owner="$2"
    local project="$3"
    local profile="$4"
    local state="$5"
    local revision="$6"
    local created="$7"
    local updated="$8"
    local canonical_sha="$9"
    local temp_file

    temp_file="$(mktemp "$root/.project.conf.XXXXXX")"
    {
        printf "OWNER='%s'\n" "$owner"
        printf "PROJECT='%s'\n" "$project"
        printf "COMPOSE_PROJECT='%s'\n" "$(vx_compose_runtime_name "$owner" "$project")"
        printf "PROFILE='%s'\n" "$profile"
        printf "STATE='%s'\n" "$state"
        printf "REVISION='%s'\n" "$revision"
        printf "SCHEMA='%s'\n" "$VX_COMPOSE_SCHEMA_VERSION"
        printf "CANONICAL_SHA256='%s'\n" "$canonical_sha"
        printf "CREATED='%s'\n" "$created"
        printf "UPDATED='%s'\n" "$updated"
    } >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f "$temp_file" "$root/project.conf"
}

vx_compose_audit() {
    local root="$1"
    local action="$2"
    local result="$3"

    printf '%s actor=root action=%s result=%s\n' \
        "$(vx_compose_now)" "$action" "$result" >>"$root/audit.log"
    chmod 0640 "$root/audit.log"
}

vx_compose_candidate_sha() {
    local candidate="$1"

    awk 'NR == 1 { print $1; exit }' "$candidate/canonical.sha256"
}

vx_compose_install_revision_files() {
    local candidate="$1"
    local revision_root="$2"

    [[ ! -e "$revision_root/manifest.sha256" ]] || {
        vx_compose_error 'finalized Compose revision is immutable'
        return 1
    }
    install -d -m 0750 "$revision_root" || return 1
    install -m 0640 "$candidate/compose.yaml" "$revision_root/compose.yaml" \
        && install -m 0640 \
            "$candidate/canonical.json" "$revision_root/canonical.json" \
        && install -m 0640 \
            "$candidate/policy.conf" "$revision_root/policy.conf" \
        || return 1
    if [[ -f "$candidate/images.json" && ! -L "$candidate/images.json" ]]; then
        install -m 0640 "$candidate/images.json" "$revision_root/images.json" \
            || return 1
    fi
    if [[ -f "$candidate/simple.json" && ! -L "$candidate/simple.json" ]]; then
        install -m 0600 "$candidate/simple.json" "$revision_root/simple.json" \
            || return 1
    fi
    if [[ -f "$candidate/alerts.conf" && ! -L "$candidate/alerts.conf" ]]; then
        install -m 0640 "$candidate/alerts.conf" "$revision_root/alerts.conf" \
            || return 1
    fi
}

vx_compose_fsync_path() {
    sync -f -- "$1" >/dev/null 2>&1
}

vx_compose_revision_manifest_write() {
    local revision_root="$1"
    local manifest_temp member
    local -a members=()

    [[ -d "$revision_root" && ! -L "$revision_root"
        && ! -e "$revision_root/manifest.sha256" ]] || {
        vx_compose_error 'Compose revision cannot be finalized'
        return 1
    }
    while IFS= read -r member; do
        [[ -f "$revision_root/$member" && ! -L "$revision_root/$member" ]] \
            || return 1
        members+=("$member")
    done < <(
        find "$revision_root" -mindepth 1 -maxdepth 1 -type f \
            ! -name manifest.sha256 -printf '%f\n' | LC_ALL=C sort
    )
    ((${#members[@]} > 0)) || return 1
    manifest_temp="$revision_root/.manifest.sha256.tmp"
    (
        cd "$revision_root" || exit 1
        sha256sum -- "${members[@]}" >".manifest.sha256.tmp"
        sha256sum --strict -c ".manifest.sha256.tmp" >/dev/null
    ) || {
        rm -f -- "$manifest_temp"
        return 1
    }
    chmod 0640 "$manifest_temp" || {
        rm -f -- "$manifest_temp"
        return 1
    }
    for member in "${members[@]}"; do
        vx_compose_fsync_path "$revision_root/$member" || {
            rm -f -- "$manifest_temp"
            return 1
        }
    done
    vx_compose_fsync_path "$manifest_temp" || {
        rm -f -- "$manifest_temp"
        return 1
    }
    mv -- "$manifest_temp" "$revision_root/manifest.sha256" || {
        rm -f -- "$manifest_temp"
        return 1
    }
    vx_compose_fsync_path "$revision_root/manifest.sha256" || return 1
    vx_compose_fsync_path "$revision_root"
}

vx_compose_revision_manifest_verify() {
    local revision_root="$1"
    local listed actual

    [[ -d "$revision_root" && ! -L "$revision_root"
        && -f "$revision_root/manifest.sha256"
        && ! -L "$revision_root/manifest.sha256" ]] || return 1
    (
        cd "$revision_root" || exit 1
        sha256sum --strict -c manifest.sha256 >/dev/null
    ) || return 1
    # Legacy revisions listed only canonical.json. They remain readable.
    [[ "$(wc -l <"$revision_root/manifest.sha256")" -gt 1 ]] || return 0
    listed="$(
        awk '{print $2}' "$revision_root/manifest.sha256" | LC_ALL=C sort
    )"
    actual="$(
        find "$revision_root" -mindepth 1 -maxdepth 1 -type f \
            ! -name manifest.sha256 -printf '%f\n' | LC_ALL=C sort
    )"
    [[ "$listed" == "$actual" ]]
}

vx_compose_active_revision_verify() {
    local owner="$1"
    local project="$2"
    local root metadata revision revision_root recorded_sha actual_sha name
    local legacy_revision=no image_evidence_kind

    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    revision="$(vx_compose_meta_get "$metadata" REVISION)" || return 1
    recorded_sha="$(vx_compose_meta_get "$metadata" CANONICAL_SHA256)" \
        || return 1
    [[ "$revision" =~ ^[1-9][0-9]*$
        && "$recorded_sha" =~ ^[a-f0-9]{64}$ ]] || {
        vx_compose_error 'active Compose revision metadata is invalid'
        return 1
    }
    printf -v revision_root '%s/revisions/%06d' "$root" "$revision"
    if ! vx_compose_image_evidence_directory_is_secure "$root" 750 \
        || ! vx_compose_image_evidence_directory_is_secure \
            "$root/revisions" 750 \
        || ! vx_compose_image_evidence_directory_is_secure \
            "$revision_root" 750 \
        || ! vx_compose_image_evidence_file_is_secure \
            "$revision_root/manifest.sha256" 640; then
        vx_compose_error 'active Compose image authority permissions are invalid'
        return 1
    fi
    vx_compose_revision_manifest_verify "$revision_root" || {
        vx_compose_error 'active Compose revision manifest is invalid'
        return 1
    }
    [[ "$(wc -l <"$revision_root/manifest.sha256")" -gt 1 ]] \
        || legacy_revision=yes
    actual_sha="$(sha256sum "$root/runtime/canonical.json" | awk '{print $1}')" \
        || return 1
    [[ "$actual_sha" == "$recorded_sha"
        && -f "$revision_root/canonical.json"
        && ! -L "$revision_root/canonical.json"
        && "$(sha256sum "$revision_root/canonical.json" | awk '{print $1}')" \
            == "$recorded_sha" ]] || {
        vx_compose_error 'active Compose canonical digest does not match authority'
        return 1
    }
    for name in compose.yaml policy.conf; do
        [[ -f "$revision_root/$name" && ! -L "$revision_root/$name"
            && -f "$root/$name" && ! -L "$root/$name"
            && "$(sha256sum "$revision_root/$name" | awk '{print $1}')" \
                == "$(sha256sum "$root/$name" | awk '{print $1}')" ]] || {
            vx_compose_error 'active Compose control files do not match the finalized revision'
            return 1
        }
    done
    if [[ -f "$revision_root/routes.conf" || -f "$root/routes.conf" ]]; then
        [[ -f "$revision_root/routes.conf"
            && ! -L "$revision_root/routes.conf"
            && -f "$root/routes.conf" && ! -L "$root/routes.conf"
            && "$(sha256sum "$revision_root/routes.conf" | awk '{print $1}')" \
                == "$(sha256sum "$root/routes.conf" | awk '{print $1}')" ]] || {
            vx_compose_error 'active Compose route intent does not match the finalized revision'
            return 1
        }
    fi
    if [[ -f "$root/images.json" ]]; then
        vx_compose_image_evidence_file_is_secure "$root/images.json" 640 || {
            vx_compose_error 'active Compose image evidence does not match the finalized revision'
            return 1
        }
        if [[ -f "$revision_root/images.json" ]]; then
            vx_compose_image_evidence_file_is_secure \
                "$revision_root/images.json" 640 || {
                vx_compose_error 'active Compose image evidence does not match the finalized revision'
                return 1
            }
            image_evidence_kind="$(vx_compose_image_evidence_kind \
                "$revision_root/images.json" 2>/dev/null)" \
                || image_evidence_kind=unsupported
            if [[ "$image_evidence_kind" \
                    == legacy-production-five-field ]]; then
                if ! vx_compose_revision_manifest_binds_images \
                        "$revision_root" \
                    && ! vx_compose_image_evidence_migration_authority_verify \
                        "$owner" "$project" "$root" "$revision" \
                        "$root/images.json"; then
                    vx_compose_error 'active Compose image migration authority is unavailable'
                    return 1
                fi
            fi
            if ! cmp -s "$revision_root/images.json" "$root/images.json"; then
                if [[ "$image_evidence_kind" \
                        != legacy-production-five-field ]] \
                    && ! vx_compose_revision_manifest_binds_images \
                        "$revision_root"; then
                    vx_compose_error 'active Compose image migration authority is unavailable'
                    return 1
                fi
                if ! vx_compose_image_evidence_matches_current \
                    "$revision_root/images.json" "$root/images.json"; then
                    vx_compose_error 'active Compose image evidence does not match the finalized revision'
                    return 1
                fi
            fi
        elif [[ "$legacy_revision" != yes ]]; then
            vx_compose_error 'active Compose image evidence does not match the finalized revision'
            return 1
        fi
    fi
    if [[ -f "$revision_root/simple.json" || -f "$root/simple.json" ]]; then
        [[ -f "$revision_root/simple.json" && ! -L "$revision_root/simple.json"
            && -f "$root/simple.json" && ! -L "$root/simple.json"
            && "$(sha256sum "$revision_root/simple.json" | awk '{print $1}')" \
                == "$(sha256sum "$root/simple.json" | awk '{print $1}')" ]] || {
            vx_compose_error 'active Compose simple metadata does not match the finalized revision'
            return 1
        }
    fi
    # Revisions finalized before alert policy became revisioned have no
    # alerts.conf member. Once present in a manifest it is mandatory and exact.
    if [[ -f "$revision_root/alerts.conf" ]]; then
        [[ -f "$revision_root/alerts.conf" && ! -L "$revision_root/alerts.conf"
            && -f "$root/alerts.conf" && ! -L "$root/alerts.conf"
            && "$(sha256sum "$revision_root/alerts.conf" | awk '{print $1}')" \
                == "$(sha256sum "$root/alerts.conf" | awk '{print $1}')" ]] || {
            vx_compose_error 'active Compose alert policy does not match the finalized revision'
            return 1
        }
    fi
}

vx_compose_stage_candidate_revision() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local transaction_root="$4"
    local routes_file="${5:-}"
    local root

    [[ -n "${VX_COMPOSE_LOCK_FD:-}"
        && "${VX_COMPOSE_LOCK_KEY:-}" == "$owner/$project"
        && ! -e "$transaction_root" ]] || return 1
    install -d -m 0700 "$transaction_root" || return 1
    if ! install -m 0640 \
        "$candidate/compose.yaml" "$transaction_root/compose.yaml" \
        || ! install -m 0640 \
            "$candidate/canonical.json" "$transaction_root/canonical.json" \
        || ! install -m 0640 \
            "$candidate/policy.conf" "$transaction_root/policy.conf" \
        || ! install -m 0640 \
            "$candidate/images.json" "$transaction_root/images.json"; then
        rm -rf -- "$transaction_root"
        return 1
    fi
    if [[ -f "$candidate/simple.json" && ! -L "$candidate/simple.json" ]]; then
        install -m 0600 "$candidate/simple.json" "$transaction_root/simple.json" \
            || {
                rm -rf -- "$transaction_root"
                return 1
            }
    fi
    if [[ -f "$candidate/alerts.conf" && ! -L "$candidate/alerts.conf" ]]; then
        install -m 0640 "$candidate/alerts.conf" "$transaction_root/alerts.conf" \
            || {
                rm -rf -- "$transaction_root"
                return 1
            }
    else
        root="$(vx_compose_project_root "$owner" "$project")"
        if [[ -f "$root/alerts.conf" && ! -L "$root/alerts.conf" ]]; then
            install -m 0640 \
                "$root/alerts.conf" "$transaction_root/alerts.conf" \
                || {
                    rm -rf -- "$transaction_root"
                    return 1
                }
        fi
    fi
    if [[ -n "$routes_file" && -f "$routes_file" && ! -L "$routes_file" ]]; then
        install -m 0640 "$routes_file" "$transaction_root/routes.conf" \
            || {
                rm -rf -- "$transaction_root"
                return 1
            }
    else
        if ! printf '{}\n' >"$transaction_root/routes.conf" \
            || ! chmod 0640 "$transaction_root/routes.conf"; then
            rm -rf -- "$transaction_root"
            return 1
        fi
    fi
}

vx_compose_commit_staged_revision() {
    local owner="$1"
    local project="$2"
    local transaction_root="$3"
    local revision="$4"
    local state="${5:-running}"
    local root metadata revision_name temp_revision profile created now sha name
    local snapshot_root switch_failed=no setup_failed=no

    [[ -n "${VX_COMPOSE_LOCK_FD:-}"
        && "${VX_COMPOSE_LOCK_KEY:-}" == "$owner/$project"
        && "$revision" =~ ^[1-9][0-9]*$ ]] || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    profile="$(vx_compose_meta_get "$metadata" PROFILE)" || return 1
    created="$(vx_compose_meta_get "$metadata" CREATED)" || return 1
    now="$(vx_compose_now)"
    sha="$(sha256sum "$transaction_root/canonical.json" | awk '{print $1}')" \
        || return 1
    printf -v revision_name '%06d' "$revision"
    temp_revision="$root/revisions/.${revision_name}.commit.$$"
    [[ -d "$transaction_root" && ! -L "$transaction_root"
        && ! -e "$root/revisions/$revision_name"
        && ! -e "$temp_revision" ]] || return 1
    if ! vx_compose_install_revision_files \
        "$transaction_root" "$temp_revision" \
        || ! install -m 0640 "$transaction_root/routes.conf" \
            "$temp_revision/routes.conf" \
        || ! vx_compose_revision_manifest_write "$temp_revision" \
        || ! mv -- "$temp_revision" "$root/revisions/$revision_name" \
        || ! vx_compose_fsync_path "$root/revisions"; then
        rm -rf -- "$temp_revision" "$root/revisions/$revision_name"
        return 1
    fi

    snapshot_root="$(mktemp -d "$root/runtime/.active-snapshot.XXXXXX")" \
        || {
            rm -rf -- "$root/revisions/$revision_name"
            return 1
        }
    install -m 0640 "$root/compose.yaml" "$snapshot_root/compose.yaml" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 "$root/policy.conf" "$snapshot_root/policy.conf" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 "$root/project.conf" "$snapshot_root/project.conf" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 "$root/runtime/canonical.json" \
            "$snapshot_root/canonical.json" || setup_failed=yes
    for name in images.json routes.conf alerts.conf; do
        [[ "$setup_failed" == yes || ! -f "$root/$name" ]] \
            || install -m 0640 "$root/$name" "$snapshot_root/$name" \
            || setup_failed=yes
    done
    [[ "$setup_failed" == yes || ! -f "$root/simple.json" ]] \
        || install -m 0600 "$root/simple.json" "$snapshot_root/simple.json" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 \
            "$transaction_root/compose.yaml" "$root/.compose.yaml.new" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 \
            "$transaction_root/policy.conf" "$root/.policy.conf.new" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 \
            "$transaction_root/images.json" "$root/.images.json.new" \
        || setup_failed=yes
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 \
            "$transaction_root/routes.conf" "$root/.routes.conf.new" \
        || setup_failed=yes
    if [[ "$setup_failed" != yes
        && -f "$transaction_root/alerts.conf"
        && ! -L "$transaction_root/alerts.conf" ]]; then
        install -m 0640 \
            "$transaction_root/alerts.conf" "$root/.alerts.conf.new" \
            || setup_failed=yes
    fi
    [[ "$setup_failed" == yes ]] \
        || install -m 0640 "$transaction_root/canonical.json" \
            "$root/runtime/.canonical.json.new" || setup_failed=yes
    if [[ "$setup_failed" == yes ]]; then
        rm -f -- \
            "$root/.compose.yaml.new" "$root/.policy.conf.new" \
            "$root/.images.json.new" "$root/.routes.conf.new" \
            "$root/.alerts.conf.new" "$root/.simple.json.new" \
            "$root/runtime/.canonical.json.new"
        rm -rf -- "$snapshot_root" "$root/revisions/$revision_name"
        return 1
    fi
    mv -- "$root/.compose.yaml.new" "$root/compose.yaml" || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -- "$root/.policy.conf.new" "$root/policy.conf" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -- "$root/.images.json.new" "$root/images.json" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || mv -- "$root/.routes.conf.new" "$root/routes.conf" \
        || switch_failed=yes
    if [[ "$switch_failed" != yes ]]; then
        if [[ -f "$transaction_root/alerts.conf" ]]; then
            mv -- "$root/.alerts.conf.new" "$root/alerts.conf" \
                || switch_failed=yes
        else
            rm -f -- "$root/alerts.conf"
        fi
    fi
    [[ "$switch_failed" == yes ]] \
        || mv -- "$root/runtime/.canonical.json.new" \
            "$root/runtime/canonical.json" || switch_failed=yes
    if [[ -f "$transaction_root/simple.json" ]]; then
        if [[ "$switch_failed" != yes ]]; then
            install -m 0600 \
                "$transaction_root/simple.json" "$root/.simple.json.new" \
                && mv -- "$root/.simple.json.new" "$root/simple.json" \
                || switch_failed=yes
        fi
    else
        rm -f -- "$root/simple.json"
    fi
    [[ "${VX_COMPOSE_TEST_COMMIT_FAIL_AFTER_ACTIVE:-no}" != yes ]] \
        || switch_failed=yes
    for name in compose.yaml policy.conf images.json routes.conf; do
        [[ "$switch_failed" == yes ]] \
            || vx_compose_fsync_path "$root/$name" || switch_failed=yes
    done
    if [[ "$switch_failed" != yes && -f "$root/alerts.conf" ]]; then
        vx_compose_fsync_path "$root/alerts.conf" || switch_failed=yes
    fi
    [[ "$switch_failed" == yes ]] \
        || vx_compose_fsync_path "$root/runtime/canonical.json" \
        || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || vx_compose_fsync_path "$root/runtime" || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || vx_compose_fsync_path "$root" || switch_failed=yes
    if [[ "$switch_failed" != yes ]]; then
        vx_compose_write_metadata \
            "$root" "$owner" "$project" "$profile" "$state" "$revision" \
            "$created" "$now" "$sha" || switch_failed=yes
    fi
    [[ "$switch_failed" == yes ]] \
        || vx_compose_fsync_path "$root/project.conf" || switch_failed=yes
    [[ "$switch_failed" == yes ]] \
        || vx_compose_fsync_path "$root" || switch_failed=yes
    if [[ "$switch_failed" == yes ]]; then
        install -m 0640 "$snapshot_root/compose.yaml" "$root/compose.yaml"
        install -m 0640 "$snapshot_root/policy.conf" "$root/policy.conf"
        install -m 0640 "$snapshot_root/project.conf" "$root/project.conf"
        install -m 0640 "$snapshot_root/canonical.json" \
            "$root/runtime/canonical.json"
        for name in images.json routes.conf alerts.conf; do
            if [[ -f "$snapshot_root/$name" ]]; then
                install -m 0640 "$snapshot_root/$name" "$root/$name"
            else
                rm -f -- "$root/$name"
            fi
        done
        if [[ -f "$snapshot_root/simple.json" ]]; then
            install -m 0600 "$snapshot_root/simple.json" "$root/simple.json"
        else
            rm -f -- "$root/simple.json"
        fi
        rm -rf -- "$snapshot_root"
        rm -f -- \
            "$root/.compose.yaml.new" "$root/.policy.conf.new" \
            "$root/.images.json.new" "$root/.routes.conf.new" \
            "$root/.alerts.conf.new" "$root/.simple.json.new" \
            "$root/runtime/.canonical.json.new"
        rm -rf -- "$root/revisions/$revision_name"
        return 1
    fi
    rm -rf -- "$snapshot_root"
}

vx_compose_store_new() {
    local owner="$1"
    local project="$2"
    local profile="$3"
    local candidate="$4"
    local projects_root root temp_root now canonical_sha

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    vx_compose_profile_is_available "$profile" \
        || {
            vx_compose_error "Compose profile is not available: $profile"
            return 1
        }
    vx_compose_profile_require_authorized "$owner" "$project" "$profile" \
        || return 1
    [[ -s "$candidate/compose.yaml"
        && -s "$candidate/canonical.json"
        && -s "$candidate/policy.conf" ]] \
        || {
            vx_compose_error 'candidate Compose output is incomplete'
            return 1
        }
    vx_compose_lock_acquire "$owner" "$project" || return 1
    projects_root="$(vx_compose_projects_root "$owner")"
    root="$(vx_compose_project_root "$owner" "$project")"
    if [[ -e "$root" ]]; then
        vx_compose_lock_release
        vx_compose_error "Compose project already exists: $owner/$project"
        return 1
    fi
    vx_compose_ports_lock_acquire || {
        vx_compose_lock_release
        return 1
    }
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
    if ! vx_compose_quota_check_candidate \
        "$owner" "$project" "$candidate/policy.conf" create; then
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ ! -f "$candidate/images.json" ]] \
        && ! vx_compose_resolve_images_to_file \
            "$owner" "$candidate/canonical.json" "$profile" \
            "$candidate/images.json"; then
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi

    temp_root="$(mktemp -d "$projects_root/.${project}.XXXXXX")"
    chmod 0750 "$temp_root"
    install -d -m 0750 \
        "$temp_root/revisions" \
        "$temp_root/runtime"
    install -d -m 0700 "$temp_root/secrets"
    install -d -m 0700 "$temp_root/runtime/docker-config" "$temp_root/runtime/home"
    : >"$temp_root/variables.env"
    chmod 0600 "$temp_root/variables.env"
    if [[ -f "$candidate/routes.conf" && ! -L "$candidate/routes.conf" ]]; then
        install -m 0640 "$candidate/routes.conf" "$temp_root/routes.conf"
    else
        printf '{}\n' >"$temp_root/routes.conf"
        chmod 0640 "$temp_root/routes.conf"
    fi
    if [[ -f "$candidate/alerts.conf" && ! -L "$candidate/alerts.conf" ]]; then
        install -m 0640 "$candidate/alerts.conf" "$temp_root/alerts.conf"
    else
        printf '%s\n' '{
  "CPU_PCT": 90,
  "MEMORY_PCT": 90,
  "NETWORK_MBPS": 100,
  "NOTIFY": true
}' >"$temp_root/alerts.conf"
    fi
    printf '[]\n' >"$temp_root/alerts.json"
    chmod 0640 "$temp_root/alerts.conf" "$temp_root/alerts.json"
    install -m 0640 "$candidate/compose.yaml" "$temp_root/compose.yaml"
    install -m 0640 "$candidate/canonical.json" "$temp_root/runtime/canonical.json"
    install -m 0640 "$candidate/policy.conf" "$temp_root/policy.conf"
    install -m 0640 "$candidate/images.json" "$temp_root/images.json"
    if [[ -f "$candidate/simple.json" && ! -L "$candidate/simple.json" ]]; then
        install -m 0600 "$candidate/simple.json" "$temp_root/simple.json"
    fi
    if ! vx_compose_install_revision_files \
        "$candidate" "$temp_root/revisions/000001" \
        || ! install -m 0640 \
            "$temp_root/routes.conf" "$temp_root/revisions/000001/routes.conf" \
        || ! install -m 0640 \
            "$temp_root/alerts.conf" \
            "$temp_root/revisions/000001/alerts.conf"; then
        rm -rf -- "$temp_root"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    vx_compose_revision_manifest_write "$temp_root/revisions/000001" || {
        rm -rf -- "$temp_root"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    now="$(vx_compose_now)"
    canonical_sha="$(vx_compose_candidate_sha "$candidate")"
    if ! vx_compose_write_metadata \
        "$temp_root" "$owner" "$project" "$profile" validated 1 \
        "$now" "$now" "$canonical_sha" \
        || ! vx_compose_audit "$temp_root" create succeeded \
        || ! mv "$temp_root" "$root"; then
        [[ ! -d "$temp_root" ]] || rm -rf -- "$temp_root"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ "${VX_COMPOSE_TEST_STORE_NEW_FAIL_DATA_ROOT:-no}" == yes ]] \
        || ! install -d -m 0750 \
            "$(vx_compose_project_data_root "$owner" "$project")" \
            "$(vx_compose_bind_root "$owner" "$project")"; then
        vx_compose_update_state "$owner" "$project" restore-required || :
        vx_compose_audit "$root" create failed \
            'managed data-root finalization failed' || :
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if id -u "$owner" >/dev/null 2>&1; then
        if ! chown "root:$owner" \
            "$(vx_compose_project_data_root "$owner" "$project")" \
            "$(vx_compose_bind_root "$owner" "$project")"; then
            vx_compose_update_state "$owner" "$project" restore-required || :
            vx_compose_owner_quota_lock_release
            vx_compose_ports_lock_release
            vx_compose_lock_release
            return 1
        fi
    fi
    if ! chmod 0750 \
        "$(vx_compose_project_data_root "$owner" "$project")" \
        "$(vx_compose_bind_root "$owner" "$project")"; then
        vx_compose_update_state "$owner" "$project" restore-required || :
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
    vx_compose_lock_release
    vx_compose_refresh_counters "$owner"
}

vx_compose_store_revision() {
    local owner="$1"
    local project="$2"
    local candidate="$3"
    local state="$4"
    local root metadata revision next_revision revision_name
    local latest_revision revision_root existing_revision
    local profile created now canonical_sha temp_revision

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    if ! vx_compose_active_revision_verify "$owner" "$project"; then
        vx_compose_lock_release
        return 1
    fi
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || {
        vx_compose_lock_release
        return 1
    }
    if [[ ! -f "$candidate/images.json" ]] \
        && ! vx_compose_resolve_images_to_file \
            "$owner" "$candidate/canonical.json" "$profile" \
            "$candidate/images.json"; then
        vx_compose_lock_release
        return 1
    fi
    vx_compose_ports_lock_acquire || {
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_ports_check_conflicts \
        "$owner" "$project" "$candidate/canonical.json"; then
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    metadata="$root/project.conf"
    revision="$(vx_compose_meta_get "$metadata" REVISION)"
    latest_revision="$revision"
    for revision_root in \
        "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]
    do
        [[ -d "$revision_root" ]] || continue
        existing_revision="$(basename -- "$revision_root")"
        existing_revision=$((10#$existing_revision))
        (( existing_revision > latest_revision )) \
            && latest_revision="$existing_revision"
    done
    next_revision=$((latest_revision + 1))
    printf -v revision_name '%06d' "$next_revision"
    temp_revision="$root/revisions/.${revision_name}.tmp"
    [[ ! -e "$root/revisions/$revision_name" ]] \
        || {
            vx_compose_ports_lock_release
            vx_compose_lock_release
            vx_compose_error "Compose revision already exists: $revision_name"
            return 1
        }
    vx_compose_owner_quota_lock_acquire "$owner" || {
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_quota_check_candidate \
        "$owner" "$project" "$candidate/policy.conf" update; then
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if ! vx_compose_install_revision_files "$candidate" "$temp_revision"; then
        rm -rf -- "$temp_revision"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    fi
    if [[ -f "$root/routes.conf" ]]; then
        install -m 0640 "$root/routes.conf" "$temp_revision/routes.conf"
    fi
    if [[ ! -f "$temp_revision/alerts.conf"
        && -f "$root/alerts.conf" && ! -L "$root/alerts.conf" ]]; then
        install -m 0640 "$root/alerts.conf" "$temp_revision/alerts.conf"
    fi
    vx_compose_revision_manifest_write "$temp_revision" || {
        rm -rf -- "$temp_revision"
        vx_compose_owner_quota_lock_release
        vx_compose_ports_lock_release
        vx_compose_lock_release
        return 1
    }
    mv "$temp_revision" "$root/revisions/$revision_name"
    vx_compose_fsync_path "$root/revisions"
    install -m 0640 "$candidate/compose.yaml" "$root/.compose.yaml.new"
    install -m 0640 "$candidate/canonical.json" "$root/runtime/.canonical.json.new"
    install -m 0640 "$candidate/policy.conf" "$root/.policy.conf.new"
    mv -f "$root/.compose.yaml.new" "$root/compose.yaml"
    mv -f "$root/runtime/.canonical.json.new" "$root/runtime/canonical.json"
    mv -f "$root/.policy.conf.new" "$root/policy.conf"
    if [[ -f "$candidate/simple.json" && ! -L "$candidate/simple.json" ]]; then
        install -m 0600 "$candidate/simple.json" "$root/.simple.json.new"
        mv -f "$root/.simple.json.new" "$root/simple.json"
    else
        rm -f -- "$root/simple.json"
    fi
    if [[ -f "$candidate/alerts.conf" && ! -L "$candidate/alerts.conf" ]]; then
        install -m 0640 "$candidate/alerts.conf" "$root/.alerts.conf.new"
        mv -f "$root/.alerts.conf.new" "$root/alerts.conf"
    fi
    rm -f -- "$root/images.json"

    created="$(vx_compose_meta_get "$metadata" CREATED)"
    now="$(vx_compose_now)"
    canonical_sha="$(vx_compose_candidate_sha "$candidate")"
    vx_compose_write_metadata \
        "$root" "$owner" "$project" "$profile" "$state" "$next_revision" \
        "$created" "$now" "$canonical_sha"
    vx_compose_audit "$root" update succeeded
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
    vx_compose_lock_release
    vx_compose_refresh_counters "$owner"
}

vx_compose_update_state() {
    local owner="$1"
    local project="$2"
    local state="$3"
    local root metadata profile revision created canonical_sha

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    metadata="$root/project.conf"
    profile="$(vx_compose_meta_get "$metadata" PROFILE)"
    revision="$(vx_compose_meta_get "$metadata" REVISION)"
    created="$(vx_compose_meta_get "$metadata" CREATED)"
    canonical_sha="$(vx_compose_meta_get "$metadata" CANONICAL_SHA256)"
    vx_compose_write_metadata \
        "$root" "$owner" "$project" "$profile" "$state" "$revision" \
        "$created" "$(vx_compose_now)" "$canonical_sha"
}

vx_compose_remove_control_root() {
    local owner="$1"
    local project="$2"
    local root expected

    root="$(vx_compose_project_root "$owner" "$project")"
    expected="$(vx_compose_projects_root "$owner")/$project"
    [[ "$root" == "$expected" && -d "$root" ]] \
        || {
            vx_compose_error 'refusing to remove unresolved Compose project root'
            return 1
        }
    rm -rf -- "$root"
}
