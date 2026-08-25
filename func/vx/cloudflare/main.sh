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

vx_cf_certificates_root() {
    printf '%s/certificates\n' "$(vx_cf_root)"
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
    local vx_root root records certificates runtime

    vx_root="$VESTA/data/vx"
    root=$(vx_cf_root)
    records=$(vx_cf_records_root)
    certificates=$(vx_cf_certificates_root)
    runtime=$(vx_cf_runtime_root)

    [[ ! -L "$VESTA/data" && ! -L "$vx_root" && ! -L "$root" \
        && ! -L "$records" && ! -L "$certificates" && ! -L "$runtime" ]] \
        || return 1
    /usr/bin/mkdir -p "$vx_root" "$root" "$records" "$certificates" \
        "$runtime" || return 1
    vx_cf_secure_path "$vx_root" 0700 || return 1
    vx_cf_secure_path "$root" 0700 || return 1
    vx_cf_secure_path "$records" 0700 || return 1
    vx_cf_secure_path "$certificates" 0700 || return 1
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

vx_cf_transport_url() {
    local method=$1 url=$2 response_path=$3 body_path=${4:-}
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
        printf 'url = "%s"\n' "$url"
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

vx_cf_transport() {
    local method=$1 api_path=$2 response_path=$3 body_path=${4:-}

    vx_cf_transport_url "$method" \
        "https://api.cloudflare.com/client/v4/zones/$VX_CF_ZONE_ID/$api_path" \
        "$response_path" "$body_path"
}

vx_cf_origin_transport() {
    local method=$1 api_path=$2 response_path=$3 body_path=${4:-}

    vx_cf_transport_url "$method" \
        "https://api.cloudflare.com/client/v4/certificates$api_path" \
        "$response_path" "$body_path"
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
    vx_cf_origin_preflight || {
        VX_CF_API_TOKEN=$old_token
        VX_CF_ZONE_ID=$old_zone
        VX_CF_ACCOUNT_EMAIL=$old_email
        VX_CF_ZONE_NAME=$old_name
        return 1
    }

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

vx_cf_certificate_path() {
    local user=$1 domain=$2
    printf '%s/%s/%s.conf\n' "$(vx_cf_certificates_root)" "$user" "$domain"
}

vx_cf_certificate_metadata_exists() {
    local user=$1 domain=$2 path

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" || return 1
    path=$(vx_cf_certificate_path "$user" "$domain")
    [[ -f "$path" && ! -L "$path" ]]
}

vx_cf_valid_certificate_id() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

vx_cf_valid_certificate_hostname() {
    local hostname=$1 suffix

    if [[ "$hostname" == \*.* ]]; then
        suffix=${hostname#*.}
        [[ "$suffix" == *.* ]] && vx_cf_valid_domain "$suffix"
    else
        vx_cf_valid_domain "$hostname"
    fi
}

vx_cf_hostname_digest() {
    /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1
}

vx_cf_collect_certificate_hostnames() {
    local user=$1 domain=$2 row aliases hostname
    local -a names=()

    vx_cf_exact_web_row "$user" "$domain" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])ALIAS=\'([^\']*)\'([[:space:]]|$) ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    aliases=${BASH_REMATCH[2]}
    names+=("$domain")
    if [[ -n "$aliases" ]]; then
        local IFS=,
        read -r -a VX_CF_ALIAS_NAMES <<<"$aliases"
        names+=("${VX_CF_ALIAS_NAMES[@]}")
    fi
    mapfile -t VX_CF_CERT_HOSTNAMES < <(
        printf '%s\n' "${names[@]}" | /usr/bin/tr '[:upper:]' '[:lower:]' \
            | LC_ALL=C /usr/bin/sort -u
    )
    (( ${#VX_CF_CERT_HOSTNAMES[@]} >= 1 \
        && ${#VX_CF_CERT_HOSTNAMES[@]} <= 200 )) \
        || { VX_CF_STATUS=invalid_alias; return 1; }
    for hostname in "${VX_CF_CERT_HOSTNAMES[@]}"; do
        vx_cf_valid_certificate_hostname "$hostname" \
            || { VX_CF_STATUS=invalid_alias; return 1; }
    done
    VX_CF_CERT_HOSTNAMES_CSV=$(IFS=,; printf '%s' "${VX_CF_CERT_HOSTNAMES[*]}")
    VX_CF_CERT_HOSTNAMES_DIGEST=$(printf '%s\n' "${VX_CF_CERT_HOSTNAMES[@]}" \
        | vx_cf_hostname_digest) || { VX_CF_STATUS=state_error; return 1; }
}

vx_cf_write_certificate_metadata() {
    local user=$1 domain=$2 certificate_id=$3 hostnames=$4 digest=$5
    local parent target temporary

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" \
        && vx_cf_valid_certificate_id "$certificate_id" \
        && [[ "$digest" =~ ^[a-f0-9]{64}$ && "$hostnames" =~ ^[a-z0-9*.,-]+$ ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    parent="$(vx_cf_certificates_root)/$user"
    target=$(vx_cf_certificate_path "$user" "$domain")
    [[ ! -L "$parent" && ! -L "$target" ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    /usr/bin/mkdir -p "$parent" || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$parent" 0700 || { VX_CF_STATUS=state_error; return 1; }
    temporary=$(/usr/bin/mktemp "$parent/.certificate.XXXXXX") \
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
        printf "CERTIFICATE_ID='%s'\n" "$certificate_id"
        printf "HOSTNAMES='%s'\n" "$hostnames"
        printf "HOSTNAMES_DIGEST='%s'\n" "$digest"
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

vx_cf_load_certificate_metadata() {
    local user=$1 domain=$2 path line key value hostname computed_digest
    local schema_seen=0 user_seen=0 domain_seen=0 zone_seen=0 id_seen=0
    local hostnames_seen=0 digest_seen=0

    path=$(vx_cf_certificate_path "$user" "$domain")
    vx_cf_secure_regular_file "$path" || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_CERT_META_SCHEMA=''
    VX_CF_CERT_META_USER=''
    VX_CF_CERT_META_DOMAIN=''
    VX_CF_CERT_META_ZONE_ID=''
    VX_CF_CERT_META_ID=''
    VX_CF_CERT_META_HOSTNAMES=''
    VX_CF_CERT_META_DIGEST=''
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z_]+)=\'([^\']*)\'$ ]] \
            || { VX_CF_STATUS=state_error; return 1; }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            SCHEMA) (( schema_seen++ == 0 )) || return 1; VX_CF_CERT_META_SCHEMA=$value ;;
            USER) (( user_seen++ == 0 )) || return 1; VX_CF_CERT_META_USER=$value ;;
            DOMAIN) (( domain_seen++ == 0 )) || return 1; VX_CF_CERT_META_DOMAIN=$value ;;
            ZONE_ID) (( zone_seen++ == 0 )) || return 1; VX_CF_CERT_META_ZONE_ID=$value ;;
            CERTIFICATE_ID) (( id_seen++ == 0 )) || return 1; VX_CF_CERT_META_ID=$value ;;
            HOSTNAMES) (( hostnames_seen++ == 0 )) || return 1; VX_CF_CERT_META_HOSTNAMES=$value ;;
            HOSTNAMES_DIGEST) (( digest_seen++ == 0 )) || return 1; VX_CF_CERT_META_DIGEST=$value ;;
            *) VX_CF_STATUS=state_error; return 1 ;;
        esac
    done <"$path"
    [[ "$VX_CF_CERT_META_SCHEMA" == 1 \
        && "$VX_CF_CERT_META_USER" == "$user" \
        && "$VX_CF_CERT_META_DOMAIN" == "$domain" \
        && "$VX_CF_CERT_META_ZONE_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_CF_CERT_META_DIGEST" =~ ^[a-f0-9]{64}$ ]] \
        && vx_cf_valid_certificate_id "$VX_CF_CERT_META_ID" \
        || { VX_CF_STATUS=state_error; return 1; }
    local IFS=,
    read -r -a VX_CF_CERT_META_NAMES <<<"$VX_CF_CERT_META_HOSTNAMES"
    (( ${#VX_CF_CERT_META_NAMES[@]} >= 1 \
        && ${#VX_CF_CERT_META_NAMES[@]} <= 200 )) \
        || { VX_CF_STATUS=state_error; return 1; }
    for hostname in "${VX_CF_CERT_META_NAMES[@]}"; do
        vx_cf_valid_certificate_hostname "$hostname" \
            || { VX_CF_STATUS=state_error; return 1; }
    done
    computed_digest=$(printf '%s\n' "${VX_CF_CERT_META_NAMES[@]}" \
        | LC_ALL=C /usr/bin/sort -u | vx_cf_hostname_digest) \
        || { VX_CF_STATUS=state_error; return 1; }
    [[ "$computed_digest" == "$VX_CF_CERT_META_DIGEST" ]] \
        || { VX_CF_STATUS=state_error; return 1; }
}

vx_cf_remove_certificate_metadata() {
    local user=$1 domain=$2 target

    target=$(vx_cf_certificate_path "$user" "$domain")
    [[ -f "$target" && ! -L "$target" ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    /usr/bin/rm -f -- "$target"
}

vx_cf_origin_ca_path() {
    if [[ "${VX_CLOUDFLARE_TEST_MODE:-}" == yes \
        && "$VESTA" != /usr/local/vesta \
        && -f "$(vx_cf_root)/stub-origin-ca.pem" ]]; then
        printf '%s/stub-origin-ca.pem\n' "$(vx_cf_root)"
    else
        printf '%s/func/vx/cloudflare/origin-ca-rsa.pem\n' "$VESTA"
    fi
}

vx_cf_origin_preflight() {
    local response

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_origin_transport GET "?zone_id=$VX_CF_ZONE_ID&per_page=1" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "array"' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    /usr/bin/rm -f -- "$response"
}

vx_cf_origin_get_certificate() {
    local certificate_id=$1 response returned_id returned_hostnames hostname digest

    vx_cf_valid_certificate_id "$certificate_id" \
        || { VX_CF_STATUS=state_error; return 1; }
    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_origin_transport GET "/$certificate_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '(.result | type == "object") and
            (.result.hostnames | type == "array")' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    returned_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    mapfile -t returned_hostnames < <(/usr/bin/jq -r '.result.hostnames[]' "$response" \
        | LC_ALL=C /usr/bin/sort -u)
    /usr/bin/rm -f -- "$response"
    [[ "$returned_id" == "$certificate_id" \
        && ${#returned_hostnames[@]} -ge 1 && ${#returned_hostnames[@]} -le 200 ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    for hostname in "${returned_hostnames[@]}"; do
        vx_cf_valid_certificate_hostname "$hostname" \
            || { VX_CF_STATUS=malformed_response; return 1; }
    done
    digest=$(printf '%s\n' "${returned_hostnames[@]}" | vx_cf_hostname_digest) \
        || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_ORIGIN_CERTIFICATE_ID=$returned_id
    VX_CF_ORIGIN_HOSTNAMES_DIGEST=$digest
}

vx_cf_origin_revoke_certificate() {
    local certificate_id=$1 response returned_id revoked_at

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_origin_transport DELETE "/$certificate_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    returned_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    revoked_at=$(/usr/bin/jq -r '.result.revoked_at // empty' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$returned_id" == "$certificate_id" \
        && "$revoked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    VX_CF_ORIGIN_REVOKED_AT=$revoked_at
}

vx_cf_origin_compensate_new_certificate() {
    local certificate_id=$1 status=$2

    vx_cf_origin_revoke_certificate "$certificate_id" >/dev/null 2>&1 || :
    VX_CF_STATUS=$status
    return 1
}

vx_cf_origin_create_certificate() {
    local domain=$1 stage=$2 key csr crt ca body response san hostname
    local certificate_id expected_names actual_names cert_key_digest private_key_digest

    key="$stage/$domain.key"
    csr="$stage/$domain.csr"
    crt="$stage/$domain.crt"
    ca="$stage/$domain.ca"
    body="$stage/request.json"
    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    san=''
    for hostname in "${VX_CF_CERT_HOSTNAMES[@]}"; do
        [[ -z "$san" ]] || san+=,
        san+="DNS:$hostname"
    done
    /usr/bin/openssl req -new -newkey rsa:2048 -nodes -sha256 \
        -subj "/CN=$domain" -addext "subjectAltName=$san" \
        -keyout "$key" -out "$csr" >/dev/null 2>&1 \
        || { /usr/bin/rm -f -- "$response"; VX_CF_STATUS=certificate_error; return 1; }
    vx_cf_secure_path "$key" 0600 && vx_cf_secure_path "$csr" 0600 \
        || { /usr/bin/rm -f -- "$response"; VX_CF_STATUS=state_error; return 1; }
    /usr/bin/jq -n --rawfile csr "$csr" --args \
        '{csr:$csr,hostnames:$ARGS.positional,request_type:"origin-rsa",requested_validity:5475}' \
        -- "${VX_CF_CERT_HOSTNAMES[@]}" >"$body" || {
        /usr/bin/rm -f -- "$response"
        VX_CF_STATUS=state_error
        return 1
    }
    vx_cf_secure_path "$body" 0600 || {
        /usr/bin/rm -f -- "$response"
        VX_CF_STATUS=state_error
        return 1
    }
    if ! vx_cf_origin_transport POST '' "$response" "$body"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    certificate_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    if ! vx_cf_valid_certificate_id "$certificate_id"; then
        /usr/bin/rm -f -- "$response"
        VX_CF_STATUS=malformed_response
        return 1
    fi
    if ! /usr/bin/jq -e '(.result | type == "object") and
            (.result.hostnames | type == "array") and
            (.result.certificate | type == "string")' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        vx_cf_origin_compensate_new_certificate "$certificate_id" malformed_response
        return
    fi
    expected_names=$(printf '%s\n' "${VX_CF_CERT_HOSTNAMES[@]}" | LC_ALL=C /usr/bin/sort -u)
    actual_names=$(/usr/bin/jq -r '.result.hostnames[]' "$response" \
        | LC_ALL=C /usr/bin/sort -u)
    /usr/bin/jq -r '.result.certificate' "$response" >"$crt"
    /usr/bin/rm -f -- "$response"
    if [[ "$actual_names" != "$expected_names" ]]; then
        vx_cf_origin_compensate_new_certificate "$certificate_id" certificate_hostname_mismatch
        return
    fi
    vx_cf_secure_path "$crt" 0600 || {
        vx_cf_origin_compensate_new_certificate "$certificate_id" state_error
        return
    }
    /usr/bin/cp -- "$(vx_cf_origin_ca_path)" "$ca" \
        && vx_cf_secure_path "$ca" 0600 \
        || {
            vx_cf_origin_compensate_new_certificate "$certificate_id" state_error
            return
        }
    /usr/bin/openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1 \
        || {
            vx_cf_origin_compensate_new_certificate "$certificate_id" certificate_error
            return
        }
    for hostname in "${VX_CF_CERT_HOSTNAMES[@]}"; do
        /usr/bin/openssl x509 -in "$crt" -noout -checkhost "$hostname" \
            >/dev/null 2>&1 || {
                vx_cf_origin_compensate_new_certificate "$certificate_id" certificate_error
                return
            }
    done
    cert_key_digest=$(/usr/bin/openssl x509 -in "$crt" -pubkey -noout 2>/dev/null \
        | /usr/bin/openssl pkey -pubin -outform DER 2>/dev/null \
        | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
    private_key_digest=$(/usr/bin/openssl pkey -in "$key" -pubout -outform DER \
        2>/dev/null | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
    [[ "$cert_key_digest" =~ ^[a-f0-9]{64}$ \
        && "$cert_key_digest" == "$private_key_digest" ]] \
        || {
            vx_cf_origin_compensate_new_certificate "$certificate_id" certificate_error
            return
        }
    VX_CF_NEW_CERTIFICATE_ID=$certificate_id
}

vx_cf_install_origin_certificate() {
    local user=$1 domain=$2 stage=$3 restart=${4:-yes} row ssl command

    vx_cf_exact_web_row "$user" "$domain" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])SSL=\'([^\']*)\'([[:space:]]|$) ]] \
        && ssl=${BASH_REMATCH[2]} || ssl=no
    if [[ "$ssl" == yes ]]; then
        command="$BIN/v-change-web-domain-sslcert"
        VESTA="$VESTA" "$command" "$user" "$domain" "$stage" "$restart" \
            >/dev/null 2>&1 \
            || { VX_CF_STATUS=certificate_install_failed; return 1; }
    else
        command="$BIN/v-add-web-domain-ssl"
        VESTA="$VESTA" "$command" "$user" "$domain" "$stage" same "$restart" \
            >/dev/null 2>&1 \
            || { VX_CF_STATUS=certificate_install_failed; return 1; }
    fi
    [[ -f "$VESTA/data/users/$user/ssl/$domain.crt" \
        && -f "$VESTA/data/users/$user/ssl/$domain.key" ]] \
        && /usr/bin/cmp -s "$stage/$domain.crt" \
            "$VESTA/data/users/$user/ssl/$domain.crt" \
        && /usr/bin/cmp -s "$stage/$domain.key" \
            "$VESTA/data/users/$user/ssl/$domain.key" \
        || { VX_CF_STATUS=certificate_install_failed; return 1; }
}

vx_cf_origin_reconcile_locked() {
    local user=$1 domain=$2 restart=${3:-yes} stage old_id='' old_hostnames=''
    local old_digest='' new_id original_status

    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    vx_cf_metadata_exists "$user" "$domain" \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    vx_cf_load_metadata "$user" "$domain" || return 1
    [[ "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    vx_cf_collect_certificate_hostnames "$user" "$domain" || return 1
    if vx_cf_certificate_metadata_exists "$user" "$domain"; then
        vx_cf_load_certificate_metadata "$user" "$domain" || return 1
        [[ "$VX_CF_CERT_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
            || { VX_CF_STATUS=ownership_mismatch; return 1; }
        old_id=$VX_CF_CERT_META_ID
        old_hostnames=$VX_CF_CERT_META_HOSTNAMES
        old_digest=$VX_CF_CERT_META_DIGEST
        if [[ "$old_digest" == "$VX_CF_CERT_HOSTNAMES_DIGEST" ]]; then
            VX_CF_STATUS=ssl_unchanged
            return 0
        fi
    fi
    stage=$(/usr/bin/mktemp -d "$(vx_cf_runtime_root)/.origin-ssl.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$stage" 0700 || {
        /usr/bin/rm -rf -- "$stage"
        VX_CF_STATUS=state_error
        return 1
    }
    if ! vx_cf_origin_create_certificate "$domain" "$stage"; then
        /usr/bin/rm -rf -- "$stage"
        return 1
    fi
    new_id=$VX_CF_NEW_CERTIFICATE_ID
    if ! vx_cf_install_origin_certificate "$user" "$domain" "$stage" "$restart"; then
        original_status=${VX_CF_STATUS:-certificate_install_failed}
        vx_cf_origin_revoke_certificate "$new_id" >/dev/null 2>&1 || :
        /usr/bin/rm -rf -- "$stage"
        VX_CF_STATUS=$original_status
        return 1
    fi
    if ! vx_cf_write_certificate_metadata "$user" "$domain" "$new_id" \
        "$VX_CF_CERT_HOSTNAMES_CSV" "$VX_CF_CERT_HOSTNAMES_DIGEST"; then
        original_status=${VX_CF_STATUS:-state_error}
        vx_cf_origin_revoke_certificate "$new_id" >/dev/null 2>&1 || :
        /usr/bin/rm -rf -- "$stage"
        VX_CF_STATUS=$original_status
        return 1
    fi
    /usr/bin/rm -rf -- "$stage"
    if [[ -n "$old_id" ]]; then
        # The replacement is already installed and authoritative. Revocation
        # of the superseded exact ID is best-effort and never rolls it back.
        vx_cf_origin_revoke_certificate "$old_id" >/dev/null 2>&1 || :
    fi
    VX_CF_STATUS=ssl_ready
}

vx_cf_origin_reconcile() {
    vx_cf_with_lock vx_cf_origin_reconcile_locked "$1" "$2" "${3:-yes}"
}

vx_cf_origin_cleanup_locked() {
    local user=$1 domain=$2 certificate_id

    if ! vx_cf_certificate_metadata_exists "$user" "$domain"; then
        VX_CF_STATUS=unchanged
        return 0
    fi
    vx_cf_load_config || return 1
    vx_cf_load_certificate_metadata "$user" "$domain" || return 1
    [[ "$VX_CF_CERT_META_ZONE_ID" == "$VX_CF_ZONE_ID" \
        && "$VX_CF_CERT_META_DOMAIN" == "$domain" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    certificate_id=$VX_CF_CERT_META_ID
    if ! vx_cf_origin_get_certificate "$certificate_id"; then
        if [[ "$VX_CF_STATUS" == not_found ]]; then
            vx_cf_remove_certificate_metadata "$user" "$domain" || return 1
            VX_CF_STATUS=deleted
            return 0
        fi
        return 1
    fi
    [[ "$VX_CF_ORIGIN_CERTIFICATE_ID" == "$certificate_id" \
        && "$VX_CF_ORIGIN_HOSTNAMES_DIGEST" == "$VX_CF_CERT_META_DIGEST" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    vx_cf_origin_revoke_certificate "$certificate_id" || return 1
    vx_cf_remove_certificate_metadata "$user" "$domain" || return 1
    VX_CF_STATUS=deleted
}

vx_cf_origin_cleanup() {
    vx_cf_with_lock vx_cf_origin_cleanup_locked "$1" "$2"
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
        vx_cf_origin_preflight || return 1
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
