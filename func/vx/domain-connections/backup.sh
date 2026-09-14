#!/usr/bin/env bash

# The ordinary user backup already carries $USER_DATA/ssl under its established
# protection. Connection manifests carry relationship and recovery authority
# only: TXT proofs and proxy header values never enter this archive member.

vx_domain_connection_backup_digest() {
    /usr/bin/jq -S -c . | /usr/bin/sha256sum | /usr/bin/awk '{print $1}'
}

vx_domain_connection_backup_manifest() {
    local record=$1 digest
    digest="$(vx_domain_connection_backup_digest <<<"$record")" || return 1
    /usr/bin/jq -ce --arg digest "$digest" '
        {VERSION,OWNER,TECHNICAL_FQDN,HOSTNAME,CONNECTION_ID,GENERATION,
         STATE,REASON,CREATED_AT,LAST_CHECKED_AT,LAST_SUCCESSFUL_AT,
         NEXT_CHECK_AT,CLEANUP,REGISTRY_SHA256:$digest,
         OBSERVATIONS:(.OBSERVATIONS.native // {})}
        | select(.VERSION == 1 and (.OWNER|type == "string")
          and (.TECHNICAL_FQDN|type == "string") and (.HOSTNAME|type == "string")
          and (.CONNECTION_ID|type == "string") and (.GENERATION|type == "number")
          and (.REGISTRY_SHA256|test("^[0-9a-f]{64}$")))' <<<"$record"
}

vx_domain_connection_backup_user() {
    local owner=$1 destination=$2 path record manifest name
    declare -F vx_domain_connection_hostname_root >/dev/null || return 0
    mkdir -p -- "$destination" || return 1
    chmod 0700 -- "$destination" || return 1
    while IFS= read -r -d '' path; do
        [[ -f "$path" && ! -L "$path" ]] || return 1
        record="$(vx_domain_connection_record_read "$(/usr/bin/jq -r .HOSTNAME "$path")")" || return 1
        [[ $(/usr/bin/jq -r .OWNER <<<"$record") == "$owner" ]] || continue
        manifest="$(vx_domain_connection_backup_manifest "$record")" || return 1
        name="$(basename -- "$path")"
        printf '%s\n' "$manifest" >"$destination/$name" || return 1
        chmod 0600 -- "$destination/$name" || return 1
    done < <(/usr/bin/find "$(vx_domain_connection_hostname_root)" -type f -name '*.json' -print0)
}

vx_domain_connection_restore_manifest_valid() {
    local owner=$1 path=$2 hostname name
    [[ -f "$path" && ! -L "$path" && $(/usr/bin/stat -c '%a' "$path") == 600 ]] || return 1
    hostname=$(/usr/bin/jq -r .HOSTNAME "$path" 2>/dev/null) || return 1
    name=$(basename -- "$path" .json)
    [[ "$name" == "$(vx_domain_connection_hash "$hostname")" ]] || return 1
    /usr/bin/jq -e --arg owner "$owner" '
        .VERSION == 1 and .OWNER == $owner
        and (.TECHNICAL_FQDN|type == "string" and length > 0)
        and (.HOSTNAME|type == "string" and length > 0)
        and (.CONNECTION_ID|test("^[A-Za-z0-9_-]{1,80}$"))
        and (.GENERATION|type == "number" and . >= 1 and floor == .)
        and (.REGISTRY_SHA256|test("^[0-9a-f]{64}$"))' "$path" >/dev/null
}

vx_domain_connection_restore_exact_registry_match() {
    local manifest=$1 existing=$2 expected actual
    expected=$(/usr/bin/jq -r .REGISTRY_SHA256 "$manifest") || return 1
    actual="$(vx_domain_connection_backup_digest <<<"$existing")" || return 1
    /usr/bin/jq -e --argjson existing "$existing" '
        .OWNER == $existing.OWNER and .TECHNICAL_FQDN == $existing.TECHNICAL_FQDN
        and .CONNECTION_ID == $existing.CONNECTION_ID and .GENERATION == $existing.GENERATION
        ' "$manifest" >/dev/null \
        && [[ "$expected" == "$actual" ]]
}

vx_domain_connection_restore_preflight() {
    local owner=$1 source_dir=$2 path hostname existing rc
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || return 0
    declare -F vx_domain_connection_record_read >/dev/null || return 1
    for path in "$source_dir"/*.json; do
        [[ -e "$path" ]] || continue
        vx_domain_connection_restore_manifest_valid "$owner" "$path" || return 1
        hostname=$(/usr/bin/jq -r .HOSTNAME "$path")
        existing="$(vx_domain_connection_record_read "$hostname" 2>/dev/null || :)"
        if [[ -n "$existing" ]]; then
            vx_domain_connection_restore_exact_registry_match "$path" "$existing" || return 1
        elif declare -F vx_domain_connection_native_hostname_in_use >/dev/null; then
            vx_domain_connection_native_hostname_in_use "$hostname"; rc=$?
            (( rc == 0 )) || return 1
        fi
    done
}

vx_domain_connection_restore_native_match() {
    local owner=$1 manifest=$2 hostname parent id generation child_row parent_row rows conf=${3:-}
    hostname=$(/usr/bin/jq -r .HOSTNAME "$manifest")
    parent=$(/usr/bin/jq -r .TECHNICAL_FQDN "$manifest")
    id=$(/usr/bin/jq -r .CONNECTION_ID "$manifest")
    generation=$(/usr/bin/jq -r .GENERATION "$manifest")
    [[ -n "$conf" ]] || conf="$VESTA/data/users/$owner/web.conf"
    rows=$(cat -- "$conf" 2>/dev/null) || return 1
    child_row=$(/usr/bin/grep -F "DOMAIN='$hostname'" <<<"$rows") || return 1
    parent_row=$(/usr/bin/grep -F "DOMAIN='$parent'" <<<"$rows") || return 1
    [[ $(wc -l <<<"$child_row") == 1 && $(wc -l <<<"$parent_row") == 1 ]] || return 1
    vx_domain_connection_restore_native_value() { /usr/bin/sed -n "s/.*[[:space:]]$2='\\([^']*\\)'.*/\\1/p" <<<" $1"; }
    [[ $(vx_domain_connection_restore_native_value "$child_row" VX_CONNECTION_ID) == "$id" \
        && $(vx_domain_connection_restore_native_value "$child_row" VX_CONNECTION_PARENT) == "$parent" \
        && $(vx_domain_connection_restore_native_value "$child_row" VX_CONNECTION_GENERATION) == "$generation" \
        && -z $(vx_domain_connection_restore_native_value "$child_row" ALIAS) \
        && $(vx_domain_connection_restore_native_value "$child_row" SSL) == yes \
        && $(vx_domain_connection_restore_native_value "$child_row" LETSENCRYPT) == yes \
        && $(vx_domain_connection_restore_native_value "$parent_row" LETSENCRYPT) != yes ]] || return 1
}

vx_domain_connection_restore_archive_preflight() {
    local owner=$1 source_dir=$2 archive=$3 path hostname parent rows
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || return 0
    for path in "$source_dir"/*.json; do
        [[ -e "$path" ]] || continue
        vx_domain_connection_restore_manifest_valid "$owner" "$path" || return 1
        hostname=$(/usr/bin/jq -r .HOSTNAME "$path")
        parent=$(/usr/bin/jq -r .TECHNICAL_FQDN "$path")
        rows=$(/usr/bin/tar -xOf "$archive" "./web/$hostname/vesta/web.conf" 2>/dev/null; \
            /usr/bin/tar -xOf "$archive" "./web/$parent/vesta/web.conf" 2>/dev/null) || return 1
        [[ -n "$rows" ]] || return 1
        vx_domain_connection_restore_native_match "$owner" "$path" <(printf '%s\n' "$rows") || return 1
    done
}

vx_domain_connection_restore_commit() {
    local owner=$1 source_dir=$2 path hostname existing recovery
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || return 0
    for path in "$source_dir"/*.json; do
        [[ -e "$path" ]] || continue
        vx_domain_connection_restore_manifest_valid "$owner" "$path" || return 1
        vx_domain_connection_restore_native_match "$owner" "$path" || return 1
        hostname=$(/usr/bin/jq -r .HOSTNAME "$path")
        vx_domain_connection_lock "$hostname" || return 1
        existing="$(vx_domain_connection_record_read "$hostname" 2>/dev/null || :)"
        if [[ -n "$existing" ]]; then
            vx_domain_connection_restore_exact_registry_match "$path" "$existing" || { vx_domain_connection_unlock; return 1; }
        else
            recovery=$(/usr/bin/jq -c --arg now "$(vx_domain_connection_now)" '
                . + {PROOF_TOKEN:null,PROOF_EXPIRES_AT:null,STATE:"recovery_required",
                     REASON:"restored_recovery_required",RESTORED_STATE:.STATE,
                     RESTORED_REGISTRY_SHA256:.REGISTRY_SHA256,LAST_CHECKED_AT:$now,
                     NEXT_CHECK_AT:$now,OBSERVATIONS:{},CLEANUP:(.CLEANUP // {})}
                | del(.REGISTRY_SHA256)' "$path") || { vx_domain_connection_unlock; return 1; }
            vx_domain_connection_record_write "$hostname" "$recovery" || { vx_domain_connection_unlock; return 1; }
        fi
        vx_domain_connection_unlock
    done
}
