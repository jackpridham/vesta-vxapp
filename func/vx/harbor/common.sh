#!/usr/bin/env bash

vx_harbor_root() {
    printf '%s\n' "$VESTA/data/harbor"
}

vx_harbor_data_root() {
    printf '%s\n' '/var/lib/vesta-harbor'
}

_vx_harbor_authority_uid() {
    printf '0\n'
}

_vx_harbor_authority_gid() {
    printf '0\n'
}

_vx_harbor_require_root() {
    (( EUID == 0 ))
}

_vx_harbor_install_directory() {
    /usr/bin/install -d -o 0 -g 0 -m 0700 "$1"
}

_vx_harbor_secure_file_set() {
    /usr/bin/chown 0:0 "$1" && /usr/bin/chmod "$2" "$1"
}

_vx_harbor_fsync() {
    /usr/bin/python3 - "$1" <<'PY'
import os
import sys

flags = os.O_RDONLY
if os.path.isdir(sys.argv[1]):
    flags |= getattr(os, "O_DIRECTORY", 0)
descriptor = os.open(sys.argv[1], flags)
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

_vx_harbor_secure_directory() {
    local path="$1"
    local expected_uid expected_gid
    [[ -d "$path" && ! -L "$path" ]] || return 1
    expected_uid="$(_vx_harbor_authority_uid)" || return 1
    expected_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:700" ]]
}

vx_harbor_secure_regular_file() {
    local path="$1"
    local mode="$2"
    local expected_uid expected_gid

    [[ "$mode" =~ ^0[0-7]{3}$ ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    expected_uid="$(_vx_harbor_authority_uid)" || return 1
    expected_gid="$(_vx_harbor_authority_gid)" || return 1
    [[ "$(/usr/bin/stat -c '%u:%g:%h:%a' -- "$path" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:1:${mode#0}" ]]
}

vx_harbor_json_write_atomic() {
    local destination="$1"
    local source="$2"
    local directory temporary

    _vx_harbor_require_root || return 1
    directory="$(dirname -- "$destination")" || return 1
    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    [[ -f "$source" && ! -L "$source" ]] || return 1
    temporary="$(/usr/bin/mktemp "$directory/.harbor-json.XXXXXX")" || return 1
    if ! /usr/bin/jq -S . "$source" >"$temporary" \
        || ! _vx_harbor_secure_file_set "$temporary" 0600; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    if ! vx_harbor_secure_regular_file "$temporary" 0600 \
        || ! _vx_harbor_fsync "$temporary" \
        || ! /usr/bin/mv -fT -- "$temporary" "$destination" \
        || ! _vx_harbor_fsync "$directory" \
        || ! vx_harbor_secure_regular_file "$destination" 0600; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

vx_harbor_provider_prepare() {
    local root source directory
    _vx_harbor_require_root || return 1
    root="$(vx_harbor_root)" || return 1

    _vx_harbor_install_directory "$root" || return 1
    _vx_harbor_secure_directory "$root" || return 1
    for directory in owners observations secrets release backups locks; do
        _vx_harbor_install_directory "$root/$directory" || return 1
        _vx_harbor_secure_directory "$root/$directory" || return 1
    done
    if [[ -e "$root/provider.json" || -L "$root/provider.json" ]]; then
        vx_harbor_secure_regular_file "$root/provider.json" 0600 || return 1
        /usr/bin/jq -e '
            type == "object" and .SCHEMA == 1
            and (.MODE == "disabled" or .MODE == "managed")
        ' "$root/provider.json" >/dev/null 2>&1
        return
    fi

    source="$(/usr/bin/mktemp "$root/.provider-source.XXXXXX")" || return 1
    if ! /usr/bin/jq -n '{
        SCHEMA: 1,
        MODE: "disabled",
        PINNED_VERSION: "v2.15.0",
        RUNNING_VERSION: null,
        INSTALLATION_ID: null,
        ORIGIN: null,
        RELEASE_MANIFEST_SHA256: null,
        LAST_HEALTH_AT: null,
        LAST_BACKUP_ID: null,
        LAST_RESTORE_TEST_AT: null,
        LAST_UPGRADE: null
    }' >"$source" \
        || ! vx_harbor_json_write_atomic "$root/provider.json" "$source"; then
        /usr/bin/rm -f -- "$source"
        return 1
    fi
    /usr/bin/rm -f -- "$source"
}

vx_harbor_provider_mode() {
    local root mode
    root="$(vx_harbor_root)" || return 1
    vx_harbor_secure_regular_file "$root/provider.json" 0600 || return 1
    mode="$(/usr/bin/jq -er '.MODE | select(. == "disabled" or . == "managed")' \
        "$root/provider.json" 2>/dev/null)" || return 1
    printf '%s\n' "$mode"
}

vx_harbor_provider_enabled() {
    [[ "$(vx_harbor_provider_mode)" == managed ]]
}

vx_harbor_provider_lock_acquire() {
    local mode="$1"
    local root lock_path requested_flag

    _vx_harbor_require_root || return 1
    [[ "$mode" == shared || "$mode" == exclusive ]] || return 1
    if [[ -n "${VX_HARBOR_PROVIDER_LOCK_FD:-}" ]]; then
        [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == "$mode" \
            && "${VX_HARBOR_PROVIDER_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ ]] || return 1
        VX_HARBOR_PROVIDER_LOCK_DEPTH=$((VX_HARBOR_PROVIDER_LOCK_DEPTH + 1))
        return 0
    fi
    root="$(vx_harbor_root)" || return 1
    _vx_harbor_install_directory "$root/locks" || return 1
    lock_path="$root/locks/provider.lock"
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
        vx_harbor_secure_regular_file "$lock_path" 0600 || return 1
    fi
    exec {VX_HARBOR_PROVIDER_LOCK_FD}>>"$lock_path" || return 1
    _vx_harbor_secure_file_set "$lock_path" 0600 || {
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    }
    vx_harbor_secure_regular_file "$lock_path" 0600 || {
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    }
    requested_flag=-s
    [[ "$mode" == exclusive ]] && requested_flag=-x
    if ! /usr/bin/flock "$requested_flag" "$VX_HARBOR_PROVIDER_LOCK_FD"; then
        exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
        unset VX_HARBOR_PROVIDER_LOCK_FD
        return 1
    fi
    VX_HARBOR_PROVIDER_LOCK_MODE="$mode"
    VX_HARBOR_PROVIDER_LOCK_DEPTH=1
}

vx_harbor_provider_lock_release() {
    [[ "${VX_HARBOR_PROVIDER_LOCK_FD:-}" =~ ^[0-9]+$ \
        && "${VX_HARBOR_PROVIDER_LOCK_DEPTH:-}" =~ ^[1-9][0-9]*$ \
        && ( "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == shared \
            || "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ) ]] || return 1
    if (( VX_HARBOR_PROVIDER_LOCK_DEPTH > 1 )); then
        VX_HARBOR_PROVIDER_LOCK_DEPTH=$((VX_HARBOR_PROVIDER_LOCK_DEPTH - 1))
        return 0
    fi
    /usr/bin/flock -u "$VX_HARBOR_PROVIDER_LOCK_FD" || return 1
    exec {VX_HARBOR_PROVIDER_LOCK_FD}>&-
    unset VX_HARBOR_PROVIDER_LOCK_FD VX_HARBOR_PROVIDER_LOCK_MODE \
        VX_HARBOR_PROVIDER_LOCK_DEPTH
}

vx_harbor_owner_state_path() {
    local owner="$1"
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    printf '%s/owners/%s.json\n' "$(vx_harbor_root)" "$owner"
}

_vx_harbor_authoritative_hostname() {
    local hostname_file

    if [[ -d /etc/sysconfig ]]; then
        hostname_file=/etc/sysconfig/network
        [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || return 1
        /usr/bin/awk -F= '
            $1 == "HOSTNAME" {
                value=substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]\047\"]+|[[:space:]\047\"]+$/, "", value)
                print value
                found++
            }
            END { if (found != 1) exit 1 }
        ' "$hostname_file"
        return
    fi

    hostname_file=/etc/hostname
    [[ -f "$hostname_file" && ! -L "$hostname_file" ]] || return 1
    /usr/bin/awk 'NF { print; found++ } END { if (found != 1) exit 1 }' \
        "$hostname_file"
}

vx_harbor_origin_json() {
    local nginx_file hostname certificate
    local -a ports certificates
    nginx_file="$VESTA/nginx/conf/nginx.conf"
    [[ -f "$nginx_file" && ! -L "$nginx_file" ]] || return 1
    hostname="$(_vx_harbor_authoritative_hostname)" || return 1
    hostname="${hostname%.}"
    hostname="${hostname,,}"
    [[ "$hostname" != localhost && "$hostname" == *.* \
        && ! "$hostname" =~ ^[0-9]+(\.[0-9]+){3}$ \
        && "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
        || return 1

    mapfile -t ports < <(/usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /listen[[:space:]]/ && /(^|[[:space:]])ssl([[:space:];]|$)/ {
            for (i = 1; i <= NF; i++) {
                token=$i
                gsub(/;/, "", token)
                if (token == "listen") {
                    token=$(i + 1); gsub(/;/, "", token)
                    sub(/^.*:/, "", token)
                    if (token ~ /^[0-9]+$/) print token
                }
            }
        }
    ' "$nginx_file") || return 1
    [[ "${#ports[@]}" -eq 1 && "${ports[0]}" -ge 1 && "${ports[0]}" -le 65535 ]] \
        || return 1
    mapfile -t certificates < <(/usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*ssl_certificate[[:space:]]+/ {
            value=$2; gsub(/;/, "", value); print value
        }
    ' "$nginx_file" | /usr/bin/sort -u) || return 1
    [[ "${#certificates[@]}" -eq 1 ]] || return 1
    certificate="${certificates[0]}"
    [[ "$certificate" == /* ]] || certificate="$VESTA/nginx/conf/$certificate"
    [[ -f "$certificate" && ! -L "$certificate" ]] || return 1
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/openssl x509 -in "$certificate" \
        -noout -checkend 0 >/dev/null 2>&1 || return 1
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/openssl x509 -in "$certificate" \
        -noout -checkhost "$hostname" >/dev/null 2>&1 || return 1
    /usr/bin/jq -n --arg hostname "$hostname" --argjson port "${ports[0]}" '
        {HOSTNAME: $hostname, PORT: $port,
         REGISTRY: ($hostname + ":" + ($port | tostring)),
         ORIGIN: ("https://" + $hostname + ":" + ($port | tostring))}
    '
}
