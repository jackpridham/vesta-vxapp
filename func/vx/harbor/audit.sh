#!/usr/bin/env bash

vx_harbor_audit() {
    local owner="$1"
    local operation="$2"
    local result="$3"
    local reason="$4"
    local root path lock_path event lock_fd timestamp

    [[ "$owner" == system || "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    [[ "$operation" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || return 1
    [[ "$result" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || return 1
    [[ ${#reason} -le 256 && "$reason" != *$'\n'* && "$reason" != *$'\r'* ]] || return 1
    root="$(vx_harbor_root)" || return 1
    /usr/bin/install -d -m 0700 "$root" "$root/locks" || return 1
    _vx_harbor_secure_directory "$root" || return 1
    _vx_harbor_secure_directory "$root/locks" || return 1
    path="$root/audit.log"
    lock_path="$root/locks/audit.lock"
    if [[ -e "$path" || -L "$path" ]]; then
        vx_harbor_secure_regular_file "$path" 0600 || return 1
    fi
    if [[ -e "$lock_path" || -L "$lock_path" ]]; then
        vx_harbor_secure_regular_file "$lock_path" 0600 || return 1
    fi
    exec {lock_fd}>>"$lock_path" || return 1
    /usr/bin/chmod 0600 "$lock_path" || { exec {lock_fd}>&-; return 1; }
    vx_harbor_secure_regular_file "$lock_path" 0600 \
        || { exec {lock_fd}>&-; return 1; }
    /usr/bin/flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
    timestamp="$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || {
        /usr/bin/flock -u "$lock_fd" || :
        exec {lock_fd}>&-
        return 1
    }
    event="$(/usr/bin/jq -cS -n --arg timestamp "$timestamp" --arg owner "$owner" \
        --arg operation "$operation" --arg result "$result" --arg reason "$reason" \
        '{TIMESTAMP:$timestamp,OWNER:$owner,OPERATION:$operation,RESULT:$result,REASON:$reason}')" \
        || {
            /usr/bin/flock -u "$lock_fd" || :
            exec {lock_fd}>&-
            return 1
        }
    if ! printf '%s\n' "$event" >>"$path" \
        || ! /usr/bin/chmod 0600 "$path" \
        || ! vx_harbor_secure_regular_file "$path" 0600 \
        || ! _vx_harbor_fsync "$path" \
        || ! _vx_harbor_fsync "$root"; then
        /usr/bin/flock -u "$lock_fd" || :
        exec {lock_fd}>&-
        return 1
    fi
    /usr/bin/flock -u "$lock_fd" || { exec {lock_fd}>&-; return 1; }
    exec {lock_fd}>&-
}
