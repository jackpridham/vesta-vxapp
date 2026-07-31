#!/usr/bin/env bash

vx_compose_owner_project_keys() {
    local owner="$1"
    local projects_root project_root project

    projects_root="$(vx_compose_projects_root "$owner")"
    [[ -d "$projects_root" ]] || return 0
    for project_root in "$projects_root"/*; do
        [[ -d "$project_root" && -f "$project_root/project.conf" ]] || continue
        project="$(basename -- "$project_root")"
        vx_compose_project_is_valid "$project" || continue
        printf '%s\n' "$project"
    done
}

vx_compose_suspend_owner() {
    local owner="$1"
    local projects_root marker temp_marker project root state

    vx_compose_require_owner "$owner" || return 1
    projects_root="$(vx_compose_projects_root "$owner")"
    [[ -d "$projects_root" ]] || return 0
    marker="$projects_root/.suspended-running"
    temp_marker="$(mktemp "$projects_root/.suspended-running.XXXXXX")" || return 1
    chmod 0640 "$temp_marker"

    while IFS= read -r project; do
        root="$(vx_compose_project_root "$owner" "$project")"
        state="$(vx_compose_meta_get "$root/project.conf" STATE)" || {
            rm -f -- "$temp_marker"
            return 1
        }
        [[ "$state" == running ]] || continue
        printf '%s\n' "$project" >>"$temp_marker"
        vx_compose_stop "$owner" "$project" || {
            mv -f -- "$temp_marker" "$marker"
            return 1
        }
    done < <(vx_compose_owner_project_keys "$owner")
    mv -f -- "$temp_marker" "$marker"
}

vx_compose_unsuspend_owner() {
    local owner="$1"
    local marker project

    vx_compose_require_owner "$owner" || return 1
    marker="$(vx_compose_projects_root "$owner")/.suspended-running"
    [[ -f "$marker" ]] || return 0
    while IFS= read -r project; do
        [[ -n "$project" ]] || continue
        vx_compose_require_project_key "$project" || return 1
        vx_compose_start "$owner" "$project" || return 1
    done <"$marker"
    rm -f -- "$marker"
}

vx_compose_rebuild_owner() {
    local owner="$1"
    local project root state expected_sha actual_sha

    vx_compose_require_owner "$owner" || return 1
    vx_compose_quota_check_current "$owner" || return 1
    while IFS= read -r project; do
        root="$(vx_compose_project_root "$owner" "$project")"
        expected_sha="$(vx_compose_meta_get "$root/project.conf" CANONICAL_SHA256)" \
            || return 1
        actual_sha="$(sha256sum "$root/runtime/canonical.json" | awk '{print $1}')" \
            || return 1
        [[ "$actual_sha" == "$expected_sha" ]] \
            || {
                vx_compose_error \
                    "Compose canonical digest mismatch: $owner/$project"
                return 1
            }
        vx_compose_policy_evaluate \
            "$root/runtime/canonical.json" \
            "$(vx_compose_meta_get "$root/project.conf" PROFILE)" \
            "$owner" "$project" \
            || return 1
        state="$(vx_compose_meta_get "$root/project.conf" STATE)" || return 1
        [[ "$state" == running ]] || continue
        vx_compose_deploy "$owner" "$project" || return 1
    done < <(vx_compose_owner_project_keys "$owner")
}

vx_compose_remove_owner_runtime() {
    local owner="$1"
    local project root

    vx_compose_require_owner "$owner" || return 1
    while IFS= read -r project; do
        root="$(vx_compose_project_root "$owner" "$project")"
        vx_compose_lock_acquire "$owner" "$project" || return 1
        vx_compose_audit "$root" owner-delete started
        if vx_compose_invoke "$owner" "$project" down --remove-orphans; then
            vx_compose_audit "$root" owner-delete succeeded
            vx_compose_lock_release
        else
            vx_compose_audit "$root" owner-delete failed
            vx_compose_lock_release
            return 1
        fi
    done < <(vx_compose_owner_project_keys "$owner")
    vx_compose_owner_data_unmount "$owner"
}
