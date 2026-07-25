#!/usr/bin/env bash

VX_COMPOSE_WEB_SOURCE_MAX_AGE="${VX_COMPOSE_WEB_SOURCE_MAX_AGE:-900}"

vx_compose_web_source_validate() {
    local source_file="$1"
    local expected_name="$2"
    local parent parent_name parent_parent directory_uid source_uid
    local now modified age

    unset VX_COMPOSE_WEB_SOURCE_PARENT
    [[ "$expected_name" == compose.yaml || "$expected_name" == simple.spec ]] \
        || return 1
    [[ -f "$source_file" && ! -L "$source_file"
        && "$(basename -- "$source_file")" == "$expected_name" ]] \
        || {
            vx_compose_error 'web operation source is invalid'
            return 1
        }
    parent="$(realpath -e -- "$(dirname -- "$source_file")")" || return 1
    [[ -d "$parent" && ! -L "$(dirname -- "$source_file")"
        && "$(realpath -e -- "$source_file")" == "$parent/$expected_name" ]] \
        || {
            vx_compose_error 'web operation source path is invalid'
            return 1
        }
    parent_name="$(basename -- "$parent")"
    parent_parent="$(realpath -e -- "$(dirname -- "$parent")")" || return 1
    [[ "$parent_parent" == /tmp
        && "$parent_name" =~ ^vx-compose-web[.][a-f0-9]{32}$
        && "$(stat -c '%a' "$parent")" == 700
        && "$(stat -c '%a' "$source_file")" == 600 ]] \
        || {
            vx_compose_error 'web operation source protection is invalid'
            return 1
        }
    directory_uid="$(stat -c '%u' "$parent")"
    source_uid="$(stat -c '%u' "$source_file")"
    [[ "$directory_uid" == "$source_uid"
        && "$(stat -c '%s' "$source_file")" -le 1048576 ]] \
        || {
            vx_compose_error 'web operation source ownership or size is invalid'
            return 1
        }
    now="$(date +%s)"
    modified="$(stat -c '%Y' "$source_file")"
    age=$((now - modified))
    (( age >= -60 && age <= VX_COMPOSE_WEB_SOURCE_MAX_AGE )) \
        || {
            vx_compose_error 'web operation source has expired'
            return 1
        }
    VX_COMPOSE_WEB_SOURCE_PARENT="$parent"
    export VX_COMPOSE_WEB_SOURCE_PARENT
}

vx_compose_web_source_cleanup() {
    local source_file="$1"
    local parent="${VX_COMPOSE_WEB_SOURCE_PARENT:-}"

    [[ -n "$parent"
        && "$parent" =~ ^/tmp/vx-compose-web[.][a-f0-9]{32}$
        && "$source_file" == "$parent/"* ]] \
        || {
            vx_compose_error 'refusing to clean unresolved web operation source'
            return 1
        }
    rm -f -- "$source_file"
    rmdir -- "$parent" || {
        vx_compose_error 'web operation source directory is not empty'
        return 1
    }
    unset VX_COMPOSE_WEB_SOURCE_PARENT
}
