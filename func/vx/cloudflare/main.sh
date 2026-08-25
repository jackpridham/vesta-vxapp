#!/bin/bash

# Vortex Cloudflare managed-domain authority. Public commands must expose only
# the stable status values emitted by vx_cf_emit_status; provider data stays in
# root-owned files and temporary curl configuration files.

VX_CF_MAX_RESPONSE_BYTES=1048576
VX_CF_CONNECT_TIMEOUT=10
VX_CF_TOTAL_TIMEOUT=30
VX_CF_MAX_ALLOCATE_ATTEMPTS=32

# A caller cannot turn protected shell values into child-process environment
# entries by pre-exporting these names before sourcing the helper.
export -n VX_CF_API_TOKEN VX_CF_ZONE_ID VX_CF_ACCOUNT_EMAIL VX_CF_INPUT_TOKEN \
    VX_CF_INPUT_ZONE_ID VX_CF_INPUT_EMAIL VX_CF_RECORD_ID VX_CF_RECORD_ADDRESS \
    VX_CF_META_ZONE_ID VX_CF_META_RECORD_ID VX_CF_META_ADDRESS \
    VX_CF_WEB_ADDRESS 2>/dev/null || :

vx_cf_root() {
    printf '%s\n' "$VESTA/data/vx/cloudflare"
}

vx_cf_config_path() {
    printf '%s/config.conf\n' "$(vx_cf_root)"
}

vx_cf_records_root() {
    printf '%s/records\n' "$(vx_cf_root)"
}

vx_cf_runtime_root() {
    printf '%s/runtime\n' "$(vx_cf_root)"
}

vx_cf_expected_uid() {
    if (( EUID == 0 )); then
        printf '0\n'
    else
        printf '%s\n' "$EUID"
    fi
}

vx_cf_expected_gid() {
    if (( EUID == 0 )); then
        printf '0\n'
    else
        /usr/bin/id -g
    fi
}

vx_cf_secure_path() {
    local path=$1 mode=$2

    [[ -e "$path" && ! -L "$path" ]] || return 1
    if (( EUID == 0 )); then
        /usr/bin/chown 0:0 "$path" || return 1
    fi
    /usr/bin/chmod "$mode" "$path"
}

vx_cf_secure_regular_file() {
    local path=$1 expected_uid expected_gid details

    [[ -f "$path" && ! -L "$path" ]] || return 1
    expected_uid=$(vx_cf_expected_uid) || return 1
    expected_gid=$(vx_cf_expected_gid) || return 1
    details=$(/usr/bin/stat -c '%u:%g:%a:%h:%F' "$path" 2>/dev/null) || return 1
    [[ "$details" == "$expected_uid:$expected_gid:600:1:regular file" ]]
}

vx_cf_secure_directory() {
    local path=$1 expected_uid expected_gid details

    [[ -d "$path" && ! -L "$path" ]] || return 1
    expected_uid=$(vx_cf_expected_uid) || return 1
    expected_gid=$(vx_cf_expected_gid) || return 1
    details=$(/usr/bin/stat -c '%u:%g:%a:%F' "$path" 2>/dev/null) || return 1
    [[ "$details" == "$expected_uid:$expected_gid:700:directory" ]]
}

vx_cf_prepare_layout() {
    local vx_root root records runtime

    vx_root="$VESTA/data/vx"
    root=$(vx_cf_root)
    records=$(vx_cf_records_root)
    runtime=$(vx_cf_runtime_root)

    [[ ! -L "$VESTA/data" && ! -L "$vx_root" && ! -L "$root" \
        && ! -L "$records" && ! -L "$runtime" ]] || return 1
    /usr/bin/mkdir -p "$vx_root" "$root" "$records" "$runtime" || return 1
    vx_cf_secure_path "$vx_root" 0700 || return 1
    vx_cf_secure_path "$root" 0700 || return 1
    vx_cf_secure_path "$records" 0700 || return 1
    vx_cf_secure_path "$runtime" 0700 || return 1
}

vx_cf_lock_acquire() {
    local lock_path

    if [[ "${VX_CF_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]]; then
        VX_CF_LOCK_DEPTH=$((VX_CF_LOCK_DEPTH + 1))
        return 0
    fi

    vx_cf_prepare_layout || return 1
    lock_path="$(vx_cf_root)/provider.lock"
    [[ ! -L "$lock_path" ]] || return 1
    exec {VX_CF_LOCK_FD}>"$lock_path" || return 1
    vx_cf_secure_path "$lock_path" 0600 || {
        exec {VX_CF_LOCK_FD}>&-
        unset VX_CF_LOCK_FD
        return 1
    }
    /usr/bin/flock -x "$VX_CF_LOCK_FD" || {
        exec {VX_CF_LOCK_FD}>&-
        unset VX_CF_LOCK_FD
        return 1
    }
    VX_CF_LOCK_DEPTH=1
}

vx_cf_lock_release() {
    [[ "${VX_CF_LOCK_DEPTH:-0}" =~ ^[1-9][0-9]*$ ]] || return 1
    if (( VX_CF_LOCK_DEPTH > 1 )); then
        VX_CF_LOCK_DEPTH=$((VX_CF_LOCK_DEPTH - 1))
        return 0
    fi
    /usr/bin/flock -u "$VX_CF_LOCK_FD" || return 1
    exec {VX_CF_LOCK_FD}>&-
    unset VX_CF_LOCK_FD VX_CF_LOCK_DEPTH
}

vx_cf_with_lock() {
    local result

    vx_cf_lock_acquire || {
        VX_CF_STATUS=state_error
        return 1
    }
    "$@"
    result=$?
    vx_cf_lock_release || {
        VX_CF_STATUS=state_error
        return 1
    }
    return "$result"
}

vx_cf_valid_user() {
    [[ "$1" =~ ^[[:alnum:]][-._[:alnum:]]{0,64}$ ]]
}

vx_cf_valid_domain() {
    local name=$1 label

    [[ ${#name} -le 253 && "$name" =~ ^[a-z0-9.-]+$ \
        && "$name" != .* && "$name" != *. && "$name" != *..* ]] || return 1
    local IFS=.
    for label in $name; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
            || return 1
    done
}

vx_cf_valid_ipv4() {
    local address=$1 octet
    local IFS=.
    local -a octets

    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    read -r -a octets <<<"$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ && 10#$octet -le 255 ]] || return 1
    done
}

vx_cf_managed_domain_matches_zone() {
    local domain=$1 zone=$2 label

    [[ "$domain" == *."$zone" ]] || return 1
    label=${domain%."$zone"}
    [[ "$label" =~ ^s-[a-f0-9]{10}$ ]]
}

vx_cf_parse_config_file() {
    local path=$1 line key value
    local token_seen=0 zone_seen=0 email_seen=0 name_seen=0

    VX_CF_API_TOKEN=''
    VX_CF_ZONE_ID=''
    VX_CF_ACCOUNT_EMAIL=''
    VX_CF_ZONE_NAME=''
    vx_cf_secure_regular_file "$path" || {
        VX_CF_STATUS=invalid_config
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=\'([^\']*)\'$ ]] || {
            VX_CF_STATUS=invalid_config
            return 1
        }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            API_TOKEN)
                (( token_seen == 0 )) || { VX_CF_STATUS=invalid_config; return 1; }
                VX_CF_API_TOKEN=$value
                token_seen=1
                ;;
            ZONE_ID)
                (( zone_seen == 0 )) || { VX_CF_STATUS=invalid_config; return 1; }
                VX_CF_ZONE_ID=$value
                zone_seen=1
                ;;
            ACCOUNT_EMAIL)
                (( email_seen == 0 )) || { VX_CF_STATUS=invalid_config; return 1; }
                VX_CF_ACCOUNT_EMAIL=$value
                email_seen=1
                ;;
            ZONE_NAME)
                (( name_seen == 0 )) || { VX_CF_STATUS=invalid_config; return 1; }
                VX_CF_ZONE_NAME=$value
                name_seen=1
                ;;
            *)
                VX_CF_STATUS=invalid_config
                return 1
                ;;
        esac
    done <"$path"

    [[ $token_seen -eq 1 && $zone_seen -eq 1 && $email_seen -eq 1 \
        && $name_seen -eq 1 ]] || { VX_CF_STATUS=invalid_config; return 1; }
    [[ "$VX_CF_API_TOKEN" =~ ^[A-Za-z0-9._-]{20,4096}$ \
        && "$VX_CF_ZONE_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_CF_ACCOUNT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] \
        || { VX_CF_STATUS=invalid_config; return 1; }
    vx_cf_valid_domain "$VX_CF_ZONE_NAME" \
        || { VX_CF_STATUS=invalid_config; return 1; }
}

vx_cf_load_config() {
    local path
    path=$(vx_cf_config_path)
    if [[ ! -e "$path" ]]; then
        VX_CF_STATUS=not_configured
        return 1
    fi
    vx_cf_parse_config_file "$path"
}

vx_cf_parse_input_file() {
    local path=$1 line key value
    local token_seen=0 zone_seen=0 email_seen=0

    VX_CF_INPUT_TOKEN=''
    VX_CF_INPUT_ZONE_ID=''
    VX_CF_INPUT_EMAIL=''
    vx_cf_secure_regular_file "$path" || {
        VX_CF_STATUS=invalid_input
        return 1
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=\'([^\']*)\'$ ]] || {
            VX_CF_STATUS=invalid_input
            return 1
        }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            API_TOKEN)
                (( token_seen == 0 )) || { VX_CF_STATUS=invalid_input; return 1; }
                VX_CF_INPUT_TOKEN=$value
                token_seen=1
                ;;
            ZONE_ID)
                (( zone_seen == 0 )) || { VX_CF_STATUS=invalid_input; return 1; }
                VX_CF_INPUT_ZONE_ID=${value,,}
                zone_seen=1
                ;;
            ACCOUNT_EMAIL)
                (( email_seen == 0 )) || { VX_CF_STATUS=invalid_input; return 1; }
                VX_CF_INPUT_EMAIL=$value
                email_seen=1
                ;;
            *)
                VX_CF_STATUS=invalid_input
                return 1
                ;;
        esac
    done <"$path"

    [[ $token_seen -eq 1 && $zone_seen -eq 1 && $email_seen -eq 1 \
        && "$VX_CF_INPUT_TOKEN" =~ ^[A-Za-z0-9._-]{20,4096}$ \
        && "$VX_CF_INPUT_ZONE_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_CF_INPUT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] \
        || { VX_CF_STATUS=invalid_input; return 1; }
}

vx_cf_curl_binary() {
    if [[ "${VX_CLOUDFLARE_TEST_MODE:-}" == yes \
        && "$VESTA" != /usr/local/vesta \
        && -n "${VX_CLOUDFLARE_TEST_CURL:-}" \
        && -x "$VX_CLOUDFLARE_TEST_CURL" ]]; then
        printf '%s\n' "$VX_CLOUDFLARE_TEST_CURL"
    else
        printf '/usr/bin/curl\n'
    fi
}

vx_cf_transport() {
    local method=$1 api_path=$2 response_path=$3 body_path=${4:-}
    local runtime curl_config status_file curl_binary curl_status result=1 size

    runtime=$(vx_cf_runtime_root)
    vx_cf_secure_directory "$runtime" || { VX_CF_STATUS=state_error; return 1; }
    curl_config=$(/usr/bin/mktemp "$runtime/.curl.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    status_file=$(/usr/bin/mktemp "$runtime/.status.XXXXXX") || {
        /usr/bin/rm -f -- "$curl_config"
        VX_CF_STATUS=state_error
        return 1
    }
    vx_cf_secure_path "$curl_config" 0600 && vx_cf_secure_path "$status_file" 0600 \
        || {
            /usr/bin/rm -f -- "$curl_config" "$status_file"
            VX_CF_STATUS=state_error
            return 1
        }

    {
        printf 'url = "https://api.cloudflare.com/client/v4/zones/%s/%s"\n' \
            "$VX_CF_ZONE_ID" "$api_path"
        printf 'request = "%s"\n' "$method"
        printf 'header = "Authorization: Bearer %s"\n' "$VX_CF_API_TOKEN"
        printf 'header = "Content-Type: application/json"\n'
        if [[ -n "$body_path" ]]; then
            printf 'data-binary = "@%s"\n' "$body_path"
        fi
        printf 'output = "%s"\n' "$response_path"
        printf 'write-out = "%%{http_code}"\n'
        printf 'connect-timeout = %s\n' "$VX_CF_CONNECT_TIMEOUT"
        printf 'max-time = %s\n' "$VX_CF_TOTAL_TIMEOUT"
        printf 'proto = "=https"\n'
        printf 'silent\n'
    } >"$curl_config" || {
        /usr/bin/rm -f -- "$curl_config" "$status_file"
        VX_CF_STATUS=state_error
        return 1
    }

    curl_binary=$(vx_cf_curl_binary)
    /usr/bin/env -i "$curl_binary" --config "$curl_config" \
        >"$status_file" 2>/dev/null
    curl_status=$?
    if [[ $curl_status -eq 28 ]]; then
        VX_CF_STATUS=timeout
    elif [[ $curl_status -ne 0 ]]; then
        VX_CF_STATUS=provider_unavailable
    elif [[ ! -f "$response_path" || -L "$response_path" ]]; then
        VX_CF_STATUS=malformed_response
    else
        size=$(/usr/bin/stat -c '%s' "$response_path" 2>/dev/null) || size=-1
        if (( size < 0 || size > VX_CF_MAX_RESPONSE_BYTES )); then
            VX_CF_STATUS=malformed_response
        else
            curl_status=$(<"$status_file")
            if [[ ! "$curl_status" =~ ^[0-9]{3}$ ]]; then
                VX_CF_STATUS=malformed_response
            else
                VX_CF_HTTP_STATUS=$curl_status
                case "$curl_status" in
                    2??) result=0 ;;
                    401|403) VX_CF_STATUS=unauthorized ;;
                    404) VX_CF_STATUS=not_found ;;
                    429) VX_CF_STATUS=rate_limited ;;
                    *) VX_CF_STATUS=provider_error ;;
                esac
            fi
        fi
    fi

    /usr/bin/rm -f -- "$curl_config" "$status_file"
    return "$result"
}

vx_cf_new_response_file() {
    local path
    path=$(/usr/bin/mktemp "$(vx_cf_runtime_root)/.response.XXXXXX") || return 1
    vx_cf_secure_path "$path" 0600 || { /usr/bin/rm -f -- "$path"; return 1; }
    printf '%s\n' "$path"
}

vx_cf_response_success() {
    local response=$1
    /usr/bin/jq -e 'type == "object" and .success == true' "$response" \
        >/dev/null 2>&1 && return 0
    if /usr/bin/jq -e 'type == "object" and (.errors | type == "array") and
        any(.errors[]?; (.code == 9109 or .code == 10000 or .code == 10001))' \
        "$response" >/dev/null 2>&1; then
        VX_CF_STATUS=unauthorized
    elif /usr/bin/jq -e . "$response" >/dev/null 2>&1; then
        VX_CF_STATUS=provider_error
    else
        VX_CF_STATUS=malformed_response
    fi
    return 1
}

vx_cf_lookup_record() {
    local domain=$1 response count

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_transport GET "dns_records?type=A&name=$domain&per_page=100" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "array"' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    count=$(/usr/bin/jq -r '.result | length' "$response" 2>/dev/null)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        VX_CF_STATUS=malformed_response
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if (( count > 1 )); then
        VX_CF_STATUS=ambiguous_record
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    VX_CF_RECORD_FOUND=no
    VX_CF_RECORD_ID=''
    if (( count == 1 )); then
        VX_CF_RECORD_ID=$(/usr/bin/jq -r '.result[0].id // empty' "$response")
        VX_CF_RECORD_NAME=$(/usr/bin/jq -r '.result[0].name // empty' "$response")
        VX_CF_RECORD_TYPE=$(/usr/bin/jq -r '.result[0].type // empty' "$response")
        VX_CF_RECORD_ADDRESS=$(/usr/bin/jq -r '.result[0].content // empty' "$response")
        VX_CF_RECORD_TTL=$(/usr/bin/jq -r '.result[0].ttl // empty' "$response")
        VX_CF_RECORD_PROXIED=$(/usr/bin/jq -r '.result[0].proxied // empty' "$response")
        if [[ ! "$VX_CF_RECORD_ID" =~ ^[a-f0-9]{32}$ \
            || "$VX_CF_RECORD_NAME" != "$domain" \
            || "$VX_CF_RECORD_TYPE" != A ]] \
            || ! vx_cf_valid_ipv4 "$VX_CF_RECORD_ADDRESS" \
            || [[ ! "$VX_CF_RECORD_TTL" =~ ^[0-9]+$ \
                || "$VX_CF_RECORD_PROXIED" != true && "$VX_CF_RECORD_PROXIED" != false ]]; then
            VX_CF_STATUS=malformed_response
            /usr/bin/rm -f -- "$response"
            return 1
        fi
        VX_CF_RECORD_FOUND=yes
    fi
    /usr/bin/rm -f -- "$response"
}

vx_cf_get_record() {
    local record_id=$1 response

    [[ "$record_id" =~ ^[a-f0-9]{32}$ ]] || { VX_CF_STATUS=state_error; return 1; }
    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_transport GET "dns_records/$record_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "object"' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    VX_CF_RECORD_ID=$(/usr/bin/jq -r '.result.id // empty' "$response")
    VX_CF_RECORD_NAME=$(/usr/bin/jq -r '.result.name // empty' "$response")
    VX_CF_RECORD_TYPE=$(/usr/bin/jq -r '.result.type // empty' "$response")
    VX_CF_RECORD_ADDRESS=$(/usr/bin/jq -r '.result.content // empty' "$response")
    VX_CF_RECORD_TTL=$(/usr/bin/jq -r '.result.ttl // empty' "$response")
    VX_CF_RECORD_PROXIED=$(/usr/bin/jq -r '.result.proxied // empty' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$VX_CF_RECORD_ID" == "$record_id" \
        && "$VX_CF_RECORD_TYPE" == A \
        && "$VX_CF_RECORD_TTL" =~ ^[0-9]+$ \
        && ( "$VX_CF_RECORD_PROXIED" == true || "$VX_CF_RECORD_PROXIED" == false ) ]] \
        && vx_cf_valid_domain "$VX_CF_RECORD_NAME" \
        && vx_cf_valid_ipv4 "$VX_CF_RECORD_ADDRESS" || {
            VX_CF_STATUS=malformed_response
            return 1
        }
}

vx_cf_mutate_record() {
    local method=$1 api_path=$2 domain=$3 address=$4 body response expected_id=${5:-}

    body=$(/usr/bin/mktemp "$(vx_cf_runtime_root)/.body.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    response=$(vx_cf_new_response_file) || {
        /usr/bin/rm -f -- "$body"
        VX_CF_STATUS=state_error
        return 1
    }
    vx_cf_secure_path "$body" 0600 || {
        /usr/bin/rm -f -- "$body" "$response"
        VX_CF_STATUS=state_error
        return 1
    }
    printf '{"type":"A","name":"%s","content":"%s","ttl":1,"proxied":true}\n' \
        "$domain" "$address" >"$body" || {
            /usr/bin/rm -f -- "$body" "$response"
            VX_CF_STATUS=state_error
            return 1
        }
    if ! vx_cf_transport "$method" "$api_path" "$response" "$body"; then
        /usr/bin/rm -f -- "$body" "$response"
        return 1
    fi
    /usr/bin/rm -f -- "$body"
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "object"' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    VX_CF_RECORD_ID=$(/usr/bin/jq -r '.result.id // empty' "$response")
    VX_CF_RECORD_NAME=$(/usr/bin/jq -r '.result.name // empty' "$response")
    VX_CF_RECORD_TYPE=$(/usr/bin/jq -r '.result.type // empty' "$response")
    VX_CF_RECORD_ADDRESS=$(/usr/bin/jq -r '.result.content // empty' "$response")
    VX_CF_RECORD_TTL=$(/usr/bin/jq -r '.result.ttl // empty' "$response")
    VX_CF_RECORD_PROXIED=$(/usr/bin/jq -r '.result.proxied // empty' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$VX_CF_RECORD_ID" =~ ^[a-f0-9]{32}$ \
        && ( -z "$expected_id" || "$VX_CF_RECORD_ID" == "$expected_id" ) \
        && "$VX_CF_RECORD_NAME" == "$domain" \
        && "$VX_CF_RECORD_TYPE" == A \
        && "$VX_CF_RECORD_ADDRESS" == "$address" \
        && "$VX_CF_RECORD_TTL" == 1 \
        && "$VX_CF_RECORD_PROXIED" == true ]] || {
            VX_CF_STATUS=malformed_response
            return 1
        }
}

vx_cf_delete_record_id() {
    local record_id=$1 response returned_id

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_transport DELETE "dns_records/$record_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    returned_id=$(/usr/bin/jq -r '.result.id // empty' "$response" 2>/dev/null)
    /usr/bin/rm -f -- "$response"
    [[ "$returned_id" == "$record_id" ]] || {
        VX_CF_STATUS=malformed_response
        return 1
    }
}

vx_cf_record_path() {
    local user=$1 domain=$2
    printf '%s/%s/%s.conf\n' "$(vx_cf_records_root)" "$user" "$domain"
}

vx_cf_metadata_exists() {
    local user=$1 domain=$2
    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" || return 1
    [[ -f "$(vx_cf_record_path "$user" "$domain")" \
        && ! -L "$(vx_cf_record_path "$user" "$domain")" ]]
}

vx_cf_write_metadata() {
    local user=$1 domain=$2 record_id=$3 address=$4 parent target temporary

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" \
        && [[ "$record_id" =~ ^[a-f0-9]{32}$ ]] \
        && vx_cf_valid_ipv4 "$address" || { VX_CF_STATUS=state_error; return 1; }
    parent="$(vx_cf_records_root)/$user"
    target=$(vx_cf_record_path "$user" "$domain")
    [[ ! -L "$parent" && ! -L "$target" ]] || { VX_CF_STATUS=state_error; return 1; }
    /usr/bin/mkdir -p "$parent" || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$parent" 0700 || { VX_CF_STATUS=state_error; return 1; }
    temporary=$(/usr/bin/mktemp "$parent/.record.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$temporary" 0600 || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    {
        printf "SCHEMA='1'\n"
        printf "USER='%s'\n" "$user"
        printf "DOMAIN='%s'\n" "$domain"
        printf "ZONE_ID='%s'\n" "$VX_CF_ZONE_ID"
        printf "RECORD_ID='%s'\n" "$record_id"
        printf "ADDRESS='%s'\n" "$address"
    } >"$temporary" || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    /usr/bin/mv -fT -- "$temporary" "$target" || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
}

vx_cf_load_metadata() {
    local user=$1 domain=$2 path line key value
    local schema_seen=0 user_seen=0 domain_seen=0 zone_seen=0 id_seen=0 address_seen=0

    path=$(vx_cf_record_path "$user" "$domain")
    vx_cf_secure_regular_file "$path" || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_META_SCHEMA=''
    VX_CF_META_USER=''
    VX_CF_META_DOMAIN=''
    VX_CF_META_ZONE_ID=''
    VX_CF_META_RECORD_ID=''
    VX_CF_META_ADDRESS=''
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=\'([^\']*)\'$ ]] \
            || { VX_CF_STATUS=state_error; return 1; }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            SCHEMA) (( schema_seen++ == 0 )) || return 1; VX_CF_META_SCHEMA=$value ;;
            USER) (( user_seen++ == 0 )) || return 1; VX_CF_META_USER=$value ;;
            DOMAIN) (( domain_seen++ == 0 )) || return 1; VX_CF_META_DOMAIN=$value ;;
            ZONE_ID) (( zone_seen++ == 0 )) || return 1; VX_CF_META_ZONE_ID=$value ;;
            RECORD_ID) (( id_seen++ == 0 )) || return 1; VX_CF_META_RECORD_ID=$value ;;
            ADDRESS) (( address_seen++ == 0 )) || return 1; VX_CF_META_ADDRESS=$value ;;
            *) VX_CF_STATUS=state_error; return 1 ;;
        esac
    done <"$path"
    [[ "$VX_CF_META_SCHEMA" == 1 && "$VX_CF_META_USER" == "$user" \
        && "$VX_CF_META_DOMAIN" == "$domain" \
        && "$VX_CF_META_ZONE_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_CF_META_RECORD_ID" =~ ^[a-f0-9]{32}$ ]] \
        && vx_cf_valid_ipv4 "$VX_CF_META_ADDRESS" || {
            VX_CF_STATUS=state_error
            return 1
        }
}

vx_cf_remove_metadata() {
    local user=$1 domain=$2 target
    target=$(vx_cf_record_path "$user" "$domain")
    [[ -f "$target" && ! -L "$target" ]] || { VX_CF_STATUS=state_error; return 1; }
    /usr/bin/rm -f -- "$target"
}

vx_cf_provider_mode() {
    local config="$VESTA/conf/vesta.conf" line
    VX_CF_PROVIDER_MODE=local
    [[ -f "$config" && ! -L "$config" ]] || return 1
    line=$(/usr/bin/grep -m1 "^VX_MANAGED_DNS_PROVIDER='" "$config" 2>/dev/null || :)
    if [[ -n "$line" ]]; then
        [[ "$line" =~ ^VX_MANAGED_DNS_PROVIDER=\'(local|cloudflare-managed)\'$ ]] || return 1
        VX_CF_PROVIDER_MODE=${BASH_REMATCH[1]}
    fi
}

vx_cf_zone_preflight() {
    local response result_id result_name

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_transport GET '' "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "object"' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    result_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    result_name=$(/usr/bin/jq -r '.result.name // empty' "$response")
    /usr/bin/rm -f -- "$response"
    result_name=${result_name,,}
    [[ "$result_id" == "$VX_CF_ZONE_ID" ]] \
        && vx_cf_valid_domain "$result_name" || {
            VX_CF_STATUS=malformed_response
            return 1
        }
    VX_CF_PREFLIGHT_ZONE_NAME=$result_name
}

vx_cf_configure_locked() {
    local input=$1 target temporary old_token old_zone old_email old_name

    vx_cf_parse_input_file "$input" || return 1
    old_token=${VX_CF_API_TOKEN:-}
    old_zone=${VX_CF_ZONE_ID:-}
    old_email=${VX_CF_ACCOUNT_EMAIL:-}
    old_name=${VX_CF_ZONE_NAME:-}
    VX_CF_API_TOKEN=$VX_CF_INPUT_TOKEN
    VX_CF_ZONE_ID=$VX_CF_INPUT_ZONE_ID
    VX_CF_ACCOUNT_EMAIL=$VX_CF_INPUT_EMAIL
    VX_CF_ZONE_NAME=''
    if ! vx_cf_zone_preflight; then
        VX_CF_API_TOKEN=$old_token
        VX_CF_ZONE_ID=$old_zone
        VX_CF_ACCOUNT_EMAIL=$old_email
        VX_CF_ZONE_NAME=$old_name
        return 1
    fi
    VX_CF_ZONE_NAME=$VX_CF_PREFLIGHT_ZONE_NAME

    target=$(vx_cf_config_path)
    [[ ! -L "$target" ]] || { VX_CF_STATUS=state_error; return 1; }
    temporary=$(/usr/bin/mktemp "$(vx_cf_root)/.config.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$temporary" 0600 || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    {
        printf "API_TOKEN='%s'\n" "$VX_CF_API_TOKEN"
        printf "ZONE_ID='%s'\n" "$VX_CF_ZONE_ID"
        printf "ACCOUNT_EMAIL='%s'\n" "$VX_CF_ACCOUNT_EMAIL"
        printf "ZONE_NAME='%s'\n" "$VX_CF_ZONE_NAME"
    } >"$temporary" || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    /usr/bin/mv -fT -- "$temporary" "$target" || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    VX_CF_STATUS=ready
}

vx_cf_configure_from_file() {
    vx_cf_with_lock vx_cf_configure_locked "$1"
}

vx_cf_status_locked() {
    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_load_config || return 1
    vx_cf_zone_preflight || return 1
    [[ "$VX_CF_PREFLIGHT_ZONE_NAME" == "$VX_CF_ZONE_NAME" ]] || {
        VX_CF_STATUS=zone_mismatch
        return 1
    }
    VX_CF_STATUS=ready
}

vx_cf_status() {
    vx_cf_with_lock vx_cf_status_locked
}

vx_cf_emit_status() {
    local status=$1 format=${2:-human}
    [[ "$status" =~ ^[a-z_]+$ ]] || status=state_error
    if [[ "$format" == json ]]; then
        printf '{"status":"%s"}\n' "$status"
    else
        printf '%s\n' "$status"
    fi
}

vx_cf_exact_web_row() {
    local user=$1 domain=$2 web_conf row_count

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    web_conf="$VESTA/data/users/$user/web.conf"
    [[ -f "$web_conf" && ! -L "$web_conf" ]] \
        || { VX_CF_STATUS=web_domain_not_found; return 1; }
    mapfile -t VX_CF_WEB_ROWS < <(/usr/bin/grep -F "DOMAIN='$domain'" "$web_conf" 2>/dev/null || :)
    row_count=${#VX_CF_WEB_ROWS[@]}
    [[ $row_count -eq 1 && "${VX_CF_WEB_ROWS[0]}" == DOMAIN="'$domain'"* ]] || {
        VX_CF_STATUS=web_domain_not_found
        return 1
    }
    VX_CF_WEB_ROW=${VX_CF_WEB_ROWS[0]}
}

vx_cf_web_address() {
    local user=$1 domain=$2 row ip_file ip_value nat_value matches

    vx_cf_exact_web_row "$user" "$domain" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])IP=\'([^\']+)\'([[:space:]]|$) ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    ip_value=${BASH_REMATCH[2]}
    if [[ -f "$VESTA/data/ips/$ip_value" && ! -L "$VESTA/data/ips/$ip_value" ]]; then
        ip_file="$VESTA/data/ips/$ip_value"
        nat_value=$(/usr/bin/sed -n "s/^NAT='\([^']*\)'.*/\1/p" "$ip_file")
        [[ -n "$nat_value" ]] && VX_CF_WEB_ADDRESS=$nat_value || VX_CF_WEB_ADDRESS=$ip_value
    else
        mapfile -t matches < <(/usr/bin/grep -lF "NAT='$ip_value'" "$VESTA/data/ips/"* 2>/dev/null || :)
        [[ ${#matches[@]} -eq 1 && -f "${matches[0]}" && ! -L "${matches[0]}" ]] \
            || { VX_CF_STATUS=state_error; return 1; }
        VX_CF_WEB_ADDRESS=$ip_value
    fi
    vx_cf_valid_ipv4 "$VX_CF_WEB_ADDRESS" || { VX_CF_STATUS=state_error; return 1; }
}

vx_cf_compensate_created_record_locked() {
    local domain=$1 address=$2 record_id=$3

    # Metadata could not become deletion authority, so compensate from the
    # exact provider identity still held by this locked create transaction.
    if ! vx_cf_get_record "$record_id"; then
        [[ "$VX_CF_STATUS" == not_found ]]
        return
    fi
    [[ "$VX_CF_RECORD_ID" == "$record_id" \
        && "$VX_CF_RECORD_NAME" == "$domain" \
        && "$VX_CF_RECORD_TYPE" == A \
        && "$VX_CF_RECORD_ADDRESS" == "$address" ]] || {
            VX_CF_STATUS=ownership_mismatch
            return 1
        }
    vx_cf_delete_record_id "$record_id" || return 1
    if vx_cf_get_record "$record_id"; then
        VX_CF_STATUS=delete_not_confirmed
        return 1
    fi
    [[ "$VX_CF_STATUS" == not_found ]]
}

vx_cf_reconcile_locked() {
    local user=$1 domain=$2 address action record_id original_status compensation_status

    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    vx_cf_managed_domain_matches_zone "$domain" "$VX_CF_ZONE_NAME" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_web_address "$user" "$domain" || return 1
    address=$VX_CF_WEB_ADDRESS
    vx_cf_lookup_record "$domain" || return 1

    if vx_cf_metadata_exists "$user" "$domain"; then
        vx_cf_load_metadata "$user" "$domain" || return 1
        [[ "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
            || { VX_CF_STATUS=ownership_mismatch; return 1; }
        if [[ "$VX_CF_RECORD_FOUND" == yes \
            && "$VX_CF_RECORD_ID" != "$VX_CF_META_RECORD_ID" ]]; then
            VX_CF_STATUS=ownership_mismatch
            return 1
        fi
    elif [[ "$VX_CF_RECORD_FOUND" == yes ]]; then
        # A name match is not ownership. Only metadata created by a successful
        # managed lifecycle may authorize update or deletion of an existing ID.
        VX_CF_STATUS=ownership_mismatch
        return 1
    fi

    if [[ "$VX_CF_RECORD_FOUND" == no ]]; then
        vx_cf_mutate_record POST dns_records "$domain" "$address" || return 1
        action=created
    else
        record_id=$VX_CF_RECORD_ID
        if [[ "$VX_CF_RECORD_ADDRESS" == "$address" \
            && "$VX_CF_RECORD_TTL" == 1 \
            && "$VX_CF_RECORD_PROXIED" == true ]]; then
            action=unchanged
        else
            vx_cf_mutate_record PUT "dns_records/$record_id" "$domain" "$address" "$record_id" \
                || return 1
            action=updated
        fi
    fi
    record_id=$VX_CF_RECORD_ID
    # Persist the exact provider identity before readback so a failed managed
    # create remains recoverable by the exact cleanup path.
    if ! vx_cf_write_metadata "$user" "$domain" "$record_id" "$address"; then
        original_status=${VX_CF_STATUS:-state_error}
        if [[ "$action" == created ]] \
            && ! vx_cf_compensate_created_record_locked \
                "$domain" "$address" "$record_id"; then
            compensation_status=${VX_CF_STATUS:-provider_error}
            # Preserve deletion authority for the caller's normal cleanup if
            # the direct provider compensation could not finish.
            vx_cf_write_metadata "$user" "$domain" "$record_id" "$address" \
                >/dev/null 2>&1 || :
            VX_CF_STATUS=$compensation_status
            return 1
        fi
        VX_CF_STATUS=$original_status
        return 1
    fi
    vx_cf_get_record "$record_id" || return 1
    [[ "$VX_CF_RECORD_NAME" == "$domain" \
        && "$VX_CF_RECORD_ADDRESS" == "$address" \
        && "$VX_CF_RECORD_TTL" == 1 \
        && "$VX_CF_RECORD_PROXIED" == true ]] || {
            VX_CF_STATUS=readback_mismatch
            return 1
        }
    VX_CF_STATUS=$action
}

vx_cf_reconcile() {
    vx_cf_with_lock vx_cf_reconcile_locked "$1" "$2"
}

vx_cf_cleanup_locked() {
    local user=$1 domain=$2 record_id

    if ! vx_cf_metadata_exists "$user" "$domain"; then
        VX_CF_STATUS=unchanged
        return 0
    fi
    vx_cf_load_metadata "$user" "$domain" || return 1
    vx_cf_load_config || return 1
    [[ "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" \
        && "$VX_CF_META_DOMAIN" == "$domain" ]] || {
            VX_CF_STATUS=ownership_mismatch
            return 1
        }
    record_id=$VX_CF_META_RECORD_ID
    if ! vx_cf_get_record "$record_id"; then
        if [[ "$VX_CF_STATUS" == not_found ]]; then
            vx_cf_remove_metadata "$user" "$domain" || return 1
            VX_CF_STATUS=deleted
            return 0
        fi
        return 1
    fi
    [[ "$VX_CF_RECORD_ID" == "$record_id" \
        && "$VX_CF_RECORD_NAME" == "$domain" \
        && "$VX_CF_RECORD_TYPE" == A ]] || {
            VX_CF_STATUS=ownership_mismatch
            return 1
        }
    vx_cf_delete_record_id "$record_id" || return 1
    if vx_cf_get_record "$record_id"; then
        VX_CF_STATUS=delete_not_confirmed
        return 1
    elif [[ "$VX_CF_STATUS" != not_found ]]; then
        return 1
    fi
    vx_cf_remove_metadata "$user" "$domain" || return 1
    VX_CF_STATUS=deleted
}

vx_cf_cleanup() {
    vx_cf_with_lock vx_cf_cleanup_locked "$1" "$2"
}

vx_cf_generated_label() {
    local value
    value=$(/usr/bin/od -An -N5 -tx1 /dev/urandom 2>/dev/null) || return 1
    value=${value//[[:space:]]/}
    [[ "$value" =~ ^[a-f0-9]{10}$ ]] || return 1
    printf 's-%s\n' "$value"
}

vx_cf_local_domain_exists() {
    local domain=$1
    /usr/bin/grep -Fq "DOMAIN='$domain'" "$VESTA/data/users/"*/web.conf 2>/dev/null \
        || /usr/bin/grep -Eq "ALIAS='([^']*,)?${domain//./\\.}(,|')" \
            "$VESTA/data/users/"*/web.conf 2>/dev/null
}

vx_cf_allocate_domain_locked() {
    local attempt label candidate

    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    for ((attempt=1; attempt <= VX_CF_MAX_ALLOCATE_ATTEMPTS; attempt++)); do
        label=$(vx_cf_generated_label) || { VX_CF_STATUS=state_error; return 1; }
        candidate="$label.$VX_CF_ZONE_NAME"
        vx_cf_local_domain_exists "$candidate" && continue
        vx_cf_lookup_record "$candidate" || return 1
        [[ "$VX_CF_RECORD_FOUND" == yes ]] && continue
        VX_CF_ALLOCATED_DOMAIN=$candidate
        VX_CF_STATUS=allocated
        return 0
    done
    VX_CF_STATUS=collision_limit
    return 1
}

vx_cf_change_provider_locked() {
    local provider=$1 target="$VESTA/conf/vesta.conf" temporary

    [[ "$provider" == local || "$provider" == cloudflare-managed ]] \
        || { VX_CF_STATUS=invalid_provider; return 1; }
    [[ -f "$target" && ! -L "$target" ]] || { VX_CF_STATUS=state_error; return 1; }
    if [[ "$provider" == cloudflare-managed ]]; then
        vx_cf_load_config || return 1
        vx_cf_zone_preflight || return 1
        [[ "$VX_CF_PREFLIGHT_ZONE_NAME" == "$VX_CF_ZONE_NAME" ]] \
            || { VX_CF_STATUS=zone_mismatch; return 1; }
    fi
    temporary=$(/usr/bin/mktemp "$VESTA/conf/.vesta.conf.cloudflare.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    /usr/bin/awk -v replacement="VX_MANAGED_DNS_PROVIDER='$provider'" '
        index($0, "VX_MANAGED_DNS_PROVIDER=") == 1 {
            if (!found) print replacement
            found=1
            next
        }
        { print }
        END { if (!found) print replacement }
    ' "$target" >"$temporary" || {
        /usr/bin/rm -f -- "$temporary"
        VX_CF_STATUS=state_error
        return 1
    }
    if (( EUID == 0 )); then
        /usr/bin/chown --reference="$target" "$temporary" || {
            /usr/bin/rm -f -- "$temporary"
            VX_CF_STATUS=state_error
            return 1
        }
    fi
    /usr/bin/chmod --reference="$target" "$temporary" \
        && /usr/bin/mv -fT -- "$temporary" "$target" || {
            /usr/bin/rm -f -- "$temporary"
            VX_CF_STATUS=state_error
            return 1
        }
    VX_CF_STATUS=changed
}

vx_cf_change_provider() {
    vx_cf_with_lock vx_cf_change_provider_locked "$1"
}
