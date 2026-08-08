#!/usr/bin/env bash

vx_compose_registry_root() {
    printf '%s/data/users/%s/docker-registry\n' "$VESTA" "$1"
}

vx_compose_registry_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?$ ]]
}

vx_compose_registry_prepare() {
    local owner="$1"
    local root

    vx_compose_require_owner "$owner" || return 1
    root="$(vx_compose_registry_root "$owner")"
    install -d -m 0700 "$root" "$root/home"
    [[ -f "$root/registries.json" ]] || printf '%s\n' '{}' >"$root/registries.json"
    [[ -f "$root/config.json" ]] || printf '%s\n' '{"auths":{}}' >"$root/config.json"
    chmod 0700 "$root" "$root/home"
    chmod 0600 "$root/registries.json" "$root/config.json"
}

vx_compose_registry_lock_acquire() {
    local owner="$1"
    local root

    vx_compose_registry_prepare "$owner" || return 1
    root="$(vx_compose_registry_root "$owner")"
    exec {VX_COMPOSE_REGISTRY_LOCK_FD}>"$root/.lock"
    flock -x "$VX_COMPOSE_REGISTRY_LOCK_FD"
}

vx_compose_registry_lock_release() {
    if [[ -n "${VX_COMPOSE_REGISTRY_LOCK_FD:-}" ]]; then
        flock -u "$VX_COMPOSE_REGISTRY_LOCK_FD"
        exec {VX_COMPOSE_REGISTRY_LOCK_FD}>&-
        unset VX_COMPOSE_REGISTRY_LOCK_FD
    fi
}

vx_compose_owner_docker() {
    local owner="$1"
    shift
    local root docker_bin

    vx_compose_registry_prepare "$owner" || return 1
    root="$(vx_compose_registry_root "$owner")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    env -i \
        PATH="$VX_COMPOSE_SAFE_PATH" \
        HOME="$root/home" \
        DOCKER_CONFIG="$root" \
        "$docker_bin" "$@"
}

vx_compose_registry_metadata_update() {
    local owner="$1"
    local registry="$2"
    local username="$3"
    local validation="$4"
    local root metadata temp_file now created

    root="$(vx_compose_registry_root "$owner")"
    metadata="$root/registries.json"
    now="$(vx_compose_now)"
    created="$(jq -r --arg registry "$registry" \
        '.[$registry].CREATED // empty' "$metadata")"
    [[ -n "$created" ]] || created="$now"
    temp_file="$(mktemp "$root/.registries.XXXXXX")"
    jq -S \
        --arg registry "$registry" \
        --arg username "$username" \
        --arg created "$created" \
        --arg rotated "$now" \
        --arg validation "$validation" \
        '.[$registry] = {
            REGISTRY: $registry,
            USERNAME: $username,
            CREATED: $created,
            ROTATED: $rotated,
            LAST_VALIDATION: $validation
        }' "$metadata" >"$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$metadata"
}

vx_compose_registry_add() {
    local owner="$1"
    local registry="$2"
    local username="$3"
    local password_file="$4"

    vx_compose_require_owner "$owner" || return 1
    vx_compose_registry_is_valid "$registry" \
        || {
            vx_compose_error 'invalid Docker registry host'
            return 1
        }
    [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$ ]] \
        || {
            vx_compose_error 'invalid Docker registry username'
            return 1
        }
    [[ -f "$password_file" && ! -L "$password_file" ]] \
        || {
            vx_compose_error 'registry password input must be a regular file'
            return 1
        }
    [[ "$(stat -c '%s' "$password_file")" -le 1048576 ]] \
        || {
            vx_compose_error 'registry password input exceeds the size limit'
            return 1
        }
    vx_compose_registry_prepare "$owner" || return 1
    vx_compose_registry_lock_acquire "$owner" || return 1
    if jq -e --arg registry "$registry" \
        '.[$registry].MANAGED_BY == "harbor"' \
        "$(vx_compose_registry_root "$owner")/registries.json" >/dev/null; then
        vx_compose_registry_lock_release
        vx_compose_error 'managed Harbor registry metadata is immutable'
        return 1
    fi
    if ! vx_compose_owner_docker "$owner" login "$registry" \
        --username "$username" --password-stdin <"$password_file" >/dev/null; then
        vx_compose_registry_lock_release
        vx_compose_error 'Docker registry validation failed'
        return 1
    fi
    chmod 0600 "$(vx_compose_registry_root "$owner")/config.json"
    if ! vx_compose_registry_metadata_update \
        "$owner" "$registry" "$username" succeeded; then
        vx_compose_registry_lock_release
        return 1
    fi
    vx_compose_owner_audit "$owner" registry-add succeeded \
        "registry_sha256=$(printf '%s' "$registry" | sha256sum | awk '{print $1}')" \
        || {
            vx_compose_registry_lock_release
            return 1
        }
    vx_compose_registry_lock_release
}

vx_compose_registry_delete() {
    local owner="$1"
    local registry="$2"
    local root metadata temp_file

    vx_compose_require_owner "$owner" || return 1
    vx_compose_registry_is_valid "$registry" \
        || {
            vx_compose_error 'invalid Docker registry host'
            return 1
        }
    vx_compose_registry_prepare "$owner" || return 1
    vx_compose_registry_lock_acquire "$owner" || return 1
    root="$(vx_compose_registry_root "$owner")"
    metadata="$root/registries.json"
    if jq -e --arg registry "$registry" \
        '.[$registry].MANAGED_BY == "harbor"' "$metadata" >/dev/null; then
        vx_compose_registry_lock_release
        vx_compose_error 'managed Harbor registry metadata is immutable'
        return 1
    fi
    vx_compose_owner_docker "$owner" logout "$registry" >/dev/null 2>&1 \
        || {
            vx_compose_registry_lock_release
            vx_compose_error 'Docker registry credential removal failed'
            return 1
        }
    chmod 0600 "$root/config.json"
    temp_file="$(mktemp "$root/.registries.XXXXXX")"
    jq -S --arg registry "$registry" 'del(.[$registry])' \
        "$metadata" >"$temp_file"
    chmod 0600 "$temp_file"
    mv -f -- "$temp_file" "$metadata"
    vx_compose_owner_audit "$owner" registry-delete succeeded \
        "registry_sha256=$(printf '%s' "$registry" | sha256sum | awk '{print $1}')" \
        || {
            vx_compose_registry_lock_release
            return 1
        }
    vx_compose_registry_lock_release
}

vx_compose_registry_list_json() {
    local owner="$1"

    vx_compose_registry_prepare "$owner" || return 1
    jq -S . "$(vx_compose_registry_root "$owner")/registries.json"
}
