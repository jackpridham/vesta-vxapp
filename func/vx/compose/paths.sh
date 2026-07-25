#!/usr/bin/env bash

vx_compose_resolve_managed_path() {
    local owner="$1"
    local project="$2"
    local requested_path="$3"
    local managed_root resolved_root parent resolved_parent resolved_path

    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    [[ "$requested_path" == /* && "$requested_path" != *$'\n'* ]] \
        || {
            vx_compose_error 'managed path must be an absolute single-line path'
            return 1
        }

    managed_root="$(vx_compose_project_data_root "$owner" "$project")"
    [[ -d "$managed_root" && ! -L "$managed_root" ]] \
        || {
            vx_compose_error 'managed project data root is unavailable'
            return 1
        }
    resolved_root="$(realpath -e -- "$managed_root")" || return 1
    parent="$(dirname -- "$requested_path")"
    resolved_parent="$(realpath -e -- "$parent" 2>/dev/null)" \
        || {
            vx_compose_error 'managed path parent must already exist'
            return 1
        }
    resolved_path="$resolved_parent/$(basename -- "$requested_path")"
    case "$resolved_path" in
        "$resolved_root"|"$resolved_root"/*)
            printf '%s\n' "$resolved_path"
            ;;
        *)
            vx_compose_error 'managed path resolves outside the project data root'
            return 1
            ;;
    esac
}
