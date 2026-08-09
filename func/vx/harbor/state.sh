#!/usr/bin/env bash

VX_HARBOR_INTEGRATION_PERMISSION_VERSION=4

_vx_harbor_install_journal_path() {
    printf '%s/operations/provider-install.json\n' "$(vx_harbor_root)"
}

vx_harbor_install_journal_validate() {
    local path="$1"
    [[ "$path" == "$(_vx_harbor_install_journal_path)" ]] || return 1
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    _vx_harbor_authority_schema_validate install-operation "$path" provider-install
}

_vx_harbor_install_journal_write() {
    local json="$1" path source result
    path="$(_vx_harbor_install_journal_path)"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/operations/.provider-install.XXXXXX")" || return 1
    printf '%s\n' "$json" >"$source" || { /usr/bin/rm -f "$source"; return 1; }
    _vx_harbor_secure_file_set "$source" 0600 \
        && _vx_harbor_authority_schema_validate install-operation "$source" provider-install \
        && vx_harbor_json_write_atomic "$path" "$source"
    result=$?
    /usr/bin/rm -f "$source"
    (( result == 0 )) || return "$result"
    vx_harbor_install_journal_validate "$path"
}

_vx_harbor_install_journal_update() {
    local filter="$1" path json
    shift
    path="$(_vx_harbor_install_journal_path)"
    vx_harbor_install_journal_validate "$path" || return 1
    json="$(/usr/bin/jq -c "$@" "$filter" "$path")" || return 1
    _vx_harbor_install_journal_write "$json"
}
