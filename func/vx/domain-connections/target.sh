#!/bin/bash

# Shared DNS-only connection target. This state is infrastructure authority,
# never tenant or managed-web-domain metadata.

declare -F vx_cf_root >/dev/null 2>&1 \
    || source "$VESTA/func/vx/cloudflare/main.sh"

vx_domain_connection_target_root() {
    printf '%s\n' "$VESTA/data/vx/domain-connections"
}

vx_domain_connection_target_path() {
    printf '%s/target.conf\n' "$(vx_domain_connection_target_root)"
}

vx_domain_connection_target_prepare_layout() {
    local root
    [[ $EUID == 0 ]] || return 1
    declare -F vx_domain_connection_safe_path >/dev/null || source "$VESTA/func/vx/domain-connections/state.sh"
    vx_domain_connection_safe_path "$VESTA/data" || return 1
    root=$(vx_domain_connection_target_root)
    [[ ! -L "$VESTA/data" && ! -L "$VESTA/data/vx" && ! -L "$root" ]] || return 1
    vx_domain_connection_prepare
}

vx_domain_connection_target_valid_address() {
    local type=$1 address=$2
    case "$type" in
        A) vx_cf_valid_ipv4 "$address" ;;
        AAAA) vx_cf_valid_ipv6 "$address" ;;
        *) return 1 ;;
    esac
}

vx_domain_connection_target_parse_file() {
    local path=$1 line key value
    local schema_seen=0 target_seen=0 zone_seen=0 a_id_seen=0 ipv4_seen=0 \
        aaaa_id_seen=0 ipv6_seen=0

    VX_DOMAIN_CONNECTION_TARGET_FQDN=''
    VX_DOMAIN_CONNECTION_TARGET_ZONE_ID=''
    VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID=''
    VX_DOMAIN_CONNECTION_TARGET_IPV4=''
    VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID=''
    VX_DOMAIN_CONNECTION_TARGET_IPV6=''
    declare -F vx_domain_connection_safe_path >/dev/null || source "$VESTA/func/vx/domain-connections/state.sh"
    vx_domain_connection_safe_path "$path" file || { VX_DOMAIN_CONNECTION_TARGET_STATUS=not_configured; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z0-9_]+)=\'([^\']*)\'$ ]] || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_config; return 1;
        }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            SCHEMA) (( schema_seen++ == 0 )) || return 1; [[ "$value" == 1 ]] || return 1 ;;
            TARGET_FQDN) (( target_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_FQDN=$value ;;
            ZONE_ID) (( zone_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_ZONE_ID=$value ;;
            A_RECORD_ID) (( a_id_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID=$value ;;
            IPV4) (( ipv4_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_IPV4=$value ;;
            AAAA_RECORD_ID) (( aaaa_id_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID=$value ;;
            IPV6) (( ipv6_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_TARGET_IPV6=$value ;;
            *) VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_config; return 1 ;;
        esac
    done <"$path"
    [[ $schema_seen -eq 1 && $target_seen -eq 1 && $zone_seen -eq 1 \
        && $a_id_seen -eq 1 && $ipv4_seen -eq 1 && $aaaa_id_seen -eq 1 \
        && $ipv6_seen -eq 1 \
        && "$VX_DOMAIN_CONNECTION_TARGET_ZONE_ID" =~ ^[a-f0-9]{32}$ \
        && "$VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID" =~ ^[a-f0-9]{32}$ ]] \
        && vx_cf_valid_domain "$VX_DOMAIN_CONNECTION_TARGET_FQDN" \
        && vx_cf_valid_ipv4 "$VX_DOMAIN_CONNECTION_TARGET_IPV4" || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_config; return 1;
        }
    if [[ -n "$VX_DOMAIN_CONNECTION_TARGET_IPV6" ]]; then
        [[ "$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID" =~ ^[a-f0-9]{32}$ ]] \
            && vx_cf_valid_ipv6 "$VX_DOMAIN_CONNECTION_TARGET_IPV6" || {
                VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_config; return 1;
            }
    else
        [[ -z "$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID" ]] || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_config; return 1;
        }
    fi
}

vx_domain_connection_target_parse_input() {
    local path=$1 line key value
    local target_seen=0 ipv4_seen=0 ipv6_seen=0 accepted_seen=0 coordinated_seen=0

    VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN=''
    VX_DOMAIN_CONNECTION_INPUT_IPV4=''
    VX_DOMAIN_CONNECTION_INPUT_IPV6=''
    VX_DOMAIN_CONNECTION_INPUT_IPV6_ACCEPTED=no
    VX_DOMAIN_CONNECTION_INPUT_COORDINATED_INGRESS_CHANGE=no
    vx_cf_secure_regular_file "$path" || { VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_input; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([A-Z0-9_]+)=\'([^\']*)\'$ ]] || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_input; return 1;
        }
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "$key" in
            TARGET_FQDN) (( target_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN=${value,,} ;;
            IPV4) (( ipv4_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_INPUT_IPV4=$value ;;
            IPV6) (( ipv6_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_INPUT_IPV6=$value ;;
            IPV6_ACCEPTED) (( accepted_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_INPUT_IPV6_ACCEPTED=$value ;;
            COORDINATED_INGRESS_CHANGE) (( coordinated_seen++ == 0 )) || return 1; VX_DOMAIN_CONNECTION_INPUT_COORDINATED_INGRESS_CHANGE=$value ;;
            *) VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_input; return 1 ;;
        esac
    done <"$path"
    [[ $target_seen -eq 1 && $ipv4_seen -eq 1 && $ipv6_seen -eq 1 \
        && $accepted_seen -eq 1 && $coordinated_seen -eq 1 \
        && "$VX_DOMAIN_CONNECTION_INPUT_IPV6_ACCEPTED" =~ ^(yes|no)$ \
        && "$VX_DOMAIN_CONNECTION_INPUT_COORDINATED_INGRESS_CHANGE" =~ ^(yes|no)$ ]] \
        && vx_cf_valid_domain "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" \
        && vx_cf_valid_ipv4 "$VX_DOMAIN_CONNECTION_INPUT_IPV4" || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_input; return 1;
        }
    if [[ -n "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ]]; then
        [[ "$VX_DOMAIN_CONNECTION_INPUT_IPV6_ACCEPTED" == yes ]] \
            && vx_cf_valid_ipv6 "$VX_DOMAIN_CONNECTION_INPUT_IPV6" || {
                VX_DOMAIN_CONNECTION_TARGET_STATUS=ipv6_not_accepted; return 1;
            }
    elif [[ "$VX_DOMAIN_CONNECTION_INPUT_IPV6_ACCEPTED" == yes ]]; then
        VX_DOMAIN_CONNECTION_TARGET_STATUS=invalid_input
        return 1
    fi
}

vx_domain_connection_target_has_connections() {
    local root
    root="$(vx_domain_connection_target_root)/hostnames"
    [[ -e "$root" && ! -L "$root" ]] || return 1
    [[ -d "$root" ]] || return 0
    /usr/bin/find "$root" -mindepth 1 -maxdepth 1 -name '*.json' -print -quit 2>/dev/null | /usr/bin/grep -q .
}

vx_domain_connection_target_record_get() {
    local record_id=$1 type=$2 response
    response=$(vx_cf_new_response_file) || { VX_DOMAIN_CONNECTION_TARGET_STATUS=state_error; return 1; }
    if ! vx_cf_transport GET "dns_records/$record_id" "$response"; then
        /usr/bin/rm -f -- "$response"; VX_DOMAIN_CONNECTION_TARGET_STATUS=${VX_CF_STATUS:-provider_error}; return 1
    fi
    if ! vx_cf_response_success "$response" || ! /usr/bin/jq -e --arg type "$type" '
        (.result | type == "object") and (.result.id | type == "string") and
        (.result.type == $type) and (.result.name | type == "string") and
        (.result.content | type == "string") and (.result.ttl | type == "number") and
        (.result.proxied == false)
    ' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"; VX_DOMAIN_CONNECTION_TARGET_STATUS=${VX_CF_STATUS:-malformed_response}; return 1
    fi
    VX_DOMAIN_CONNECTION_TARGET_RECORD_ID=$(/usr/bin/jq -r '.result.id' "$response")
    VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME=$(/usr/bin/jq -r '.result.name' "$response")
    VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS=$(/usr/bin/jq -r '.result.content' "$response")
    VX_DOMAIN_CONNECTION_TARGET_RECORD_TTL=$(/usr/bin/jq -r '.result.ttl' "$response")
    VX_DOMAIN_CONNECTION_TARGET_RECORD_PROXIED=$(/usr/bin/jq -r '.result.proxied' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ID" == "$record_id" \
        && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_TTL" == 1 \
        && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_PROXIED" == false ]] \
        && vx_cf_valid_domain "$VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME" \
        && vx_domain_connection_target_valid_address "$type" "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS" || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=malformed_response; return 1;
        }
}

# Persist the complete requested change before touching either address family.
# A provider comment binds interrupted POST recovery to this exact operation.
vx_domain_connection_target_intent() {
    local path="$(vx_domain_connection_target_root)/target-operation.json" payload temp
    if [[ -e "$path" || -L "$path" ]]; then
        vx_domain_connection_safe_path "$path" file || return 1
        jq -e --arg zone "$VX_CF_ZONE_ID" --arg name "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" --arg ipv4 "$VX_DOMAIN_CONNECTION_INPUT_IPV4" --arg ipv6 "$VX_DOMAIN_CONNECTION_INPUT_IPV6" '.ZONE_ID==$zone and .NAME==$name and .IPV4==$ipv4 and .IPV6==$ipv6' "$path" >/dev/null || { VX_DOMAIN_CONNECTION_TARGET_STATUS=target_recovery_required; return 1; }
    else
        temp=$(mktemp "$(vx_domain_connection_target_root)/.target-operation.XXXXXX") || return 1
        jq -cn --arg zone "$VX_CF_ZONE_ID" --arg name "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" --arg ipv4 "$VX_DOMAIN_CONNECTION_INPUT_IPV4" --arg ipv6 "$VX_DOMAIN_CONNECTION_INPUT_IPV6" --arg token "$(head -c 32 /dev/urandom | sha256sum | cut -c1-32)" '{ZONE_ID:$zone,NAME:$name,IPV4:$ipv4,IPV6:$ipv6,TOKEN:$token,CREATE_AUTHORIZED:{}}' >"$temp" || return 1
        chmod 600 "$temp" && vx_domain_connection_atomic_replace "$temp" "$path" || return 1
    fi
    VX_DOMAIN_CONNECTION_TARGET_OPERATION_TOKEN=$(jq -er '.TOKEN | select(test("^[a-f0-9]{32}$"))' "$path")
}

vx_domain_connection_target_authorize_post() {
    local type=$1 path="$(vx_domain_connection_target_root)/target-operation.json" temp
    temp=$(mktemp "$(vx_domain_connection_target_root)/.target-operation.XXXXXX") || return 1
    jq --arg type "$type" '.CREATE_AUTHORIZED[$type]=true' "$path" >"$temp" || return 1
    chmod 600 "$temp" && vx_domain_connection_atomic_replace "$temp" "$path"
}

vx_domain_connection_target_recover_post() {
    local type=$1 name=$2 address=$3 response
    response=$(vx_cf_new_response_file) || return 1
    if ! vx_cf_transport GET "dns_records?type=$type&name=$name&per_page=100" "$response" || ! vx_cf_response_success "$response"; then rm -f "$response"; return 1; fi
    if ! jq -e --arg type "$type" --arg name "$name" --arg address "$address" --arg comment "vx-domain-connection-target:$VX_DOMAIN_CONNECTION_TARGET_OPERATION_TOKEN" '
        (.result|length)==1 and (.result[0] | .type==$type and .name==$name and .content==$address and .ttl==1 and .proxied==false and .comment==$comment and (.id|test("^[a-f0-9]{32}$")))' "$response" >/dev/null; then rm -f "$response"; return 1; fi
    VX_DOMAIN_CONNECTION_TARGET_RECORD_ID=$(jq -r '.result[0].id' "$response")
    rm -f "$response"
}

vx_domain_connection_target_record_mutate() {
    local method=$1 api_path=$2 type=$3 name=$4 address=$5 expected_id=${6:-}
    local body response
    body=$(/usr/bin/mktemp "$(vx_cf_runtime_root)/.target-body.XXXXXX") || return 1
    response=$(vx_cf_new_response_file) || { /usr/bin/rm -f -- "$body"; return 1; }
    vx_cf_secure_path "$body" 0600 || { /usr/bin/rm -f -- "$body" "$response"; return 1; }
    /usr/bin/jq -nc --arg type "$type" --arg name "$name" --arg address "$address" --arg comment "vx-domain-connection-target:$VX_DOMAIN_CONNECTION_TARGET_OPERATION_TOKEN" \
        '{type:$type,name:$name,content:$address,ttl:1,proxied:false,comment:$comment}' >"$body" || return 1
    if ! vx_cf_transport "$method" "$api_path" "$response" "$body"; then
        /usr/bin/rm -f -- "$body" "$response"; VX_DOMAIN_CONNECTION_TARGET_STATUS=${VX_CF_STATUS:-provider_error}; return 1
    fi
    /usr/bin/rm -f -- "$body"
    if ! vx_cf_response_success "$response" || ! /usr/bin/jq -e --arg type "$type" \
        --arg name "$name" --arg address "$address" --arg id "$expected_id" '
        .result | type == "object" and (.id | type == "string") and
        (.type == $type) and (.name == $name) and (.content == $address) and
        (.ttl == 1) and (.proxied == false) and ($id == "" or .id == $id)
    ' "$response" >/dev/null 2>&1; then
        /usr/bin/rm -f -- "$response"; VX_DOMAIN_CONNECTION_TARGET_STATUS=${VX_CF_STATUS:-malformed_response}; return 1
    fi
    VX_DOMAIN_CONNECTION_TARGET_RECORD_ID=$(/usr/bin/jq -r '.result.id' "$response")
    /usr/bin/rm -f -- "$response"
    [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ID" =~ ^[a-f0-9]{32}$ ]] || {
        VX_DOMAIN_CONNECTION_TARGET_STATUS=malformed_response; return 1;
    }
}

vx_domain_connection_target_reconcile_record() {
    local type=$1 name=$2 address=$3 record_id=$4 response
    if [[ -n "$record_id" ]]; then
        if vx_domain_connection_target_record_get "$record_id" "$type"; then
            if [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME" == "$name" \
                && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS" == "$address" ]]; then
                VX_DOMAIN_CONNECTION_TARGET_RESULT_ID=$record_id
                return 0
            fi
            if ! vx_domain_connection_target_record_mutate PUT "dns_records/$record_id" "$type" \
                "$name" "$address" "$record_id"; then
                # A timed-out PUT may still have committed. Exact-ID readback
                # is the only safe recovery; do not issue a second mutation.
                vx_domain_connection_target_record_get "$record_id" "$type" || return 1
                [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME" == "$name" \
                    && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS" == "$address" ]] \
                    || return 1
            fi
            VX_DOMAIN_CONNECTION_TARGET_RESULT_ID=$VX_DOMAIN_CONNECTION_TARGET_RECORD_ID
            return 0
        fi
        [[ "$VX_DOMAIN_CONNECTION_TARGET_STATUS" == not_found ]] || return 1
    fi
    if jq -e --arg type "$type" '.CREATE_AUTHORIZED[$type]==true' "$(vx_domain_connection_target_root)/target-operation.json" >/dev/null; then
        if vx_domain_connection_target_recover_post "$type" "$name" "$address"; then
            VX_DOMAIN_CONNECTION_TARGET_RESULT_ID=$VX_DOMAIN_CONNECTION_TARGET_RECORD_ID; return 0
        fi
    fi
    # Reject same-family and CNAME collisions while allowing our own other
    # admitted family. An unrelated existing record is never adopted.
    response=$(vx_cf_new_response_file) || return 1
    vx_cf_transport GET "dns_records?name=$name&per_page=100" "$response" && vx_cf_response_success "$response" || { rm -f "$response"; return 1; }
    if ! jq -e --arg type "$type" --arg a "$VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID" --arg aaaa "$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID" 'all(.result[]; .type!=$type and .type!="CNAME" and (.id==$a or .id==$aaaa))' "$response" >/dev/null; then
        rm -f "$response"; VX_DOMAIN_CONNECTION_TARGET_STATUS=ownership_mismatch; return 1
    fi
    rm -f "$response"
    vx_domain_connection_target_authorize_post "$type" || return 1
    if ! vx_domain_connection_target_record_mutate POST dns_records "$type" "$name" "$address"; then
        vx_domain_connection_target_recover_post "$type" "$name" "$address" || return 1
    fi
    VX_DOMAIN_CONNECTION_TARGET_RESULT_ID=$VX_DOMAIN_CONNECTION_TARGET_RECORD_ID
}

vx_domain_connection_target_write() {
    local target temporary
    target=$(vx_domain_connection_target_path)
    [[ ! -L "$target" ]] || return 1
    temporary=$(/usr/bin/mktemp "$(vx_domain_connection_target_root)/.target.XXXXXX") || return 1
    vx_cf_secure_path "$temporary" 0600 || { /usr/bin/rm -f -- "$temporary"; return 1; }
    {
        printf "SCHEMA='1'\nTARGET_FQDN='%s'\nZONE_ID='%s'\nA_RECORD_ID='%s'\nIPV4='%s'\nAAAA_RECORD_ID='%s'\nIPV6='%s'\n" \
            "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" "$VX_CF_ZONE_ID" \
            "$VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID" "$VX_DOMAIN_CONNECTION_INPUT_IPV4" \
            "$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID" "$VX_DOMAIN_CONNECTION_INPUT_IPV6"
    } >"$temporary" && vx_domain_connection_atomic_replace "$temporary" "$target" || {
        /usr/bin/rm -f -- "$temporary"; return 1;
    }
}

vx_domain_connection_target_configure_locked() {
    local input=$1 old_ipv4='' old_ipv6='' old_target='' old_a='' old_aaaa=''
    vx_domain_connection_target_parse_input "$input" || return 1
    vx_cf_load_config || { VX_DOMAIN_CONNECTION_TARGET_STATUS=${VX_CF_STATUS:-not_configured}; return 1; }
    vx_domain_connection_target_prepare_layout || { VX_DOMAIN_CONNECTION_TARGET_STATUS=state_error; return 1; }
    VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID='' VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID=''
    if [[ -e "$(vx_domain_connection_target_path)" || -L "$(vx_domain_connection_target_path)" ]]; then
        vx_domain_connection_target_parse_file "$(vx_domain_connection_target_path)" || return 1
        old_ipv4=$VX_DOMAIN_CONNECTION_TARGET_IPV4; old_ipv6=$VX_DOMAIN_CONNECTION_TARGET_IPV6
        old_target=$VX_DOMAIN_CONNECTION_TARGET_FQDN; old_a=$VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID
        old_aaaa=$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID
        [[ "$VX_DOMAIN_CONNECTION_TARGET_ZONE_ID" == "$VX_CF_ZONE_ID" ]] || {
            VX_DOMAIN_CONNECTION_TARGET_STATUS=zone_mismatch; return 1;
        }
    fi
    if [[ -n "$old_target" && ( "$old_target" != "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" \
        || "$old_ipv4" != "$VX_DOMAIN_CONNECTION_INPUT_IPV4" \
        || "$old_ipv6" != "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ) ]] \
        && vx_domain_connection_target_has_connections \
        && [[ "$VX_DOMAIN_CONNECTION_INPUT_COORDINATED_INGRESS_CHANGE" != yes ]]; then
        VX_DOMAIN_CONNECTION_TARGET_STATUS=connections_require_coordination
        return 1
    fi
    if [[ -n "$old_aaaa" && -z "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ]]; then VX_DOMAIN_CONNECTION_TARGET_STATUS=ipv6_removal_requires_migration; return 1; fi
    vx_domain_connection_target_intent || return 1
    vx_domain_connection_target_reconcile_record A "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" \
        "$VX_DOMAIN_CONNECTION_INPUT_IPV4" "$old_a" || return 1
    VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID=$VX_DOMAIN_CONNECTION_TARGET_RESULT_ID
    VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID=''
    if [[ -n "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ]]; then
        vx_domain_connection_target_reconcile_record AAAA "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" \
            "$VX_DOMAIN_CONNECTION_INPUT_IPV6" "$old_aaaa" || return 1
        VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID=$VX_DOMAIN_CONNECTION_TARGET_RESULT_ID
    elif [[ -n "$old_aaaa" ]]; then
        # Removing an admitted IPv6 path is a coordinated ingress change; do
        # not remove the provider record automatically because it is shared.
        VX_DOMAIN_CONNECTION_TARGET_STATUS=ipv6_removal_requires_migration
        return 1
    fi
    vx_domain_connection_target_record_get "$VX_DOMAIN_CONNECTION_TARGET_A_RECORD_ID" A || return 1
    [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME" == "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS" == "$VX_DOMAIN_CONNECTION_INPUT_IPV4" ]] || { VX_DOMAIN_CONNECTION_TARGET_STATUS=readback_mismatch; return 1; }
    if [[ -n "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ]]; then
        vx_domain_connection_target_record_get "$VX_DOMAIN_CONNECTION_TARGET_AAAA_RECORD_ID" AAAA || return 1
        [[ "$VX_DOMAIN_CONNECTION_TARGET_RECORD_NAME" == "$VX_DOMAIN_CONNECTION_INPUT_TARGET_FQDN" && "$VX_DOMAIN_CONNECTION_TARGET_RECORD_ADDRESS" == "$VX_DOMAIN_CONNECTION_INPUT_IPV6" ]] || { VX_DOMAIN_CONNECTION_TARGET_STATUS=readback_mismatch; return 1; }
    fi
    vx_domain_connection_target_write || { VX_DOMAIN_CONNECTION_TARGET_STATUS=state_error; return 1; }
    vx_domain_connection_target_parse_file "$(vx_domain_connection_target_path)" || return 1
    rm -f -- "$(vx_domain_connection_target_root)/target-operation.json" || return 1
    VX_DOMAIN_CONNECTION_TARGET_STATUS=ready
}

vx_domain_connection_target_configure_from_file() {
    vx_cf_with_lock vx_domain_connection_target_configure_locked "$1"
}

vx_domain_connection_target_read_json() {
    vx_domain_connection_target_parse_file "$(vx_domain_connection_target_path)" || return 1
    /usr/bin/jq -nc --arg target "$VX_DOMAIN_CONNECTION_TARGET_FQDN" \
        --arg ipv4 "$VX_DOMAIN_CONNECTION_TARGET_IPV4" --arg ipv6 "$VX_DOMAIN_CONNECTION_TARGET_IPV6" \
        '{TARGET_FQDN:$target,IPV4:$ipv4,IPV6:$ipv6,INGRESS_FAMILIES:(if $ipv6 == "" then ["IPv4"] else ["IPv4","IPv6"] end)}'
}

vx_domain_connection_target_dns_observe() {
    local hostname=$1 target=$2 cname='' dig_binary=${VX_DOMAIN_CONNECTION_TEST_DIG:-/usr/bin/dig}
    vx_cf_valid_domain "$hostname" && vx_cf_valid_domain "$target" || return 1
    [[ "$dig_binary" == /usr/bin/dig || ( "${VX_CLOUDFLARE_TEST_MODE:-}" == yes && -x "$dig_binary" ) ]] || return 1
    cname=$(/usr/bin/timeout 5 "$dig_binary" +time=2 +tries=1 +short CNAME "$hostname" 2>/dev/null | /usr/bin/head -n1) || cname=''
    cname=${cname%.}; cname=${cname,,}
    [[ -z "$cname" ]] || vx_cf_valid_domain "$cname" || cname=''
    /usr/bin/jq -nc --arg hostname "$hostname" --arg target "$target" --arg cname "$cname" \
        '{HOSTNAME:$hostname,TARGET_FQDN:$target,CNAME:$cname,MATCHES:($cname == $target)}'
}
