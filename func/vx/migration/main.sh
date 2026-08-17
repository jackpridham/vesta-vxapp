#!/usr/bin/env bash

# shellcheck source=func/vx/migration/transport.sh
source "$VESTA/func/vx/migration/transport.sh"
# shellcheck source=func/vx/migration/archive.sh
source "$VESTA/func/vx/migration/archive.sh"

vx_migration_require_root() {
    [[ $(id -u) -eq 0 ]] || {
        echo "Error: migration commands must run as root" >&2
        return 1
    }
}

vx_migration_confirm() {
    local description=$1
    local answer
    [[ "${VX_MIGRATION_ASSUME_YES:-no}" == yes ]] && return 0
    printf '%s\n' "$description"
    read -r -p "Type 'yes' to continue: " answer
    [[ "$answer" == yes ]]
}

vx_migration_run() {
    local mode=$1
    local username=$2
    local target=$3
    local port=$4
    local identity=$5
    local force=$6
    local normalize=$7
    local stage control_dir archive remote_dir receiver source_major target_major
    local archive_bytes remote_available required_bytes

    stage=$(mktemp -d /var/tmp/vesta-migration.XXXXXX) || return 1
    control_dir=$(mktemp -d /tmp/vm-ssh.XXXXXX) || {
        rm -rf -- "$stage"
        return 1
    }
    chmod 0700 "$stage" "$control_dir"
    trap '
        if [[ -n "${remote_dir:-}" && -n "${VX_MIGRATION_CONTROL_TARGET:-}" ]]; then
            vx_migration_transport_exec /bin/rm -rf -- "$remote_dir" >/dev/null 2>&1 || :
        fi
        vx_migration_transport_close
        rm -rf -- "${stage:-}" "${control_dir:-}"
        trap - RETURN
    ' RETURN

    vx_migration_transport_open "$target" "$port" "$identity" "$control_dir" \
        || return 1
    remote_dir=$(vx_migration_transport_exec \
        'umask 077; id -u | grep -qx 0 && mktemp -d /var/tmp/vesta-migration.XXXXXX') \
        || return 1
    [[ "$remote_dir" =~ ^/var/tmp/vesta-migration\.[A-Za-z0-9]+$ ]] || {
        echo "Error: target returned an invalid staging path" >&2
        return 1
    }
    source_major=$(vx_migration_debian_major) || {
        echo "Error: source host must run Debian" >&2
        return 1
    }
    if [[ "$mode" == host && ! -d "$VESTA/install/debian/$source_major" ]]; then
        echo "Error: this Vesta instance has no installer payload for Debian $source_major" >&2
        return 1
    fi
    target_major=$(vx_migration_transport_exec \
        'test -r /etc/debian_version && cut -d. -f1 </etc/debian_version') \
        || {
            echo "Error: target host must run Debian" >&2
            return 1
        }
    [[ "$source_major" == "$target_major" ]] || {
        echo "Error: source and target Debian major versions differ" >&2
        return 1
    }
    if [[ "$mode" == user ]]; then
        vx_migration_transport_exec \
            'test -x /usr/local/vesta/bin/v-restore-user' || {
            echo "Error: user migration target must already have Vesta installed" >&2
            return 1
        }
        vx_migration_transport_exec \
            "test ! -d /usr/local/vesta/data/users/$username" || {
            echo "Error: target Vesta user already exists" >&2
            return 1
        }
    elif vx_migration_transport_exec \
        'test -x /usr/local/vesta/bin/v-list-users'; then
        [[ "$force" == yes ]] || {
            echo "Error: Vesta is already installed on target; FORCE=yes is required" >&2
            return 1
        }
        if vx_migration_transport_exec \
            'find /usr/local/vesta/data/users -mindepth 1 -maxdepth 1 -type d ! -name admin -print -quit | grep -q .'; then
            echo "Error: target contains non-admin Vesta users" >&2
            return 1
        fi
    elif ! vx_migration_transport_exec \
        'test ! -e /usr/local/vesta && ! id -u admin >/dev/null 2>&1'; then
        echo "Error: target is not clean enough for unattended Vesta installation" >&2
        return 1
    fi

    echo "Creating integrity-protected $mode migration bundle..."
    if [[ "$mode" == host ]]; then
        archive=$(vx_migration_create_host_bundle "$stage") || return 1
    else
        archive=$(vx_migration_create_user_bundle "$username" "$stage") || return 1
    fi
    archive_bytes=$(stat -c %s "$archive") || return 1
    remote_available=$(vx_migration_transport_exec \
        "df -PB1 /var/tmp | awk 'NR == 2 {print \$4}'") || return 1
    [[ "$remote_available" =~ ^[0-9]+$ ]] || {
        echo "Error: could not determine target staging capacity" >&2
        return 1
    }
    required_bytes=$((archive_bytes * 6 + 1073741824))
    (( remote_available >= required_bytes )) || {
        echo "Error: target /var/tmp lacks migration staging capacity" >&2
        return 1
    }

    receiver="$VESTA/func/vx/migration/receive.sh"
    vx_migration_transport_copy "$receiver" "$remote_dir/receive.sh" || return 1
    vx_migration_transport_copy "$archive" "$remote_dir/$(basename "$archive")" \
        || return 1
    vx_migration_transport_copy "$archive.sha256" \
        "$remote_dir/$(basename "$archive").sha256" || return 1

    echo "Applying migration on $target..."
    vx_migration_transport_exec /bin/bash "$remote_dir/receive.sh" \
        "$mode" "$remote_dir/$(basename "$archive")" \
        "$remote_dir/$(basename "$archive").sha256" "$force" "$normalize"
    local result=$?
    (( result == 0 )) || return "$result"
    echo "Migration completed on $target. Source data and DNS remain unchanged."
}
