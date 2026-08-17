#!/usr/bin/env bash

vx_migration_validate_target() {
    local target=${1-}
    [[ "$target" =~ ^root@([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)$ ]]
}

vx_migration_validate_port() {
    local port=${1-}
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

vx_migration_validate_identity() {
    local identity=${1-}
    [[ -z "$identity" || "$identity" == "-" || ( -f "$identity" && ! -L "$identity" ) ]]
}

vx_migration_target_is_local() {
    local target=$1
    local host=${target#root@}
    local address local_address
    case "$host" in
        localhost|localhost.localdomain|127.*|"$(hostname)"|"$(hostname -f 2>/dev/null)")
            return 0
            ;;
    esac
    while IFS= read -r address; do
        for local_address in $(hostname -I 2>/dev/null); do
            [[ "$address" == "$local_address" ]] && return 0
        done
    done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    return 1
}

vx_migration_prompt_connection() {
    local target_name=${1-}
    local port_name=${2-}
    local identity_name=${3-}
    local -n target_ref=$target_name
    local -n port_ref=$port_name
    local -n identity_ref=$identity_name

    if [[ -z "$target_ref" ]]; then
        read -r -p "Target SSH host (root@hostname): " target_ref
    fi
    if [[ -z "$port_ref" ]]; then
        read -r -p "Target SSH port [22]: " port_ref
        port_ref=${port_ref:-22}
    fi
    if [[ -z "$identity_ref" ]]; then
        read -r -p "SSH private key path [OpenSSH prompt/agent]: " identity_ref
        identity_ref=${identity_ref:--}
    fi

    vx_migration_validate_target "$target_ref" || {
        echo "Error: target must use the form root@hostname" >&2
        return 2
    }
    vx_migration_validate_port "$port_ref" || {
        echo "Error: invalid SSH port" >&2
        return 2
    }
    vx_migration_validate_identity "$identity_ref" || {
        echo "Error: SSH identity must be a regular local file or '-'" >&2
        return 2
    }
    if vx_migration_target_is_local "$target_ref"; then
        echo "Error: migration target resolves to this host" >&2
        return 2
    fi
}

vx_migration_transport_open() {
    local target=$1
    local port=$2
    local identity=$3
    local control_dir=$4
    local control_path="$control_dir/control"

    mkdir -p -- "$control_dir"
    chmod 0700 "$control_dir"

    VX_MIGRATION_SSH_OPTIONS=(
        -o "ControlMaster=auto"
        -o "ControlPath=$control_path"
        -o "ControlPersist=10800"
        -o "StrictHostKeyChecking=accept-new"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=6"
        -p "$port"
    )
    VX_MIGRATION_SCP=(
        /usr/bin/scp
        -o "ControlMaster=auto"
        -o "ControlPath=$control_path"
        -o "StrictHostKeyChecking=accept-new"
        -P "$port"
    )
    if [[ "$identity" != "-" ]]; then
        VX_MIGRATION_SSH_OPTIONS+=( -i "$identity" -o IdentitiesOnly=yes )
        VX_MIGRATION_SCP+=( -i "$identity" -o IdentitiesOnly=yes )
    fi
    echo "Connecting to $target. OpenSSH may now request credentials."
    /usr/bin/ssh "${VX_MIGRATION_SSH_OPTIONS[@]}" -MNf "$target"
    VX_MIGRATION_CONTROL_TARGET=$target
    VX_MIGRATION_CONTROL_PATH=$control_path
}

vx_migration_transport_exec() {
    # All callers pass fixed commands and values validated by this module or
    # root-owned mktemp output before OpenSSH constructs the remote command.
    # shellcheck disable=SC2029
    /usr/bin/ssh "${VX_MIGRATION_SSH_OPTIONS[@]}" \
        "$VX_MIGRATION_CONTROL_TARGET" "$@"
}

vx_migration_transport_copy() {
    local source=$1
    local remote_path=$2
    "${VX_MIGRATION_SCP[@]}" -- "$source" \
        "$VX_MIGRATION_CONTROL_TARGET:$remote_path"
}

vx_migration_transport_close() {
    if [[ -n "${VX_MIGRATION_CONTROL_TARGET:-}" \
        && -n "${VX_MIGRATION_CONTROL_PATH:-}" ]]; then
        /usr/bin/ssh -o "ControlPath=$VX_MIGRATION_CONTROL_PATH" \
            -O exit "$VX_MIGRATION_CONTROL_TARGET" >/dev/null 2>&1 || :
    fi
}
