#!/usr/bin/env bash

# Used by storage.sh after this file is sourced through main.sh.
# shellcheck disable=SC2034
VX_COMPOSE_SCHEMA_VERSION='1'
VX_COMPOSE_DEFAULT_PROFILE='standard'
VX_COMPOSE_POLICY_SCHEMA_VERSION='1'
VX_COMPOSE_POLICY_VALIDATOR_VERSION='2'
# Used by lifecycle.sh after this file is sourced through main.sh.
# shellcheck disable=SC2034
VX_COMPOSE_WAIT_TIMEOUT='60'
# Used by canonicalize.sh and lifecycle.sh after this file is sourced.
# shellcheck disable=SC2034
VX_COMPOSE_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
VX_COMPOSE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${VESTA:-}/conf/vx-docker-policy.conf" ]]; then
    # shellcheck source=conf/vx-docker-policy.conf
    source "$VESTA/conf/vx-docker-policy.conf"
    VX_COMPOSE_POLICY_SCHEMA_VERSION="$VX_DOCKER_POLICY_SCHEMA_VERSION"
    VX_COMPOSE_POLICY_VALIDATOR_VERSION="$VX_DOCKER_POLICY_VALIDATOR_VERSION"
fi
[[ "$VX_COMPOSE_POLICY_SCHEMA_VERSION" =~ ^[1-9][0-9]*$ ]] \
    || VX_COMPOSE_POLICY_SCHEMA_VERSION='1'
[[ "$VX_COMPOSE_POLICY_VALIDATOR_VERSION" =~ ^[1-9][0-9]*$ ]] \
    || VX_COMPOSE_POLICY_VALIDATOR_VERSION='1'

vx_compose_error() {
    echo "$1" >&2
    return 1
}

vx_compose_project_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

vx_compose_owner_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

vx_compose_require_owner() {
    local owner="$1"

    vx_compose_owner_is_valid "$owner" \
        || {
            vx_compose_error "invalid Compose project owner: $owner"
            return 1
        }
    [[ -d "$VESTA/data/users/$owner" ]] \
        || {
            vx_compose_error "Vesta user does not exist: $owner"
            return 1
        }
}

vx_compose_require_project_key() {
    vx_compose_project_is_valid "$1" \
        || {
            vx_compose_error "invalid Compose project key: $1"
            return 1
        }
}

vx_compose_runtime_name() {
    local owner="$1"
    local project="$2"

    printf 'vx-%s-%s\n' "$owner" "$project"
}

vx_compose_now() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

vx_compose_authority_uid() {
    if (( EUID == 0 )); then
        printf '0\n'
    else
        printf '%s\n' "$EUID"
    fi
}

vx_compose_authority_gid() {
    if (( EUID == 0 )); then
        printf '0\n'
    else
        id -g
    fi
}

vx_compose_control_file_is_secure() {
    local path="$1" mode="$2" expected

    expected="$(vx_compose_authority_uid):$(vx_compose_authority_gid):$mode:regular file" \
        || return 1
    [[ ! -L "$path"
        && "$(stat -c '%u:%g:%a:%F' "$path" 2>/dev/null)" == "$expected" ]]
}

vx_compose_control_file_protect() {
    local path="$1" mode="$2" expected_uid expected_gid

    expected_uid="$(vx_compose_authority_uid)" || return 1
    expected_gid="$(vx_compose_authority_gid)" || return 1
    if (( EUID == 0 )); then
        chown "$expected_uid:$expected_gid" "$path" || return 1
    else
        [[ "$(stat -c '%u' "$path" 2>/dev/null)" == "$expected_uid" ]] \
            || return 1
        chgrp "$expected_gid" "$path" || return 1
    fi
    chmod "$mode" "$path"
}

vx_compose_docker_bin() {
    if [[ -n "${VX_COMPOSE_DOCKER_BIN:-}" ]]; then
        printf '%s\n' "$VX_COMPOSE_DOCKER_BIN"
        return
    fi

    command -v docker
}

vx_compose_require_runtime_tools() {
    local docker_bin

    command -v jq >/dev/null 2>&1 \
        || {
            vx_compose_error 'jq is required for Compose project management'
            return 1
        }
    docker_bin="$(vx_compose_docker_bin)" \
        || {
            vx_compose_error 'Docker is required for Compose project management'
            return 1
        }
    [[ -x "$docker_bin" ]] \
        || {
            vx_compose_error "Docker executable is not usable: $docker_bin"
            return 1
        }
    "$docker_bin" compose version >/dev/null 2>&1 \
        || {
            vx_compose_error 'Docker Compose v2 is required for project management'
            return 1
        }
}

vx_compose_profile_is_available() {
    local profile_path configured='yes'

    profile_path="$(vx_compose_profile_path "$1")" || return 1
    case "$1" in
        standard)
            configured="${VX_DOCKER_PROFILE_STANDARD_ENABLED:-yes}"
            ;;
        admin-approved)
            configured="${VX_DOCKER_PROFILE_ADMIN_APPROVED_ENABLED:-yes}"
            ;;
        slave-vxapp)
            configured="${VX_DOCKER_PROFILE_SLAVE_VXAPP_ENABLED:-yes}"
            ;;
    esac
    [[ "$configured" == yes ]] || return 1
    jq -e '.enabled == true' "$profile_path" >/dev/null 2>&1
}

vx_compose_profile_path() {
    local profile="$1"
    local profile_path

    [[ "$profile" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
    profile_path="$VX_COMPOSE_LIB_DIR/profiles/$profile.json"
    [[ -f "$profile_path" ]] || return 1
    printf '%s\n' "$profile_path"
}

vx_compose_profile_version() {
    local profile_path

    profile_path="$(vx_compose_profile_path "$1")" || return 1
    jq -er '.version | select(type == "number" and . >= 1) | floor' \
        "$profile_path"
}
