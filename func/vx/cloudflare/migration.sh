#!/bin/bash

# Explicit, plan-bound migration of native Vesta web domains to Vortex-owned
# Cloudflare technical hostnames. This helper is sourced after main.sh; public
# entrypoints accept only a bounded plan name and an optional prepare user.

VX_CF_MIGRATION_SCHEMA=1
VX_CF_MIGRATION_MAX_ITEMS=10000

vx_cf_migration_root() {
    printf '%s/migrations\n' "$(vx_cf_root)"
}

vx_cf_migration_valid_plan() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]
}

vx_cf_migration_valid_user() {
    vx_cf_valid_user "$1"
}

vx_cf_migration_is_test() {
    [[ "${VX_CLOUDFLARE_TEST_MODE:-}" == yes && "$VESTA" != /usr/local/vesta ]]
}

vx_cf_migration_require_root() {
    (( EUID == 0 )) || vx_cf_migration_is_test
}

vx_cf_migration_require_managed_provider() {
    vx_cf_provider_mode || {
        VX_CF_MIGRATION_STATUS=provider_not_ready
        return 1
    }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] || {
        VX_CF_MIGRATION_STATUS=provider_not_ready
        return 1
    }
}

vx_cf_migration_fail() {
    VX_CF_MIGRATION_STATUS=$1
    return "${2:-1}"
}

vx_cf_migration_sha256() {
    /usr/bin/sha256sum -- "$1" | /usr/bin/cut -d ' ' -f1
}

vx_cf_migration_secure_directory() {
    local path=$1 uid gid details

    [[ -d "$path" && ! -L "$path" ]] || return 1
    uid=$(vx_cf_expected_uid) || return 1
    gid=$(vx_cf_expected_gid) || return 1
    details=$(/usr/bin/stat -c '%u:%g:%a:%F' "$path" 2>/dev/null) || return 1
    [[ "$details" == "$uid:$gid:700:directory" ]]
}

vx_cf_migration_secure_file() {
    vx_cf_secure_regular_file "$1"
}

vx_cf_migration_make_directory() {
    local path=$1

    [[ ! -L "$path" ]] || return 1
    /usr/bin/mkdir -p -- "$path" || return 1
    vx_cf_secure_path "$path" 0700 || return 1
    vx_cf_migration_secure_directory "$path"
}

vx_cf_migration_atomic_write() {
    local target=$1 parent temporary

    parent=${target%/*}
    vx_cf_migration_secure_directory "$parent" || return 1
    [[ ! -L "$target" ]] || return 1
    temporary=$(/usr/bin/mktemp "$parent/.migration-write.XXXXXX") || return 1
    if ! vx_cf_secure_path "$temporary" 0600 || ! /usr/bin/cat >"$temporary" \
        || ! /usr/bin/mv -fT -- "$temporary" "$target" \
        || ! vx_cf_migration_secure_file "$target"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

vx_cf_migration_copy_protected() {
    local source=$1 target=$2

    [[ -f "$source" && ! -L "$source" ]] || return 1
    vx_cf_migration_atomic_write "$target" <"$source"
}

vx_cf_migration_row_value() {
    local row=$1 wanted=$2 rest key value matched found=0

    VX_CF_MIGRATION_ROW_VALUE=''
    rest=$row
    while [[ -n "$rest" ]]; do
        [[ "$rest" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'([[:space:]]|$) ]] \
            || return 1
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        matched=${BASH_REMATCH[0]}
        if [[ "$key" == "$wanted" ]]; then
            (( found == 0 )) || return 1
            VX_CF_MIGRATION_ROW_VALUE=$value
            found=1
        fi
        rest=${rest:${#matched}}
    done
    (( found == 1 ))
}

vx_cf_migration_validate_row() {
    local row=$1 rest key matched
    local -A seen=()

    [[ -n "$row" && "$row" != *$'\n'* && "$row" != *$'\r'* \
        && "$row" != *$'\t'* ]] || return 1
    rest=$row
    while [[ -n "$rest" ]]; do
        [[ "$rest" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'([[:space:]]|$) ]] \
            || return 1
        key=${BASH_REMATCH[1]}
        matched=${BASH_REMATCH[0]}
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        rest=${rest:${#matched}}
    done
    (( ${#seen[@]} >= 1 ))
}

vx_cf_migration_validate_web_row() {
    local row=$1 key

    vx_cf_migration_validate_row "$row" || return 1
    for key in DOMAIN ALIAS SSL LETSENCRYPT; do
        vx_cf_migration_row_value "$row" "$key" || return 1
    done
}

vx_cf_migration_row_replace() {
    local row=$1 key=$2 value=$3 old

    [[ "$value" != *"'"* && "$value" != *$'\n'* && "$value" != *$'\r'* \
        && "$value" != *$'\t'* ]] || return 1
    vx_cf_migration_row_value "$row" "$key" || return 1
    old=$VX_CF_MIGRATION_ROW_VALUE
    VX_CF_MIGRATION_ROW=${row/"$key='$old'"/"$key='$value'"}
    [[ "$VX_CF_MIGRATION_ROW" != "$row" || "$old" == "$value" ]]
}

vx_cf_migration_aliases() {
    local source=$1 target=$2 aliases=$3 alias result=$source
    local -A seen=(["$source"]=1 ["$target"]=1)
    local -a values=()

    [[ -z "$aliases" ]] || IFS=, read -r -a values <<<"$aliases"
    for alias in "${values[@]}"; do
        [[ -n "$alias" ]] || continue
        vx_cf_valid_domain "$alias" || return 1
        [[ -n "${seen[$alias]+x}" ]] && continue
        seen[$alias]=1
        result+=",$alias"
    done
    VX_CF_MIGRATION_ALIASES=$result
}

vx_cf_migration_target_row() {
    local source=$1 target=$2 original=$3 aliases row

    vx_cf_migration_validate_web_row "$original" || return 1
    vx_cf_migration_row_value "$original" DOMAIN || return 1
    [[ "$VX_CF_MIGRATION_ROW_VALUE" == "$source" ]] || return 1
    vx_cf_migration_row_value "$original" ALIAS || return 1
    aliases=$VX_CF_MIGRATION_ROW_VALUE
    vx_cf_migration_aliases "$source" "$target" "$aliases" || return 1
    vx_cf_migration_row_replace "$original" DOMAIN "$target" || return 1
    row=$VX_CF_MIGRATION_ROW
    vx_cf_migration_row_replace "$row" ALIAS "$VX_CF_MIGRATION_ALIASES" || return 1
    row=$VX_CF_MIGRATION_ROW
    vx_cf_migration_row_replace "$row" LETSENCRYPT no || return 1
    VX_CF_MIGRATION_TARGET_ROW=$VX_CF_MIGRATION_ROW
}

vx_cf_migration_row_alias_count() {
    local row=$1 aliases alias
    local count=0
    local -a values=()

    vx_cf_migration_row_value "$row" ALIAS || return 1
    aliases=$VX_CF_MIGRATION_ROW_VALUE
    [[ -z "$aliases" ]] || IFS=, read -r -a values <<<"$aliases"
    for alias in "${values[@]}"; do
        [[ -n "$alias" ]] || return 1
        vx_cf_valid_domain "$alias" || return 1
        ((count++))
    done
    VX_CF_MIGRATION_ALIAS_COUNT=$count
}

vx_cf_migration_replace_exact_row() {
    local file=$1 old=$2 new=$3 temporary count

    [[ -f "$file" && ! -L "$file" ]] || return 1
    count=$(/usr/bin/grep -Fxc -- "$old" "$file" 2>/dev/null) || :
    [[ "$count" == 1 ]] || return 1
    temporary=$(/usr/bin/mktemp "${file%/*}/.migration-row.XXXXXX") || return 1
    if ! /usr/bin/awk -v old="$old" -v new="$new" '
        $0 == old && !done { print new; done=1; next }
        { print }
        END { if (!done) exit 1 }
    ' "$file" >"$temporary" \
        || ! /usr/bin/chmod --reference="$file" "$temporary" \
        || ! { (( EUID != 0 )) \
            || /usr/bin/chown --reference="$file" "$temporary"; } \
        || ! /usr/bin/mv -fT -- "$temporary" "$file"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

vx_cf_migration_tree_digest() {
    local root=$1 path relative kind payload

    if [[ ! -e "$root" && ! -L "$root" ]]; then
        printf 'missing\n' | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1
        return
    fi
    [[ -d "$root" && ! -L "$root" ]] || return 1
    while IFS= read -r -d '' path; do
        relative=${path#"$root"}
        [[ -n "$relative" ]] || relative=.
        if [[ -L "$path" ]]; then
            kind=link
            payload=$(/usr/bin/readlink -- "$path") || return 1
        elif [[ -f "$path" ]]; then
            kind=file
            payload=$(vx_cf_migration_sha256 "$path") || return 1
        elif [[ -d "$path" ]]; then
            kind=directory
            payload=-
        else
            kind=other
            payload=$(/usr/bin/stat -c '%F' "$path") || return 1
        fi
        printf '%s\t%s\t%s\t%s\n' \
            "$(printf '%s' "$relative" | /usr/bin/base64 -w0)" "$kind" \
            "$(/usr/bin/stat -c '%a:%u:%g:%h:%s' "$path")" "$payload"
    done < <(/usr/bin/find -P "$root" -xdev -print0 | LC_ALL=C /usr/bin/sort -z) \
        | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1
}

vx_cf_migration_path_fingerprint() {
    local path=$1

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf 'missing\t-\n'
    elif [[ -L "$path" ]]; then
        return 1
    elif [[ -f "$path" ]]; then
        printf 'file\t%s\n' "$(
            printf '%s\t%s\n' "$(/usr/bin/stat -c '%a:%u:%g:%h:%s' "$path")" \
                "$(vx_cf_migration_sha256 "$path")" | /usr/bin/sha256sum \
                    | /usr/bin/cut -d ' ' -f1
        )"
    elif [[ -d "$path" ]]; then
        printf 'directory\t%s\n' "$(vx_cf_migration_tree_digest "$path")"
    else
        return 1
    fi
}

vx_cf_migration_read_path_fingerprint() {
    local line

    line=$(vx_cf_migration_path_fingerprint "$1") || return 1
    [[ "$line" == *$'\t'* && "$line" != *$'\n'* ]] || return 1
    VX_CF_MIGRATION_PATH_KIND=${line%%$'\t'*}
    VX_CF_MIGRATION_PATH_VALUE=${line#*$'\t'}
}

vx_cf_migration_homedir() {
    vx_cf_runtime_home_root || return 1
    VX_CF_MIGRATION_HOME=$VX_CF_HOME_ROOT
}

vx_cf_migration_log_root() {
    local web_system line

    if vx_cf_migration_is_test \
        && [[ -n "${VX_CLOUDFLARE_MIGRATION_LOG_ROOT:-}" ]]; then
        line=$VX_CLOUDFLARE_MIGRATION_LOG_ROOT
    else
        web_system=$(/usr/bin/sed -n "s/^WEB_SYSTEM='\([^']*\)'$/\1/p" \
            "$VESTA/conf/vesta.conf") || return 1
        [[ "$web_system" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
        line="/var/log/$web_system/domains"
    fi
    [[ "$line" == /* && "$line" != / && "$line" != *'/../'* \
        && "$line" != */.. ]] || return 1
    VX_CF_MIGRATION_LOG_ROOT=${line%/}
}

vx_cf_migration_passwd_file() {
    if vx_cf_migration_is_test \
        && [[ -n "${VX_CLOUDFLARE_MIGRATION_PASSWD_FILE:-}" ]]; then
        VX_CF_MIGRATION_PASSWD=$VX_CLOUDFLARE_MIGRATION_PASSWD_FILE
    else
        VX_CF_MIGRATION_PASSWD=/etc/passwd
    fi
    [[ "$VX_CF_MIGRATION_PASSWD" == /* \
        && -f "$VX_CF_MIGRATION_PASSWD" \
        && ! -L "$VX_CF_MIGRATION_PASSWD" ]]
}

vx_cf_migration_ftp_snapshot() {
    local row=$1 ftp_users ftp_user entry home
    local -a users=()

    vx_cf_migration_row_value "$row" FTP_USER || {
        VX_CF_MIGRATION_FTP_LINES=''
        return 0
    }
    ftp_users=$VX_CF_MIGRATION_ROW_VALUE
    [[ -z "$ftp_users" ]] || IFS=: read -r -a users <<<"$ftp_users"
    vx_cf_migration_passwd_file || return 1
    VX_CF_MIGRATION_FTP_LINES=''
    for ftp_user in "${users[@]}"; do
        vx_cf_migration_valid_user "$ftp_user" || return 1
        entry=$(/usr/bin/awk -F: -v user="$ftp_user" '$1 == user { print; count++ }
            END { if (count != 1) exit 1 }' "$VX_CF_MIGRATION_PASSWD") || return 1
        home=$(/usr/bin/printf '%s\n' "$entry" | /usr/bin/cut -d: -f6)
        [[ "$home" == /* && "$home" != *$'\t'* && "$home" != *$'\n'* ]] \
            || return 1
        VX_CF_MIGRATION_FTP_LINES+="$ftp_user"$'\t'"$home"$'\n'
    done
}

vx_cf_migration_emit() {
    local format=$1 status=$2 total=$3 pending=$4 applied=$5 rolled_back=$6 failed=$7

    [[ "$status" =~ ^[a-z_]+$ && "$total" =~ ^[0-9]+$ \
        && "$pending" =~ ^[0-9]+$ && "$applied" =~ ^[0-9]+$ \
        && "$rolled_back" =~ ^[0-9]+$ && "$failed" =~ ^[0-9]+$ ]] || {
        status=state_error total=0 pending=0 applied=0 rolled_back=0 failed=1
    }
    if [[ "$format" == json ]]; then
        printf '{"status":"%s","total":%s,"pending":%s,"applied":%s,"rolled_back":%s,"failed":%s}\n' \
            "$status" "$total" "$pending" "$applied" "$rolled_back" "$failed"
    else
        printf '%s total=%s pending=%s applied=%s rolled_back=%s failed=%s\n' \
            "$status" "$total" "$pending" "$applied" "$rolled_back" "$failed"
    fi
}

vx_cf_migration_plan_load() {
    local artifact=$1 path line key value
    local schema='' plan='' scope='' config_sha='' vesta_sha=''
    local inventory_sha='' filesystem_sha='' scope_sha=''
    local total='' pending='' skipped=''
    local -A seen=()

    path="$artifact/plan.conf"
    vx_cf_migration_secure_file "$path" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] || return 1
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        case "$key" in
            SCHEMA) schema=$value ;;
            PLAN) plan=$value ;;
            SCOPE_USER) scope=$value ;;
            CONFIG_SHA256) config_sha=$value ;;
            VESTA_CONFIG_SHA256) vesta_sha=$value ;;
            INVENTORY_SHA256) inventory_sha=$value ;;
            FILESYSTEM_SHA256) filesystem_sha=$value ;;
            SCOPE_SHA256) scope_sha=$value ;;
            TOTAL) total=$value ;;
            PENDING) pending=$value ;;
            SKIPPED) skipped=$value ;;
            *) return 1 ;;
        esac
    done <"$path"
    [[ "$schema" == "$VX_CF_MIGRATION_SCHEMA" ]] || return 1
    vx_cf_migration_valid_plan "$plan" || return 1
    [[ "$scope" == all ]] || vx_cf_migration_valid_user "$scope" || return 1
    [[ "$config_sha" =~ ^[a-f0-9]{64}$ && "$vesta_sha" =~ ^[a-f0-9]{64}$ \
        && "$inventory_sha" =~ ^[a-f0-9]{64}$ \
        && "$filesystem_sha" =~ ^[a-f0-9]{64}$ \
        && "$scope_sha" =~ ^[a-f0-9]{64}$ \
        && "$total" =~ ^[0-9]+$ && "$pending" =~ ^[0-9]+$ \
        && "$skipped" =~ ^[0-9]+$ \
        && $((pending + skipped)) -eq total \
        && total -le VX_CF_MIGRATION_MAX_ITEMS ]] || return 1
    VX_CF_MIGRATION_PLAN=$plan
    VX_CF_MIGRATION_SCOPE=$scope
    VX_CF_MIGRATION_CONFIG_SHA=$config_sha
    VX_CF_MIGRATION_VESTA_SHA=$vesta_sha
    VX_CF_MIGRATION_INVENTORY_SHA=$inventory_sha
    VX_CF_MIGRATION_FILESYSTEM_SHA=$filesystem_sha
    VX_CF_MIGRATION_SCOPE_SHA=$scope_sha
    VX_CF_MIGRATION_TOTAL=$total
    VX_CF_MIGRATION_PENDING=$pending
    VX_CF_MIGRATION_SKIPPED=$skipped
    VX_CF_MIGRATION_PLAN_SHA=$(vx_cf_migration_sha256 "$path") || return 1
}

vx_cf_migration_plan_rows_validate() {
    local artifact=$1 line item user source target hostnames_digest address retain
    local expected count=0
    local -A seen_items=() seen_sources=() seen_targets=()

    vx_cf_migration_secure_file "$artifact/plan.tsv" || return 1
    IFS= read -r line <"$artifact/plan.tsv" || return 1
    [[ "$line" == $'ITEM\tUSER\tSOURCE\tTARGET\tHOSTNAMES_SHA256\tADDRESS\tRETAIN_SOURCE_SSL' ]] \
        || return 1
    /usr/bin/awk -F '\t' 'NF != 7 { exit 1 }' "$artifact/plan.tsv" \
        || return 1
    while IFS=$'\t' read -r item user source target hostnames_digest address retain; do
        [[ "$item" != ITEM ]] || continue
        ((count++))
        expected=$(/usr/bin/printf '%06d' "$count")
        [[ "$item" == "$expected" ]] \
            && vx_cf_migration_valid_user "$user" \
            && vx_cf_valid_domain "$source" \
            && vx_cf_valid_domain "$target" \
            && vx_cf_valid_ipv4 "$address" \
            && [[ "$source" != "$target" \
                && "$hostnames_digest" =~ ^[a-f0-9]{64}$ \
                && "$retain" =~ ^(yes|no)$ ]] || return 1
        [[ -z "${seen_items[$item]+x}" \
            && -z "${seen_sources[$user/$source]+x}" \
            && -z "${seen_targets[$target]+x}" ]] || return 1
        seen_items[$item]=1
        seen_sources[$user/$source]=1
        seen_targets[$target]=1
    done <"$artifact/plan.tsv"
    (( count == VX_CF_MIGRATION_PENDING ))
}

vx_cf_migration_mutable_recovery_path() {
    [[ "$1" =~ ^recovery/[0-9]{6}/(user\.conf|metadata\.tsv|rendered\.digest|rendered\.tar)$ ]]
}

vx_cf_migration_manifest_write() {
    local artifact=$1 relative path digest

    while IFS= read -r -d '' path; do
        relative=${path#"$artifact/"}
        case "$relative" in
            manifest.sha256|mapping.json|results.tsv|recovery.conf)
                continue
                ;;
        esac
        vx_cf_migration_mutable_recovery_path "$relative" && continue
        [[ "$relative" =~ ^[A-Za-z0-9._/-]+$ \
            && "$relative" != /* \
            && "$relative" != *'../'* ]] || return 1
        vx_cf_migration_secure_file "$path" || return 1
        digest=$(vx_cf_migration_sha256 "$path") || return 1
        printf '%s  %s\n' "$digest" "$relative"
    done < <(/usr/bin/find -P "$artifact" -type f -print0 | LC_ALL=C /usr/bin/sort -z)
}

vx_cf_migration_manifest_verify() {
    local artifact=$1 line digest relative path count=0
    local -A listed=()

    vx_cf_migration_secure_file "$artifact/manifest.sha256" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([a-f0-9]{64})[[:space:]][[:space:]]([A-Za-z0-9._/-]+)$ ]] \
            || return 1
        digest=${BASH_REMATCH[1]}
        relative=${BASH_REMATCH[2]}
        [[ "$relative" != /* && "$relative" != *'../'* \
            && "$relative" != manifest.sha256 \
            && "$relative" != mapping.json \
            && "$relative" != results.tsv \
            && "$relative" != recovery.conf \
            && "$relative" != recovery/* \
            && -z "${listed[$relative]+x}" ]] || return 1
        path="$artifact/$relative"
        vx_cf_migration_secure_file "$path" || return 1
        [[ "$(vx_cf_migration_sha256 "$path")" == "$digest" ]] || return 1
        listed[$relative]=1
        ((count++))
    done <"$artifact/manifest.sha256"
    (( count >= 5 )) || return 1
    for relative in plan.conf plan.tsv inventory.tsv filesystem.tsv \
        mapping-plan.json scope-users.tsv; do
        [[ -n "${listed[$relative]+x}" ]] || return 1
    done
    while IFS= read -r -d '' path; do
        relative=${path#"$artifact/"}
        case "$relative" in
            manifest.sha256|mapping.json|results.tsv|recovery.conf) ;;
            *) vx_cf_migration_mutable_recovery_path "$relative" \
                || [[ -n "${listed[$relative]+x}" ]] || return 1 ;;
        esac
    done < <(/usr/bin/find -P "$artifact" -type f -print0)
    VX_CF_MIGRATION_MANIFEST_SHA=$(vx_cf_migration_sha256 \
        "$artifact/manifest.sha256") || return 1
}

vx_cf_migration_results_initialize() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl

    {
        printf "SCHEMA='%s' PLAN_SHA256='%s' MANIFEST_SHA256='%s'\n" \
            "$VX_CF_MIGRATION_SCHEMA" "$VX_CF_MIGRATION_PLAN_SHA" \
            "$VX_CF_MIGRATION_MANIFEST_SHA"
        while IFS=$'\t' read -r item user source target hostnames_digest address \
            retain_source_ssl; do
            [[ "$item" != ITEM ]] || continue
            printf "ITEM='%s' STATE='pending' RECORD_ID='' CERTIFICATE_ID=''\n" \
                "$item"
        done <"$artifact/plan.tsv"
    } | vx_cf_migration_atomic_write "$artifact/results.tsv"
    {
        printf "SCHEMA='%s'\n" "$VX_CF_MIGRATION_SCHEMA"
        printf "PLAN_SHA256='%s'\n" "$VX_CF_MIGRATION_PLAN_SHA"
        printf "MANIFEST_SHA256='%s'\n" "$VX_CF_MIGRATION_MANIFEST_SHA"
        printf "STATUS='clean'\n"
        printf "FAILED='0'\n"
    } | vx_cf_migration_atomic_write "$artifact/recovery.conf"
}

vx_cf_migration_results_validate() {
    local artifact=$1 line item state record certificate expected_count=0 count=0
    local header_schema header_plan header_manifest
    local -A expected=() seen=()

    vx_cf_migration_secure_file "$artifact/results.tsv" || return 1
    IFS= read -r line <"$artifact/results.tsv" || return 1
    vx_cf_migration_validate_row "$line" || return 1
    vx_cf_migration_row_value "$line" SCHEMA || return 1
    header_schema=$VX_CF_MIGRATION_ROW_VALUE
    vx_cf_migration_row_value "$line" PLAN_SHA256 || return 1
    header_plan=$VX_CF_MIGRATION_ROW_VALUE
    vx_cf_migration_row_value "$line" MANIFEST_SHA256 || return 1
    header_manifest=$VX_CF_MIGRATION_ROW_VALUE
    [[ "$header_schema" == "$VX_CF_MIGRATION_SCHEMA" \
        && "$header_plan" == "$VX_CF_MIGRATION_PLAN_SHA" \
        && "$header_manifest" == "$VX_CF_MIGRATION_MANIFEST_SHA" ]] || return 1
    while IFS=$'\t' read -r item _; do
        [[ "$item" != ITEM ]] || continue
        [[ "$item" =~ ^[0-9]{6}$ && -z "${expected[$item]+x}" ]] || return 1
        expected[$item]=1
        ((expected_count++))
    done <"$artifact/plan.tsv"
    while IFS= read -r line; do
        [[ "$line" == ITEM=* ]] || continue
        vx_cf_migration_validate_row "$line" || return 1
        vx_cf_migration_row_value "$line" ITEM || return 1
        item=$VX_CF_MIGRATION_ROW_VALUE
        vx_cf_migration_row_value "$line" STATE || return 1
        state=$VX_CF_MIGRATION_ROW_VALUE
        vx_cf_migration_row_value "$line" RECORD_ID || return 1
        record=$VX_CF_MIGRATION_ROW_VALUE
        vx_cf_migration_row_value "$line" CERTIFICATE_ID || return 1
        certificate=$VX_CF_MIGRATION_ROW_VALUE
        [[ -n "${expected[$item]+x}" && -z "${seen[$item]+x}" \
            && "$state" =~ ^(pending|renaming|renamed|record_ready|provisioned|applied|rolling_back|rolled_back|recovery_required)$ \
            && ( -z "$record" || "$record" =~ ^[A-Za-z0-9_-]{1,64}$ ) \
            && ( -z "$certificate" || "$certificate" =~ ^[A-Za-z0-9_-]{1,64}$ ) ]] \
            || return 1
        seen[$item]=1
        ((count++))
    done <"$artifact/results.tsv"
    (( count == expected_count ))
}

vx_cf_migration_recovery_load() {
    local artifact=$1 line key value schema='' plan='' manifest='' status='' failed=''
    local -A seen=()

    vx_cf_migration_secure_file "$artifact/recovery.conf" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\'([^\']*)\'$ ]] || return 1
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        [[ -z "${seen[$key]+x}" ]] || return 1
        seen[$key]=1
        case "$key" in
            SCHEMA) schema=$value ;;
            PLAN_SHA256) plan=$value ;;
            MANIFEST_SHA256) manifest=$value ;;
            STATUS) status=$value ;;
            FAILED) failed=$value ;;
            *) return 1 ;;
        esac
    done <"$artifact/recovery.conf"
    [[ "$schema" == "$VX_CF_MIGRATION_SCHEMA" \
        && "$plan" == "$VX_CF_MIGRATION_PLAN_SHA" \
        && "$manifest" == "$VX_CF_MIGRATION_MANIFEST_SHA" \
        && "$status" =~ ^(clean|failed|recovery_required|rolled_back)$ \
        && "$failed" =~ ^[0-9]+$ ]] || return 1
    VX_CF_MIGRATION_RECOVERY_STATUS=$status
    VX_CF_MIGRATION_FAILED=$failed
}

vx_cf_migration_artifact_validate() {
    local artifact=$1 path relative

    vx_cf_migration_secure_directory "$artifact" || return 1
    while IFS= read -r -d '' path; do
        if [[ -L "$path" ]]; then
            return 1
        elif [[ -d "$path" ]]; then
            vx_cf_migration_secure_directory "$path" || return 1
            relative=${path#"$artifact/"}
            [[ "$relative" == snapshots \
                || "$relative" == snapshots/users \
                || "$relative" == snapshots/ssl \
                || "$relative" == recovery \
                || "$relative" =~ ^snapshots/users/[A-Za-z0-9][-._A-Za-z0-9]{0,64}$ \
                || "$relative" =~ ^snapshots/ssl/[0-9]{6}$ \
                || "$relative" =~ ^recovery/[0-9]{6}$ ]] || return 1
        elif [[ -f "$path" ]]; then
            vx_cf_migration_secure_file "$path" || return 1
        else
            return 1
        fi
    done < <(/usr/bin/find -P "$artifact" -mindepth 1 -print0)
    vx_cf_migration_plan_load "$artifact" || return 1
    vx_cf_migration_plan_rows_validate "$artifact" || return 1
    vx_cf_migration_manifest_verify "$artifact" || return 1
    vx_cf_migration_secure_file "$artifact/mapping.json" || return 1
    vx_cf_migration_results_validate "$artifact" || return 1
    vx_cf_migration_recovery_load "$artifact"
}

vx_cf_migration_exact_row() {
    local user=$1 domain=$2 file row count

    file="$VESTA/data/users/$user/web.conf"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    mapfile -t VX_CF_MIGRATION_ROWS < <(
        /usr/bin/awk -v domain="$domain" '
            index($0, "DOMAIN=\047" domain "\047") == 1 { print }
        ' "$file"
    )
    count=${#VX_CF_MIGRATION_ROWS[@]}
    (( count == 1 )) || return 1
    row=${VX_CF_MIGRATION_ROWS[0]}
    vx_cf_migration_validate_web_row "$row" || return 1
    vx_cf_migration_row_value "$row" DOMAIN || return 1
    [[ "$VX_CF_MIGRATION_ROW_VALUE" == "$domain" ]] || return 1
    VX_CF_MIGRATION_SOURCE_ROW=$row
}

vx_cf_migration_filesystem_write() {
    local plan_file=$1 include_docroot_metadata=${2:-yes}
    local item user source target hostnames_digest address retain_source_ssl
    local row kind digest path ftp_line component extension link_target logs_kind

    [[ "$include_docroot_metadata" =~ ^(yes|no)$ ]] || return 1
    vx_cf_migration_homedir || return 1
    vx_cf_migration_log_root || return 1
    printf 'ITEM\tCOMPONENT\tKIND\tDIGEST_OR_VALUE\n'
    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_exact_row "$user" "$source" || return 1
        row=$VX_CF_MIGRATION_SOURCE_ROW
        path="$VX_CF_MIGRATION_HOME/$user/web/$source"
        IFS=$'\t' read -r kind digest < <(vx_cf_migration_path_fingerprint "$path") \
            || return 1
        [[ "$kind" == directory ]] || return 1
        printf '%s\tdocroot\t%s\t%s\n' "$item" "$kind" "$digest"
        if [[ "$include_docroot_metadata" == yes ]]; then
            printf '%s\tdocroot.root\tmetadata\t%s\n' "$item" \
                "$(/usr/bin/stat -c '%a:%u:%g' "$path")"
            path="$VX_CF_MIGRATION_HOME/$user/web/$source/logs"
            if [[ -d "$path" && ! -L "$path" ]]; then
                logs_kind=metadata
                printf '%s\tdocroot.logs\tmetadata\t%s\n' "$item" \
                    "$(/usr/bin/stat -c '%a:%u:%g' "$path")"
            elif [[ ! -e "$path" && ! -L "$path" ]]; then
                logs_kind=missing
                printf '%s\tdocroot.logs\tmissing\t-\n' "$item"
            else
                return 1
            fi
            for extension in log error.log; do
                path="$VX_CF_MIGRATION_HOME/$user/web/$source/logs/$source.$extension"
                if [[ "$logs_kind" == metadata && -L "$path" ]]; then
                    link_target=$(/usr/bin/readlink -- "$path") || return 1
                    [[ "$link_target" \
                        == "$VX_CF_MIGRATION_LOG_ROOT/$source.$extension" ]] \
                        || return 1
                    printf '%s\tdocroot.log-link.%s\tlink\t%s\n' "$item" \
                        "$extension" "$(/usr/bin/stat -c '%a:%u:%g' "$path")"
                else
                    [[ ! -e "$path" ]] || return 1
                    printf '%s\tdocroot.log-link.%s\tmissing\t-\n' \
                        "$item" "$extension"
                fi
            done
        fi
        for component in log error bytes; do
            case "$component" in
                log) path="$VX_CF_MIGRATION_LOG_ROOT/$source.log" ;;
                error) path="$VX_CF_MIGRATION_LOG_ROOT/$source.error.log" ;;
                bytes) path="$VX_CF_MIGRATION_LOG_ROOT/$source.bytes" ;;
            esac
            IFS=$'\t' read -r kind digest \
                < <(vx_cf_migration_path_fingerprint "$path") || return 1
            [[ "$kind" == file || "$kind" == missing ]] || return 1
            printf '%s\tlog.%s\t%s\t%s\n' "$item" "$component" "$kind" "$digest"
        done
        for component in crt key ca pem; do
            path="$VESTA/data/users/$user/ssl/$source.$component"
            IFS=$'\t' read -r kind digest \
                < <(vx_cf_migration_path_fingerprint "$path") || return 1
            [[ "$kind" == file || "$kind" == missing ]] || return 1
            printf '%s\tssl.%s\t%s\t%s\n' "$item" "$component" "$kind" "$digest"
        done
        path="$VX_CF_MIGRATION_HOME/$user/conf/web"
        IFS=$'\t' read -r kind digest < <(vx_cf_migration_path_fingerprint "$path") \
            || return 1
        [[ "$kind" == directory || "$kind" == missing ]] || return 1
        printf '%s\trendered\t%s\t%s\n' "$item" "$kind" "$digest"
        vx_cf_migration_ftp_snapshot "$row" || return 1
        while IFS= read -r ftp_line; do
            [[ -n "$ftp_line" ]] || continue
            printf '%s\tftp.%s\tvalue\t%s\n' "$item" \
                "${ftp_line%%$'\t'*}" "${ftp_line#*$'\t'}"
        done <<<"$VX_CF_MIGRATION_FTP_LINES"
    done <"$plan_file"
}

vx_cf_migration_snapshot_user() {
    local stage=$1 user=$2 source target rendered temporary

    source="$VESTA/data/users/$user"
    target="$stage/snapshots/users/$user"
    vx_cf_migration_valid_user "$user" || return 1
    [[ -d "$source" && ! -L "$source" \
        && -f "$source/web.conf" && ! -L "$source/web.conf" \
        && -f "$source/user.conf" && ! -L "$source/user.conf" ]] || return 1
    vx_cf_migration_user_conf_projection "$source/user.conf" >/dev/null \
        || return 1
    vx_cf_migration_make_directory "$target" || return 1
    vx_cf_migration_copy_protected "$source/web.conf" "$target/web.conf" \
        && vx_cf_migration_copy_protected "$source/user.conf" "$target/user.conf" \
        || return 1
    printf 'WEB\tpresent\t%s\t%s\t%s\n' \
        "$(/usr/bin/stat -c '%a' "$source/web.conf")" \
        "$(/usr/bin/stat -c '%u' "$source/web.conf")" \
        "$(/usr/bin/stat -c '%g' "$source/web.conf")" \
        >"$target/metadata.tsv"
    printf 'USER\tpresent\t%s\t%s\t%s\n' \
        "$(/usr/bin/stat -c '%a' "$source/user.conf")" \
        "$(/usr/bin/stat -c '%u' "$source/user.conf")" \
        "$(/usr/bin/stat -c '%g' "$source/user.conf")" \
        >>"$target/metadata.tsv"
    vx_cf_migration_homedir || return 1
    rendered="$VX_CF_MIGRATION_HOME/$user/conf/web"
    if [[ ! -e "$rendered" && ! -L "$rendered" ]]; then
        printf 'RENDERED\tabsent\t-\t-\t-\n' >>"$target/metadata.tsv"
        printf 'absent\n' | vx_cf_migration_atomic_write "$target/rendered.state" \
            || return 1
        vx_cf_secure_path "$target/metadata.tsv" 0600
        return
    fi
    [[ -d "$rendered" && ! -L "$rendered" ]] || return 1
    printf 'RENDERED\tpresent\t%s\t%s\t%s\n' \
        "$(/usr/bin/stat -c '%a' "$rendered")" \
        "$(/usr/bin/stat -c '%u' "$rendered")" \
        "$(/usr/bin/stat -c '%g' "$rendered")" \
        >>"$target/metadata.tsv"
    vx_cf_secure_path "$target/metadata.tsv" 0600 || return 1
    printf 'present\n' | vx_cf_migration_atomic_write "$target/rendered.state" \
        || return 1
    temporary=$(/usr/bin/mktemp "$target/.rendered.XXXXXX") || return 1
    vx_cf_secure_path "$temporary" 0600 || {
        /usr/bin/rm -f -- "$temporary"
        return 1
    }
    if ! /usr/bin/tar --numeric-owner --acls --xattrs -C "$rendered" \
        -cpf "$temporary" . \
        || ! /usr/bin/mv -fT -- "$temporary" "$target/rendered.tar" \
        || ! vx_cf_migration_secure_file "$target/rendered.tar"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

vx_cf_migration_snapshot_ssl() {
    local stage=$1 item=$2 user=$3 source=$4 extension path target directory

    target="$stage/snapshots/ssl/$item"
    vx_cf_migration_make_directory "$target" || return 1
    directory="$VESTA/data/users/$user/ssl"
    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
        printf 'DIRECTORY\tpresent\t%s\t%s\t%s\n' \
            "$(/usr/bin/stat -c '%a' "$directory")" \
            "$(/usr/bin/stat -c '%u' "$directory")" \
            "$(/usr/bin/stat -c '%g' "$directory")" \
            >"$target/metadata.tsv"
    else
        printf 'DIRECTORY\tabsent\t-\t-\t-\n' >"$target/metadata.tsv"
    fi
    for extension in crt key ca pem; do
        path="$VESTA/data/users/$user/ssl/$source.$extension"
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" && ! -L "$path" ]] || return 1
            vx_cf_migration_copy_protected "$path" "$target/$extension" || return 1
            printf '%s\tpresent\t%s\t%s\t%s\n' "$extension" \
                "$(/usr/bin/stat -c '%a' "$path")" \
                "$(/usr/bin/stat -c '%u' "$path")" \
                "$(/usr/bin/stat -c '%g' "$path")" \
                >>"$target/metadata.tsv"
        else
            printf '%s\tabsent\t-\t-\t-\n' "$extension" \
                >>"$target/metadata.tsv"
        fi
    done
    vx_cf_secure_path "$target/metadata.tsv" 0600 \
        && vx_cf_migration_secure_file "$target/metadata.tsv"
}

vx_cf_migration_live_matches_plan() {
    local artifact=$1 snapshot user temporary users_now result=1
    local item_count metadata_count include_docroot_metadata

    [[ "$(vx_cf_migration_sha256 "$(vx_cf_config_path)")" \
        == "$VX_CF_MIGRATION_CONFIG_SHA" \
        && "$(vx_cf_migration_sha256 "$VESTA/conf/vesta.conf")" \
        == "$VX_CF_MIGRATION_VESTA_SHA" ]] || return 1
    users_now=$(/usr/bin/mktemp "$(vx_cf_migration_root)/.users.XXXXXX") \
        || return 1
    vx_cf_secure_path "$users_now" 0600 || {
        /usr/bin/rm -f -- "$users_now"
        return 1
    }
    if [[ "$VX_CF_MIGRATION_SCOPE" == all ]]; then
        /usr/bin/find -P "$VESTA/data/users" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | LC_ALL=C /usr/bin/sort >"$users_now" || {
                /usr/bin/rm -f -- "$users_now"
                return 1
            }
    else
        printf '%s\n' "$VX_CF_MIGRATION_SCOPE" >"$users_now"
    fi
    if ! /usr/bin/cmp -s -- "$users_now" "$artifact/scope-users.tsv"; then
        /usr/bin/rm -f -- "$users_now"
        return 1
    fi
    /usr/bin/rm -f -- "$users_now"
    while IFS= read -r -d '' snapshot; do
        user=${snapshot#"$artifact/snapshots/users/"}
        user=${user%%/*}
        vx_cf_migration_valid_user "$user" || return 1
        /usr/bin/cmp -s -- "$snapshot" "$VESTA/data/users/$user/web.conf" \
            || return 1
        /usr/bin/cmp -s -- "$artifact/snapshots/users/$user/user.conf" \
            "$VESTA/data/users/$user/user.conf" || return 1
    done < <(/usr/bin/find -P "$artifact/snapshots/users" -mindepth 2 \
        -maxdepth 2 -type f -name web.conf -print0)
    temporary=$(/usr/bin/mktemp "$(vx_cf_migration_root)/.filesystem.XXXXXX") \
        || return 1
    vx_cf_secure_path "$temporary" 0600 || {
        /usr/bin/rm -f -- "$temporary"
        return 1
    }
    item_count=$(/usr/bin/awk -F '\t' 'NR > 1 { count++ } END { print count + 0 }' \
        "$artifact/plan.tsv") || return 1
    metadata_count=$(/usr/bin/awk -F '\t' \
        '$2 == "docroot.root" { count++ } END { print count + 0 }' \
        "$artifact/filesystem.tsv") || return 1
    if (( metadata_count == item_count )); then
        include_docroot_metadata=yes
    elif (( metadata_count == 0 )); then
        include_docroot_metadata=no
    else
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    if vx_cf_migration_filesystem_write "$artifact/plan.tsv" \
        "$include_docroot_metadata" >"$temporary" \
        && /usr/bin/cmp -s -- "$temporary" "$artifact/filesystem.tsv"; then
        result=0
    fi
    /usr/bin/rm -f -- "$temporary"
    return "$result"
}

vx_cf_migration_candidate_reserved() {
    local candidate=$1 root plan_file

    root=$(vx_cf_migration_root)
    while IFS= read -r -d '' plan_file; do
        # An unsafe plan is a state error, never a reason to reuse its names.
        vx_cf_migration_secure_file "$plan_file" || return 0
        if /usr/bin/awk -F '\t' -v candidate="$candidate" \
            'NR > 1 && $4 == candidate { found=1 } END { exit !found }' \
            "$plan_file"; then
            return 0
        fi
    done < <(/usr/bin/find -P "$root" -mindepth 2 -maxdepth 2 \
        -type f -name plan.tsv -print0 2>/dev/null)
    return 1
}

vx_cf_migration_source_ssl_is_system_referenced() {
    local user=$1 domain=$2 reference count

    vx_cf_migration_valid_user "$user" && vx_cf_valid_domain "$domain" \
        && [[ -f "$VESTA/conf/vesta.conf" \
            && ! -L "$VESTA/conf/vesta.conf" ]] || return 1
    reference="$user:$domain"
    count=$(/usr/bin/awk -v reference="$reference" '
        $0 == "VESTA_CERTIFICATE=\047" reference "\047" ||
        $0 == "MAIL_CERTIFICATE=\047" reference "\047" { count++ }
        END { print count + 0 }
    ' "$VESTA/conf/vesta.conf") || return 1
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    if (( count > 0 )); then
        VX_CF_MIGRATION_RETAIN_SOURCE_SSL=yes
    else
        VX_CF_MIGRATION_RETAIN_SOURCE_SSL=no
    fi
}

vx_cf_migration_prepare_build() {
    local stage=$1 plan=$2 scope=$3 user row domain aliases target item
    local total=0 pending=0 skipped=0 config_sha vesta_sha inventory_sha filesystem_sha
    local scope_sha final_aliases attempt
    local -a users=()
    local -A reserved=()

    vx_cf_migration_make_directory "$stage/snapshots" \
        && vx_cf_migration_make_directory "$stage/snapshots/users" \
        && vx_cf_migration_make_directory "$stage/snapshots/ssl" \
        && vx_cf_migration_make_directory "$stage/recovery" || return 1
    printf 'USER\tSOURCE\tROW_SHA256\tCLASS\tTARGET\n' \
        | vx_cf_migration_atomic_write "$stage/inventory.tsv" || return 1
    printf 'ITEM\tUSER\tSOURCE\tTARGET\tHOSTNAMES_SHA256\tADDRESS\tRETAIN_SOURCE_SSL\n' \
        | vx_cf_migration_atomic_write "$stage/plan.tsv" || return 1
    printf 'USER\tFORMER_PRIMARY\tGENERATED_PRIMARY\tFINAL_ALIASES\tMIGRATION_STATE\tROLLBACK_STATE\n' \
        | vx_cf_migration_atomic_write "$stage/mapping-plan.tsv" || return 1

    if [[ "$scope" == all ]]; then
        mapfile -t users < <(/usr/bin/find -P "$VESTA/data/users" -mindepth 1 \
            -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C /usr/bin/sort)
    else
        users=("$scope")
    fi
    (( ${#users[@]} >= 1 )) || return 1
    printf '%s\n' "${users[@]}" >"$stage/scope-users.tsv" || return 1
    for user in "${users[@]}"; do
        vx_cf_migration_valid_user "$user" || return 1
        vx_cf_migration_snapshot_user "$stage" "$user" || return 1
        while IFS= read -r row || [[ -n "$row" ]]; do
            [[ -n "$row" ]] || continue
            vx_cf_migration_validate_web_row "$row" || return 1
            vx_cf_migration_row_value "$row" DOMAIN || return 1
            domain=$VX_CF_MIGRATION_ROW_VALUE
            vx_cf_valid_domain "$domain" || return 1
            ((total++))
            (( total <= VX_CF_MIGRATION_MAX_ITEMS )) || return 1
            vx_cf_migration_row_value "$row" ALIAS || return 1
            aliases=$VX_CF_MIGRATION_ROW_VALUE
            if vx_cf_metadata_exists "$user" "$domain" \
                || vx_cf_certificate_metadata_exists "$user" "$domain"; then
                if ! vx_cf_verify_managed_site_locked "$user" "$domain" \
                    || [[ "$VX_CF_STATUS" != managed ]]; then
                    VX_CF_MIGRATION_STATUS=degraded
                    return 1
                fi
                ((skipped++))
                printf '%s\t%s\t%s\tmanaged\t-\n' "$user" "$domain" \
                    "$(printf '%s\n' "$row" | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)" \
                    >>"$stage/inventory.tsv"
                printf '%s\t%s\t%s\t%s\tskipped\tnot_required\n' \
                    "$user" "$domain" "$domain" "$aliases" \
                    >>"$stage/mapping-plan.tsv"
                continue
            fi
            for ((attempt=1; attempt <= VX_CF_MAX_ALLOCATE_ATTEMPTS; attempt++)); do
                vx_cf_allocate_domain_locked || return 1
                target=$VX_CF_ALLOCATED_DOMAIN
                [[ -z "${reserved[$target]+x}" ]] \
                    && ! vx_cf_migration_candidate_reserved "$target" && break
                target=''
            done
            [[ -n "$target" ]] || { VX_CF_STATUS=collision_limit; return 1; }
            reserved[$target]=1
            vx_cf_migration_preflight_locked "$user" "$domain" "$target" \
                || return 1
            [[ "$VX_CF_STATUS" == ready \
                && "$VX_CF_MIGRATION_HOSTNAMES_DIGEST" =~ ^[a-f0-9]{64}$ \
                && "$VX_CF_WEB_ADDRESS" =~ ^[0-9.]+$ ]] || return 1
            ((pending++))
            item=$(/usr/bin/printf '%06d' "$pending")
            vx_cf_migration_source_ssl_is_system_referenced "$user" "$domain" \
                || return 1
            printf '%s\t%s\t%s\tunmanaged\t%s\n' "$user" "$domain" \
                "$(printf '%s\n' "$row" | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)" \
                "$target" >>"$stage/inventory.tsv"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$item" "$user" "$domain" \
                "$target" "$VX_CF_MIGRATION_HOSTNAMES_DIGEST" \
                "$VX_CF_WEB_ADDRESS" "$VX_CF_MIGRATION_RETAIN_SOURCE_SSL" \
                >>"$stage/plan.tsv"
            vx_cf_migration_target_row "$domain" "$target" "$row" || return 1
            vx_cf_migration_row_value "$VX_CF_MIGRATION_TARGET_ROW" ALIAS \
                || return 1
            final_aliases=$VX_CF_MIGRATION_ROW_VALUE
            printf '%s\t%s\t%s\t%s\tpending\tpending\n' "$user" "$domain" \
                "$target" "$final_aliases" >>"$stage/mapping-plan.tsv"
            vx_cf_migration_snapshot_ssl "$stage" "$item" "$user" "$domain" \
                || return 1
        done <"$VESTA/data/users/$user/web.conf"
    done
    vx_cf_secure_path "$stage/inventory.tsv" 0600 \
        && vx_cf_secure_path "$stage/plan.tsv" 0600 \
        && vx_cf_secure_path "$stage/mapping-plan.tsv" 0600 \
        && vx_cf_secure_path "$stage/scope-users.tsv" 0600 || return 1
    vx_cf_migration_filesystem_write "$stage/plan.tsv" \
        | vx_cf_migration_atomic_write "$stage/filesystem.tsv" || return 1
    /usr/bin/jq -Rn '
        [inputs | split("\t")
          | select(.[0] != "USER")
          | {user:.[0],former_primary:.[1],generated_primary:.[2],
             final_aliases:(if .[3] == "" then [] else (.[3] | split(",")) end),
             migration_state:.[4],rollback_state:.[5]}]
    ' <"$stage/mapping-plan.tsv" \
        | vx_cf_migration_atomic_write "$stage/mapping-plan.json" || return 1
    vx_cf_migration_copy_protected "$stage/mapping-plan.json" "$stage/mapping.json" \
        || return 1
    /usr/bin/rm -f -- "$stage/mapping-plan.tsv"
    config_sha=$(vx_cf_migration_sha256 "$(vx_cf_config_path)") || return 1
    vesta_sha=$(vx_cf_migration_sha256 "$VESTA/conf/vesta.conf") || return 1
    inventory_sha=$(vx_cf_migration_sha256 "$stage/inventory.tsv") || return 1
    filesystem_sha=$(vx_cf_migration_sha256 "$stage/filesystem.tsv") || return 1
    scope_sha=$(vx_cf_migration_sha256 "$stage/scope-users.tsv") || return 1
    {
        printf "SCHEMA='%s'\n" "$VX_CF_MIGRATION_SCHEMA"
        printf "PLAN='%s'\n" "$plan"
        printf "SCOPE_USER='%s'\n" "$scope"
        printf "CONFIG_SHA256='%s'\n" "$config_sha"
        printf "VESTA_CONFIG_SHA256='%s'\n" "$vesta_sha"
        printf "INVENTORY_SHA256='%s'\n" "$inventory_sha"
        printf "FILESYSTEM_SHA256='%s'\n" "$filesystem_sha"
        printf "SCOPE_SHA256='%s'\n" "$scope_sha"
        printf "TOTAL='%s'\n" "$total"
        printf "PENDING='%s'\n" "$pending"
        printf "SKIPPED='%s'\n" "$skipped"
    } | vx_cf_migration_atomic_write "$stage/plan.conf" || return 1
    vx_cf_migration_plan_load "$stage" || return 1
    vx_cf_migration_manifest_write "$stage" \
        | vx_cf_migration_atomic_write "$stage/manifest.sha256" || return 1
    vx_cf_migration_manifest_verify "$stage" || return 1
    vx_cf_migration_results_initialize "$stage" || return 1
    vx_cf_migration_artifact_validate "$stage" || return 1
    vx_cf_migration_live_matches_plan "$stage" || {
        VX_CF_MIGRATION_STATUS=drift
        return 1
    }
    VX_CF_MIGRATION_STATUS=prepared
}

vx_cf_migration_prepare_locked() {
    local plan=$1 scope=$2 root artifact stage

    vx_cf_migration_require_managed_provider || return 15
    if ! vx_cf_status_locked || [[ "$VX_CF_STATUS" != ready ]]; then
        VX_CF_MIGRATION_STATUS=provider_not_ready
        return 15
    fi
    vx_cf_load_config || { VX_CF_MIGRATION_STATUS=provider_not_ready; return 15; }
    declare -F vx_cf_migration_preflight_locked >/dev/null \
        && declare -F vx_cf_verify_managed_site_locked >/dev/null || {
            VX_CF_MIGRATION_STATUS=state_error
            return 19
        }
    vx_cf_prepare_layout || { VX_CF_MIGRATION_STATUS=state_error; return 19; }
    root=$(vx_cf_migration_root)
    vx_cf_migration_make_directory "$root" \
        || { VX_CF_MIGRATION_STATUS=artifact_invalid; return 12; }
    artifact="$root/$plan"
    if [[ -e "$artifact" || -L "$artifact" ]]; then
        vx_cf_migration_artifact_validate "$artifact" \
            && [[ "$VX_CF_MIGRATION_PLAN" == "$plan" \
                && "$VX_CF_MIGRATION_SCOPE" == "$scope" ]] \
            && vx_cf_migration_live_matches_plan "$artifact" || {
                VX_CF_MIGRATION_STATUS=drift
                return 7
            }
        VX_CF_MIGRATION_STATUS=prepared
        return 0
    fi
    stage=$(/usr/bin/mktemp -d "$root/.${plan}.prepare.XXXXXX") \
        || { VX_CF_MIGRATION_STATUS=state_error; return 19; }
    vx_cf_secure_path "$stage" 0700 || {
        /usr/bin/rm -rf -- "$stage"
        VX_CF_MIGRATION_STATUS=state_error
        return 19
    }
    if ! vx_cf_migration_prepare_build "$stage" "$plan" "$scope"; then
        /usr/bin/rm -rf -- "$stage"
        [[ -n "${VX_CF_MIGRATION_STATUS:-}" ]] \
            || VX_CF_MIGRATION_STATUS=${VX_CF_STATUS:-state_error}
        return 19
    fi
    if [[ -e "$artifact" || -L "$artifact" ]] \
        || ! /usr/bin/mv -T -- "$stage" "$artifact" \
        || ! vx_cf_migration_artifact_validate "$artifact"; then
        [[ ! -e "$stage" ]] || /usr/bin/rm -rf -- "$stage"
        VX_CF_MIGRATION_STATUS=artifact_invalid
        return 12
    fi
}

vx_cf_migration_external_status_ready() {
    local command output

    command="$VESTA/bin/v-list-vx-cloudflare-status"
    [[ -x "$command" ]] || return 1
    output=$(VESTA="$VESTA" "$command" 2>/dev/null) || return 1
    [[ "$output" == ready ]]
}

vx_cf_migration_prepare() {
    local plan=${1:-} scope=${2:-all} format=${3:-human} rc=0

    VX_CF_MIGRATION_STATUS=invalid_argument
    VX_CF_MIGRATION_TOTAL=0 VX_CF_MIGRATION_PENDING=0 VX_CF_MIGRATION_SKIPPED=0
    vx_cf_migration_require_root || rc=10
    (( rc != 0 )) || vx_cf_migration_valid_plan "$plan" || rc=2
    (( rc != 0 )) || [[ "$scope" == all ]] \
        || vx_cf_migration_valid_user "$scope" || rc=2
    (( rc != 0 )) || [[ "$format" == human || "$format" == json ]] || rc=2
    if (( rc == 10 )); then
        VX_CF_MIGRATION_STATUS=forbidden
    elif (( rc == 0 )); then
        if ! vx_cf_migration_require_managed_provider; then
            rc=15
        elif ! vx_cf_migration_external_status_ready; then
            VX_CF_MIGRATION_STATUS=provider_not_ready
            rc=15
        elif ! vx_cf_lock_acquire; then
            VX_CF_MIGRATION_STATUS=state_error
            rc=19
        elif vx_cf_migration_prepare_locked "$plan" "$scope"; then
            vx_cf_lock_release \
                || { VX_CF_MIGRATION_STATUS=state_error; rc=19; }
        else
            rc=$?
            (( rc != 0 )) || rc=19
            vx_cf_lock_release >/dev/null 2>&1 || :
        fi
    fi
    vx_cf_migration_emit "$format" "$VX_CF_MIGRATION_STATUS" \
        "${VX_CF_MIGRATION_TOTAL:-0}" "${VX_CF_MIGRATION_PENDING:-0}" 0 0 \
        "$([[ "$VX_CF_MIGRATION_STATUS" == prepared ]] && printf 0 || printf 1)"
    return "$rc"
}

vx_cf_migration_results_get() {
    local artifact=$1 item=$2 line count=0

    while IFS= read -r line; do
        [[ "$line" == "ITEM='$item' "* ]] || continue
        ((count++))
        vx_cf_migration_validate_row "$line" || return 1
        vx_cf_migration_row_value "$line" STATE || return 1
        VX_CF_MIGRATION_ITEM_STATE=$VX_CF_MIGRATION_ROW_VALUE
        vx_cf_migration_row_value "$line" RECORD_ID || return 1
        VX_CF_MIGRATION_ITEM_RECORD_ID=$VX_CF_MIGRATION_ROW_VALUE
        vx_cf_migration_row_value "$line" CERTIFICATE_ID || return 1
        VX_CF_MIGRATION_ITEM_CERTIFICATE_ID=$VX_CF_MIGRATION_ROW_VALUE
    done <"$artifact/results.tsv"
    (( count == 1 ))
}

vx_cf_migration_mapping_update() {
    local artifact=$1 target=$2 migration_state=$3 rollback_state=$4

    /usr/bin/jq -c --arg target "$target" --arg migration "$migration_state" \
        --arg rollback "$rollback_state" '
        map(if .generated_primary == $target then
            .migration_state=$migration | .rollback_state=$rollback
        else . end)
    ' "$artifact/mapping.json" \
        | vx_cf_migration_atomic_write "$artifact/mapping.json"
}

vx_cf_migration_results_set() {
    local artifact=$1 item=$2 state=$3 record=$4 certificate=$5 target=${6:-}

    [[ "$item" =~ ^[0-9]{6}$ \
        && "$state" =~ ^(pending|renaming|renamed|record_ready|provisioned|applied|rolling_back|rolled_back|recovery_required)$ \
        && ( -z "$record" || "$record" =~ ^[A-Za-z0-9_-]{1,64}$ ) \
        && ( -z "$certificate" || "$certificate" =~ ^[A-Za-z0-9_-]{1,64}$ ) ]] \
        || return 1
    /usr/bin/awk -v item="$item" -v state="$state" -v record="$record" \
        -v certificate="$certificate" '
        $0 ~ ("^ITEM=\047" item "\047 ") && !done {
            printf "ITEM=\047%s\047 STATE=\047%s\047 RECORD_ID=\047%s\047 CERTIFICATE_ID=\047%s\047\n", item, state, record, certificate
            done=1
            next
        }
        { print }
        END { if (!done) exit 1 }
    ' "$artifact/results.tsv" \
        | vx_cf_migration_atomic_write "$artifact/results.tsv" || return 1
    vx_cf_migration_results_validate "$artifact" || return 1
    [[ -n "$target" ]] || return 0
    case "$state" in
        applied) vx_cf_migration_mapping_update "$artifact" "$target" applied pending ;;
        rolled_back) vx_cf_migration_mapping_update "$artifact" "$target" rolled_back complete ;;
        recovery_required) vx_cf_migration_mapping_update "$artifact" "$target" recovery_required recovery_required ;;
        *) vx_cf_migration_mapping_update "$artifact" "$target" "$state" pending ;;
    esac
}

vx_cf_migration_recovery_set() {
    local artifact=$1 status=$2 failed=$3

    [[ "$status" =~ ^(clean|failed|recovery_required|rolled_back)$ \
        && "$failed" =~ ^[0-9]+$ ]] || return 1
    {
        printf "SCHEMA='%s'\n" "$VX_CF_MIGRATION_SCHEMA"
        printf "PLAN_SHA256='%s'\n" "$VX_CF_MIGRATION_PLAN_SHA"
        printf "MANIFEST_SHA256='%s'\n" "$VX_CF_MIGRATION_MANIFEST_SHA"
        printf "STATUS='%s'\n" "$status"
        printf "FAILED='%s'\n" "$failed"
    } | vx_cf_migration_atomic_write "$artifact/recovery.conf" || return 1
    vx_cf_migration_recovery_load "$artifact"
}

vx_cf_migration_observe_record_id() {
    local record_id=$1

    [[ "$record_id" =~ ^[a-f0-9]{32}$ \
        && -n "${VX_CF_MIGRATION_ACTIVE_ARTIFACT:-}" \
        && -n "${VX_CF_MIGRATION_ACTIVE_ITEM:-}" ]] || return 1
    vx_cf_migration_results_get "$VX_CF_MIGRATION_ACTIVE_ARTIFACT" \
        "$VX_CF_MIGRATION_ACTIVE_ITEM" || return 1
    [[ "$VX_CF_MIGRATION_ITEM_STATE" == renamed \
        && -z "$VX_CF_MIGRATION_ITEM_RECORD_ID" ]] || return 1
    vx_cf_migration_results_set "$VX_CF_MIGRATION_ACTIVE_ARTIFACT" \
        "$VX_CF_MIGRATION_ACTIVE_ITEM" "$VX_CF_MIGRATION_ITEM_STATE" \
        "$record_id" "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" \
        "$VX_CF_MIGRATION_ACTIVE_TARGET"
}

vx_cf_migration_observe_certificate_id() {
    local certificate_id=$1

    vx_cf_valid_certificate_id "$certificate_id" \
        && [[ -n "${VX_CF_MIGRATION_ACTIVE_ARTIFACT:-}" \
            && -n "${VX_CF_MIGRATION_ACTIVE_ITEM:-}" ]] || return 1
    vx_cf_migration_results_get "$VX_CF_MIGRATION_ACTIVE_ARTIFACT" \
        "$VX_CF_MIGRATION_ACTIVE_ITEM" || return 1
    [[ "$VX_CF_MIGRATION_ITEM_STATE" == record_ready \
        && -z "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" ]] || return 1
    vx_cf_migration_results_set "$VX_CF_MIGRATION_ACTIVE_ARTIFACT" \
        "$VX_CF_MIGRATION_ACTIVE_ITEM" "$VX_CF_MIGRATION_ITEM_STATE" \
        "$VX_CF_MIGRATION_ITEM_RECORD_ID" "$certificate_id" \
        "$VX_CF_MIGRATION_ACTIVE_TARGET"
}

vx_cf_migration_move_one() {
    local source=$1 target=$2 required=$3

    [[ ! -L "$source" && ! -L "$target" ]] || return 1
    if [[ ! -e "$source" ]]; then
        [[ "$required" == optional && ! -e "$target" ]]
        return
    fi
    [[ ! -e "$target" && -d "${source%/*}" && ! -L "${source%/*}" \
        && -d "${target%/*}" && ! -L "${target%/*}" ]] || return 1
    /usr/bin/mv -T -- "$source" "$target"
}

vx_cf_migration_native_file_clone() {
    local source=$1 target=$2 temporary source_details target_details

    [[ ! -L "$source" && ! -L "$target" ]] || return 1
    if [[ ! -e "$source" ]]; then
        [[ ! -e "$target" ]]
        return
    fi
    [[ -f "$source" && ! -e "$target" \
        && -d "${source%/*}" && ! -L "${source%/*}" \
        && -d "${target%/*}" && ! -L "${target%/*}" ]] || return 1
    source_details=$(/usr/bin/stat -c '%a:%u:%g:%s' "$source") || return 1
    temporary=$(/usr/bin/mktemp "${target%/*}/.migration-ssl-clone.XXXXXX") \
        || return 1
    if ! /usr/bin/cp -- "$source" "$temporary" \
        || ! /usr/bin/chmod --reference="$source" "$temporary" \
        || ! { (( EUID != 0 )) \
            || /usr/bin/chown --reference="$source" "$temporary"; } \
        || ! /usr/bin/touch --reference="$source" "$temporary" \
        || ! /usr/bin/mv -T -- "$temporary" "$target"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    [[ -f "$target" && ! -L "$target" ]] || return 1
    target_details=$(/usr/bin/stat -c '%a:%u:%g:%s' "$target") || return 1
    [[ "$target_details" == "$source_details" ]] \
        && /usr/bin/cmp -s -- "$source" "$target"
}

vx_cf_migration_paths_forward() {
    local user=$1 source=$2 target=$3 retain_source_ssl=${4:-no}
    local extension old new

    [[ "$retain_source_ssl" =~ ^(yes|no)$ ]] || return 1
    vx_cf_migration_homedir && vx_cf_migration_log_root || return 1
    vx_cf_migration_move_one "$VX_CF_MIGRATION_HOME/$user/web/$source" \
        "$VX_CF_MIGRATION_HOME/$user/web/$target" required || return 1
    for extension in log error.log bytes; do
        vx_cf_migration_move_one "$VX_CF_MIGRATION_LOG_ROOT/$source.$extension" \
            "$VX_CF_MIGRATION_LOG_ROOT/$target.$extension" optional || return 1
    done
    if [[ -d "$VESTA/data/users/$user/ssl" \
        && ! -L "$VESTA/data/users/$user/ssl" ]]; then
        for extension in crt key ca pem; do
            old="$VESTA/data/users/$user/ssl/$source.$extension"
            new="$VESTA/data/users/$user/ssl/$target.$extension"
            if [[ "$retain_source_ssl" == yes ]]; then
                vx_cf_migration_native_file_clone "$old" "$new" || return 1
            else
                vx_cf_migration_move_one "$old" "$new" optional || return 1
            fi
        done
    fi
}

vx_cf_migration_etc_root() {
    if vx_cf_migration_is_test; then
        VX_CF_MIGRATION_ETC_ROOT=${VX_CLOUDFLARE_MIGRATION_ETC_ROOT:-$VESTA/data/vx/cloudflare/test-etc}
        VX_CF_MIGRATION_ETC_ROOT=${VX_CF_MIGRATION_ETC_ROOT%/}
    else
        VX_CF_MIGRATION_ETC_ROOT=/etc
    fi
    [[ "$VX_CF_MIGRATION_ETC_ROOT" == /* \
        && "$VX_CF_MIGRATION_ETC_ROOT" != / \
        && "$VX_CF_MIGRATION_ETC_ROOT" != *'/../'* \
        && "$VX_CF_MIGRATION_ETC_ROOT" != */.. ]]
}

vx_cf_migration_regular_file() {
    [[ -f "$1" && ! -L "$1" ]]
}

vx_cf_migration_verify_applied_native() {
    local artifact=$1 user=$2 source=$3 target=$4 original expected row
    local rendered web_system proxy_system proxy stats tpl backend version pool
    local path
    local -a paths=()

    vx_cf_migration_valid_user "$user" && vx_cf_valid_domain "$source" \
        && vx_cf_valid_domain "$target" || return 1
    vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
        "$source" || return 1
    original=$VX_CF_MIGRATION_SOURCE_ROW
    vx_cf_migration_target_row "$source" "$target" "$original" || return 1
    vx_cf_migration_row_replace "$VX_CF_MIGRATION_TARGET_ROW" SSL yes \
        || return 1
    expected=$VX_CF_MIGRATION_ROW
    vx_cf_migration_exact_row "$user" "$target" || return 1
    row=$VX_CF_MIGRATION_SOURCE_ROW
    [[ "$row" == "$expected" ]] || return 1

    vx_cf_rendered_ssl_paths "$user" "$target" || return 1
    rendered=$VX_CF_RENDERED_SSL_DIRECTORY
    web_system=${WEB_SYSTEM:-}
    proxy_system=${PROXY_SYSTEM:-}
    vx_cf_migration_row_value "$row" PROXY && proxy=$VX_CF_MIGRATION_ROW_VALUE \
        || proxy=''
    vx_cf_migration_row_value "$row" STATS && stats=$VX_CF_MIGRATION_ROW_VALUE \
        || stats=''
    vx_cf_migration_row_value "$row" TPL && tpl=$VX_CF_MIGRATION_ROW_VALUE \
        || tpl=''
    vx_cf_migration_row_value "$row" BACKEND \
        && backend=$VX_CF_MIGRATION_ROW_VALUE || backend=''

    if [[ -n "$web_system" && "$web_system" != no ]]; then
        [[ "$web_system" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
        paths+=(
            "$rendered/$target.$web_system.conf"
            "$rendered/$target.$web_system.ssl.conf"
        )
    fi
    if [[ -n "$proxy_system" && "$proxy_system" != no \
        && -n "$proxy" && "$proxy" != no ]]; then
        [[ "$proxy_system" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
        paths+=(
            "$rendered/$target.$proxy_system.conf"
            "$rendered/$target.$proxy_system.ssl.conf"
        )
    fi
    if [[ -n "$stats" && "$stats" != no ]]; then
        [[ "$stats" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
        paths+=("$rendered/$stats.$target.conf")
    fi
    for path in "${paths[@]}"; do
        vx_cf_migration_regular_file "$path" || return 1
    done

    if [[ -n "$backend" && "$backend" != no \
        && "$tpl" =~ ^PHP-FPM-([0-9])([0-9])(-ioncube)?$ ]]; then
        version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        pool=pool.d
        [[ -z "${BASH_REMATCH[3]}" ]] || pool=pool.d-ioncube
        vx_cf_migration_etc_root || return 1
        vx_cf_migration_regular_file \
            "$VX_CF_MIGRATION_ETC_ROOT/php/$version/fpm/$pool/$target.conf" \
            || return 1
    fi
}

vx_cf_migration_remove_exact_file() {
    local path=$1

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    /usr/bin/rm -f -- "$path"
}

vx_cf_migration_queue_remove_exact() {
    local expected=$1 queue="$VESTA/data/queue/webstats.pipe" temporary

    [[ "$expected" != *$'\n'* && "$expected" != *$'\r'* ]] || return 1
    [[ ! -e "$queue" && ! -L "$queue" ]] && return 0
    [[ -f "$queue" && ! -L "$queue" ]] || return 1
    temporary=$(/usr/bin/mktemp "${queue%/*}/.migration-queue.XXXXXX") \
        || return 1
    if ! /usr/bin/awk -v expected="$expected" '$0 != expected { print }' \
        "$queue" >"$temporary" \
        || ! /usr/bin/chmod --reference="$queue" "$temporary" \
        || ! { (( EUID != 0 )) \
            || /usr/bin/chown --reference="$queue" "$temporary"; } \
        || ! /usr/bin/mv -fT -- "$temporary" "$queue"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
}

vx_cf_migration_cleanup_stale_identity() {
    local user=$1 domain=$2 row=$3 live_domain=$4 rendered logs
    local web_system proxy_system proxy stats tpl extension path expected_link
    local version pool
    local -a paths=()

    vx_cf_valid_domain "$domain" && vx_cf_migration_valid_user "$user" \
        && vx_cf_valid_domain "$live_domain" \
        && vx_cf_migration_validate_web_row "$row" || return 1
    vx_cf_migration_homedir && vx_cf_migration_log_root \
        && vx_cf_migration_etc_root || return 1
    rendered="$VX_CF_MIGRATION_HOME/$user/conf/web"
    logs="$VX_CF_MIGRATION_HOME/$user/web/$live_domain/logs"
    [[ -d "$rendered" && ! -L "$rendered" ]] || return 1
    [[ -d "$logs" && ! -L "$logs" ]] || return 1
    web_system=${WEB_SYSTEM:-}
    proxy_system=${PROXY_SYSTEM:-}
    [[ "$web_system" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    [[ -z "$proxy_system" \
        || "$proxy_system" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    vx_cf_migration_row_value "$row" PROXY && proxy=$VX_CF_MIGRATION_ROW_VALUE \
        || proxy=''
    vx_cf_migration_row_value "$row" STATS && stats=$VX_CF_MIGRATION_ROW_VALUE \
        || stats=''
    vx_cf_migration_row_value "$row" TPL && tpl=$VX_CF_MIGRATION_ROW_VALUE \
        || tpl=''
    paths=(
        "$rendered/$domain.$web_system.conf"
        "$rendered/$domain.$web_system.ssl.conf"
        "$rendered/ssl.$domain.crt"
        "$rendered/ssl.$domain.key"
        "$rendered/ssl.$domain.ca"
        "$rendered/ssl.$domain.pem"
        "$rendered/$web_system.$domain.conf_htaccess"
        "$rendered/s$web_system.$domain.conf_htaccess"
        "$rendered/$web_system.$domain.htpasswd"
        "$rendered/s$web_system.$domain.htpasswd"
        "$rendered/$web_system.$domain.conf_letsencrypt"
        "$rendered/s$web_system.$domain.conf_letsencrypt"
    )
    if [[ -n "$proxy_system" && -n "$proxy" ]]; then
        paths+=(
            "$rendered/$domain.$proxy_system.conf"
            "$rendered/$domain.$proxy_system.ssl.conf"
        )
    fi
    if [[ -n "$stats" && "$stats" != no ]]; then
        [[ "$stats" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
        paths+=("$rendered/$stats.$domain.conf")
    fi
    for path in "${paths[@]}"; do
        vx_cf_migration_remove_exact_file "$path" || return 1
    done
    for extension in log error.log; do
        path="$logs/$domain.$extension"
        expected_link="$VX_CF_MIGRATION_LOG_ROOT/$domain.$extension"
        if [[ -L "$path" ]]; then
            [[ "$(/usr/bin/readlink -- "$path")" == "$expected_link" ]] \
                || return 1
            /usr/bin/rm -f -- "$path" || return 1
        else
            [[ ! -e "$path" ]] || return 1
        fi
    done
    if [[ "$stats" == awstats ]]; then
        path="$VX_CF_MIGRATION_ETC_ROOT/awstats/$stats.$domain.conf"
        expected_link="$rendered/$stats.$domain.conf"
        if [[ -L "$path" ]]; then
            [[ "$(/usr/bin/readlink -- "$path")" == "$expected_link" ]] \
                || return 1
            /usr/bin/rm -f -- "$path" || return 1
        else
            [[ ! -e "$path" ]] || return 1
        fi
    fi
    vx_cf_migration_queue_remove_exact \
        "${BIN:-$VESTA/bin}/v-update-web-domain-stat $user $domain" || return 1
    if [[ "$tpl" =~ ^PHP-FPM-([0-9])([0-9])(-ioncube)?$ ]]; then
        version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        pool=pool.d
        [[ -z "${BASH_REMATCH[3]}" ]] || pool=pool.d-ioncube
        vx_cf_migration_remove_exact_file \
            "$VX_CF_MIGRATION_ETC_ROOT/php/$version/fpm/$pool/$domain.conf" \
            || return 1
        vx_cf_migration_remove_exact_file \
            "$VX_CF_MIGRATION_ETC_ROOT/php5/fpm/$pool/$domain.conf" || return 1
    fi
}

vx_cf_migration_restore_docroot_metadata() {
    local artifact=$1 item=$2 user=$3 live_domain=$4 root logs
    local extension path expected_link kind value mode uid gid
    local logs_kind logs_mode logs_uid logs_gid

    vx_cf_migration_valid_user "$user" && vx_cf_valid_domain "$live_domain" \
        && vx_cf_migration_homedir && vx_cf_migration_log_root || return 1
    root="$VX_CF_MIGRATION_HOME/$user/web/$live_domain"
    logs="$root/logs"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    vx_cf_migration_filesystem_component "$artifact" "$item" docroot.root \
        || return 1
    kind=$VX_CF_MIGRATION_COMPONENT_KIND
    value=$VX_CF_MIGRATION_COMPONENT_VALUE
    [[ "$kind" == metadata \
        && "$value" =~ ^([0-7]{3,4}):([0-9]+):([0-9]+)$ ]] || return 1
    mode=${BASH_REMATCH[1]}
    uid=${BASH_REMATCH[2]}
    gid=${BASH_REMATCH[3]}
    /usr/bin/chmod "$mode" "$root" || return 1
    (( EUID != 0 )) || /usr/bin/chown "$uid:$gid" "$root" || return 1
    [[ "$(/usr/bin/stat -c '%a:%u:%g' "$root")" == "$mode:$uid:$gid" ]] \
        || return 1
    vx_cf_migration_filesystem_component "$artifact" "$item" docroot.logs \
        || return 1
    logs_kind=$VX_CF_MIGRATION_COMPONENT_KIND
    value=$VX_CF_MIGRATION_COMPONENT_VALUE
    if [[ "$logs_kind" == metadata ]]; then
        [[ "$value" =~ ^([0-7]{3,4}):([0-9]+):([0-9]+)$ ]] \
            || return 1
        logs_mode=${BASH_REMATCH[1]}
        logs_uid=${BASH_REMATCH[2]}
        logs_gid=${BASH_REMATCH[3]}
        [[ -d "$logs" && ! -L "$logs" ]] || return 1
    elif [[ "$logs_kind" == missing && "$value" == - ]]; then
        [[ (! -e "$logs" && ! -L "$logs") || (-d "$logs" && ! -L "$logs") ]] \
            || return 1
    else
        return 1
    fi
    for extension in log error.log; do
        path="$logs/$live_domain.$extension"
        expected_link="$VX_CF_MIGRATION_LOG_ROOT/$live_domain.$extension"
        vx_cf_migration_filesystem_component "$artifact" "$item" \
            "docroot.log-link.$extension" || return 1
        kind=$VX_CF_MIGRATION_COMPONENT_KIND
        value=$VX_CF_MIGRATION_COMPONENT_VALUE
        if [[ "$kind" == link ]]; then
            [[ "$logs_kind" == metadata ]] || return 1
            [[ "$value" =~ ^([0-7]{3,4}):([0-9]+):([0-9]+)$ ]] \
                || return 1
            mode=${BASH_REMATCH[1]}
            uid=${BASH_REMATCH[2]}
            gid=${BASH_REMATCH[3]}
            [[ -L "$path" \
                && "$(/usr/bin/readlink -- "$path")" == "$expected_link" ]] \
                || return 1
            (( EUID != 0 )) || /usr/bin/chown -h "$uid:$gid" "$path" \
                || return 1
            [[ "$(/usr/bin/stat -c '%a:%u:%g' "$path")" \
                == "$mode:$uid:$gid" ]] || return 1
        elif [[ "$kind" == missing && "$value" == - ]]; then
            if [[ -L "$path" ]]; then
                [[ "$(/usr/bin/readlink -- "$path")" == "$expected_link" ]] \
                    || return 1
                /usr/bin/rm -f -- "$path" || return 1
            else
                [[ ! -e "$path" ]] || return 1
            fi
        else
            return 1
        fi
    done
    if [[ "$logs_kind" == metadata ]]; then
        /usr/bin/chmod "$logs_mode" "$logs" || return 1
        (( EUID != 0 )) || /usr/bin/chown "$logs_uid:$logs_gid" "$logs" \
            || return 1
        [[ "$(/usr/bin/stat -c '%a:%u:%g' "$logs")" \
            == "$logs_mode:$logs_uid:$logs_gid" ]] || return 1
    elif [[ -d "$logs" && ! -L "$logs" ]]; then
        /usr/bin/rmdir -- "$logs" || return 1
    fi
}

vx_cf_migration_ftp_one() {
    local ftp_user=$1 old_prefix=$2 new_prefix=$3 entry home desired temporary

    vx_cf_migration_passwd_file || return 1
    entry=$(/usr/bin/awk -F: -v user="$ftp_user" '$1 == user { print; count++ }
        END { if (count != 1) exit 1 }' "$VX_CF_MIGRATION_PASSWD") || return 1
    home=$(/usr/bin/printf '%s\n' "$entry" | /usr/bin/cut -d: -f6)
    if [[ "$home" == "$new_prefix" || "$home" == "$new_prefix/"* ]]; then
        return 0
    fi
    [[ "$home" == "$old_prefix" || "$home" == "$old_prefix/"* ]] || return 1
    desired="$new_prefix${home#"$old_prefix"}"
    if vx_cf_migration_is_test; then
        temporary=$(/usr/bin/mktemp "${VX_CF_MIGRATION_PASSWD%/*}/.passwd.XXXXXX") \
            || return 1
        if ! /usr/bin/awk -F: -v OFS=: -v user="$ftp_user" -v home="$desired" '
            $1 == user && !done { $6=home; done=1 }
            { print }
            END { if (!done) exit 1 }
        ' "$VX_CF_MIGRATION_PASSWD" >"$temporary" \
            || ! /usr/bin/chmod --reference="$VX_CF_MIGRATION_PASSWD" "$temporary" \
            || ! /usr/bin/mv -fT -- "$temporary" "$VX_CF_MIGRATION_PASSWD"; then
            /usr/bin/rm -f -- "$temporary"
            return 1
        fi
    else
        /usr/sbin/usermod -d "$desired" "$ftp_user" >/dev/null 2>&1 || return 1
    fi
    entry=$(/usr/bin/awk -F: -v user="$ftp_user" '$1 == user { print; count++ }
        END { if (count != 1) exit 1 }' "$VX_CF_MIGRATION_PASSWD") || return 1
    [[ "$(/usr/bin/printf '%s\n' "$entry" | /usr/bin/cut -d: -f6)" == "$desired" ]]
}

vx_cf_migration_ftp_change() {
    local row=$1 user=$2 source=$3 target=$4 ftp_users ftp_user
    local -a users=()

    vx_cf_migration_row_value "$row" FTP_USER || return 0
    ftp_users=$VX_CF_MIGRATION_ROW_VALUE
    [[ -z "$ftp_users" ]] || IFS=: read -r -a users <<<"$ftp_users"
    vx_cf_migration_homedir || return 1
    for ftp_user in "${users[@]}"; do
        vx_cf_migration_valid_user "$ftp_user" || return 1
        vx_cf_migration_ftp_one "$ftp_user" \
            "$VX_CF_MIGRATION_HOME/$user/web/$source" \
            "$VX_CF_MIGRATION_HOME/$user/web/$target" || return 1
    done
}

vx_cf_migration_filesystem_component() {
    local artifact=$1 item=$2 component=$3 line count=0

    while IFS=$'\t' read -r found_item found_component kind value; do
        [[ "$found_item" == "$item" && "$found_component" == "$component" ]] \
            || continue
        ((count++))
        VX_CF_MIGRATION_COMPONENT_KIND=$kind
        VX_CF_MIGRATION_COMPONENT_VALUE=$value
    done <"$artifact/filesystem.tsv"
    (( count == 1 ))
}

vx_cf_migration_verify_source_ssl_forward() {
    local artifact=$1 item=$2 user=$3 source=$4 retain_source_ssl=$5
    local extension path

    [[ "$retain_source_ssl" =~ ^(yes|no)$ ]] || return 1
    for extension in crt key ca pem; do
        path="$VESTA/data/users/$user/ssl/$source.$extension"
        if [[ "$retain_source_ssl" == yes ]]; then
            vx_cf_migration_read_path_fingerprint "$path" || return 1
            vx_cf_migration_filesystem_component "$artifact" "$item" \
                "ssl.$extension" || return 1
            [[ "$VX_CF_MIGRATION_PATH_KIND" \
                    == "$VX_CF_MIGRATION_COMPONENT_KIND" \
                && "$VX_CF_MIGRATION_PATH_VALUE" \
                    == "$VX_CF_MIGRATION_COMPONENT_VALUE" ]] || return 1
        else
            [[ ! -e "$path" && ! -L "$path" ]] || return 1
        fi
    done
}

vx_cf_migration_ssl_metadata() {
    local artifact=$1 item=$2 component=$3 found state mode uid gid count=0

    while IFS=$'\t' read -r found state mode uid gid; do
        [[ "$found" == "$component" ]] || continue
        ((count++))
        VX_CF_MIGRATION_SSL_STATE=$state
        VX_CF_MIGRATION_SSL_MODE=$mode
        VX_CF_MIGRATION_SSL_UID=$uid
        VX_CF_MIGRATION_SSL_GID=$gid
    done <"$artifact/snapshots/ssl/$item/metadata.tsv"
    (( count == 1 )) || return 1
    [[ "$VX_CF_MIGRATION_SSL_STATE" == absent \
        || ( "$VX_CF_MIGRATION_SSL_STATE" == present \
            && "$VX_CF_MIGRATION_SSL_MODE" =~ ^[0-7]{3,4}$ \
            && "$VX_CF_MIGRATION_SSL_UID" =~ ^[0-9]+$ \
            && "$VX_CF_MIGRATION_SSL_GID" =~ ^[0-9]+$ ) ]]
}

vx_cf_migration_native_file_restore() {
    local saved=$1 target=$2 mode=$3 uid=$4 gid=$5 temporary details

    [[ -f "$saved" && ! -L "$saved" && -d "${target%/*}" \
        && ! -L "${target%/*}" && ! -L "$target" ]] || return 1
    temporary=$(/usr/bin/mktemp "${target%/*}/.migration-ssl.XXXXXX") || return 1
    if ! /usr/bin/cp -- "$saved" "$temporary" \
        || ! /usr/bin/chmod "$mode" "$temporary" \
        || ! { (( EUID != 0 )) \
            || /usr/bin/chown "$uid:$gid" "$temporary"; } \
        || ! /usr/bin/mv -fT -- "$temporary" "$target"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    details=$(/usr/bin/stat -c '%a:%u:%g:%F' "$target") || return 1
    [[ "$details" == "$mode:$uid:$gid:regular file" ]]
}

vx_cf_migration_restore_paths() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5 extension from to saved
    local component ssl_directory directory_was_absent=no

    vx_cf_migration_homedir && vx_cf_migration_log_root || return 1
    from="$VX_CF_MIGRATION_HOME/$user/web/$target"
    to="$VX_CF_MIGRATION_HOME/$user/web/$source"
    if [[ -e "$from" && ! -e "$to" && ! -L "$from" && ! -L "$to" ]]; then
        /usr/bin/mv -T -- "$from" "$to" || return 1
    fi
    [[ -d "$to" && ! -L "$to" && ! -e "$from" ]] || return 1
    for extension in log error.log bytes; do
        from="$VX_CF_MIGRATION_LOG_ROOT/$target.$extension"
        to="$VX_CF_MIGRATION_LOG_ROOT/$source.$extension"
        case "$extension" in
            log) component=log.log ;;
            error.log) component=log.error ;;
            bytes) component=log.bytes ;;
        esac
        vx_cf_migration_filesystem_component "$artifact" "$item" "$component" \
            || return 1
        if [[ "$VX_CF_MIGRATION_COMPONENT_KIND" == file ]]; then
            if [[ -e "$from" && ! -e "$to" && ! -L "$from" && ! -L "$to" ]]; then
                /usr/bin/mv -T -- "$from" "$to" || return 1
            fi
            [[ -f "$to" && ! -L "$to" && ! -e "$from" ]] || return 1
        else
            [[ "$VX_CF_MIGRATION_COMPONENT_KIND" == missing \
                && ! -e "$to" && ! -L "$to" ]] || return 1
            if [[ -e "$from" || -L "$from" ]]; then
                [[ -f "$from" && ! -L "$from" ]] || return 1
                /usr/bin/rm -f -- "$from" || return 1
            fi
        fi
    done
    ssl_directory="$VESTA/data/users/$user/ssl"
    vx_cf_migration_ssl_metadata "$artifact" "$item" DIRECTORY || return 1
    if [[ "$VX_CF_MIGRATION_SSL_STATE" == present ]]; then
        if [[ ! -e "$ssl_directory" && ! -L "$ssl_directory" ]]; then
            /usr/bin/mkdir -- "$ssl_directory" || return 1
        fi
        [[ -d "$ssl_directory" && ! -L "$ssl_directory" ]] || return 1
        /usr/bin/chmod "$VX_CF_MIGRATION_SSL_MODE" "$ssl_directory" || return 1
        (( EUID != 0 )) || /usr/bin/chown \
            "$VX_CF_MIGRATION_SSL_UID:$VX_CF_MIGRATION_SSL_GID" "$ssl_directory" \
            || return 1
    else
        directory_was_absent=yes
        [[ ! -L "$ssl_directory" ]] || return 1
        [[ ! -e "$ssl_directory" || -d "$ssl_directory" ]] || return 1
    fi
    for extension in crt key ca pem; do
        from="$ssl_directory/$target.$extension"
        to="$ssl_directory/$source.$extension"
        saved="$artifact/snapshots/ssl/$item/$extension"
        if [[ -e "$from" || -L "$from" ]]; then
            [[ -f "$from" && ! -L "$from" ]] || return 1
            /usr/bin/rm -f -- "$from" || return 1
        fi
        vx_cf_migration_ssl_metadata "$artifact" "$item" "$extension" || return 1
        if [[ "$VX_CF_MIGRATION_SSL_STATE" == present ]]; then
            vx_cf_migration_native_file_restore "$saved" "$to" \
                "$VX_CF_MIGRATION_SSL_MODE" "$VX_CF_MIGRATION_SSL_UID" \
                "$VX_CF_MIGRATION_SSL_GID" || return 1
        else
            if [[ -e "$to" || -L "$to" ]]; then
                [[ -f "$to" && ! -L "$to" ]] || return 1
                /usr/bin/rm -f -- "$to" || return 1
            fi
        fi
    done
    if [[ "$directory_was_absent" == yes && -d "$ssl_directory" ]]; then
        /usr/bin/rmdir -- "$ssl_directory" 2>/dev/null || return 1
    fi
}

vx_cf_migration_row_from_file() {
    local file=$1 domain=$2 row count

    [[ -f "$file" && ! -L "$file" ]] || return 1
    mapfile -t VX_CF_MIGRATION_ROWS < <(/usr/bin/awk -v domain="$domain" '
        index($0, "DOMAIN=\047" domain "\047") == 1 { print }
    ' "$file")
    count=${#VX_CF_MIGRATION_ROWS[@]}
    (( count == 1 )) || return 1
    row=${VX_CF_MIGRATION_ROWS[0]}
    vx_cf_migration_validate_web_row "$row" || return 1
    vx_cf_migration_row_value "$row" DOMAIN || return 1
    [[ "$VX_CF_MIGRATION_ROW_VALUE" == "$domain" ]] || return 1
    VX_CF_MIGRATION_SOURCE_ROW=$row
}

vx_cf_migration_provider_cleanup_locked() {
    local artifact=$1 item=$2 user=$3 target=$4 hostnames_digest=$5 address=$6
    local record_id certificate_id

    vx_cf_migration_results_get "$artifact" "$item" || return 1
    record_id=$VX_CF_MIGRATION_ITEM_RECORD_ID
    certificate_id=$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID
    if vx_cf_metadata_exists "$user" "$target"; then
        vx_cf_cleanup_locked "$user" "$target" || return 1
    fi
    if [[ -n "$record_id" ]]; then
        if vx_cf_get_record "$record_id"; then
            [[ "$VX_CF_RECORD_ID" == "$record_id" \
                && "$VX_CF_RECORD_NAME" == "$target" \
                && "$VX_CF_RECORD_TYPE" == A \
                && "$VX_CF_RECORD_ADDRESS" == "$address" ]] || return 1
            vx_cf_compensate_created_record_locked "$target" "$address" \
                "$record_id" || return 1
        else
            [[ "$VX_CF_STATUS" == not_found ]] || return 1
        fi
    fi
    if vx_cf_certificate_metadata_exists "$user" "$target"; then
        vx_cf_origin_cleanup_locked "$user" "$target" || return 1
    fi
    if [[ -n "$certificate_id" ]]; then
        if vx_cf_origin_get_certificate "$certificate_id"; then
            [[ "$VX_CF_ORIGIN_CERTIFICATE_ID" == "$certificate_id" \
                && "$VX_CF_ORIGIN_HOSTNAMES_DIGEST" == "$hostnames_digest" ]] \
                || return 1
            if [[ "$VX_CF_ORIGIN_REVOKED" != yes ]]; then
                vx_cf_origin_revoke_certificate "$certificate_id" || return 1
                if vx_cf_origin_get_certificate "$certificate_id"; then
                    [[ "$VX_CF_ORIGIN_REVOKED" == yes ]] || return 1
                else
                    [[ "$VX_CF_STATUS" == not_found ]] || return 1
                fi
            fi
        else
            [[ "$VX_CF_STATUS" == not_found ]] || return 1
        fi
    fi
}

vx_cf_migration_restore_item_locked() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5 hostnames_digest=$6 address=$7
    local original live

    vx_cf_migration_provider_cleanup_locked "$artifact" "$item" "$user" \
        "$target" "$hostnames_digest" "$address" || return 1
    vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
        "$source" || return 1
    original=$VX_CF_MIGRATION_SOURCE_ROW
    vx_cf_migration_ftp_change "$original" "$user" "$target" "$source" \
        || return 1
    if vx_cf_migration_exact_row "$user" "$target"; then
        live=$VX_CF_MIGRATION_SOURCE_ROW
        vx_cf_migration_replace_exact_row "$VESTA/data/users/$user/web.conf" \
            "$live" "$original" || return 1
    elif vx_cf_migration_exact_row "$user" "$source"; then
        [[ "$VX_CF_MIGRATION_SOURCE_ROW" == "$original" ]] || return 1
    else
        return 1
    fi
    vx_cf_migration_restore_paths "$artifact" "$item" "$user" "$source" \
        "$target"
}

vx_cf_migration_user_metadata() {
    local artifact=$1 user=$2 component=$3 found state mode uid gid count=0

    while IFS=$'\t' read -r found state mode uid gid; do
        [[ "$found" == "$component" ]] || continue
        ((count++))
        VX_CF_MIGRATION_USER_STATE=$state
        VX_CF_MIGRATION_USER_MODE=$mode
        VX_CF_MIGRATION_USER_UID=$uid
        VX_CF_MIGRATION_USER_GID=$gid
    done <"$artifact/snapshots/users/$user/metadata.tsv"
    (( count == 1 )) || return 1
    [[ "$VX_CF_MIGRATION_USER_STATE" == absent \
        || ( "$VX_CF_MIGRATION_USER_STATE" == present \
            && "$VX_CF_MIGRATION_USER_MODE" =~ ^[0-7]{3,4}$ \
            && "$VX_CF_MIGRATION_USER_UID" =~ ^[0-9]+$ \
            && "$VX_CF_MIGRATION_USER_GID" =~ ^[0-9]+$ ) ]]
}

vx_cf_migration_user_conf_projection() {
    local file=$1

    [[ -f "$file" && ! -L "$file" ]] || return 1
    /usr/bin/awk '
        /^U_WEB_SSL=\047[0-9]+\047$/ {
            ssl_count++
            print "U_WEB_SSL=\047<migration-owned>\047"
            next
        }
        /^U_WEB_ALIASES=\047[0-9]+\047$/ {
            alias_count++
            print "U_WEB_ALIASES=\047<migration-owned>\047"
            next
        }
        { print }
        END { if (ssl_count != 1 || alias_count != 1) exit 1 }
    ' "$file"
}

vx_cf_migration_user_counter_value() {
    local file=$1 key=$2 line count

    [[ -f "$file" && ! -L "$file" \
        && "$key" =~ ^U_WEB_(SSL|ALIASES)$ ]] || return 1
    line=$(/usr/bin/grep -E "^${key}='(0|[1-9][0-9]{0,8})'$" "$file") \
        || return 1
    count=$(/usr/bin/grep -Ec "^${key}='(0|[1-9][0-9]{0,8})'$" "$file") \
        || return 1
    [[ "$count" == 1 ]] || return 1
    VX_CF_MIGRATION_USER_COUNTER=${line#*=\'}
    VX_CF_MIGRATION_USER_COUNTER=${VX_CF_MIGRATION_USER_COUNTER%\'}
}

vx_cf_migration_user_ssl_counter_value() {
    vx_cf_migration_user_counter_value "$1" U_WEB_SSL || return 1
    VX_CF_MIGRATION_USER_SSL_COUNTER=$VX_CF_MIGRATION_USER_COUNTER
}

vx_cf_migration_expected_user_ssl_counter() {
    local artifact=$1 user=$2 item row_user source target hostnames address retain
    local state ssl baseline delta=0

    vx_cf_migration_user_ssl_counter_value \
        "$artifact/snapshots/users/$user/user.conf" || return 1
    baseline=$VX_CF_MIGRATION_USER_SSL_COUNTER
    while IFS=$'\t' read -r item row_user source target hostnames address retain; do
        [[ "$item" != ITEM && "$row_user" == "$user" ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        state=$VX_CF_MIGRATION_ITEM_STATE
        [[ "$state" == provisioned || "$state" == applied \
            || "$state" == rolling_back || "$state" == recovery_required ]] \
            || continue
        vx_cf_migration_row_from_file \
            "$artifact/snapshots/users/$user/web.conf" "$source" || return 1
        vx_cf_migration_row_value "$VX_CF_MIGRATION_SOURCE_ROW" SSL || return 1
        ssl=$VX_CF_MIGRATION_ROW_VALUE
        [[ "$ssl" == yes || "$ssl" == no ]] || return 1
        [[ "$ssl" == yes ]] || ((delta++))
    done <"$artifact/plan.tsv"
    (( baseline <= 999999999 - delta )) || return 1
    VX_CF_MIGRATION_EXPECTED_USER_SSL_COUNTER=$((baseline + delta))
}

vx_cf_migration_expected_user_alias_counter() {
    local artifact=$1 user=$2 item row_user source target hostnames address retain
    local state baseline original_count target_count delta=0

    vx_cf_migration_user_counter_value \
        "$artifact/snapshots/users/$user/user.conf" U_WEB_ALIASES || return 1
    baseline=$VX_CF_MIGRATION_USER_COUNTER
    while IFS=$'\t' read -r item row_user source target hostnames address retain; do
        [[ "$item" != ITEM && "$row_user" == "$user" ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        state=$VX_CF_MIGRATION_ITEM_STATE
        [[ "$state" == provisioned || "$state" == applied \
            || "$state" == rolling_back || "$state" == recovery_required ]] \
            || continue
        vx_cf_migration_row_from_file \
            "$artifact/snapshots/users/$user/web.conf" "$source" || return 1
        vx_cf_migration_row_alias_count "$VX_CF_MIGRATION_SOURCE_ROW" \
            || return 1
        original_count=$VX_CF_MIGRATION_ALIAS_COUNT
        vx_cf_migration_target_row "$source" "$target" \
            "$VX_CF_MIGRATION_SOURCE_ROW" || return 1
        vx_cf_migration_row_alias_count "$VX_CF_MIGRATION_TARGET_ROW" \
            || return 1
        target_count=$VX_CF_MIGRATION_ALIAS_COUNT
        ((delta += target_count - original_count))
    done <"$artifact/plan.tsv"
    (( baseline + delta >= 0 && baseline + delta <= 999999999 )) || return 1
    VX_CF_MIGRATION_EXPECTED_USER_ALIAS_COUNTER=$((baseline + delta))
}

vx_cf_migration_write_user_owned_counters() {
    local file=$1 expected_ssl=$2 expected_aliases=$3
    local current_ssl current_aliases old_ssl old_aliases new_ssl new_aliases
    local temporary

    [[ "$expected_ssl" =~ ^(0|[1-9][0-9]{0,8})$ \
        && "$expected_aliases" =~ ^(0|[1-9][0-9]{0,8})$ ]] || return 1
    vx_cf_migration_user_counter_value "$file" U_WEB_SSL || return 1
    current_ssl=$VX_CF_MIGRATION_USER_COUNTER
    vx_cf_migration_user_counter_value "$file" U_WEB_ALIASES || return 1
    current_aliases=$VX_CF_MIGRATION_USER_COUNTER
    [[ "$current_ssl" == "$expected_ssl" \
        && "$current_aliases" == "$expected_aliases" ]] && return 0
    old_ssl="U_WEB_SSL='$current_ssl'"
    old_aliases="U_WEB_ALIASES='$current_aliases'"
    new_ssl="U_WEB_SSL='$expected_ssl'"
    new_aliases="U_WEB_ALIASES='$expected_aliases'"
    temporary=$(/usr/bin/mktemp "${file%/*}/.migration-counters.XXXXXX") \
        || return 1
    if ! /usr/bin/awk -v old_ssl="$old_ssl" -v new_ssl="$new_ssl" \
        -v old_aliases="$old_aliases" -v new_aliases="$new_aliases" '
            $0 == old_ssl && !ssl_done { print new_ssl; ssl_done=1; next }
            $0 == old_aliases && !aliases_done {
                print new_aliases
                aliases_done=1
                next
            }
            { print }
            END { if (!ssl_done || !aliases_done) exit 1 }
        ' "$file" >"$temporary" \
        || ! /usr/bin/chmod --reference="$file" "$temporary" \
        || ! { (( EUID != 0 )) \
            || /usr/bin/chown --reference="$file" "$temporary"; } \
        || ! /usr/bin/mv -fT -- "$temporary" "$file"; then
        /usr/bin/rm -f -- "$temporary"
        return 1
    fi
    vx_cf_migration_user_counter_value "$file" U_WEB_SSL \
        && [[ "$VX_CF_MIGRATION_USER_COUNTER" == "$expected_ssl" ]] \
        && vx_cf_migration_user_counter_value "$file" U_WEB_ALIASES \
        && [[ "$VX_CF_MIGRATION_USER_COUNTER" == "$expected_aliases" ]]
}

vx_cf_migration_reconcile_user_owned_counters() {
    local artifact=$1 user=$2 file

    vx_cf_migration_valid_user "$user" || return 1
    vx_cf_migration_user_conf_matches_snapshot "$artifact" "$user" yes no \
        || return 1
    vx_cf_migration_expected_user_ssl_counter "$artifact" "$user" || return 1
    vx_cf_migration_expected_user_alias_counter "$artifact" "$user" || return 1
    file="$VESTA/data/users/$user/user.conf"
    vx_cf_migration_write_user_owned_counters "$file" \
        "$VX_CF_MIGRATION_EXPECTED_USER_SSL_COUNTER" \
        "$VX_CF_MIGRATION_EXPECTED_USER_ALIAS_COUNTER" || return 1
    vx_cf_migration_user_conf_matches_snapshot "$artifact" "$user" yes
}

vx_cf_migration_user_has_planned_item() {
    local artifact=$1 user=$2

    vx_cf_migration_valid_user "$user" || return 1
    /usr/bin/awk -F '\t' -v user="$user" '
        NR > 1 && $2 == user { found=1 }
        END { exit !found }
    ' "$artifact/plan.tsv"
}

vx_cf_migration_user_conf_matches_snapshot() {
    local artifact=$1 user=$2 allow_owned_counter=$3 saved live details expected
    local enforce_expected_counter=${4:-yes}
    local root saved_projection live_projection result=1 live_counter
    local live_alias_counter saved_alias_counter saved_ssl_counter

    saved="$artifact/snapshots/users/$user/user.conf"
    live="$VESTA/data/users/$user/user.conf"
    vx_cf_migration_valid_user "$user" \
        && vx_cf_migration_secure_file "$saved" \
        && [[ -f "$live" && ! -L "$live" \
            && "$allow_owned_counter" =~ ^(yes|no)$ \
            && "$enforce_expected_counter" =~ ^(yes|no)$ ]] || return 1
    vx_cf_migration_user_metadata "$artifact" "$user" USER || return 1
    [[ "$VX_CF_MIGRATION_USER_STATE" == present ]] || return 1
    details=$(/usr/bin/stat -c '%a:%u:%g' "$live") || return 1
    expected="$VX_CF_MIGRATION_USER_MODE:$VX_CF_MIGRATION_USER_UID:$VX_CF_MIGRATION_USER_GID"
    [[ "$details" == "$expected" ]] || return 1
    if [[ "$allow_owned_counter" == no ]]; then
        /usr/bin/cmp -s -- "$saved" "$live"
        return
    fi
    root=$(vx_cf_migration_root)
    vx_cf_migration_secure_directory "$root" || return 1
    saved_projection=$(/usr/bin/mktemp "$root/.user-saved.XXXXXX") || return 1
    live_projection=$(/usr/bin/mktemp "$root/.user-live.XXXXXX") || {
        /usr/bin/rm -f -- "$saved_projection"
        return 1
    }
    if vx_cf_secure_path "$saved_projection" 0600 \
        && vx_cf_secure_path "$live_projection" 0600 \
        && vx_cf_migration_user_conf_projection "$saved" >"$saved_projection" \
        && vx_cf_migration_user_conf_projection "$live" >"$live_projection" \
        && /usr/bin/cmp -s -- "$saved_projection" "$live_projection"; then
        result=0
    fi
    /usr/bin/rm -f -- "$saved_projection" "$live_projection"
    (( result == 0 )) || return 1
    [[ "$enforce_expected_counter" == yes ]] || return 0
    vx_cf_migration_expected_user_ssl_counter "$artifact" "$user" || return 1
    vx_cf_migration_user_ssl_counter_value "$live" || return 1
    live_counter=$VX_CF_MIGRATION_USER_SSL_COUNTER
    vx_cf_migration_expected_user_alias_counter "$artifact" "$user" || return 1
    vx_cf_migration_user_counter_value "$live" U_WEB_ALIASES || return 1
    live_alias_counter=$VX_CF_MIGRATION_USER_COUNTER
    if [[ "$live_counter" == "$VX_CF_MIGRATION_EXPECTED_USER_SSL_COUNTER" \
        && "$live_alias_counter" \
            == "$VX_CF_MIGRATION_EXPECTED_USER_ALIAS_COUNTER" ]]; then
        return 0
    fi
    [[ "$VX_CF_MIGRATION_RECOVERY_STATUS" == recovery_required ]] || return 1
    vx_cf_migration_user_ssl_counter_value "$saved" || return 1
    saved_ssl_counter=$VX_CF_MIGRATION_USER_SSL_COUNTER
    vx_cf_migration_user_counter_value "$saved" U_WEB_ALIASES || return 1
    saved_alias_counter=$VX_CF_MIGRATION_USER_COUNTER
    [[ "$live_counter" == "$saved_ssl_counter" \
        && "$live_alias_counter" == "$saved_alias_counter" ]]
}

vx_cf_migration_user_conf_scope_matches() {
    local artifact=$1 user allow_owned_counter

    while IFS= read -r user || [[ -n "$user" ]]; do
        [[ -n "$user" ]] || continue
        allow_owned_counter=no
        if vx_cf_migration_user_has_planned_item "$artifact" "$user"; then
            allow_owned_counter=yes
        fi
        vx_cf_migration_user_conf_matches_snapshot "$artifact" "$user" \
            "$allow_owned_counter" || return 1
    done <"$artifact/scope-users.tsv"
    return 0
}

vx_cf_migration_restore_user_owned_counters() {
    local artifact=$1 user=$2 saved live

    saved="$artifact/snapshots/users/$user/user.conf"
    live="$VESTA/data/users/$user/user.conf"
    vx_cf_migration_user_conf_matches_snapshot "$artifact" "$user" yes no \
        || return 1
    vx_cf_migration_user_metadata "$artifact" "$user" USER || return 1
    vx_cf_migration_native_file_restore "$saved" "$live" \
        "$VX_CF_MIGRATION_USER_MODE" "$VX_CF_MIGRATION_USER_UID" \
        "$VX_CF_MIGRATION_USER_GID" || return 1
    /usr/bin/cmp -s -- "$saved" "$live"
}

vx_cf_migration_restore_user_snapshot() {
    local artifact=$1 user=$2 rendered state

    vx_cf_migration_user_metadata "$artifact" "$user" WEB || return 1
    vx_cf_migration_native_file_restore \
        "$artifact/snapshots/users/$user/web.conf" \
        "$VESTA/data/users/$user/web.conf" "$VX_CF_MIGRATION_USER_MODE" \
        "$VX_CF_MIGRATION_USER_UID" "$VX_CF_MIGRATION_USER_GID" || return 1
    if vx_cf_migration_user_has_planned_item "$artifact" "$user"; then
        vx_cf_migration_restore_user_owned_counters "$artifact" "$user" \
            || return 1
    fi
    vx_cf_migration_homedir || return 1
    rendered="$VX_CF_MIGRATION_HOME/$user/conf/web"
    vx_cf_migration_user_metadata "$artifact" "$user" RENDERED || return 1
    if [[ "$VX_CF_MIGRATION_USER_STATE" == present ]]; then
        if [[ ! -e "$rendered" && ! -L "$rendered" ]]; then
            /usr/bin/mkdir -- "$rendered" || return 1
        fi
        [[ -d "$rendered" && ! -L "$rendered" ]] || return 1
        /usr/bin/find -P "$rendered" -mindepth 1 -delete || return 1
        /usr/bin/tar --numeric-owner --acls --xattrs -C "$rendered" \
            -xpf "$artifact/snapshots/users/$user/rendered.tar" || return 1
        /usr/bin/chmod "$VX_CF_MIGRATION_USER_MODE" "$rendered" || return 1
        (( EUID != 0 )) || /usr/bin/chown \
            "$VX_CF_MIGRATION_USER_UID:$VX_CF_MIGRATION_USER_GID" "$rendered" \
            || return 1
    else
        [[ ! -L "$rendered" ]] || return 1
        if [[ -d "$rendered" ]]; then
            /usr/bin/find -P "$rendered" -mindepth 1 -delete || return 1
            /usr/bin/rmdir -- "$rendered" || return 1
        fi
    fi
}

vx_cf_migration_rebuild_locked() {
    local artifact=$1 restart=${2:-yes} user
    local -A seen=()

    while IFS=$'\t' read -r _ user _; do
        [[ "$user" != USER ]] || continue
        [[ -z "${seen[$user]+x}" ]] || continue
        seen[$user]=1
        VX_CLOUDFLARE_INTERNAL_MIGRATION=1 VESTA="$VESTA" \
            "$VESTA/bin/v-rebuild-web-domains" "$user" no \
            >/dev/null 2>&1 || return 1
    done <"$artifact/plan.tsv"
    [[ "$restart" == no ]] && return 0
    VESTA="$VESTA" "$VESTA/bin/v-restart-web" yes >/dev/null 2>&1 \
        && VESTA="$VESTA" "$VESTA/bin/v-restart-proxy" yes >/dev/null 2>&1
}

vx_cf_migration_restored_items_pending() {
    local artifact=$1 item user source target hostnames address retain state

    while IFS=$'\t' read -r item user source target hostnames address retain; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        state=$VX_CF_MIGRATION_ITEM_STATE
        case "$state" in
            rolling_back)
                vx_cf_migration_results_set "$artifact" "$item" pending '' '' \
                    "$target" || return 1
                ;;
            pending|rolled_back) ;;
            *) return 1 ;;
        esac
    done <"$artifact/plan.tsv"
    return 0
}

vx_cf_migration_restore_all_locked() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl state
    local failed=0
    local -a rows=()

    mapfile -t rows < <(/usr/bin/tail -n +2 "$artifact/plan.tsv" | /usr/bin/tac)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r item user source target hostnames_digest address \
            retain_source_ssl <<<"$row"
        vx_cf_migration_results_get "$artifact" "$item" || { failed=1; continue; }
        state=$VX_CF_MIGRATION_ITEM_STATE
        [[ "$state" != pending && "$state" != rolled_back ]] || continue
        vx_cf_migration_results_set "$artifact" "$item" rolling_back \
            "$VX_CF_MIGRATION_ITEM_RECORD_ID" \
            "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" "$target" \
            || { failed=1; continue; }
        if ! vx_cf_migration_restore_item_locked "$artifact" "$item" "$user" \
            "$source" "$target" "$hostnames_digest" "$address"; then
            vx_cf_migration_results_get "$artifact" "$item" || :
            vx_cf_migration_results_set "$artifact" "$item" recovery_required \
                "${VX_CF_MIGRATION_ITEM_RECORD_ID:-}" \
                "${VX_CF_MIGRATION_ITEM_CERTIFICATE_ID:-}" "$target" || :
            failed=1
        fi
    done
    (( failed == 0 )) || return 1
    vx_cf_migration_rebuild_locked "$artifact" no || return 1
    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
            "$source" || return 1
        vx_cf_migration_cleanup_stale_identity "$user" "$target" \
            "$VX_CF_MIGRATION_SOURCE_ROW" "$source" || return 1
        vx_cf_migration_restore_docroot_metadata "$artifact" "$item" \
            "$user" "$source" || return 1
    done <"$artifact/plan.tsv"
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        vx_cf_migration_restore_user_snapshot "$artifact" "$user" || return 1
    done <"$artifact/scope-users.tsv"
    vx_cf_migration_restored_items_pending "$artifact" || return 1
    VESTA="$VESTA" "$VESTA/bin/v-restart-web" yes >/dev/null 2>&1 \
        && VESTA="$VESTA" "$VESTA/bin/v-restart-proxy" yes >/dev/null 2>&1 \
        || return 1
    vx_cf_migration_live_matches_plan "$artifact"
}

vx_cf_migration_state_counts() {
    local artifact=$1 item state record certificate

    VX_CF_MIGRATION_COUNT_PENDING=0
    VX_CF_MIGRATION_COUNT_APPLIED=0
    VX_CF_MIGRATION_COUNT_ROLLED_BACK=0
    VX_CF_MIGRATION_COUNT_OTHER=0
    while IFS= read -r line; do
        [[ "$line" == ITEM=* ]] || continue
        vx_cf_migration_row_value "$line" STATE || return 1
        state=$VX_CF_MIGRATION_ROW_VALUE
        case "$state" in
            pending) ((VX_CF_MIGRATION_COUNT_PENDING++)) ;;
            applied) ((VX_CF_MIGRATION_COUNT_APPLIED++)) ;;
            rolled_back) ((VX_CF_MIGRATION_COUNT_ROLLED_BACK++)) ;;
            *) ((VX_CF_MIGRATION_COUNT_OTHER++)) ;;
        esac
    done <"$artifact/results.tsv"
    return 0
}

vx_cf_migration_preapply_locked() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl

    if ! vx_cf_status_locked || [[ "$VX_CF_STATUS" != ready ]]; then
        VX_CF_MIGRATION_STATUS=provider_not_ready
        return 1
    fi
    vx_cf_migration_live_matches_plan "$artifact" || {
        VX_CF_MIGRATION_STATUS=drift
        return 1
    }
    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_preflight_locked "$user" "$source" "$target" || {
            VX_CF_MIGRATION_STATUS=drift
            return 1
        }
        [[ "$VX_CF_STATUS" == ready \
            && "$VX_CF_MIGRATION_HOSTNAMES_DIGEST" == "$hostnames_digest" \
            && "$VX_CF_WEB_ADDRESS" == "$address" ]] || {
                VX_CF_MIGRATION_STATUS=drift
                return 1
            }
    done <"$artifact/plan.tsv"
}

vx_cf_migration_apply_item_locked() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5 hostnames_digest=$6 address=$7
    local retain_source_ssl=$8
    local original target_row rc

    vx_cf_migration_exact_row "$user" "$source" || return 1
    original=$VX_CF_MIGRATION_SOURCE_ROW
    vx_cf_migration_target_row "$source" "$target" "$original" || return 1
    target_row=$VX_CF_MIGRATION_TARGET_ROW
    vx_cf_migration_results_set "$artifact" "$item" renaming '' '' "$target" \
        || return 1
    vx_cf_migration_paths_forward "$user" "$source" "$target" \
        "$retain_source_ssl" || return 1
    vx_cf_migration_ftp_change "$original" "$user" "$source" "$target" \
        || return 1
    vx_cf_migration_replace_exact_row "$VESTA/data/users/$user/web.conf" \
        "$original" "$target_row" || return 1
    vx_cf_migration_exact_row "$user" "$target" \
        && [[ "$VX_CF_MIGRATION_SOURCE_ROW" == "$target_row" ]] || return 1
    vx_cf_migration_results_set "$artifact" "$item" renamed '' '' "$target" \
        || return 1

    VX_CF_MIGRATION_ACTIVE_ARTIFACT=$artifact
    VX_CF_MIGRATION_ACTIVE_ITEM=$item
    VX_CF_MIGRATION_ACTIVE_TARGET=$target
    if vx_cf_reconcile_locked "$user" "$target"; then rc=0; else rc=$?; fi
    unset VX_CF_MIGRATION_ACTIVE_ARTIFACT VX_CF_MIGRATION_ACTIVE_ITEM \
        VX_CF_MIGRATION_ACTIVE_TARGET
    (( rc == 0 )) || return "$rc"
    vx_cf_migration_results_get "$artifact" "$item" || return 1
    [[ -n "$VX_CF_MIGRATION_ITEM_RECORD_ID" ]] || return 1
    vx_cf_load_metadata "$user" "$target" || return 1
    [[ "$VX_CF_META_RECORD_ID" == "$VX_CF_MIGRATION_ITEM_RECORD_ID" \
        && "$VX_CF_META_ADDRESS" == "$address" ]] || return 1
    vx_cf_migration_results_set "$artifact" "$item" record_ready \
        "$VX_CF_MIGRATION_ITEM_RECORD_ID" '' "$target" || return 1

    VX_CF_MIGRATION_ACTIVE_ARTIFACT=$artifact
    VX_CF_MIGRATION_ACTIVE_ITEM=$item
    VX_CF_MIGRATION_ACTIVE_TARGET=$target
    if VX_CLOUDFLARE_INTERNAL_MIGRATION=1 \
        vx_cf_origin_reconcile_locked "$user" "$target" no; then
        rc=0
    else
        rc=$?
    fi
    unset VX_CF_MIGRATION_ACTIVE_ARTIFACT VX_CF_MIGRATION_ACTIVE_ITEM \
        VX_CF_MIGRATION_ACTIVE_TARGET
    (( rc == 0 )) || return "$rc"
    vx_cf_migration_results_get "$artifact" "$item" || return 1
    [[ -n "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" ]] || return 1
    vx_cf_load_certificate_metadata "$user" "$target" || return 1
    [[ "$VX_CF_CERT_META_ID" == "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" \
        && "$VX_CF_CERT_META_DIGEST" == "$hostnames_digest" ]] || return 1
    vx_cf_migration_results_set "$artifact" "$item" provisioned \
        "$VX_CF_MIGRATION_ITEM_RECORD_ID" \
        "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" "$target" || return 1
    vx_cf_migration_reconcile_user_owned_counters "$artifact" "$user"
}

vx_cf_migration_verify_and_finish_locked() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl

    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_verify_managed_site_locked "$user" "$target" \
            && [[ "$VX_CF_STATUS" == managed ]] || return 1
        vx_cf_migration_verify_source_ssl_forward "$artifact" "$item" "$user" \
            "$source" "$retain_source_ssl" || return 1
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        [[ "$VX_CF_MIGRATION_ITEM_STATE" == provisioned ]] || return 1
        vx_cf_migration_results_set "$artifact" "$item" applied \
            "$VX_CF_MIGRATION_ITEM_RECORD_ID" \
            "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" "$target" || return 1
    done <"$artifact/plan.tsv"
}

vx_cf_migration_scope_matches() {
    local artifact=$1 temporary result=1

    temporary=$(/usr/bin/mktemp "$(vx_cf_migration_root)/.scope.XXXXXX") \
        || return 1
    vx_cf_secure_path "$temporary" 0600 || {
        /usr/bin/rm -f -- "$temporary"
        return 1
    }
    if [[ "$VX_CF_MIGRATION_SCOPE" == all ]]; then
        /usr/bin/find -P "$VESTA/data/users" -mindepth 1 -maxdepth 1 -type d \
            -printf '%f\n' | LC_ALL=C /usr/bin/sort >"$temporary" || :
    else
        printf '%s\n' "$VX_CF_MIGRATION_SCOPE" >"$temporary"
    fi
    /usr/bin/cmp -s "$temporary" "$artifact/scope-users.tsv" && result=0
    /usr/bin/rm -f -- "$temporary"
    return "$result"
}

vx_cf_migration_applied_matches_locked() {
    local artifact=$1 user temporary item row_user source target hostnames_digest address
    local retain_source_ssl
    local original expected target_row state

    [[ "$(vx_cf_migration_sha256 "$(vx_cf_config_path)")" \
        == "$VX_CF_MIGRATION_CONFIG_SHA" \
        && "$(vx_cf_migration_sha256 "$VESTA/conf/vesta.conf")" \
        == "$VX_CF_MIGRATION_VESTA_SHA" ]] || return 1
    vx_cf_migration_scope_matches "$artifact" || return 1
    vx_cf_migration_user_conf_scope_matches "$artifact" || return 1
    while IFS= read -r user; do
        [[ -n "$user" ]] || continue
        temporary=$(/usr/bin/mktemp "$(vx_cf_migration_root)/.expected.XXXXXX") \
            || return 1
        vx_cf_secure_path "$temporary" 0600 || {
            /usr/bin/rm -f -- "$temporary"
            return 1
        }
        /usr/bin/cp -- "$artifact/snapshots/users/$user/web.conf" "$temporary" \
            || { /usr/bin/rm -f -- "$temporary"; return 1; }
        while IFS=$'\t' read -r item row_user source target hostnames_digest address \
            retain_source_ssl; do
            [[ "$item" != ITEM && "$row_user" == "$user" ]] || continue
            vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
                "$source" || { /usr/bin/rm -f -- "$temporary"; return 1; }
            original=$VX_CF_MIGRATION_SOURCE_ROW
            vx_cf_migration_results_get "$artifact" "$item" \
                || { /usr/bin/rm -f -- "$temporary"; return 1; }
            state=$VX_CF_MIGRATION_ITEM_STATE
            if [[ "$state" == applied ]]; then
                vx_cf_migration_target_row "$source" "$target" "$original" \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
                target_row=$VX_CF_MIGRATION_TARGET_ROW
                vx_cf_migration_row_replace "$target_row" SSL yes \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
                expected=$VX_CF_MIGRATION_ROW
                vx_cf_migration_replace_exact_row "$temporary" "$original" "$expected" \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
                vx_cf_verify_managed_site_locked "$user" "$target" \
                    && [[ "$VX_CF_STATUS" == managed ]] \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
                vx_cf_migration_verify_source_ssl_forward "$artifact" "$item" \
                    "$user" "$source" "$retain_source_ssl" \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
                vx_cf_migration_verify_applied_native "$artifact" "$user" \
                    "$source" "$target" \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
            elif [[ "$state" == rolled_back || "$state" == pending ]]; then
                vx_cf_migration_verify_restored_item_locked "$artifact" "$item" \
                    "$user" "$source" "$target" \
                    || { /usr/bin/rm -f -- "$temporary"; return 1; }
            else
                /usr/bin/rm -f -- "$temporary"
                return 1
            fi
        done <"$artifact/plan.tsv"
        /usr/bin/cmp -s "$temporary" "$VESTA/data/users/$user/web.conf" \
            || { /usr/bin/rm -f -- "$temporary"; return 1; }
        /usr/bin/rm -f -- "$temporary"
    done <"$artifact/scope-users.tsv"
    return 0
}

vx_cf_migration_context_snapshot() {
    local artifact=$1 item=$2 user=$3 context rendered temporary

    context="$artifact/recovery/$item"
    [[ ! -e "$context" && ! -L "$context" ]] || return 1
    vx_cf_migration_make_directory "$context" || return 1
    vx_cf_migration_copy_protected "$VESTA/data/users/$user/user.conf" \
        "$context/user.conf" || return 1
    printf 'USER\tpresent\t%s\t%s\t%s\n' \
        "$(/usr/bin/stat -c '%a' "$VESTA/data/users/$user/user.conf")" \
        "$(/usr/bin/stat -c '%u' "$VESTA/data/users/$user/user.conf")" \
        "$(/usr/bin/stat -c '%g' "$VESTA/data/users/$user/user.conf")" \
        >"$context/metadata.tsv"
    vx_cf_migration_homedir || return 1
    rendered="$VX_CF_MIGRATION_HOME/$user/conf/web"
    if [[ ! -e "$rendered" && ! -L "$rendered" ]]; then
        printf 'RENDERED\tabsent\t-\t-\t-\n' >>"$context/metadata.tsv"
        printf 'missing\n' | vx_cf_migration_atomic_write \
            "$context/rendered.digest" || return 1
    else
        [[ -d "$rendered" && ! -L "$rendered" ]] || return 1
        printf 'RENDERED\tpresent\t%s\t%s\t%s\n' \
            "$(/usr/bin/stat -c '%a' "$rendered")" \
            "$(/usr/bin/stat -c '%u' "$rendered")" \
            "$(/usr/bin/stat -c '%g' "$rendered")" \
            >>"$context/metadata.tsv"
        vx_cf_migration_tree_digest "$rendered" \
            | vx_cf_migration_atomic_write "$context/rendered.digest" || return 1
        temporary=$(/usr/bin/mktemp "$context/.rendered.XXXXXX") || return 1
        vx_cf_secure_path "$temporary" 0600 || return 1
        /usr/bin/tar --numeric-owner --acls --xattrs -C "$rendered" \
            -cpf "$temporary" . \
            && /usr/bin/mv -fT -- "$temporary" "$context/rendered.tar" \
            && vx_cf_migration_secure_file "$context/rendered.tar" || {
                /usr/bin/rm -f -- "$temporary"
                return 1
            }
    fi
    vx_cf_secure_path "$context/metadata.tsv" 0600 \
        && vx_cf_migration_secure_file "$context/metadata.tsv"
}

vx_cf_migration_context_metadata() {
    local artifact=$1 item=$2 component=$3 found state mode uid gid count=0

    vx_cf_migration_secure_file "$artifact/recovery/$item/metadata.tsv" \
        || return 1
    /usr/bin/awk -F '\t' 'NF != 5 { exit 1 }' \
        "$artifact/recovery/$item/metadata.tsv" || return 1
    while IFS=$'\t' read -r found state mode uid gid; do
        [[ "$found" == "$component" ]] || continue
        ((count++))
        VX_CF_MIGRATION_CONTEXT_STATE=$state
        VX_CF_MIGRATION_CONTEXT_MODE=$mode
        VX_CF_MIGRATION_CONTEXT_UID=$uid
        VX_CF_MIGRATION_CONTEXT_GID=$gid
    done <"$artifact/recovery/$item/metadata.tsv"
    (( count == 1 )) || return 1
    if [[ "$component" == USER ]]; then
        [[ "$VX_CF_MIGRATION_CONTEXT_STATE" == present ]]
    else
        [[ "$component" == RENDERED \
            && "$VX_CF_MIGRATION_CONTEXT_STATE" =~ ^(present|absent)$ ]] \
            || return 1
    fi
    if [[ "$VX_CF_MIGRATION_CONTEXT_STATE" == present ]]; then
        [[ "$VX_CF_MIGRATION_CONTEXT_MODE" =~ ^[0-7]{3,4}$ \
            && "$VX_CF_MIGRATION_CONTEXT_UID" =~ ^[0-9]+$ \
            && "$VX_CF_MIGRATION_CONTEXT_GID" =~ ^[0-9]+$ ]]
    else
        [[ "$VX_CF_MIGRATION_CONTEXT_MODE" == - \
            && "$VX_CF_MIGRATION_CONTEXT_UID" == - \
            && "$VX_CF_MIGRATION_CONTEXT_GID" == - ]]
    fi
}

vx_cf_migration_context_validate() {
    local artifact=$1 item=$2 context digest entry count=0

    [[ "$item" =~ ^[0-9]{6}$ ]] || return 1
    context="$artifact/recovery/$item"
    vx_cf_migration_secure_directory "$context" \
        && vx_cf_migration_secure_file "$context/user.conf" \
        && vx_cf_migration_secure_file "$context/metadata.tsv" \
        && vx_cf_migration_secure_file "$context/rendered.digest" || return 1
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        ((count++))
        [[ "$entry" == USER$'\t'* || "$entry" == RENDERED$'\t'* ]] \
            || return 1
    done <"$context/metadata.tsv"
    (( count == 2 )) || return 1
    vx_cf_migration_context_metadata "$artifact" "$item" USER || return 1
    vx_cf_migration_context_metadata "$artifact" "$item" RENDERED || return 1
    IFS= read -r digest <"$context/rendered.digest" || return 1
    [[ -n "$digest" \
        && "$(/usr/bin/wc -l <"$context/rendered.digest")" == 1 ]] || return 1
    if [[ "$VX_CF_MIGRATION_CONTEXT_STATE" == present ]]; then
        [[ "$digest" =~ ^[a-f0-9]{64}$ ]] \
            && vx_cf_migration_secure_file "$context/rendered.tar" \
            && /usr/bin/tar -tf "$context/rendered.tar" >/dev/null 2>&1 \
            || return 1
        while IFS= read -r entry; do
            [[ "$entry" != /* \
                && "$entry" != .. \
                && "$entry" != ../* \
                && "$entry" != */../* \
                && "$entry" != */.. ]] || return 1
        done < <(/usr/bin/tar -tf "$context/rendered.tar")
    else
        [[ "$digest" == missing \
            && ! -e "$context/rendered.tar" \
            && ! -L "$context/rendered.tar" ]] || return 1
    fi
}

vx_cf_migration_context_restore() {
    local artifact=$1 item=$2 user=$3 context rendered expected actual

    context="$artifact/recovery/$item"
    vx_cf_migration_context_validate "$artifact" "$item" || return 1
    vx_cf_migration_context_metadata "$artifact" "$item" USER || return 1
    vx_cf_migration_native_file_restore "$context/user.conf" \
        "$VESTA/data/users/$user/user.conf" "$VX_CF_MIGRATION_CONTEXT_MODE" \
        "$VX_CF_MIGRATION_CONTEXT_UID" "$VX_CF_MIGRATION_CONTEXT_GID" \
        || return 1
    vx_cf_migration_homedir || return 1
    rendered="$VX_CF_MIGRATION_HOME/$user/conf/web"
    vx_cf_migration_context_metadata "$artifact" "$item" RENDERED || return 1
    if [[ "$VX_CF_MIGRATION_CONTEXT_STATE" == present ]]; then
        if [[ ! -e "$rendered" && ! -L "$rendered" ]]; then
            /usr/bin/mkdir -- "$rendered" || return 1
        fi
        [[ -d "$rendered" && ! -L "$rendered" ]] || return 1
        /usr/bin/find -P "$rendered" -mindepth 1 -delete || return 1
        /usr/bin/tar --numeric-owner --acls --xattrs -C "$rendered" \
            -xpf "$context/rendered.tar" || return 1
        /usr/bin/chmod "$VX_CF_MIGRATION_CONTEXT_MODE" "$rendered" || return 1
        (( EUID != 0 )) || /usr/bin/chown \
            "$VX_CF_MIGRATION_CONTEXT_UID:$VX_CF_MIGRATION_CONTEXT_GID" \
            "$rendered" || return 1
        expected=$(<"$context/rendered.digest")
        actual=$(vx_cf_migration_tree_digest "$rendered") || return 1
        [[ "$actual" == "$expected" ]] || return 1
    else
        [[ "$VX_CF_MIGRATION_CONTEXT_STATE" == absent && ! -L "$rendered" ]] \
            || return 1
        if [[ -d "$rendered" ]]; then
            /usr/bin/find -P "$rendered" -mindepth 1 -delete || return 1
            /usr/bin/rmdir -- "$rendered" || return 1
        fi
    fi
    /usr/bin/cmp -s "$context/user.conf" "$VESTA/data/users/$user/user.conf"
}

vx_cf_migration_context_clear() {
    local artifact=$1 item=$2 context

    [[ "$item" =~ ^[0-9]{6}$ ]] || return 1
    context="$artifact/recovery/$item"
    [[ ! -e "$context" ]] && return 0
    vx_cf_migration_secure_directory "$context" || return 1
    /usr/bin/rm -rf -- "$context"
}

vx_cf_migration_rebuild_one_locked() {
    local user=$1 restart=${2:-yes}

    VX_CLOUDFLARE_INTERNAL_MIGRATION=1 VESTA="$VESTA" \
        "$VESTA/bin/v-rebuild-web-domains" "$user" no >/dev/null 2>&1 \
        || return 1
    [[ "$restart" == no ]] && return 0
    VESTA="$VESTA" "$VESTA/bin/v-restart-web" yes >/dev/null 2>&1 \
        && VESTA="$VESTA" "$VESTA/bin/v-restart-proxy" yes >/dev/null 2>&1
}

vx_cf_migration_verify_restored_item_locked() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5 original
    local component extension path kind value ftp_user expected entry home

    ! vx_cf_metadata_exists "$user" "$target" \
        && ! vx_cf_certificate_metadata_exists "$user" "$target" || return 1
    vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
        "$source" || return 1
    original=$VX_CF_MIGRATION_SOURCE_ROW
    vx_cf_migration_exact_row "$user" "$source" \
        && [[ "$VX_CF_MIGRATION_SOURCE_ROW" == "$original" ]] || return 1
    ! vx_cf_migration_exact_row "$user" "$target" || return 1
    vx_cf_migration_homedir && vx_cf_migration_log_root || return 1
    path="$VX_CF_MIGRATION_HOME/$user/web/$source"
    vx_cf_migration_read_path_fingerprint "$path" || return 1
    vx_cf_migration_filesystem_component "$artifact" "$item" docroot || return 1
    [[ "$VX_CF_MIGRATION_PATH_KIND" == "$VX_CF_MIGRATION_COMPONENT_KIND" \
        && "$VX_CF_MIGRATION_PATH_VALUE" == "$VX_CF_MIGRATION_COMPONENT_VALUE" ]] \
        || return 1
    [[ ! -e "$VX_CF_MIGRATION_HOME/$user/web/$target" \
        && ! -L "$VX_CF_MIGRATION_HOME/$user/web/$target" ]] || return 1
    for extension in log error.log bytes; do
        case "$extension" in
            log) component=log.log ;;
            error.log) component=log.error ;;
            bytes) component=log.bytes ;;
        esac
        path="$VX_CF_MIGRATION_LOG_ROOT/$source.$extension"
        vx_cf_migration_read_path_fingerprint "$path" || return 1
        vx_cf_migration_filesystem_component "$artifact" "$item" "$component" \
            || return 1
        [[ "$VX_CF_MIGRATION_PATH_KIND" == "$VX_CF_MIGRATION_COMPONENT_KIND" \
            && "$VX_CF_MIGRATION_PATH_VALUE" == "$VX_CF_MIGRATION_COMPONENT_VALUE" ]] \
            || return 1
        [[ ! -e "$VX_CF_MIGRATION_LOG_ROOT/$target.$extension" \
            && ! -L "$VX_CF_MIGRATION_LOG_ROOT/$target.$extension" ]] || return 1
    done
    for extension in crt key ca pem; do
        path="$VESTA/data/users/$user/ssl/$source.$extension"
        vx_cf_migration_read_path_fingerprint "$path" || return 1
        vx_cf_migration_filesystem_component "$artifact" "$item" "ssl.$extension" \
            || return 1
        [[ "$VX_CF_MIGRATION_PATH_KIND" == "$VX_CF_MIGRATION_COMPONENT_KIND" \
            && "$VX_CF_MIGRATION_PATH_VALUE" == "$VX_CF_MIGRATION_COMPONENT_VALUE" ]] \
            || return 1
        [[ ! -e "$VESTA/data/users/$user/ssl/$target.$extension" \
            && ! -L "$VESTA/data/users/$user/ssl/$target.$extension" ]] || return 1
    done
    vx_cf_migration_passwd_file || return 1
    while IFS=$'\t' read -r _ component _ expected; do
        [[ "$component" == ftp.* ]] || continue
        ftp_user=${component#ftp.}
        entry=$(/usr/bin/awk -F: -v user="$ftp_user" '$1 == user { print; count++ }
            END { if (count != 1) exit 1 }' "$VX_CF_MIGRATION_PASSWD") || return 1
        home=$(/usr/bin/printf '%s\n' "$entry" | /usr/bin/cut -d: -f6)
        [[ "$home" == "$expected" ]] || return 1
    done < <(/usr/bin/awk -F '\t' -v item="$item" '$1 == item' \
        "$artifact/filesystem.tsv")
}

vx_cf_migration_restore_failed_item_locked() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5 hostnames_digest=$6 address=$7
    local record_id certificate_id

    vx_cf_migration_results_get "$artifact" "$item" || return 1
    record_id=$VX_CF_MIGRATION_ITEM_RECORD_ID
    certificate_id=$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID
    vx_cf_migration_results_set "$artifact" "$item" rolling_back \
        "$record_id" "$certificate_id" "$target" || return 1
    vx_cf_migration_restore_item_locked "$artifact" "$item" "$user" "$source" \
        "$target" "$hostnames_digest" "$address" || return 1
    vx_cf_migration_rebuild_one_locked "$user" no || return 1
    vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
        "$source" || return 1
    vx_cf_migration_cleanup_stale_identity "$user" "$target" \
        "$VX_CF_MIGRATION_SOURCE_ROW" "$source" || return 1
    vx_cf_migration_restore_docroot_metadata "$artifact" "$item" "$user" \
        "$source" || return 1
    vx_cf_migration_context_restore "$artifact" "$item" "$user" || return 1
    VESTA="$VESTA" "$VESTA/bin/v-restart-web" yes >/dev/null 2>&1 \
        && VESTA="$VESTA" "$VESTA/bin/v-restart-proxy" yes >/dev/null 2>&1 \
        || return 1
    vx_cf_migration_verify_restored_item_locked "$artifact" "$item" "$user" \
        "$source" "$target" || return 1
    vx_cf_migration_results_set "$artifact" "$item" rolled_back '' '' "$target" \
        || return 1
    vx_cf_migration_mapping_update "$artifact" "$target" failed restored \
        || return 1
    vx_cf_migration_context_clear "$artifact" "$item"
}

vx_cf_migration_apply_locked() {
    local plan=$1 artifact item user source target hostnames_digest address
    local retain_source_ssl state
    local command_failed=0 item_failed=0

    vx_cf_migration_require_managed_provider || return 15
    artifact="$(vx_cf_migration_root)/$plan"
    vx_cf_migration_artifact_validate "$artifact" \
        && [[ "$VX_CF_MIGRATION_PLAN" == "$plan" ]] || {
            VX_CF_MIGRATION_STATUS=artifact_invalid
            return 12
        }
    [[ "$VX_CF_MIGRATION_RECOVERY_STATUS" != recovery_required ]] || {
        VX_CF_MIGRATION_STATUS=recovery_required
        return 19
    }
    vx_cf_migration_state_counts "$artifact" || return 12
    if (( VX_CF_MIGRATION_COUNT_APPLIED == VX_CF_MIGRATION_PENDING )); then
        vx_cf_migration_applied_matches_locked "$artifact" || {
            VX_CF_MIGRATION_STATUS=recovery_required
            vx_cf_migration_recovery_set "$artifact" recovery_required \
                "$((VX_CF_MIGRATION_FAILED + 1))" || :
            return 19
        }
        VX_CF_MIGRATION_STATUS=applied
        return 0
    fi
    if (( VX_CF_MIGRATION_COUNT_ROLLED_BACK == VX_CF_MIGRATION_PENDING )); then
        vx_cf_migration_live_matches_plan "$artifact" || {
            VX_CF_MIGRATION_STATUS=recovery_required
            return 19
        }
        if [[ "$VX_CF_MIGRATION_RECOVERY_STATUS" == rolled_back ]]; then
            VX_CF_MIGRATION_STATUS=rolled_back
            return 0
        fi
        VX_CF_MIGRATION_STATUS=failed
        return 19
    fi
    (( VX_CF_MIGRATION_COUNT_OTHER == 0 )) || {
            VX_CF_MIGRATION_STATUS=recovery_required
            vx_cf_migration_recovery_set "$artifact" recovery_required \
                "$((VX_CF_MIGRATION_FAILED + 1))" || :
            return 19
        }
    if (( VX_CF_MIGRATION_COUNT_PENDING == VX_CF_MIGRATION_PENDING )); then
        vx_cf_migration_preapply_locked "$artifact" || return 7
    else
        [[ "$(vx_cf_migration_sha256 "$(vx_cf_config_path)")" \
            == "$VX_CF_MIGRATION_CONFIG_SHA" \
            && "$(vx_cf_migration_sha256 "$VESTA/conf/vesta.conf")" \
            == "$VX_CF_MIGRATION_VESTA_SHA" ]] \
            && vx_cf_migration_scope_matches "$artifact" \
            && vx_cf_migration_user_conf_scope_matches "$artifact" \
            && vx_cf_status_locked && [[ "$VX_CF_STATUS" == ready ]] || {
                VX_CF_MIGRATION_STATUS=drift
                return 7
            }
    fi
    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 12
        state=$VX_CF_MIGRATION_ITEM_STATE
        if [[ "$state" == applied ]]; then
            vx_cf_verify_managed_site_locked "$user" "$target" \
                && [[ "$VX_CF_STATUS" == managed ]] || {
                    VX_CF_MIGRATION_STATUS=recovery_required
                    return 19
                }
            vx_cf_migration_verify_source_ssl_forward "$artifact" "$item" \
                "$user" "$source" "$retain_source_ssl" || {
                    VX_CF_MIGRATION_STATUS=recovery_required
                    return 19
                }
            continue
        fi
        [[ "$state" == rolled_back ]] && continue
        [[ "$state" == pending ]] || {
            VX_CF_MIGRATION_STATUS=recovery_required
            return 19
        }
        vx_cf_migration_verify_restored_item_locked "$artifact" "$item" \
            "$user" "$source" "$target" \
            && vx_cf_migration_preflight_locked "$user" "$source" "$target" \
            && [[ "$VX_CF_STATUS" == ready \
                && "$VX_CF_MIGRATION_HOSTNAMES_DIGEST" == "$hostnames_digest" \
                && "$VX_CF_WEB_ADDRESS" == "$address" ]] || {
                    VX_CF_MIGRATION_STATUS=drift
                    return 7
                }
        item_failed=0
        if ! vx_cf_migration_context_snapshot "$artifact" "$item" "$user"; then
            item_failed=1
        elif ! vx_cf_migration_apply_item_locked "$artifact" "$item" "$user" \
            "$source" "$target" "$hostnames_digest" "$address" \
            "$retain_source_ssl"; then
            item_failed=1
        elif ! vx_cf_migration_rebuild_one_locked "$user" no; then
            item_failed=1
        elif ! vx_cf_migration_row_from_file \
            "$artifact/snapshots/users/$user/web.conf" "$source"; then
            item_failed=1
        elif ! vx_cf_migration_cleanup_stale_identity "$user" "$source" \
            "$VX_CF_MIGRATION_SOURCE_ROW" "$target"; then
            item_failed=1
        elif ! vx_cf_migration_restore_docroot_metadata "$artifact" "$item" \
            "$user" "$target"; then
            item_failed=1
        elif ! VESTA="$VESTA" "$VESTA/bin/v-restart-web" yes \
            >/dev/null 2>&1 \
            || ! VESTA="$VESTA" "$VESTA/bin/v-restart-proxy" yes \
            >/dev/null 2>&1; then
            item_failed=1
        elif ! vx_cf_verify_managed_site_locked "$user" "$target" \
            || [[ "$VX_CF_STATUS" != managed ]]; then
            item_failed=1
        elif ! vx_cf_migration_verify_source_ssl_forward "$artifact" "$item" \
            "$user" "$source" "$retain_source_ssl"; then
            item_failed=1
        elif ! vx_cf_migration_verify_applied_native "$artifact" "$user" \
            "$source" "$target"; then
            item_failed=1
        elif ! vx_cf_migration_user_conf_matches_snapshot "$artifact" \
            "$user" yes; then
            item_failed=1
        else
            vx_cf_migration_results_get "$artifact" "$item" || item_failed=1
            if (( item_failed == 0 )); then
                [[ "$VX_CF_MIGRATION_ITEM_STATE" == provisioned ]] \
                    || item_failed=1
            fi
            if (( item_failed == 0 )); then
                vx_cf_migration_results_set "$artifact" "$item" applied \
                    "$VX_CF_MIGRATION_ITEM_RECORD_ID" \
                    "$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID" "$target" \
                    || item_failed=1
            fi
        fi
        if (( item_failed == 0 )); then
            vx_cf_migration_context_clear "$artifact" "$item" || {
                vx_cf_migration_results_get "$artifact" "$item" || :
                vx_cf_migration_results_set "$artifact" "$item" recovery_required \
                    "${VX_CF_MIGRATION_ITEM_RECORD_ID:-}" \
                    "${VX_CF_MIGRATION_ITEM_CERTIFICATE_ID:-}" "$target" || :
                item_failed=1
            }
        fi
        if (( item_failed != 0 )); then
            command_failed=1
            if [[ -d "$artifact/recovery/$item" && ! -L "$artifact/recovery/$item" ]] \
                && vx_cf_migration_restore_failed_item_locked "$artifact" "$item" \
                    "$user" "$source" "$target" "$hostnames_digest" "$address"; then
                vx_cf_migration_recovery_set "$artifact" failed \
                    "$((VX_CF_MIGRATION_FAILED + 1))" || {
                        VX_CF_MIGRATION_STATUS=recovery_required
                        return 19
                    }
            else
                vx_cf_migration_results_get "$artifact" "$item" || :
                vx_cf_migration_results_set "$artifact" "$item" recovery_required \
                    "${VX_CF_MIGRATION_ITEM_RECORD_ID:-}" \
                    "${VX_CF_MIGRATION_ITEM_CERTIFICATE_ID:-}" "$target" || :
                vx_cf_migration_recovery_set "$artifact" recovery_required \
                    "$((VX_CF_MIGRATION_FAILED + 1))" || :
            fi
        fi
    done <"$artifact/plan.tsv"
    vx_cf_migration_state_counts "$artifact" || return 12
    if (( VX_CF_MIGRATION_COUNT_OTHER != 0 )); then
        VX_CF_MIGRATION_STATUS=recovery_required
        return 19
    fi
    if (( command_failed != 0 || VX_CF_MIGRATION_COUNT_ROLLED_BACK != 0 )); then
        VX_CF_MIGRATION_STATUS=failed
        return 19
    fi
    vx_cf_migration_recovery_set "$artifact" clean "$VX_CF_MIGRATION_FAILED" || {
        VX_CF_MIGRATION_STATUS=recovery_required
        return 19
    }
    VX_CF_MIGRATION_STATUS=applied
}

vx_cf_migration_mark_rolled_back() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl

    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        [[ "$VX_CF_MIGRATION_ITEM_STATE" == pending \
            || "$VX_CF_MIGRATION_ITEM_STATE" == rolled_back ]] || return 1
        vx_cf_migration_results_set "$artifact" "$item" rolled_back '' '' \
            "$target" || return 1
        vx_cf_migration_context_clear "$artifact" "$item" || return 1
    done <"$artifact/plan.tsv"
}

vx_cf_migration_cleanup_provider_preflight_locked() {
    vx_cf_load_config || return 1
    vx_cf_zone_preflight || return 1
    [[ "$VX_CF_PREFLIGHT_ZONE_NAME" == "$VX_CF_ZONE_NAME" ]] || {
        VX_CF_STATUS=zone_mismatch
        return 1
    }
    vx_cf_origin_preflight || return 1
}

vx_cf_migration_verify_rollback_ownership_locked() {
    local artifact=$1 item=$2 user=$3 source=$4 target=$5
    local hostnames_digest=$6 address=$7 original target_row expected source_count
    local record_id certificate_id

    vx_cf_migration_row_from_file "$artifact/snapshots/users/$user/web.conf" \
        "$source" || return 1
    original=$VX_CF_MIGRATION_SOURCE_ROW
    vx_cf_migration_target_row "$source" "$target" "$original" || return 1
    target_row=$VX_CF_MIGRATION_TARGET_ROW
    vx_cf_migration_row_replace "$target_row" SSL yes || return 1
    expected=$VX_CF_MIGRATION_ROW
    vx_cf_migration_exact_row "$user" "$target" \
        && [[ "$VX_CF_MIGRATION_SOURCE_ROW" == "$expected" ]] || return 1
    source_count=$(/usr/bin/awk -v domain="$source" '
        index($0, "DOMAIN=\047" domain "\047") == 1 { count++ }
        END { print count + 0 }
    ' "$VESTA/data/users/$user/web.conf") || return 1
    [[ "$source_count" == 0 ]] || return 1

    vx_cf_migration_results_get "$artifact" "$item" || return 1
    record_id=$VX_CF_MIGRATION_ITEM_RECORD_ID
    certificate_id=$VX_CF_MIGRATION_ITEM_CERTIFICATE_ID
    [[ "$record_id" =~ ^[a-f0-9]{32}$ ]] \
        && vx_cf_valid_certificate_id "$certificate_id" || return 1
    vx_cf_managed_domain_matches_zone "$target" "$VX_CF_ZONE_NAME" || return 1

    vx_cf_load_metadata "$user" "$target" || return 1
    [[ "$VX_CF_META_USER" == "$user" \
        && "$VX_CF_META_DOMAIN" == "$target" \
        && "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" \
        && "$VX_CF_META_RECORD_ID" == "$record_id" \
        && "$VX_CF_META_ADDRESS" == "$address" ]] || return 1
    vx_cf_get_record "$record_id" || return 1
    [[ "$VX_CF_RECORD_ID" == "$record_id" \
        && "$VX_CF_RECORD_NAME" == "$target" \
        && "$VX_CF_RECORD_TYPE" == A \
        && "$VX_CF_RECORD_ADDRESS" == "$address" \
        && "$VX_CF_RECORD_TTL" == 1 \
        && "$VX_CF_RECORD_PROXIED" == true ]] || return 1

    vx_cf_collect_certificate_hostnames "$user" "$target" || return 1
    [[ "$VX_CF_CERT_HOSTNAMES_DIGEST" == "$hostnames_digest" ]] || return 1
    vx_cf_load_certificate_metadata "$user" "$target" || return 1
    [[ "$VX_CF_CERT_META_USER" == "$user" \
        && "$VX_CF_CERT_META_DOMAIN" == "$target" \
        && "$VX_CF_CERT_META_ZONE_ID" == "$VX_CF_ZONE_ID" \
        && "$VX_CF_CERT_META_ID" == "$certificate_id" \
        && "$VX_CF_CERT_META_HOSTNAMES" == "$VX_CF_CERT_HOSTNAMES_CSV" \
        && "$VX_CF_CERT_META_DIGEST" == "$hostnames_digest" \
        && -z "$VX_CF_CERT_META_PENDING_IDS" ]] || return 1
    vx_cf_origin_get_certificate "$certificate_id" || return 1
    [[ "$VX_CF_ORIGIN_CERTIFICATE_ID" == "$certificate_id" \
        && "$VX_CF_ORIGIN_HOSTNAMES_DIGEST" == "$hostnames_digest" \
        && "$VX_CF_ORIGIN_REVOKED" == no ]]
}

vx_cf_migration_validate_terminal_items_locked() {
    local artifact=$1 item user source target hostnames_digest address retain_source_ssl state

    while IFS=$'\t' read -r item user source target hostnames_digest address \
        retain_source_ssl; do
        [[ "$item" != ITEM ]] || continue
        vx_cf_migration_results_get "$artifact" "$item" || return 1
        state=$VX_CF_MIGRATION_ITEM_STATE
        if [[ "$state" == applied ]]; then
            vx_cf_migration_verify_rollback_ownership_locked "$artifact" \
                "$item" "$user" "$source" "$target" "$hostnames_digest" \
                "$address" || return 1
        elif [[ "$state" == rolled_back || "$state" == pending ]]; then
            vx_cf_migration_verify_restored_item_locked "$artifact" "$item" \
                "$user" "$source" "$target" || return 1
        elif [[ "$state" == rolling_back ]]; then
            vx_cf_migration_verify_restored_item_locked "$artifact" "$item" \
                "$user" "$source" "$target" \
                || vx_cf_migration_context_validate "$artifact" "$item" \
                || return 1
        elif [[ "$state" =~ ^(renaming|renamed|record_ready|provisioned|recovery_required)$ ]]; then
            vx_cf_migration_context_validate "$artifact" "$item" || return 1
        else
            return 1
        fi
    done <"$artifact/plan.tsv"
}

vx_cf_migration_rollback_locked() {
    local plan=$1 artifact

    vx_cf_migration_require_managed_provider || return 15
    artifact="$(vx_cf_migration_root)/$plan"
    vx_cf_migration_artifact_validate "$artifact" \
        && [[ "$VX_CF_MIGRATION_PLAN" == "$plan" ]] || {
            VX_CF_MIGRATION_STATUS=artifact_invalid
            return 12
        }
    vx_cf_migration_state_counts "$artifact" || return 12
    if (( VX_CF_MIGRATION_COUNT_ROLLED_BACK == VX_CF_MIGRATION_PENDING )); then
        vx_cf_migration_live_matches_plan "$artifact" || {
            VX_CF_MIGRATION_STATUS=recovery_required
            return 19
        }
        VX_CF_MIGRATION_STATUS=rolled_back
        return 0
    fi
    if (( VX_CF_MIGRATION_COUNT_PENDING == VX_CF_MIGRATION_PENDING \
        && VX_CF_MIGRATION_COUNT_OTHER == 0 )) \
        && [[ "$VX_CF_MIGRATION_RECOVERY_STATUS" != recovery_required ]]; then
        vx_cf_migration_live_matches_plan "$artifact" || {
            VX_CF_MIGRATION_STATUS=drift
            return 7
        }
        vx_cf_migration_mark_rolled_back "$artifact" || return 19
        vx_cf_migration_recovery_set "$artifact" rolled_back \
            "$VX_CF_MIGRATION_FAILED" || return 19
        VX_CF_MIGRATION_STATUS=rolled_back
        return 0
    fi
    [[ "$(vx_cf_migration_sha256 "$(vx_cf_config_path)")" \
        == "$VX_CF_MIGRATION_CONFIG_SHA" \
        && "$(vx_cf_migration_sha256 "$VESTA/conf/vesta.conf")" \
        == "$VX_CF_MIGRATION_VESTA_SHA" ]] \
        && vx_cf_migration_scope_matches "$artifact" || {
            VX_CF_MIGRATION_STATUS=drift
            return 7
        }
    vx_cf_migration_user_conf_scope_matches "$artifact" || {
        VX_CF_MIGRATION_STATUS=drift
        return 7
    }
    if ! vx_cf_migration_cleanup_provider_preflight_locked; then
        VX_CF_MIGRATION_STATUS=provider_not_ready
        return 15
    fi
    vx_cf_migration_validate_terminal_items_locked "$artifact" || {
        VX_CF_MIGRATION_STATUS=recovery_required
        vx_cf_migration_recovery_set "$artifact" recovery_required \
            "$((VX_CF_MIGRATION_FAILED + 1))" || :
        return 19
    }
    vx_cf_migration_recovery_set "$artifact" recovery_required \
        "$VX_CF_MIGRATION_FAILED" || {
            VX_CF_MIGRATION_STATUS=recovery_required
            return 19
        }
    if ! vx_cf_migration_restore_all_locked "$artifact"; then
        vx_cf_migration_recovery_set "$artifact" recovery_required \
            "$((VX_CF_MIGRATION_FAILED + 1))" || :
        VX_CF_MIGRATION_STATUS=recovery_required
        return 19
    fi
    vx_cf_migration_mark_rolled_back "$artifact" || {
        vx_cf_migration_recovery_set "$artifact" recovery_required \
            "$((VX_CF_MIGRATION_FAILED + 1))" || :
        VX_CF_MIGRATION_STATUS=recovery_required
        return 19
    }
    vx_cf_migration_recovery_set "$artifact" rolled_back \
        "$VX_CF_MIGRATION_FAILED" || {
            VX_CF_MIGRATION_STATUS=recovery_required
            return 19
        }
    VX_CF_MIGRATION_STATUS=rolled_back
}

vx_cf_migration_run_plan_command() {
    local action=$1 plan=${2:-} format=${3:-human} rc=0 locked_function artifact

    VX_CF_MIGRATION_STATUS=invalid_argument
    VX_CF_MIGRATION_TOTAL=0 VX_CF_MIGRATION_PENDING=0
    VX_CF_MIGRATION_COUNT_PENDING=0 VX_CF_MIGRATION_COUNT_APPLIED=0
    VX_CF_MIGRATION_COUNT_ROLLED_BACK=0 VX_CF_MIGRATION_COUNT_OTHER=0
    vx_cf_migration_require_root || rc=10
    (( rc != 0 )) || vx_cf_migration_valid_plan "$plan" || rc=2
    (( rc != 0 )) || [[ "$format" == human || "$format" == json ]] || rc=2
    case "$action" in
        apply) locked_function=vx_cf_migration_apply_locked ;;
        rollback) locked_function=vx_cf_migration_rollback_locked ;;
        *) rc=2; locked_function='' ;;
    esac
    if (( rc == 10 )); then
        VX_CF_MIGRATION_STATUS=forbidden
    elif (( rc == 0 )); then
        if ! vx_cf_migration_require_managed_provider; then
            rc=15
        elif ! vx_cf_lock_acquire; then
            VX_CF_MIGRATION_STATUS=state_error
            rc=19
        elif "$locked_function" "$plan"; then
            vx_cf_lock_release \
                || { VX_CF_MIGRATION_STATUS=state_error; rc=19; }
        else
            rc=$?
            (( rc != 0 )) || rc=19
            vx_cf_lock_release >/dev/null 2>&1 || :
        fi
    fi
    artifact="$(vx_cf_migration_root)/$plan"
    if [[ -d "$artifact" && ! -L "$artifact" ]] \
        && vx_cf_migration_artifact_validate "$artifact"; then
        vx_cf_migration_state_counts "$artifact" || :
    fi
    vx_cf_migration_emit "$format" "$VX_CF_MIGRATION_STATUS" \
        "${VX_CF_MIGRATION_TOTAL:-0}" "${VX_CF_MIGRATION_COUNT_PENDING:-0}" \
        "${VX_CF_MIGRATION_COUNT_APPLIED:-0}" \
        "${VX_CF_MIGRATION_COUNT_ROLLED_BACK:-0}" \
        "$([[ "$VX_CF_MIGRATION_STATUS" == applied \
            || "$VX_CF_MIGRATION_STATUS" == rolled_back ]] \
            && printf 0 || printf 1)"
    return "$rc"
}

vx_cf_migration_apply() {
    vx_cf_migration_run_plan_command apply "$1" "${2:-human}"
}

vx_cf_migration_rollback() {
    vx_cf_migration_run_plan_command rollback "$1" "${2:-human}"
}
