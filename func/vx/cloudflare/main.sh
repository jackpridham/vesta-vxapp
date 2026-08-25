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

vx_cf_runtime_home_root() {
    local root=${HOMEDIR:-/home}

    root=${root%/}
    [[ -n "$root" && "$root" == /* && "$root" != / \
        && "$root" != *$'\n'* && "$root" != *'/../'* \
        && "$root" != */.. && "$root" != *'/./'* \
        && "$root" != */. ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_HOME_ROOT=$root
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

vx_cf_zone_transport() {
    local zone_id=$1 method=$2 api_path=$3 response_path=$4 body_path=${5:-}

    [[ "$zone_id" =~ ^[a-f0-9]{32}$ ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_transport_url "$method" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/$api_path" \
        "$response_path" "$body_path"
}

vx_cf_account_transport() {
    local method=$1 api_path=$2 response_path=$3 body_path=${4:-}

    vx_cf_transport_url "$method" \
        "https://api.cloudflare.com/client/v4/$api_path" \
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

vx_cf_lookup_any_record() {
    local domain=$1 response count

    vx_cf_valid_domain "$domain" || { VX_CF_STATUS=invalid_domain; return 1; }
    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_transport GET "dns_records?name=$domain&per_page=100" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e --arg name "$domain" '
            (.result | type == "array") and
            all(.result[]?;
                (type == "object") and
                (.id | type == "string") and
                (.id | test("^[a-f0-9]{32}$")) and
                (.name | type == "string") and
                ((.name | ascii_downcase) == $name) and
                (.type | type == "string") and (.type | length > 0))
        ' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    count=$(/usr/bin/jq -r '.result | length' "$response" 2>/dev/null)
    /usr/bin/rm -f -- "$response"
    [[ "$count" =~ ^[0-9]+$ ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    VX_CF_ANY_RECORD_FOUND=no
    (( count == 0 )) || VX_CF_ANY_RECORD_FOUND=yes
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
    local created_record_id observer_status
    local saved_name saved_type saved_address saved_ttl saved_proxied

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
    if [[ "$method" == POST ]]; then
        created_record_id=$VX_CF_RECORD_ID
        [[ "$created_record_id" =~ ^[a-f0-9]{32}$ ]] \
            || { VX_CF_STATUS=malformed_response; return 1; }
        if declare -F vx_cf_migration_observe_record_id >/dev/null 2>&1; then
            saved_name=$VX_CF_RECORD_NAME
            saved_type=$VX_CF_RECORD_TYPE
            saved_address=$VX_CF_RECORD_ADDRESS
            saved_ttl=$VX_CF_RECORD_TTL
            saved_proxied=$VX_CF_RECORD_PROXIED
            if ! vx_cf_migration_observe_record_id "$created_record_id"; then
                observer_status=state_error
                VX_CF_RECORD_ID=$created_record_id
                VX_CF_RECORD_NAME=$saved_name
                VX_CF_RECORD_TYPE=$saved_type
                VX_CF_RECORD_ADDRESS=$saved_address
                VX_CF_RECORD_TTL=$saved_ttl
                VX_CF_RECORD_PROXIED=$saved_proxied
                if ! vx_cf_compensate_created_record_locked \
                    "$domain" "$address" "$created_record_id"; then
                    return 1
                fi
                VX_CF_STATUS=$observer_status
                return 1
            fi
            VX_CF_RECORD_ID=$created_record_id
            VX_CF_RECORD_NAME=$saved_name
            VX_CF_RECORD_TYPE=$saved_type
            VX_CF_RECORD_ADDRESS=$saved_address
            VX_CF_RECORD_TTL=$saved_ttl
            VX_CF_RECORD_PROXIED=$saved_proxied
        fi
    fi
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

vx_cf_zone_ssl_readback() {
    local zone_id=$1 response setting_id setting_value

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_zone_transport "$zone_id" GET settings/ssl "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "object"' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    setting_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    setting_value=$(/usr/bin/jq -r '.result.value // empty' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$setting_id" == ssl && "$setting_value" =~ ^(off|flexible|full|strict|origin_pull)$ ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    [[ "$setting_value" == strict ]] \
        || { VX_CF_STATUS=strict_not_enabled; return 1; }
}

vx_cf_zone_enforce_strict() {
    local zone_id=$1 body response result_id result_value

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
    printf '{"value":"strict"}\n' >"$body" || {
        /usr/bin/rm -f -- "$body" "$response"
        VX_CF_STATUS=state_error
        return 1
    }
    if ! vx_cf_zone_transport "$zone_id" PATCH settings/ssl "$response" "$body"; then
        /usr/bin/rm -f -- "$body" "$response"
        return 1
    fi
    /usr/bin/rm -f -- "$body"
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '.result | type == "object"' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    result_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    result_value=$(/usr/bin/jq -r '.result.value // empty' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$result_id" == ssl && "$result_value" == strict ]] \
        || { VX_CF_STATUS=readback_mismatch; return 1; }
    vx_cf_zone_ssl_readback "$zone_id"
}

vx_cf_edge_pattern_covers() {
    local pattern=$1 hostname=$2 suffix prefix

    [[ "$pattern" == "$hostname" ]] && return 0
    [[ "$pattern" == \*.* ]] || return 1
    suffix=${pattern#*.}
    [[ "$hostname" == *."$suffix" ]] || return 1
    prefix=${hostname%."$suffix"}
    [[ -n "$prefix" && "$prefix" != *.* ]]
}

vx_cf_edge_hostname_preflight() {
    local zone_id=$1 hostname=$2 response page count edge_host

    [[ "$zone_id" =~ ^[a-f0-9]{32}$ ]] && vx_cf_valid_domain "$hostname" \
        || { VX_CF_STATUS=state_error; return 1; }
    for ((page=1; page <= 100; page++)); do
        response=$(vx_cf_new_response_file) \
            || { VX_CF_STATUS=state_error; return 1; }
        if ! vx_cf_zone_transport "$zone_id" GET \
            "ssl/certificate_packs?per_page=50&page=$page" "$response"; then
            /usr/bin/rm -f -- "$response"
            return 1
        fi
        if ! vx_cf_response_success "$response" \
            || ! /usr/bin/jq -e '
                (.result | type == "array") and
                all(.result[]?;
                    (type == "object") and (.certificates | type == "array") and
                    all(.certificates[]?;
                        (type == "object") and (.status | type == "string") and
                        (.hosts | type == "array") and
                        all(.hosts[]?; type == "string")))
            ' "$response" >/dev/null 2>&1; then
            /usr/bin/rm -f -- "$response"
            [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
            return 1
        fi
        count=$(/usr/bin/jq -r '.result | length' "$response")
        while IFS= read -r edge_host; do
            vx_cf_valid_certificate_hostname "$edge_host" || {
                /usr/bin/rm -f -- "$response"
                VX_CF_STATUS=malformed_response
                return 1
            }
            if vx_cf_edge_pattern_covers "$edge_host" "$hostname"; then
                /usr/bin/rm -f -- "$response"
                return 0
            fi
        done < <(/usr/bin/jq -r '
            .result[]?.certificates[]? |
            select(.status == "active") | .hosts[]?
        ' "$response")
        /usr/bin/rm -f -- "$response"
        [[ "$count" =~ ^[0-9]+$ ]] \
            || { VX_CF_STATUS=malformed_response; return 1; }
        (( count == 50 )) || break
    done
    (( page <= 100 )) || { VX_CF_STATUS=malformed_response; return 1; }
    VX_CF_STATUS=edge_certificate_missing
    return 1
}

vx_cf_primary_edge_preflight() {
    local probe_hostname

    probe_hostname="s-0000000000.$VX_CF_ZONE_NAME"
    vx_cf_edge_hostname_preflight "$VX_CF_ZONE_ID" "$probe_hostname"
}

vx_cf_discover_zone_for_hostname() {
    local hostname=${1#\*.} candidate response count result_id result_name result_status

    vx_cf_valid_domain "$hostname" || { VX_CF_STATUS=invalid_alias; return 1; }
    candidate=$hostname
    while [[ "$candidate" == *.* ]]; do
        response=$(vx_cf_new_response_file) \
            || { VX_CF_STATUS=state_error; return 1; }
        if ! vx_cf_account_transport GET \
            "zones?name=$candidate&status=active&match=all&per_page=50" "$response"; then
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
        count=$(/usr/bin/jq -r '.result | length' "$response")
        [[ "$count" =~ ^[0-9]+$ ]] || {
            /usr/bin/rm -f -- "$response"
            VX_CF_STATUS=malformed_response
            return 1
        }
        if (( count > 1 )); then
            /usr/bin/rm -f -- "$response"
            VX_CF_STATUS=ambiguous_zone
            return 1
        fi
        if (( count == 1 )); then
            result_id=$(/usr/bin/jq -r '.result[0].id // empty' "$response")
            result_name=$(/usr/bin/jq -r '.result[0].name // empty' "$response")
            result_status=$(/usr/bin/jq -r '.result[0].status // empty' "$response")
            /usr/bin/rm -f -- "$response"
            result_name=${result_name,,}
            [[ "$result_id" =~ ^[a-f0-9]{32}$ \
                && "$result_name" == "$candidate" && "$result_status" == active ]] \
                || { VX_CF_STATUS=malformed_response; return 1; }
            VX_CF_DISCOVERED_ZONE_ID=$result_id
            VX_CF_DISCOVERED_ZONE_NAME=$result_name
            return 0
        fi
        /usr/bin/rm -f -- "$response"
        candidate=${candidate#*.}
    done
    VX_CF_STATUS=alias_zone_not_found
    return 1
}

vx_cf_alias_dns_preflight() {
    local zone_id=$1 alias=$2 ingress=$3 technical_domain=$4 response count
    local route_count=0 row_type row_name row_content row_proxied normalized_content

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_zone_transport "$zone_id" GET \
        "dns_records?name=$alias&per_page=100" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e --arg name "$alias" '
            (.result | type == "array") and
            all(.result[]?;
                (type == "object") and (.name | ascii_downcase) == $name and
                (.type | type == "string") and (.content | type == "string"))
        ' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    count=$(/usr/bin/jq -r '.result | length' "$response")
    [[ "$count" =~ ^[0-9]+$ ]] && (( count < 100 )) || {
        /usr/bin/rm -f -- "$response"
        VX_CF_STATUS=ambiguous_record
        return 1
    }
    while IFS=$'\t' read -r row_type row_name row_content row_proxied; do
        ((route_count++))
        normalized_content=${row_content%.}
        normalized_content=${normalized_content,,}
        case "$row_type" in
            A)
                [[ "$row_name" == "$alias" && "$row_proxied" == true ]] \
                    && vx_cf_valid_ipv4 "$row_content" \
                    && [[ "$row_content" == "$ingress" ]] || {
                        /usr/bin/rm -f -- "$response"
                        VX_CF_STATUS=alias_dns_mismatch
                        return 1
                    }
                ;;
            CNAME)
                [[ "$row_name" == "$alias" && "$row_proxied" == true \
                    && "$normalized_content" == "$technical_domain" ]] || {
                        /usr/bin/rm -f -- "$response"
                        VX_CF_STATUS=alias_dns_mismatch
                        return 1
                    }
                ;;
            *)
                /usr/bin/rm -f -- "$response"
                VX_CF_STATUS=alias_dns_mismatch
                return 1
                ;;
        esac
    done < <(/usr/bin/jq -r '
        .result[]? | select(.type == "A" or .type == "AAAA" or .type == "CNAME") |
        [.type, (.name | ascii_downcase), .content, (.proxied | tostring)] | @tsv
    ' "$response")
    /usr/bin/rm -f -- "$response"
    (( route_count >= 1 )) || { VX_CF_STATUS=alias_dns_mismatch; return 1; }
}

vx_cf_certificate_provider_preflight() {
    local user=$1 domain=$2 hostname zone_id
    local -A strict_zones=()

    vx_cf_web_address "$user" "$domain" || return 1
    vx_cf_zone_enforce_strict "$VX_CF_ZONE_ID" || return 1
    strict_zones["$VX_CF_ZONE_ID"]=yes
    vx_cf_edge_hostname_preflight "$VX_CF_ZONE_ID" "$domain" || return 1
    for hostname in "${VX_CF_CERT_HOSTNAMES[@]}"; do
        [[ "$hostname" == "$domain" ]] && continue
        [[ "$hostname" != \*.* ]] \
            || { VX_CF_STATUS=invalid_alias; return 1; }
        vx_cf_discover_zone_for_hostname "$hostname" || return 1
        zone_id=$VX_CF_DISCOVERED_ZONE_ID
        vx_cf_alias_dns_preflight "$zone_id" "$hostname" \
            "$VX_CF_WEB_ADDRESS" "$domain" || return 1
        vx_cf_edge_hostname_preflight "$zone_id" "$hostname" || return 1
        if [[ -z "${strict_zones[$zone_id]:-}" ]]; then
            vx_cf_zone_enforce_strict "$zone_id" || return 1
            strict_zones["$zone_id"]=yes
        fi
    done
}

vx_cf_certificate_provider_readback() {
    local primary=$1 ingress=$2 hostname zone_id
    local -A strict_zones=()
    shift 2

    vx_cf_valid_domain "$primary" && vx_cf_valid_ipv4 "$ingress" \
        && (( $# >= 1 && $# <= 200 )) \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_zone_ssl_readback "$VX_CF_ZONE_ID" || return 1
    strict_zones["$VX_CF_ZONE_ID"]=yes
    vx_cf_edge_hostname_preflight "$VX_CF_ZONE_ID" "$primary" || return 1
    for hostname in "$@"; do
        vx_cf_valid_certificate_hostname "$hostname" \
            || { VX_CF_STATUS=invalid_alias; return 1; }
        [[ "$hostname" == "$primary" ]] && continue
        [[ "$hostname" != \*.* ]] \
            || { VX_CF_STATUS=invalid_alias; return 1; }
        vx_cf_discover_zone_for_hostname "$hostname" || return 1
        zone_id=$VX_CF_DISCOVERED_ZONE_ID
        vx_cf_alias_dns_preflight "$zone_id" "$hostname" \
            "$ingress" "$primary" || return 1
        vx_cf_edge_hostname_preflight "$zone_id" "$hostname" || return 1
        if [[ -z "${strict_zones[$zone_id]:-}" ]]; then
            vx_cf_zone_ssl_readback "$zone_id" || return 1
            strict_zones["$zone_id"]=yes
        fi
    done
}

vx_cf_collect_migration_hostnames() {
    local user=$1 source=$2 target=$3 row aliases hostname
    local -a names=()

    vx_cf_exact_web_row "$user" "$source" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])ALIAS=\'([^\']*)\'([[:space:]]|$) ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    aliases=${BASH_REMATCH[2]}
    names+=("$target" "$source")
    if [[ -n "$aliases" ]]; then
        local IFS=,
        read -r -a VX_CF_MIGRATION_ALIAS_NAMES <<<"$aliases"
        names+=("${VX_CF_MIGRATION_ALIAS_NAMES[@]}")
    fi
    mapfile -t VX_CF_MIGRATION_HOSTNAMES < <(
        printf '%s\n' "${names[@]}" | /usr/bin/tr '[:upper:]' '[:lower:]' \
            | LC_ALL=C /usr/bin/sort -u
    )
    (( ${#VX_CF_MIGRATION_HOSTNAMES[@]} >= 2 \
        && ${#VX_CF_MIGRATION_HOSTNAMES[@]} <= 200 )) \
        || { VX_CF_STATUS=invalid_alias; return 1; }
    for hostname in "${VX_CF_MIGRATION_HOSTNAMES[@]}"; do
        vx_cf_valid_certificate_hostname "$hostname" \
            || { VX_CF_STATUS=invalid_alias; return 1; }
    done
    VX_CF_MIGRATION_HOSTNAMES_CSV=$(IFS=,; \
        printf '%s' "${VX_CF_MIGRATION_HOSTNAMES[*]}")
    VX_CF_MIGRATION_HOSTNAMES_DIGEST=$(printf '%s\n' \
        "${VX_CF_MIGRATION_HOSTNAMES[@]}" | vx_cf_hostname_digest) \
        || { VX_CF_STATUS=state_error; return 1; }
}

vx_cf_migration_preflight_locked() {
    local user=$1 source=$2 target=$3 path

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$source" \
        && vx_cf_valid_domain "$target" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    vx_cf_managed_domain_matches_zone "$target" "$VX_CF_ZONE_NAME" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    [[ "$source" != "$target" ]] \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_exact_web_row "$user" "$source" || return 1

    for path in "$(vx_cf_record_path "$user" "$source")" \
        "$(vx_cf_certificate_path "$user" "$source")"; do
        [[ ! -e "$path" && ! -L "$path" ]] \
            || { VX_CF_STATUS=ownership_mismatch; return 1; }
    done
    vx_cf_local_domain_exists "$target" \
        && { VX_CF_STATUS=target_in_use; return 1; }
    for path in "$(vx_cf_record_path "$user" "$target")" \
        "$(vx_cf_certificate_path "$user" "$target")"; do
        [[ ! -e "$path" && ! -L "$path" ]] \
            || { VX_CF_STATUS=target_in_use; return 1; }
    done
    vx_cf_lookup_any_record "$target" || return 1
    [[ "$VX_CF_ANY_RECORD_FOUND" == no ]] \
        || { VX_CF_STATUS=target_record_exists; return 1; }

    vx_cf_web_address "$user" "$source" || return 1
    vx_cf_collect_migration_hostnames "$user" "$source" "$target" || return 1
    vx_cf_certificate_provider_readback "$target" "$VX_CF_WEB_ADDRESS" \
        "${VX_CF_MIGRATION_HOSTNAMES[@]}" || return 1
    VX_CF_STATUS=ready
}

vx_cf_verify_managed_site_locked() {
    local user=$1 target=$2 record_path certificate_path

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$target" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    vx_cf_managed_domain_matches_zone "$target" "$VX_CF_ZONE_NAME" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_web_address "$user" "$target" || return 1

    record_path=$(vx_cf_record_path "$user" "$target")
    [[ -e "$record_path" || -L "$record_path" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    vx_cf_load_metadata "$user" "$target" || return 1
    [[ "$VX_CF_META_USER" == "$user" \
        && "$VX_CF_META_DOMAIN" == "$target" \
        && "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    [[ "$VX_CF_META_ADDRESS" == "$VX_CF_WEB_ADDRESS" ]] \
        || { VX_CF_STATUS=readback_mismatch; return 1; }
    vx_cf_get_record "$VX_CF_META_RECORD_ID" || return 1
    [[ "$VX_CF_RECORD_NAME" == "$target" \
        && "$VX_CF_RECORD_TYPE" == A \
        && "$VX_CF_RECORD_ADDRESS" == "$VX_CF_WEB_ADDRESS" \
        && "$VX_CF_RECORD_TTL" == 1 \
        && "$VX_CF_RECORD_PROXIED" == true ]] \
        || { VX_CF_STATUS=readback_mismatch; return 1; }

    vx_cf_collect_certificate_hostnames "$user" "$target" || return 1
    vx_cf_certificate_provider_readback "$target" "$VX_CF_WEB_ADDRESS" \
        "${VX_CF_CERT_HOSTNAMES[@]}" || return 1
    certificate_path=$(vx_cf_certificate_path "$user" "$target")
    [[ -e "$certificate_path" || -L "$certificate_path" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    vx_cf_load_certificate_metadata "$user" "$target" || return 1
    [[ "$VX_CF_CERT_META_USER" == "$user" \
        && "$VX_CF_CERT_META_DOMAIN" == "$target" \
        && "$VX_CF_CERT_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    [[ "$VX_CF_CERT_META_HOSTNAMES" == "$VX_CF_CERT_HOSTNAMES_CSV" \
        && "$VX_CF_CERT_META_DIGEST" == "$VX_CF_CERT_HOSTNAMES_DIGEST" ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    [[ -z "$VX_CF_CERT_META_PENDING_IDS" ]] \
        || { VX_CF_STATUS=certificate_cleanup_pending; return 1; }
    vx_cf_origin_get_certificate "$VX_CF_CERT_META_ID" || return 1
    [[ "$VX_CF_ORIGIN_CERTIFICATE_ID" == "$VX_CF_CERT_META_ID" \
        && "$VX_CF_ORIGIN_HOSTNAMES_DIGEST" == "$VX_CF_CERT_META_DIGEST" ]] \
        || { VX_CF_STATUS=ownership_mismatch; return 1; }
    [[ "$VX_CF_ORIGIN_REVOKED" == no ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    vx_cf_installed_certificate_health "$user" "$target" \
        "$VX_CF_CERT_META_DIGEST" \
        "$VX_CF_ORIGIN_CERTIFICATE_FINGERPRINT" || return 1
    VX_CF_STATUS=managed
}

vx_cf_assert_zone_rotation_safe() {
    local candidate_zone=$1 root parent path zone_line zone_id

    for root in "$(vx_cf_records_root)" "$(vx_cf_certificates_root)"; do
        while IFS= read -r -d '' parent; do
            vx_cf_secure_directory "$parent" \
                || { VX_CF_STATUS=state_error; return 1; }
        done < <(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -print0 \
            2>/dev/null)
        while IFS= read -r -d '' path; do
            vx_cf_secure_regular_file "$path" \
                || { VX_CF_STATUS=state_error; return 1; }
            mapfile -t VX_CF_METADATA_ZONE_LINES < <(
                /usr/bin/grep -E "^ZONE_ID='[a-f0-9]{32}'$" "$path" 2>/dev/null || :
            )
            [[ ${#VX_CF_METADATA_ZONE_LINES[@]} -eq 1 ]] \
                || { VX_CF_STATUS=state_error; return 1; }
            zone_line=${VX_CF_METADATA_ZONE_LINES[0]}
            zone_id=${zone_line#ZONE_ID=\'}
            zone_id=${zone_id%\'}
            [[ "$zone_id" == "$candidate_zone" ]] \
                || { VX_CF_STATUS=managed_zone_in_use; return 1; }
        done < <(/usr/bin/find "$root" -mindepth 2 -maxdepth 2 \
            -name '*.conf' -print0 2>/dev/null)
    done
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
    vx_cf_assert_zone_rotation_safe "$VX_CF_ZONE_ID" || {
        VX_CF_API_TOKEN=$old_token
        VX_CF_ZONE_ID=$old_zone
        VX_CF_ACCOUNT_EMAIL=$old_email
        VX_CF_ZONE_NAME=$old_name
        return 1
    }
    vx_cf_zone_enforce_strict "$VX_CF_ZONE_ID" || {
        VX_CF_API_TOKEN=$old_token
        VX_CF_ZONE_ID=$old_zone
        VX_CF_ACCOUNT_EMAIL=$old_email
        VX_CF_ZONE_NAME=$old_name
        return 1
    }
    vx_cf_origin_preflight || {
        VX_CF_API_TOKEN=$old_token
        VX_CF_ZONE_ID=$old_zone
        VX_CF_ACCOUNT_EMAIL=$old_email
        VX_CF_ZONE_NAME=$old_name
        return 1
    }
    vx_cf_primary_edge_preflight || {
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
    vx_cf_origin_preflight || return 1
    vx_cf_zone_ssl_readback "$VX_CF_ZONE_ID" || return 1
    vx_cf_primary_edge_preflight || return 1
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
    local exact_record_found=no exact_name='' exact_address=''
    local exact_ttl='' exact_proxied=''

    vx_cf_provider_mode || { VX_CF_STATUS=state_error; return 1; }
    [[ "$VX_CF_PROVIDER_MODE" == cloudflare-managed ]] \
        || { VX_CF_STATUS=provider_disabled; return 1; }
    vx_cf_load_config || return 1
    vx_cf_managed_domain_matches_zone "$domain" "$VX_CF_ZONE_NAME" \
        || { VX_CF_STATUS=invalid_domain; return 1; }
    vx_cf_web_address "$user" "$domain" || return 1
    address=$VX_CF_WEB_ADDRESS

    if vx_cf_metadata_exists "$user" "$domain"; then
        vx_cf_load_metadata "$user" "$domain" || return 1
        [[ "$VX_CF_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
            || { VX_CF_STATUS=ownership_mismatch; return 1; }
        record_id=$VX_CF_META_RECORD_ID
        if vx_cf_get_record "$record_id"; then
            exact_record_found=yes
            exact_name=$VX_CF_RECORD_NAME
            exact_address=$VX_CF_RECORD_ADDRESS
            exact_ttl=$VX_CF_RECORD_TTL
            exact_proxied=$VX_CF_RECORD_PROXIED
            # An exact provider ID remains the authority if its name drifts,
            # but never overwrite a different record already at the desired
            # name. The exact-ID read must precede this collision lookup.
            vx_cf_lookup_record "$domain" || return 1
            if [[ "$VX_CF_RECORD_FOUND" == yes \
                && "$VX_CF_RECORD_ID" != "$record_id" ]]; then
                VX_CF_STATUS=ownership_mismatch
                return 1
            fi
        elif [[ "$VX_CF_STATUS" == not_found ]]; then
            # Only a confirmed exact-ID absence permits replacement creation,
            # and a desired-name match is never adopted without metadata.
            vx_cf_lookup_record "$domain" || return 1
            if [[ "$VX_CF_RECORD_FOUND" == yes ]]; then
                VX_CF_STATUS=ownership_mismatch
                return 1
            fi
        else
            return 1
        fi
    else
        vx_cf_lookup_record "$domain" || return 1
        if [[ "$VX_CF_RECORD_FOUND" == yes ]]; then
            # A name match is not ownership. Only metadata created by a
            # successful managed lifecycle may authorize an existing ID.
            VX_CF_STATUS=ownership_mismatch
            return 1
        fi
    fi

    if [[ "$exact_record_found" == no ]]; then
        vx_cf_mutate_record POST dns_records "$domain" "$address" || return 1
        action=created
    else
        if [[ "$exact_name" == "$domain" \
            && "$exact_address" == "$address" \
            && "$exact_ttl" == 1 \
            && "$exact_proxied" == true ]]; then
            VX_CF_RECORD_ID=$record_id
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

vx_cf_normalize_certificate_ids() {
    local csv=$1 certificate_id
    local -a ids=()

    VX_CF_NORMALIZED_CERTIFICATE_IDS=''
    [[ -n "$csv" ]] || return 0
    local IFS=,
    read -r -a ids <<<"$csv"
    (( ${#ids[@]} >= 1 && ${#ids[@]} <= 1000 )) \
        || { VX_CF_STATUS=state_error; return 1; }
    for certificate_id in "${ids[@]}"; do
        vx_cf_valid_certificate_id "$certificate_id" \
            || { VX_CF_STATUS=state_error; return 1; }
    done
    VX_CF_NORMALIZED_CERTIFICATE_IDS=$(printf '%s\n' "${ids[@]}" \
        | LC_ALL=C /usr/bin/sort -u | /usr/bin/paste -sd, -) \
        || { VX_CF_STATUS=state_error; return 1; }
}

vx_cf_add_certificate_id() {
    local csv=$1 certificate_id=$2

    vx_cf_valid_certificate_id "$certificate_id" \
        || { VX_CF_STATUS=state_error; return 1; }
    [[ -z "$csv" ]] && csv=$certificate_id || csv+=",$certificate_id"
    vx_cf_normalize_certificate_ids "$csv" || return 1
    VX_CF_UPDATED_CERTIFICATE_IDS=$VX_CF_NORMALIZED_CERTIFICATE_IDS
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
    local pending_ids=${6:-}
    local parent target temporary

    vx_cf_normalize_certificate_ids "$pending_ids" || return 1
    pending_ids=$VX_CF_NORMALIZED_CERTIFICATE_IDS
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
        printf "SCHEMA='2'\n"
        printf "USER='%s'\n" "$user"
        printf "DOMAIN='%s'\n" "$domain"
        printf "ZONE_ID='%s'\n" "$VX_CF_ZONE_ID"
        printf "CERTIFICATE_ID='%s'\n" "$certificate_id"
        printf "HOSTNAMES='%s'\n" "$hostnames"
        printf "HOSTNAMES_DIGEST='%s'\n" "$digest"
        printf "PENDING_REVOKE_IDS='%s'\n" "$pending_ids"
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
    local hostnames_seen=0 digest_seen=0 pending_seen=0

    path=$(vx_cf_certificate_path "$user" "$domain")
    vx_cf_secure_regular_file "$path" || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_CERT_META_SCHEMA=''
    VX_CF_CERT_META_USER=''
    VX_CF_CERT_META_DOMAIN=''
    VX_CF_CERT_META_ZONE_ID=''
    VX_CF_CERT_META_ID=''
    VX_CF_CERT_META_HOSTNAMES=''
    VX_CF_CERT_META_DIGEST=''
    VX_CF_CERT_META_PENDING_IDS=''
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
            PENDING_REVOKE_IDS) (( pending_seen++ == 0 )) || return 1; VX_CF_CERT_META_PENDING_IDS=$value ;;
            *) VX_CF_STATUS=state_error; return 1 ;;
        esac
    done <"$path"
    [[ ( "$VX_CF_CERT_META_SCHEMA" == 1 || "$VX_CF_CERT_META_SCHEMA" == 2 ) \
        && ( "$VX_CF_CERT_META_SCHEMA:$pending_seen" == 1:0 \
            || "$VX_CF_CERT_META_SCHEMA:$pending_seen" == 2:1 ) \
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
    vx_cf_normalize_certificate_ids "$VX_CF_CERT_META_PENDING_IDS" || return 1
    VX_CF_CERT_META_PENDING_IDS=$VX_CF_NORMALIZED_CERTIFICATE_IDS
    local IFS=,
    read -r -a VX_CF_CERT_META_PENDING_ID_LIST <<<"$VX_CF_CERT_META_PENDING_IDS"
    for value in "${VX_CF_CERT_META_PENDING_ID_LIST[@]}"; do
        [[ -z "$value" || "$value" != "$VX_CF_CERT_META_ID" ]] \
            || { VX_CF_STATUS=state_error; return 1; }
    done
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
    if ! vx_cf_origin_transport GET "?zone_id=$VX_CF_ZONE_ID&per_page=5" "$response"; then
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
    local revoked_at fingerprint

    vx_cf_valid_certificate_id "$certificate_id" \
        || { VX_CF_STATUS=state_error; return 1; }
    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_origin_transport GET "/$certificate_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        return 1
    fi
    if ! vx_cf_response_success "$response" \
        || ! /usr/bin/jq -e '(.result | type == "object") and
            (.result.hostnames | type == "array") and
            (.result.certificate | type == "string")' "$response" \
            >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"
        [[ -n "${VX_CF_STATUS:-}" ]] || VX_CF_STATUS=malformed_response
        return 1
    fi
    returned_id=$(/usr/bin/jq -r '.result.id // empty' "$response")
    mapfile -t returned_hostnames < <(/usr/bin/jq -r '.result.hostnames[]' "$response" \
        | LC_ALL=C /usr/bin/sort -u)
    revoked_at=$(/usr/bin/jq -r '.result.revoked_at // empty' "$response")
    fingerprint=$(/usr/bin/jq -r '.result.certificate' "$response" \
        | /usr/bin/openssl x509 -outform DER 2>/dev/null \
        | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
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
    [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    [[ -z "$revoked_at" || "$revoked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] \
        || { VX_CF_STATUS=malformed_response; return 1; }
    VX_CF_ORIGIN_CERTIFICATE_ID=$returned_id
    VX_CF_ORIGIN_HOSTNAMES_DIGEST=$digest
    VX_CF_ORIGIN_CERTIFICATE_FINGERPRINT=$fingerprint
    VX_CF_ORIGIN_REVOKED=no
    if [[ -n "$revoked_at" ]]; then
        VX_CF_ORIGIN_REVOKED=yes
        VX_CF_ORIGIN_REVOKED_AT=$revoked_at
    fi
}

vx_cf_origin_revoke_certificate() {
    local certificate_id=$1 response returned_id revoked_at

    response=$(vx_cf_new_response_file) || { VX_CF_STATUS=state_error; return 1; }
    if ! vx_cf_origin_transport DELETE "/$certificate_id" "$response"; then
        /usr/bin/rm -f -- "$response"
        if [[ "$VX_CF_STATUS" == not_found ]]; then
            VX_CF_ORIGIN_REVOKED_AT=already_revoked
            return 0
        fi
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
    local observed_certificate_id

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
    observed_certificate_id=$certificate_id
    if declare -F vx_cf_migration_observe_certificate_id >/dev/null 2>&1 \
        && ! vx_cf_migration_observe_certificate_id "$observed_certificate_id"; then
        certificate_id=$observed_certificate_id
        /usr/bin/rm -f -- "$response"
        vx_cf_origin_compensate_new_certificate "$certificate_id" state_error
        return
    fi
    certificate_id=$observed_certificate_id
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
    /usr/bin/openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1 \
        || {
            vx_cf_origin_compensate_new_certificate "$certificate_id" certificate_error
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

vx_cf_rendered_ssl_paths() {
    local user=$1 domain=$2 home_root directory component resolved

    vx_cf_valid_user "$user" && vx_cf_valid_domain "$domain" \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_runtime_home_root || return 1
    home_root=$VX_CF_HOME_ROOT
    directory="$home_root/$user/conf/web"
    for component in "$home_root" "$home_root/$user" \
        "$home_root/$user/conf" "$directory"; do
        [[ -d "$component" && ! -L "$component" ]] \
            || { VX_CF_STATUS=state_error; return 1; }
    done
    resolved=$(/usr/bin/realpath -e -- "$directory" 2>/dev/null) \
        || { VX_CF_STATUS=state_error; return 1; }
    [[ "$resolved" == "$directory" ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_RENDERED_SSL_DIRECTORY=$directory
    VX_CF_RENDERED_SSL_PATHS=(
        "$directory/ssl.$domain.crt"
        "$directory/ssl.$domain.key"
        "$directory/ssl.$domain.ca"
        "$directory/ssl.$domain.pem"
    )
}

vx_cf_rendered_ssl_matches_canonical() {
    local user=$1 domain=$2 extension canonical rendered

    vx_cf_rendered_ssl_paths "$user" "$domain" || return 1
    for extension in crt key ca pem; do
        canonical="$VESTA/data/users/$user/ssl/$domain.$extension"
        rendered="$VX_CF_RENDERED_SSL_DIRECTORY/ssl.$domain.$extension"
        [[ -f "$canonical" && ! -L "$canonical" \
            && -f "$rendered" && ! -L "$rendered" ]] \
            && /usr/bin/cmp -s "$canonical" "$rendered" || return 1
    done
}

vx_cf_origin_pem_is_canonical() {
    local crt=$1 ca=$2 pem=$3

    [[ -f "$crt" && ! -L "$crt" && -f "$ca" && ! -L "$ca" \
        && -f "$pem" && ! -L "$pem" ]] \
        && /usr/bin/cmp -s "$pem" <(/usr/bin/cat -- "$crt" "$ca")
}

vx_cf_snapshot_native_ssl() {
    local user=$1 domain=$2 snapshot=$3 row ssl source extension
    local restorable=yes

    /usr/bin/mkdir -p "$snapshot" \
        && vx_cf_secure_path "$snapshot" 0700 \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_exact_web_row "$user" "$domain" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])SSL=\'([^\']*)\'([[:space:]]|$) ]] \
        && ssl=${BASH_REMATCH[2]} || ssl=no
    [[ "$ssl" == yes || "$ssl" == no ]] \
        || { VX_CF_STATUS=state_error; return 1; }
    VX_CF_SNAPSHOT_SSL=$ssl
    VX_CF_SNAPSHOT_RESTORABLE=yes
    [[ "$ssl" == yes ]] || return 0
    for extension in crt key ca pem; do
        source="$VESTA/data/users/$user/ssl/$domain.$extension"
        if [[ -e "$source" || -L "$source" ]]; then
            [[ -f "$source" && ! -L "$source" ]] \
                || { VX_CF_STATUS=state_error; return 1; }
            /usr/bin/cp -- "$source" "$snapshot/$domain.$extension" \
                && vx_cf_secure_path "$snapshot/$domain.$extension" 0600 \
                || { VX_CF_STATUS=state_error; return 1; }
        elif [[ "$extension" != ca ]]; then
            restorable=no
        fi
    done
    VX_CF_SNAPSHOT_RESTORABLE=$restorable
}

vx_cf_native_ssl_matches_snapshot() {
    local user=$1 domain=$2 snapshot=$3 extension live saved

    vx_cf_exact_web_row "$user" "$domain" || return 1
    if [[ "$VX_CF_SNAPSHOT_SSL" == no ]]; then
        [[ "$VX_CF_WEB_ROW" =~ (^|[[:space:]])SSL=\'no\'([[:space:]]|$) ]] \
            || return 1
        for extension in crt key ca pem; do
            live="$VESTA/data/users/$user/ssl/$domain.$extension"
            [[ ! -e "$live" && ! -L "$live" ]] || return 1
        done
        return 0
    fi
    [[ "$VX_CF_WEB_ROW" =~ (^|[[:space:]])SSL=\'yes\'([[:space:]]|$) ]] \
        || return 1
    for extension in crt key ca pem; do
        live="$VESTA/data/users/$user/ssl/$domain.$extension"
        saved="$snapshot/$domain.$extension"
        if [[ -f "$saved" && ! -L "$saved" ]]; then
            [[ -f "$live" && ! -L "$live" ]] \
                && /usr/bin/cmp -s "$saved" "$live" || return 1
        else
            [[ ! -e "$live" && ! -L "$live" ]] || return 1
        fi
    done
}

vx_cf_run_internal_origin_ssl() {
    local command=$1
    shift

    if [[ "${VX_CLOUDFLARE_INTERNAL_MIGRATION:-}" == 1 ]]; then
        VX_CLOUDFLARE_INTERNAL_ORIGIN_SSL=1 \
            VX_CLOUDFLARE_INTERNAL_MIGRATION=1 VESTA="$VESTA" \
            "$command" "$@" >/dev/null 2>&1
    else
        VX_CLOUDFLARE_INTERNAL_ORIGIN_SSL=1 VESTA="$VESTA" \
            "$command" "$@" >/dev/null 2>&1
    fi
}

vx_cf_restore_native_ssl() {
    local user=$1 domain=$2 snapshot=$3 restart=${4:-yes} command

    [[ "$VX_CF_SNAPSHOT_RESTORABLE" == yes ]] || return 1
    if [[ "$VX_CF_SNAPSHOT_SSL" == yes ]]; then
        command="$VESTA/bin/v-change-web-domain-sslcert"
        vx_cf_run_internal_origin_ssl "$command" "$user" "$domain" \
            "$snapshot" "$restart" || return 1
        if [[ -f "$snapshot/$domain.pem" && ! -L "$snapshot/$domain.pem" ]]; then
            /usr/bin/cp -f -- "$snapshot/$domain.pem" \
                "$VESTA/data/users/$user/ssl/$domain.pem" || return 1
        fi
    else
        command="$VESTA/bin/v-delete-web-domain-ssl"
        vx_cf_run_internal_origin_ssl "$command" "$user" "$domain" \
            "$restart" || return 1
    fi
    vx_cf_native_ssl_matches_snapshot "$user" "$domain" "$snapshot"
}

vx_cf_installed_certificate_health() {
    local user=$1 domain=$2 expected_digest=$3 expected_fingerprint=$4
    local crt key ca pem cert_key_digest private_key_digest fingerprint san_output token
    local token_count=0 san_digest
    local -a installed_names=()

    vx_cf_exact_web_row "$user" "$domain" || return 1
    [[ "$VX_CF_WEB_ROW" =~ (^|[[:space:]])SSL=\'yes\'([[:space:]]|$) ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    crt="$VESTA/data/users/$user/ssl/$domain.crt"
    key="$VESTA/data/users/$user/ssl/$domain.key"
    ca="$VESTA/data/users/$user/ssl/$domain.ca"
    pem="$VESTA/data/users/$user/ssl/$domain.pem"
    [[ -f "$crt" && ! -L "$crt" && -f "$key" && ! -L "$key" \
        && -f "$ca" && ! -L "$ca" && -f "$pem" && ! -L "$pem" ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    vx_cf_origin_pem_is_canonical "$crt" "$ca" "$pem" \
        && vx_cf_rendered_ssl_matches_canonical "$user" "$domain" \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    /usr/bin/openssl x509 -in "$crt" -noout -checkend 86400 >/dev/null 2>&1 \
        && /usr/bin/openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1 \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    cert_key_digest=$(/usr/bin/openssl x509 -in "$crt" -pubkey -noout 2>/dev/null \
        | /usr/bin/openssl pkey -pubin -outform DER 2>/dev/null \
        | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
    private_key_digest=$(/usr/bin/openssl pkey -in "$key" -pubout -outform DER \
        2>/dev/null | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
    fingerprint=$(/usr/bin/openssl x509 -in "$crt" -outform DER 2>/dev/null \
        | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1)
    [[ "$cert_key_digest" =~ ^[a-f0-9]{64}$ \
        && "$cert_key_digest" == "$private_key_digest" \
        && "$fingerprint" == "$expected_fingerprint" ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    san_output=$(/usr/bin/openssl x509 -in "$crt" -noout \
        -ext subjectAltName 2>/dev/null) \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    while IFS= read -r token; do
        token=${token#${token%%[![:space:]]*}}
        token=${token%${token##*[![:space:]]}}
        [[ -n "$token" ]] || continue
        ((token_count++))
        [[ "$token" == DNS:* ]] \
            || { VX_CF_STATUS=certificate_drift; return 1; }
        token=${token#DNS:}
        vx_cf_valid_certificate_hostname "$token" \
            || { VX_CF_STATUS=certificate_drift; return 1; }
        installed_names+=("${token,,}")
    done < <(printf '%s\n' "$san_output" | /usr/bin/sed '1d' \
        | /usr/bin/tr ',' '\n')
    (( token_count >= 1 && token_count == ${#installed_names[@]} )) \
        || { VX_CF_STATUS=certificate_drift; return 1; }
    san_digest=$(printf '%s\n' "${installed_names[@]}" \
        | LC_ALL=C /usr/bin/sort -u | vx_cf_hostname_digest) \
        || { VX_CF_STATUS=state_error; return 1; }
    [[ "$san_digest" == "$expected_digest" ]] \
        || { VX_CF_STATUS=certificate_drift; return 1; }
}

vx_cf_drain_pending_certificate_revokes() {
    local user=$1 domain=$2 certificate_id remaining=''

    for certificate_id in "${VX_CF_CERT_META_PENDING_ID_LIST[@]}"; do
        [[ -n "$certificate_id" ]] || continue
        if vx_cf_origin_get_certificate "$certificate_id"; then
            if [[ "$VX_CF_ORIGIN_REVOKED" != yes ]] \
                && ! vx_cf_origin_revoke_certificate "$certificate_id"; then
                [[ -z "$remaining" ]] && remaining=$certificate_id \
                    || remaining+=",$certificate_id"
            fi
        elif [[ "$VX_CF_STATUS" != not_found ]]; then
            [[ -z "$remaining" ]] && remaining=$certificate_id \
                || remaining+=",$certificate_id"
        fi
    done
    vx_cf_write_certificate_metadata "$user" "$domain" \
        "$VX_CF_CERT_META_ID" "$VX_CF_CERT_META_HOSTNAMES" \
        "$VX_CF_CERT_META_DIGEST" "$remaining" || return 1
    VX_CF_CERT_META_PENDING_IDS=$remaining
    local IFS=,
    read -r -a VX_CF_CERT_META_PENDING_ID_LIST <<<"$remaining"
}

vx_cf_install_origin_certificate() {
    local user=$1 domain=$2 stage=$3 restart=${4:-yes} row ssl command expected_pem
    local canonical_pem rendered_pem

    vx_cf_exact_web_row "$user" "$domain" || return 1
    row=$VX_CF_WEB_ROW
    [[ "$row" =~ (^|[[:space:]])SSL=\'([^\']*)\'([[:space:]]|$) ]] \
        && ssl=${BASH_REMATCH[2]} || ssl=no
    expected_pem="$stage/$domain.pem"
    /usr/bin/cat -- "$stage/$domain.crt" "$stage/$domain.ca" >"$expected_pem" \
        && vx_cf_secure_path "$expected_pem" 0600 \
        || { VX_CF_STATUS=state_error; return 1; }
    if [[ "$ssl" == yes ]]; then
        command="$VESTA/bin/v-change-web-domain-sslcert"
        vx_cf_run_internal_origin_ssl "$command" "$user" "$domain" \
            "$stage" "$restart" \
            || { VX_CF_STATUS=certificate_install_failed; return 1; }
    else
        command="$VESTA/bin/v-add-web-domain-ssl"
        vx_cf_run_internal_origin_ssl "$command" "$user" "$domain" \
            "$stage" same "$restart" \
            || { VX_CF_STATUS=certificate_install_failed; return 1; }
    fi
    vx_cf_rendered_ssl_paths "$user" "$domain" \
        || { VX_CF_STATUS=certificate_install_failed; return 1; }
    canonical_pem="$VESTA/data/users/$user/ssl/$domain.pem"
    rendered_pem="$VX_CF_RENDERED_SSL_DIRECTORY/ssl.$domain.pem"
    [[ -f "$canonical_pem" && ! -L "$canonical_pem" \
        && -f "$rendered_pem" && ! -L "$rendered_pem" ]] \
        && /usr/bin/cp -f -- "$expected_pem" "$canonical_pem" \
        && /usr/bin/cp -f -- "$expected_pem" "$rendered_pem" \
        || { VX_CF_STATUS=certificate_install_failed; return 1; }
    [[ -f "$VESTA/data/users/$user/ssl/$domain.crt" \
        && ! -L "$VESTA/data/users/$user/ssl/$domain.crt" \
        && -f "$VESTA/data/users/$user/ssl/$domain.key" \
        && ! -L "$VESTA/data/users/$user/ssl/$domain.key" \
        && -f "$VESTA/data/users/$user/ssl/$domain.ca" \
        && ! -L "$VESTA/data/users/$user/ssl/$domain.ca" \
        && -f "$VESTA/data/users/$user/ssl/$domain.pem" \
        && ! -L "$VESTA/data/users/$user/ssl/$domain.pem" ]] \
        && /usr/bin/cmp -s "$stage/$domain.crt" \
            "$VESTA/data/users/$user/ssl/$domain.crt" \
        && /usr/bin/cmp -s "$stage/$domain.key" \
            "$VESTA/data/users/$user/ssl/$domain.key" \
        && /usr/bin/cmp -s "$stage/$domain.ca" \
            "$VESTA/data/users/$user/ssl/$domain.ca" \
        && /usr/bin/cmp -s "$expected_pem" \
            "$VESTA/data/users/$user/ssl/$domain.pem" \
        && vx_cf_rendered_ssl_matches_canonical "$user" "$domain" \
        || { VX_CF_STATUS=certificate_install_failed; return 1; }
}

vx_cf_origin_reconcile_locked() {
    local user=$1 domain=$2 restart=${3:-yes} stage snapshot
    local old_id='' old_hostnames='' old_digest='' old_pending=''
    local new_id pending_ids='' rollback_pending='' original_status

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
    # A healthy local/provider certificate is only reusable after the current
    # site routes, edge coverage, and strict settings have all been read back.
    vx_cf_certificate_provider_preflight "$user" "$domain" || return 1
    if vx_cf_certificate_metadata_exists "$user" "$domain"; then
        vx_cf_load_certificate_metadata "$user" "$domain" || return 1
        [[ "$VX_CF_CERT_META_ZONE_ID" == "$VX_CF_ZONE_ID" ]] \
            || { VX_CF_STATUS=ownership_mismatch; return 1; }
        old_id=$VX_CF_CERT_META_ID
        old_hostnames=$VX_CF_CERT_META_HOSTNAMES
        old_digest=$VX_CF_CERT_META_DIGEST
        old_pending=$VX_CF_CERT_META_PENDING_IDS
        if vx_cf_origin_get_certificate "$old_id"; then
            [[ "$VX_CF_ORIGIN_CERTIFICATE_ID" == "$old_id" \
                && "$VX_CF_ORIGIN_HOSTNAMES_DIGEST" == "$old_digest" ]] \
                || { VX_CF_STATUS=ownership_mismatch; return 1; }
            if [[ "$VX_CF_ORIGIN_REVOKED" == no \
                && "$old_digest" == "$VX_CF_CERT_HOSTNAMES_DIGEST" ]] \
                && vx_cf_installed_certificate_health "$user" "$domain" \
                    "$old_digest" "$VX_CF_ORIGIN_CERTIFICATE_FINGERPRINT"; then
                vx_cf_drain_pending_certificate_revokes "$user" "$domain" || :
                VX_CF_STATUS=ssl_unchanged
                return 0
            fi
        elif [[ "$VX_CF_STATUS" != not_found ]]; then
            return 1
        fi
    fi
    stage=$(/usr/bin/mktemp -d "$(vx_cf_runtime_root)/.origin-ssl.XXXXXX") \
        || { VX_CF_STATUS=state_error; return 1; }
    vx_cf_secure_path "$stage" 0700 || {
        /usr/bin/rm -rf -- "$stage"
        VX_CF_STATUS=state_error
        return 1
    }
    snapshot="$stage/previous"
    vx_cf_snapshot_native_ssl "$user" "$domain" "$snapshot" || {
        /usr/bin/rm -rf -- "$stage"
        return 1
    }
    if ! vx_cf_origin_create_certificate "$domain" "$stage"; then
        /usr/bin/rm -rf -- "$stage"
        return 1
    fi
    new_id=$VX_CF_NEW_CERTIFICATE_ID
    pending_ids=$old_pending
    if [[ -n "$old_id" ]]; then
        vx_cf_add_certificate_id "$pending_ids" "$old_id" || {
            vx_cf_origin_revoke_certificate "$new_id" >/dev/null 2>&1 || :
            /usr/bin/rm -rf -- "$stage"
            return 1
        }
        pending_ids=$VX_CF_UPDATED_CERTIFICATE_IDS
    fi
    # Commit exact recovery authority before native mutation. If the process is
    # interrupted, the next reconcile detects local/provider drift and rotates.
    if ! vx_cf_write_certificate_metadata "$user" "$domain" "$new_id" \
        "$VX_CF_CERT_HOSTNAMES_CSV" "$VX_CF_CERT_HOSTNAMES_DIGEST" \
        "$pending_ids"; then
        original_status=${VX_CF_STATUS:-state_error}
        vx_cf_origin_revoke_certificate "$new_id" >/dev/null 2>&1 || :
        /usr/bin/rm -rf -- "$stage"
        VX_CF_STATUS=$original_status
        return 1
    fi
    if ! vx_cf_install_origin_certificate "$user" "$domain" "$stage" "$restart"; then
        original_status=${VX_CF_STATUS:-certificate_install_failed}
        if vx_cf_native_ssl_matches_snapshot "$user" "$domain" "$snapshot" \
            || vx_cf_restore_native_ssl "$user" "$domain" "$snapshot" "$restart"; then
            if [[ -n "$old_id" ]]; then
                rollback_pending=$old_pending
                if ! vx_cf_add_certificate_id "$rollback_pending" "$new_id"; then
                    # Pre-install metadata still names the new certificate and
                    # the prior exact ID. Preserve that recovery authority.
                    VX_CF_STATUS=certificate_restore_failed
                    return 1
                fi
                rollback_pending=$VX_CF_UPDATED_CERTIFICATE_IDS
                if ! vx_cf_write_certificate_metadata "$user" "$domain" "$old_id" \
                    "$old_hostnames" "$old_digest" "$rollback_pending"; then
                    # Never revoke the new ID until durable metadata represents
                    # the restored old active ID and the new pending authority.
                    VX_CF_STATUS=certificate_restore_failed
                    return 1
                fi
                if vx_cf_origin_revoke_certificate "$new_id"; then
                    # If this clearing write fails, the durable pending ID is
                    # intentionally retained for idempotent future cleanup.
                    vx_cf_write_certificate_metadata "$user" "$domain" "$old_id" \
                        "$old_hostnames" "$old_digest" "$old_pending" \
                        >/dev/null 2>&1 || :
                fi
            else
                # With no previous certificate, keep the new active metadata
                # until its exact ID has been safely revoked.
                if vx_cf_origin_revoke_certificate "$new_id"; then
                    vx_cf_remove_certificate_metadata "$user" "$domain" \
                        >/dev/null 2>&1 || :
                fi
            fi
            /usr/bin/rm -rf -- "$stage"
            VX_CF_STATUS=$original_status
            return 1
        fi
        # The new exact ID remains durable metadata authority and may be live;
        # retain the secure snapshot and never revoke it in this state.
        VX_CF_STATUS=certificate_restore_failed
        return 1
    fi
    /usr/bin/rm -rf -- "$stage"
    vx_cf_load_certificate_metadata "$user" "$domain" || return 1
    vx_cf_drain_pending_certificate_revokes "$user" "$domain" || :
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
    vx_cf_drain_pending_certificate_revokes "$user" "$domain" || return 1
    [[ -z "$VX_CF_CERT_META_PENDING_IDS" ]] \
        || { VX_CF_STATUS=certificate_cleanup_pending; return 1; }
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
    if [[ "$VX_CF_ORIGIN_REVOKED" != yes ]]; then
        vx_cf_origin_revoke_certificate "$certificate_id" || return 1
        if vx_cf_origin_get_certificate "$certificate_id"; then
            [[ "$VX_CF_ORIGIN_REVOKED" == yes ]] \
                || { VX_CF_STATUS=revoke_not_confirmed; return 1; }
        elif [[ "$VX_CF_STATUS" != not_found ]]; then
            return 1
        fi
    fi
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
        vx_cf_lookup_any_record "$candidate" || return 1
        [[ "$VX_CF_ANY_RECORD_FOUND" == yes ]] && continue
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
        vx_cf_assert_zone_rotation_safe "$VX_CF_ZONE_ID" || return 1
        vx_cf_zone_enforce_strict "$VX_CF_ZONE_ID" || return 1
        vx_cf_origin_preflight || return 1
        vx_cf_primary_edge_preflight || return 1
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
