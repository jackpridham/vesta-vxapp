#!/usr/bin/env bash

if declare -p VX_COMPOSE_SHELL_GROUP >/dev/null 2>&1 \
    && [[ "$(declare -p VX_COMPOSE_SHELL_GROUP)" \
        != 'declare -r VX_COMPOSE_SHELL_GROUP="vesta-compose-users"' ]]; then
    return 1
fi
if declare -p VX_COMPOSE_ACCESS_LOCK_ROOT >/dev/null 2>&1 \
    && [[ "$(declare -p VX_COMPOSE_ACCESS_LOCK_ROOT)" \
        != 'declare -r VX_COMPOSE_ACCESS_LOCK_ROOT="/run/lock/vesta-compose-user-access"' ]]; then
    return 1
fi
declare -p VX_COMPOSE_SHELL_GROUP >/dev/null 2>&1 \
    || VX_COMPOSE_SHELL_GROUP='vesta-compose-users'
declare -p VX_COMPOSE_ACCESS_LOCK_ROOT >/dev/null 2>&1 \
    || VX_COMPOSE_ACCESS_LOCK_ROOT='/run/lock/vesta-compose-user-access'
readonly VX_COMPOSE_SHELL_GROUP VX_COMPOSE_ACCESS_LOCK_ROOT
[[ "$(declare -p VX_COMPOSE_SHELL_GROUP)" \
    == 'declare -r VX_COMPOSE_SHELL_GROUP="vesta-compose-users"'
    && "$(declare -p VX_COMPOSE_ACCESS_LOCK_ROOT)" \
        == 'declare -r VX_COMPOSE_ACCESS_LOCK_ROOT="/run/lock/vesta-compose-user-access"' ]] \
    || return 1

vx_compose_shell_is_interactive() {
    [[ "$1" == bash || "$1" == /bin/bash || "$1" == /usr/bin/bash ]]
}

vx_compose_shell_passwd_by_uid() {
    /usr/bin/getent passwd "$1"
}

vx_compose_shell_passwd_by_name() {
    /usr/bin/getent passwd "$1"
}

vx_compose_shell_effective_uid() {
    printf '%s\n' "$EUID"
}

vx_compose_shell_actor_uid() {
    /usr/bin/id -u "$1"
}

vx_compose_shell_actor_gids() {
    /usr/bin/id -G "$1"
}

vx_compose_shell_getfacl() {
    /usr/bin/getfacl -cnep -- "$1"
}

vx_compose_shell_groups() {
    /usr/bin/id -nG "$1"
}

vx_compose_shell_actor_resolve() {
    local record actor uid gid home

    [[ "$(vx_compose_shell_effective_uid)" == 0 ]] || return 1
    [[ "${SUDO_UID:-}" =~ ^[1-9][0-9]*$
        && "${SUDO_GID:-}" =~ ^[1-9][0-9]*$
        && "${SUDO_USER:-}" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    record="$(vx_compose_shell_passwd_by_uid "$SUDO_UID")" || return 1
    [[ "$record" != *$'\n'* ]] || return 1
    IFS=: read -r actor _ uid gid _ home _ <<<"$record"
    [[ -n "$actor" && "$actor" == "$SUDO_USER" && "$uid" == "$SUDO_UID"
        && "$gid" == "$SUDO_GID" && "$actor" != root && "$actor" != admin
        && "$home" == "${HOMEDIR:-/home}/$actor" ]] || return 1
    printf '%s\n' "$actor"
}

vx_compose_shell_group_state() {
    local actor="$1" groups group
    groups="$(vx_compose_shell_groups "$actor")" || return 2
    while IFS= read -r group; do
        [[ "$group" == "$VX_COMPOSE_SHELL_GROUP" ]] && return 0
    done < <(printf '%s\n' "$groups" | tr ' ' '\n')
    return 1
}

vx_compose_shell_group_contains() {
    vx_compose_shell_group_state "$1"
}

vx_compose_shell_user_conf_secure() {
    local actor="$1" conf="$2" authority_uid actor_uid mode file_gid links gid
    local acl line qualifier permissions effective
    [[ -f "$conf" && ! -L "$conf" ]] || return 1
    authority_uid="$(vx_compose_authority_uid)" || return 1
    actor_uid="$(vx_compose_shell_actor_uid "$actor" 2>/dev/null)" || return 1
    [[ "$(stat -c '%u' "$conf" 2>/dev/null)" == "$authority_uid" ]] || return 1
    links="$(stat -c '%h' "$conf" 2>/dev/null)" || return 1
    [[ "$links" == 1 ]] || return 1
    mode="$(stat -c '%a' "$conf" 2>/dev/null)" || return 1
    [[ "$(stat -c '%u' "$conf")" != "$actor_uid" ]] || return 1
    (( (8#$mode & 0002) == 0 )) || return 1
    if (( (8#$mode & 0020) != 0 )); then
        file_gid="$(stat -c '%g' "$conf")" || return 1
        for gid in $(vx_compose_shell_actor_gids "$actor" 2>/dev/null); do
            [[ "$gid" != "$file_gid" ]] || return 1
        done
    fi
    acl="$(vx_compose_shell_getfacl "$conf" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ ^(user|group):([0-9]*):([rwx-]{3})([[:space:]]+#effective:([rwx-]{3}))?$ ]]; then
            qualifier="${BASH_REMATCH[2]}"
            permissions="${BASH_REMATCH[3]}"
            effective="${BASH_REMATCH[5]:-$permissions}"
            [[ -z "$qualifier" || "$effective" != *w* ]] || return 1
        elif [[ "$line" =~ ^(mask|other)::([rwx-]{3})$ ]]; then
            :
        else
            return 1
        fi
    done <<<"$acl"
}

vx_compose_shell_group_revoke() {
    local actor="$1"
    /usr/bin/getent group "$VX_COMPOSE_SHELL_GROUP" >/dev/null 2>&1 || return 1
    /usr/bin/gpasswd -d "$actor" -- "$VX_COMPOSE_SHELL_GROUP" >/dev/null 2>&1 || {
        vx_compose_shell_group_state "$actor"
        case $? in 1) return 0 ;; *) return 1 ;; esac
    }
}

vx_compose_shell_group_grant_if_eligible() {
    local actor="$1"
    vx_compose_shell_should_be_group_member "$actor" || return 0
    /usr/bin/getent group "$VX_COMPOSE_SHELL_GROUP" >/dev/null 2>&1 || return 1
    /usr/sbin/usermod -a -G "$VX_COMPOSE_SHELL_GROUP" -- "$actor"
}

vx_compose_shell_require_eligible_except_group() {
    local actor="$1" conf suspended shell limit record passwd_actor uid home passwd_shell
    vx_compose_require_owner "$actor" || return 1
    conf="$VESTA/data/users/$actor/user.conf"
    vx_compose_shell_user_conf_secure "$actor" "$conf" || return 1
    awk '
        !/^[A-Z][A-Z0-9_]*=('\''[^'\'']*'\''|)$/ { invalid = 1; next }
        /^SUSPENDED=/ { suspended++ }
        /^SHELL=/ { shell++ }
        /^DOCKER_PROJECTS=/ { projects++ }
        END {
            exit (invalid || suspended != 1 || shell != 1 || projects != 1)
        }
    ' "$conf" || return 1
    suspended="$(vx_compose_meta_get "$conf" SUSPENDED)" || return 1
    shell="$(vx_compose_meta_get "$conf" SHELL)" || return 1
    limit="$(vx_compose_meta_get "$conf" DOCKER_PROJECTS)" || return 1
    record="$(vx_compose_shell_passwd_by_name "$actor")" || return 1
    [[ "$record" != *$'\n'* ]] || return 1
    IFS=: read -r passwd_actor _ uid _ _ home passwd_shell <<<"$record"
    [[ "$passwd_actor" == "$actor" && "$uid" =~ ^[1-9][0-9]*$
        && "$home" == "${HOMEDIR:-/home}/$actor" && "${passwd_shell##*/}" == "$shell" ]] || return 1
    [[ "$suspended" == no ]] && vx_compose_shell_is_interactive "$shell" \
        && vx_compose_package_docker_is_enabled "$limit"
}

vx_compose_shell_should_be_group_member() {
    local actor="$1"
    [[ "$actor" != admin && "$actor" != root ]] || return 1
    vx_compose_shell_require_eligible_except_group "$actor"
}

vx_compose_shell_require_eligible() {
    local actor="$1"
    vx_compose_shell_access_deny_is_clear "$actor" || return 1
    vx_compose_shell_require_eligible_except_group "$actor" || return 1
    vx_compose_shell_group_state "$actor"
}

vx_compose_shell_access_deny_path() {
    printf '%s/%s.deny\n' "$VX_COMPOSE_ACCESS_LOCK_ROOT" "$1"
}

vx_compose_shell_access_deny_establish() {
    local owner="$1" path
    [[ "${VX_COMPOSE_ACCESS_LOCK_OWNER:-}" == "$owner"
        && "${VX_COMPOSE_ACCESS_LOCK_FD:-}" =~ ^[0-9]+$ ]] || return 1
    path="$(vx_compose_shell_access_deny_path "$owner")" || return 1
    install -m 0600 -o root -g root /dev/null "$path" || return 1
    [[ -f "$path" && ! -L "$path"
        && "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]]
}

vx_compose_shell_access_deny_is_clear() {
    local owner="$1" path
    path="$(vx_compose_shell_access_deny_path "$owner")" || return 1
    [[ ! -e "$path" && ! -L "$path" ]]
}

vx_compose_shell_access_transition_complete() {
    local owner="$1" path
    [[ "${VX_COMPOSE_ACCESS_LOCK_OWNER:-}" == "$owner" ]] || return 1
    vx_compose_shell_group_grant_if_eligible "$owner" || return 1
    path="$(vx_compose_shell_access_deny_path "$owner")" || return 1
    [[ -f "$path" && ! -L "$path"
        && "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]] || return 1
    rm -f -- "$path"
}

vx_compose_shell_require_standard_project() {
    local actor="$1" project="$2" root profile authority_uid authority_gid mode
    vx_compose_require_project "$actor" "$project" || return 1
    root="$(vx_compose_project_root "$actor" "$project")"
    authority_uid="$(vx_compose_authority_uid)" || return 1
    authority_gid="$(vx_compose_authority_gid)" || return 1
    [[ -f "$root/project.conf" && ! -L "$root/project.conf"
        && "$(stat -c '%u:%g' "$root/project.conf" 2>/dev/null)" \
            == "$authority_uid:$authority_gid" ]] || return 1
    mode="$(stat -c '%a' "$root/project.conf" 2>/dev/null)" || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    profile="$(vx_compose_meta_get "$root/project.conf" PROFILE)" || return 1
    [[ "$profile" == standard ]] || return 1
}

vx_compose_shell_access_lock_acquire() {
    local owner="$1" path
    vx_compose_owner_is_valid "$owner" || return 1
    if [[ -n "${VX_COMPOSE_ACCESS_LOCK_FD:-}" ]]; then
        [[ "${VX_COMPOSE_ACCESS_LOCK_OWNER:-}" == "$owner" ]] || return 1
        VX_COMPOSE_ACCESS_LOCK_DEPTH=$((VX_COMPOSE_ACCESS_LOCK_DEPTH + 1))
        return 0
    fi
    install -d -m 0700 -o root -g root "$VX_COMPOSE_ACCESS_LOCK_ROOT" || return 1
    [[ ! -L "$VX_COMPOSE_ACCESS_LOCK_ROOT"
        && "$(stat -c '%u:%g:%a:%F' "$VX_COMPOSE_ACCESS_LOCK_ROOT")" == '0:0:700:directory' ]] || return 1
    path="$VX_COMPOSE_ACCESS_LOCK_ROOT/$owner.lock"
    exec {VX_COMPOSE_ACCESS_LOCK_FD}>"$path" || return 1
    chmod 0600 "$path" || { exec {VX_COMPOSE_ACCESS_LOCK_FD}>&-; unset VX_COMPOSE_ACCESS_LOCK_FD; return 1; }
    [[ -f "$path" && ! -L "$path"
        && "$(stat -c '%u:%g:%a' "$path")" == '0:0:600' ]] \
        || { exec {VX_COMPOSE_ACCESS_LOCK_FD}>&-; unset VX_COMPOSE_ACCESS_LOCK_FD; return 1; }
    flock -x "$VX_COMPOSE_ACCESS_LOCK_FD" || { exec {VX_COMPOSE_ACCESS_LOCK_FD}>&-; unset VX_COMPOSE_ACCESS_LOCK_FD; return 1; }
    VX_COMPOSE_ACCESS_LOCK_OWNER="$owner"
    VX_COMPOSE_ACCESS_LOCK_DEPTH=1
}

vx_compose_shell_access_lock_close_child_copy() {
    [[ "${VX_COMPOSE_ACCESS_LOCK_FD:-}" =~ ^[0-9]+$ ]] || return 0
    exec {VX_COMPOSE_ACCESS_LOCK_FD}>&-
}

vx_compose_shell_access_lock_release() {
    [[ -n "${VX_COMPOSE_ACCESS_LOCK_FD:-}" ]] || return 0
    if (( VX_COMPOSE_ACCESS_LOCK_DEPTH > 1 )); then
        VX_COMPOSE_ACCESS_LOCK_DEPTH=$((VX_COMPOSE_ACCESS_LOCK_DEPTH - 1))
        return 0
    fi
    flock -u "$VX_COMPOSE_ACCESS_LOCK_FD" || return 1
    exec {VX_COMPOSE_ACCESS_LOCK_FD}>&-
    unset VX_COMPOSE_ACCESS_LOCK_FD VX_COMPOSE_ACCESS_LOCK_OWNER VX_COMPOSE_ACCESS_LOCK_DEPTH
}

vx_compose_shell_snapshot_stdin() {
    local vx_snapshot_internal_kind="${1-}" vx_snapshot_internal_max_bytes="${2-}"
    local vx_snapshot_internal_root_name="${3-}" vx_snapshot_internal_file_name="${4-}"
    local vx_snapshot_internal_root='' vx_snapshot_internal_file='' vx_snapshot_internal_id
    local vx_snapshot_internal_declaration vx_snapshot_internal_bytes vx_snapshot_internal_name
    local vx_snapshot_internal_attempts=0
    (( $# == 4 )) || return 1
    [[ "$vx_snapshot_internal_kind" =~ ^(compose|secret|registry|recipient)$
        && "$vx_snapshot_internal_max_bytes" =~ ^[1-9][0-9]*$
        && "$vx_snapshot_internal_root_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$
        && "$vx_snapshot_internal_file_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$
        && "$vx_snapshot_internal_root_name" != "$vx_snapshot_internal_file_name"
        && "$vx_snapshot_internal_root_name" != vx_snapshot_internal_*
        && "$vx_snapshot_internal_file_name" != vx_snapshot_internal_* ]] || return 1
    for vx_snapshot_internal_name in \
        "$vx_snapshot_internal_root_name" "$vx_snapshot_internal_file_name"; do
        if vx_snapshot_internal_declaration="$(declare -p "$vx_snapshot_internal_name" 2>/dev/null)"; then
            [[ "$vx_snapshot_internal_declaration" == 'declare -- '* ]] || return 1
        fi
    done
    local -n vx_snapshot_internal_root_output="$vx_snapshot_internal_root_name"
    local -n vx_snapshot_internal_file_output="$vx_snapshot_internal_file_name"
    vx_snapshot_internal_root_output=
    vx_snapshot_internal_file_output=
    if [[ "$vx_snapshot_internal_kind" == compose ]]; then
        while (( vx_snapshot_internal_attempts < 128 )); do
            vx_snapshot_internal_id="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')" || return 1
            [[ "$vx_snapshot_internal_id" =~ ^[a-f0-9]{32}$ ]] || return 1
            vx_snapshot_internal_root="/tmp/vx-compose-web.$vx_snapshot_internal_id"
            if mkdir -m 0700 -- "$vx_snapshot_internal_root" 2>/dev/null; then
                break
            fi
            [[ -e "$vx_snapshot_internal_root" || -L "$vx_snapshot_internal_root" ]] || return 1
            vx_snapshot_internal_root=
            vx_snapshot_internal_attempts=$((vx_snapshot_internal_attempts + 1))
        done
        [[ -n "$vx_snapshot_internal_root" ]] || return 1
        vx_snapshot_internal_file="$vx_snapshot_internal_root/compose.yaml"
    else
        vx_snapshot_internal_root="$(mktemp -d /var/tmp/vesta-compose-shell.XXXXXXXX)" || return 1
        vx_snapshot_internal_file="$vx_snapshot_internal_root/$vx_snapshot_internal_kind.input"
    fi
    # The nameref outputs are consumed through caller-selected variable names.
    # shellcheck disable=SC2034
    vx_snapshot_internal_root_output="$vx_snapshot_internal_root"
    # shellcheck disable=SC2034
    vx_snapshot_internal_file_output="$vx_snapshot_internal_file"
    chmod 0700 "$vx_snapshot_internal_root" \
        || { rm -rf -- "$vx_snapshot_internal_root"; return 1; }
    install -m 0600 /dev/null "$vx_snapshot_internal_file" \
        || { rm -rf -- "$vx_snapshot_internal_root"; return 1; }
    head -c "$((vx_snapshot_internal_max_bytes + 1))" >"$vx_snapshot_internal_file" \
        || { rm -rf -- "$vx_snapshot_internal_root"; return 1; }
    chmod 0600 "$vx_snapshot_internal_file" \
        || { rm -rf -- "$vx_snapshot_internal_root"; return 1; }
    vx_snapshot_internal_bytes="$(stat -c '%s' "$vx_snapshot_internal_file")" \
        || { rm -rf -- "$vx_snapshot_internal_root"; return 1; }
    if (( vx_snapshot_internal_bytes == 0
            || vx_snapshot_internal_bytes > vx_snapshot_internal_max_bytes )) \
        || [[ -L "$vx_snapshot_internal_root" || -L "$vx_snapshot_internal_file"
            || "$(stat -c '%u:%g:%a:%F' "$vx_snapshot_internal_root")" != '0:0:700:directory'
            || "$(stat -c '%u:%g:%a:%F' "$vx_snapshot_internal_file")" != '0:0:600:regular file' ]]; then
        rm -rf -- "$vx_snapshot_internal_root"
        return 1
    fi
}

vx_compose_shell_broker_audit() {
    local actor="$1" operation="$2" owner="$3" project="$4" result="$5"
    local path="$VESTA/data/log/compose-shell-audit.log" event
    [[ "$actor" =~ ^[a-z0-9][a-z0-9_-]{0,31}$
        && "$operation" =~ ^[a-z][a-z0-9-]{0,31}$
        && "$owner" == "$actor" && "$result" =~ ^(succeeded|failed)$
        && ( -z "$project" || "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ) ]] || return 1
    event="$(jq -cn --arg timestamp "$(vx_compose_now)" --arg actor "$actor" \
        --arg operation "$operation" --arg owner "$owner" --arg project "$project" \
        --arg result "$result" '{TIMESTAMP:$timestamp,ACTOR:$actor,OPERATION:$operation,OWNER:$owner,PROJECT:$project,RESULT:$result}')" || return 1
    vx_compose_audit_append "$path" 0600 "$event"
}
