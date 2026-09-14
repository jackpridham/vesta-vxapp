#!/bin/bash
# Native Vesta child authority for verified customer domain connections.

vx_domain_connection_native_record_load() {
    local record=$1
    VX_DC_OWNER='' VX_DC_TECHNICAL_FQDN='' VX_DC_HOSTNAME=''
    VX_DC_CONNECTION_ID='' VX_DC_GENERATION='' VX_DC_STATE=''
    [[ -f "$record" && ! -L "$record" ]] || return 1
    [[ $(/usr/bin/stat -c '%u:%a:%h' "$record" 2>/dev/null) == 0:600:1 ]] || return 1
    vx_domain_connection_safe_path "$record" file || return 1
    VX_DC_OWNER=$(/usr/bin/jq -r '.OWNER // empty' "$record")
    VX_DC_TECHNICAL_FQDN=$(/usr/bin/jq -r '.TECHNICAL_FQDN // empty' "$record")
    VX_DC_HOSTNAME=$(/usr/bin/jq -r '.HOSTNAME // empty' "$record")
    VX_DC_CONNECTION_ID=$(/usr/bin/jq -r '.CONNECTION_ID // empty' "$record")
    VX_DC_GENERATION=$(/usr/bin/jq -r '.GENERATION // empty' "$record")
    VX_DC_STATE=$(/usr/bin/jq -r '.STATE // empty' "$record")
    /usr/bin/jq -e 'type == "object"' "$record" >/dev/null || return 1
    [[ "$VX_DC_OWNER" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ \
        && "$VX_DC_TECHNICAL_FQDN" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ \
        && "$VX_DC_HOSTNAME" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ \
        && "$VX_DC_CONNECTION_ID" =~ ^[A-Za-z0-9_-]{1,80}$ \
        && "$VX_DC_GENERATION" =~ ^[0-9]+$ ]] || return 1
}

vx_domain_connection_native_row() {
    local owner=$1 hostname=$2 conf
    conf="$VESTA/data/users/$owner/web.conf"
    VX_DC_ROW=''
    [[ -f "$conf" && ! -L "$conf" && ! -L "${conf%/*}" ]] || return 1
    mapfile -t VX_DC_ROWS < <(/usr/bin/grep -F "DOMAIN='$hostname'" "$conf" 2>/dev/null || :)
    [[ ${#VX_DC_ROWS[@]} -eq 1 && "${VX_DC_ROWS[0]}" == "DOMAIN='$hostname'"* ]] || return 1
    VX_DC_ROW=${VX_DC_ROWS[0]}
}

vx_domain_connection_native_value() {
    local row=$1 key=$2
    /usr/bin/sed -n "s/.*[[:space:]]${key}='\\([^']*\\)'.*/\\1/p" <<<" $row"
}

vx_domain_connection_native_hostname_in_use() {
    local hostname=$1 conf
    [[ "$hostname" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] || return 10
    for conf in "$VESTA"/data/users/*/web.conf; do
        [[ ! -L "$conf" && ! -L "${conf%/*}" ]] || return 1
        [[ -f "$conf" ]] || continue
        /usr/bin/grep -Fq "DOMAIN='$hostname'" "$conf" && return 10
        /usr/bin/grep -Eq "ALIAS='([^']*,)?${hostname//./\\.}(,[^']*)?'" "$conf" && return 10
    done
    return 0
}

vx_domain_connection_native_parent_binding() {
    vx_domain_connection_native_row "$VX_DC_OWNER" "$VX_DC_TECHNICAL_FQDN" || return 1
    [[ $(vx_domain_connection_native_value "$VX_DC_ROW" LETSENCRYPT) != yes \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" SSL) == yes \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" SUSPENDED) != yes \
        && -z $(vx_domain_connection_native_value "$VX_DC_ROW" VX_CONNECTION_ID) ]] || return 1
    [[ -f "$VESTA/data/users/$VX_DC_OWNER/user.conf" && ! -L "$VESTA/data/users/$VX_DC_OWNER/user.conf" ]] || return 1
    ! /usr/bin/grep -q "SUSPENDED='yes'" "$VESTA/data/users/$VX_DC_OWNER/user.conf" || return 1
    declare -F vx_cf_load_metadata >/dev/null || source "$VESTA/func/vx/cloudflare/main.sh"
    vx_cf_native_web_authority_preflight "$VX_DC_OWNER" "$VX_DC_TECHNICAL_FQDN" || return 1
    [[ "$VX_CF_WEB_AUTHORITY_STATE" == managed ]] || return 1
    VX_DC_PARENT_IP=$(vx_domain_connection_native_value "$VX_DC_ROW" IP)
    VX_DC_PARENT_TPL=$(vx_domain_connection_native_value "$VX_DC_ROW" TPL)
    VX_DC_PARENT_BACKEND=$(vx_domain_connection_native_value "$VX_DC_ROW" BACKEND)
    VX_DC_PARENT_PROXY=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY)
    VX_DC_PARENT_PROXY_EXT=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_EXT)
    VX_DC_PARENT_PROXY_MODE=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_MODE)
    VX_DC_PARENT_PROXY_TARGET=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_TARGET)
    VX_DC_PARENT_PROXY_PRESERVE_HOST=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_PRESERVE_HOST)
    VX_DC_PARENT_PROXY_PROFILE=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_PROFILE)
    VX_DC_PARENT_PROXY_TIMEOUT=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_TIMEOUT)
    VX_DC_PARENT_PROXY_HEADERS=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_HEADERS)
    VX_DC_PARENT_PROXY_PATH=$(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_PATH)
    [[ "$VX_DC_PARENT_PROXY" == vx-proxy && "$VX_DC_PARENT_PROXY_MODE" == proxy \
        && -n "$VX_DC_PARENT_PROXY_TARGET" ]] || return 1
    VX_DC_PARENT_PROXY_PATH=${VX_DC_PARENT_PROXY_PATH:-/}

}

vx_domain_connection_native_marker_matches() {
    vx_domain_connection_native_row "$VX_DC_OWNER" "$VX_DC_HOSTNAME" || return 1
    [[ $(vx_domain_connection_native_value "$VX_DC_ROW" VX_CONNECTION_ID) == "$VX_DC_CONNECTION_ID" \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" VX_CONNECTION_PARENT) == "$VX_DC_TECHNICAL_FQDN" \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" VX_CONNECTION_GENERATION) == "$VX_DC_GENERATION" ]]
}

vx_domain_connection_native_apply_binding() {
    local mode=$1 domain=$VX_DC_HOSTNAME
    add_object_key web DOMAIN "$domain" VX_CONNECTION_ID STATS
    add_object_key web DOMAIN "$domain" VX_CONNECTION_PARENT STATS
    add_object_key web DOMAIN "$domain" VX_CONNECTION_GENERATION STATS
    update_object_value web DOMAIN "$domain" '$VX_CONNECTION_ID' "$VX_DC_CONNECTION_ID"
    update_object_value web DOMAIN "$domain" '$VX_CONNECTION_PARENT' "$VX_DC_TECHNICAL_FQDN"
    update_object_value web DOMAIN "$domain" '$VX_CONNECTION_GENERATION' "$VX_DC_GENERATION"
    update_object_value web DOMAIN "$domain" '$IP' "$VX_DC_PARENT_IP"
    update_object_value web DOMAIN "$domain" '$TPL' "$VX_DC_PARENT_TPL"
    update_object_value web DOMAIN "$domain" '$BACKEND' "$VX_DC_PARENT_BACKEND"
    update_object_value web DOMAIN "$domain" '$PROXY' "$VX_DC_PARENT_PROXY"
    update_object_value web DOMAIN "$domain" '$PROXY_EXT' "$VX_DC_PARENT_PROXY_EXT"
    update_object_value web DOMAIN "$domain" '$PROXY_MODE' "$mode"
    update_object_value web DOMAIN "$domain" '$PROXY_TARGET' "$VX_DC_PARENT_PROXY_TARGET"
    update_object_value web DOMAIN "$domain" '$PROXY_PRESERVE_HOST' "$VX_DC_PARENT_PROXY_PRESERVE_HOST"
    update_object_value web DOMAIN "$domain" '$PROXY_PROFILE' "$VX_DC_PARENT_PROXY_PROFILE"
    update_object_value web DOMAIN "$domain" '$PROXY_TIMEOUT' "$VX_DC_PARENT_PROXY_TIMEOUT"
    update_object_value web DOMAIN "$domain" '$PROXY_HEADERS' "$VX_DC_PARENT_PROXY_HEADERS"
    update_object_value web DOMAIN "$domain" '$PROXY_PATH' "$VX_DC_PARENT_PROXY_PATH"
}

# These callbacks run while the worker owns the owner and exact hostname locks.
# Exported descriptors retain the same locked open file description in native
# subprocesses; environment flags alone never grant a lifecycle capability.
vx_domain_connection_native_context() {
    local record=$1 lock fd
    [[ $EUID == 0 ]] || return 1
    vx_domain_connection_native_record_load "$record" || return 1
    [[ "$record" == "$(vx_domain_connection_record_path "$VX_DC_HOSTNAME")" ]] || return 1
    local expected index=0
    for fd in "${VX_DOMAIN_CONNECTION_OWNER_LOCK_FD:-}" "${VX_DOMAIN_CONNECTION_LOCK_FD:-}"; do
        [[ "$fd" =~ ^[0-9]+$ ]] || return 1
        lock=$(/usr/bin/readlink "/proc/self/fd/$fd") || return 1
        if (( index == 0 )); then expected="$(vx_domain_connection_root)/.$VX_DC_OWNER.lock"
        else expected="$(vx_domain_connection_hostname_root)/.$(vx_domain_connection_hash "$VX_DC_HOSTNAME").lock"; fi
        [[ "$lock" == "$expected" ]] || return 1
        /usr/bin/flock -n "$fd" || return 1
        index=$((index + 1))
    done
    export VX_DOMAIN_CONNECTION_OWNER_LOCK_FD VX_DOMAIN_CONNECTION_LOCK_FD
}

vx_domain_connection_native_creation_values() {
    vx_domain_connection_native_context "$VX_DOMAIN_CONNECTION_RECORD" || return 1
    vx_domain_connection_native_parent_binding || return 1
    WEB_TEMPLATE=$VX_DC_PARENT_TPL BACKEND_TEMPLATE=$VX_DC_PARENT_BACKEND
    PROXY_TEMPLATE=vx-proxy PROXY=vx-proxy PROXY_MODE=holding
    PROXY_TARGET=$VX_DC_PARENT_PROXY_TARGET PROXY_PROFILE=$VX_DC_PARENT_PROXY_PROFILE
    PROXY_PRESERVE_HOST=$VX_DC_PARENT_PROXY_PRESERVE_HOST PROXY_TIMEOUT=$VX_DC_PARENT_PROXY_TIMEOUT
    PROXY_HEADERS=$VX_DC_PARENT_PROXY_HEADERS PROXY_PATH=$VX_DC_PARENT_PROXY_PATH
    VX_CONNECTION_ID=$VX_DC_CONNECTION_ID VX_CONNECTION_PARENT=$VX_DC_TECHNICAL_FQDN
    VX_CONNECTION_GENERATION=$VX_DC_GENERATION
}

vx_domain_connection_native_create() (
    local record=$1
    vx_domain_connection_native_context "$record" || return 1
    vx_domain_connection_native_parent_binding || return 1
    if vx_domain_connection_native_hostname_in_use "$VX_DC_HOSTNAME"; then
        export VX_DOMAIN_CONNECTION_RECORD="$record" VX_DOMAIN_CONNECTION_NATIVE_CREATE=1
        "$BIN/v-add-web-domain" "$VX_DC_OWNER" "$VX_DC_HOSTNAME" "$VX_DC_PARENT_IP" no none "$VX_DC_PARENT_PROXY_EXT" >/dev/null 2>&1 || :
    fi
    # An exact protected marker and binding reconciles a lost command response;
    # the name alone can never turn a pre-existing row into connection authority.
    vx_domain_connection_native_marker_matches || return 1
    [[ -z $(vx_domain_connection_native_value "$VX_DC_ROW" ALIAS) ]] || return 1
    if ! vx_domain_connection_native_binding_matches holding; then
        vx_domain_connection_native_binding_matches proxy \
            && [[ $(vx_domain_connection_native_value "$VX_DC_ROW" SSL) == yes \
                && $(vx_domain_connection_native_value "$VX_DC_ROW" LETSENCRYPT) == yes ]] || return 1
    fi
    vx_domain_connection_native_configtest && vx_domain_connection_native_restart
)

vx_domain_connection_native_binding_matches() {
    local mode=$1 child=$VX_DC_ROW key expected
    vx_domain_connection_native_parent_binding || return 1
    for key in IP TPL BACKEND PROXY PROXY_EXT PROXY_MODE PROXY_TARGET PROXY_PRESERVE_HOST PROXY_PROFILE PROXY_TIMEOUT PROXY_HEADERS PROXY_PATH; do
        expected="VX_DC_PARENT_$key"; expected=${!expected}
        [[ "$key" != PROXY_MODE ]] || expected=$mode
        [[ $(vx_domain_connection_native_value "$child" "$key") == "$expected" ]] || { VX_DC_ROW=$child; return 1; }
    done
    VX_DC_ROW=$child
}

vx_domain_connection_native_render() (
    vx_domain_connection_native_record_load "$(vx_domain_connection_record_path "$VX_DC_HOSTNAME")" || return 1
    vx_domain_connection_native_marker_matches || return 1
    local user=$VX_DC_OWNER domain=$VX_DC_HOSTNAME
    USER_DATA="$VESTA/data/users/$user"
    source "$VESTA/func/domain.sh"
    get_domain_values web
    local_ip=$(get_real_ip "$IP")
    prepare_web_domain_values
    add_web_config "$WEB_SYSTEM" "$TPL.tpl" || return 1
    add_web_config "$PROXY_SYSTEM" "$PROXY.tpl" || return 1
    if [[ "$SSL" == yes ]]; then
        add_web_config "$WEB_SYSTEM" "$TPL.stpl" || return 1
        add_web_config "$PROXY_SYSTEM" "$PROXY.stpl" || return 1
    fi
)

vx_domain_connection_native_configtest() (
    local service_name service_limit
    for service_name in "$WEB_SYSTEM" "$PROXY_SYSTEM"; do
        [[ -n "$service_name" && "$service_name" != remote ]] || continue
        case "$service_name" in
            apache2)
                # Some packaged init scripts do not expose configtest.
                /usr/sbin/apache2ctl configtest >/dev/null 2>&1 || return 1
                ;;
            nginx)
                # nginx -t opens each vhost log. Match the running service's
                # configured descriptor limit in this validator process only;
                # a CLI's lower default can otherwise reject valid live config.
                service_limit=$(/usr/bin/systemctl show nginx --property=LimitNOFILESoft --value 2>/dev/null) || service_limit=''
                if [[ -n "$service_limit" ]]; then
                    [[ "$service_limit" =~ ^[0-9]+$ ]] || return 1
                    ulimit -Sn "$service_limit" || return 1
                fi
                /usr/sbin/nginx -t >/dev/null 2>&1 || return 1
                ;;
            *) /usr/sbin/service "$service_name" configtest >/dev/null 2>&1 || return 1 ;;
        esac
    done
)

vx_domain_connection_native_restart() {
    "$BIN/v-restart-web" now >/dev/null 2>&1 && "$BIN/v-restart-proxy" now >/dev/null 2>&1
}

vx_domain_connection_native_activate() (
    local record=$1 user domain USER_DATA
    vx_domain_connection_native_context "$record" || return 1
    vx_domain_connection_native_parent_binding || return 1
    vx_domain_connection_native_marker_matches || return 1
    [[ -z $(vx_domain_connection_native_value "$VX_DC_ROW" ALIAS) \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" LETSENCRYPT) == yes \
        && $(vx_domain_connection_native_value "$VX_DC_ROW" SSL) == yes ]] || return 1
    # An accepted row needs observation only. A transient public probe failure
    # must not turn an already serving site back into holding mode.
    if [[ $(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_MODE) == proxy ]]; then
        vx_domain_connection_native_binding_matches proxy || return 1
        if /usr/bin/grep -Fq "proxy_pass $VX_DC_PARENT_PROXY_TARGET;" \
            "$HOMEDIR/$VX_DC_OWNER/conf/web/$VX_DC_HOSTNAME.$PROXY_SYSTEM.ssl.conf" 2>/dev/null; then return 0; fi
    fi
    user=$VX_DC_OWNER domain=$VX_DC_HOSTNAME USER_DATA="$VESTA/data/users/$VX_DC_OWNER"
    vx_domain_connection_native_apply_binding "$VX_DC_PARENT_PROXY_MODE" || return 1
    if vx_domain_connection_native_render && vx_domain_connection_native_configtest && vx_domain_connection_native_restart; then return 0; fi
    vx_domain_connection_native_apply_binding holding
    vx_domain_connection_native_render && vx_domain_connection_native_configtest && vx_domain_connection_native_restart
    return 1
)

vx_domain_connection_native_observe() (
    local record=$1 tls=missing config=false identity=false present=false rendered response ip target certificate expiry='' row
    vx_domain_connection_native_record_load "$record" || return 1
    if vx_domain_connection_native_marker_matches; then
        present=true; row=$VX_DC_ROW
        certificate="$VESTA/data/users/$VX_DC_OWNER/ssl/$VX_DC_HOSTNAME.crt"
        if [[ $(vx_domain_connection_native_value "$row" SSL) == yes \
            && $(vx_domain_connection_native_value "$row" LETSENCRYPT) == yes \
            && -f "$certificate" && ! -L "$certificate" ]] \
            && /usr/bin/openssl x509 -in "$certificate" -noout -checkhost "$VX_DC_HOSTNAME" >/dev/null 2>&1 \
            && /usr/bin/openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1; then
            tls=issued
            expiry=$(/usr/bin/openssl x509 -in "$certificate" -noout -enddate | /usr/bin/cut -d= -f2-)
            if [[ -z $(vx_domain_connection_native_value "$row" ALIAS) ]] \
                && vx_domain_connection_native_binding_matches proxy \
                && vx_domain_connection_native_configtest; then
                rendered="$HOMEDIR/$VX_DC_OWNER/conf/web/$VX_DC_HOSTNAME.$PROXY_SYSTEM.ssl.conf"
                if [[ -f "$rendered" && ! -L "$rendered" ]] \
                    && /usr/bin/grep -Fq "ssl.$VX_DC_HOSTNAME.pem" "$rendered" \
                    && /usr/bin/grep -Fq "return 200 \"$VX_DC_CONNECTION_ID\"" "$rendered"; then
                    config=true
                    vx_domain_connection_native_rendered_binding_valid "$row" "$rendered" || config=false
                fi
            fi
            # Probe only the admitted public ingress, with normal CA and SNI
            # verification. Persisted IP and public DNS never select arbitrary
            # probe destinations. No proxy environment or redirects are used.
            target=$(vx_domain_connection_target_read_json) || target='{}'
            if [[ "$config" == true ]]; then
                identity=true
                while IFS= read -r ip; do
                    [[ -n "$ip" ]] || continue
                    { vx_domain_connection_dns_public_ipv4 "$ip" || vx_domain_connection_dns_global_ipv6 "$ip"; } || { identity=false; break; }
                    [[ "$ip" != *:* ]] || ip="[$ip]"
                    response=$(vx_domain_connection_native_https_identity "$VX_DC_HOSTNAME" "$ip") || { identity=false; break; }
                    [[ "$response" == "$VX_DC_CONNECTION_ID" ]] || { identity=false; break; }
                done < <(/usr/bin/jq -r '[.IPV4, .IPV6] | .[] | select(type=="string" and length>0)' <<<"$target")
                /usr/bin/jq -e '[.IPV4, .IPV6] | map(select(type=="string" and length>0)) | length>0' >/dev/null <<<"$target" || identity=false
                [[ "$identity" != true ]] || tls=accepted
            fi
        fi
    fi
    /usr/bin/jq -cn --argjson present "$present" --arg tls "$tls" --argjson identity "$identity" \
        --argjson config "$config" --arg expiry "$expiry" '{NATIVE_CHILD_PRESENT:$present,TLS_STATE:$tls,HTTPS_IDENTITY:$identity,CONFIG_VALID:$config,CERTIFICATE_EXPIRES_AT:$expiry}'
)

vx_domain_connection_native_cleanup() (
    local record=$1 snapshot payload row file present=false artifacts=false
    vx_domain_connection_native_context "$record" || return 1
    [[ "$VX_DC_STATE" == disconnecting ]] || return 1
    VX_DC_GENERATION=$(/usr/bin/jq -r '.CLEANUP.NATIVE_GENERATION // .GENERATION' "$record")
    snapshot=$(/usr/bin/jq -r '.CLEANUP.NATIVE_SNAPSHOT // empty' "$record")
    if vx_domain_connection_native_row "$VX_DC_OWNER" "$VX_DC_HOSTNAME"; then
        vx_domain_connection_native_marker_matches || return 1
        [[ -z $(vx_domain_connection_native_value "$VX_DC_ROW" ALIAS) ]] || return 1
        present=true
    fi
    if [[ -n "$snapshot" ]]; then
        [[ "$snapshot" =~ ^\.native-tls\.[A-Za-z0-9]+$ ]] || return 1
        snapshot="$(vx_domain_connection_root)/$snapshot"
        [[ -d "$snapshot" && ! -L "$snapshot" && $(stat -c '%u:%a' "$snapshot") == 0:700 \
            && -f "$snapshot/row" && ! -L "$snapshot/row" ]] || return 1
        row=$(<"$snapshot/row")
        [[ "$row" == "DOMAIN='$VX_DC_HOSTNAME' "* \
            && $(vx_domain_connection_native_value "$row" VX_CONNECTION_ID) == "$VX_DC_CONNECTION_ID" \
            && $(vx_domain_connection_native_value "$row" VX_CONNECTION_PARENT) == "$VX_DC_TECHNICAL_FQDN" \
            && $(vx_domain_connection_native_value "$row" VX_CONNECTION_GENERATION) == "$VX_DC_GENERATION" ]] || return 1
    elif [[ "$present" == true ]]; then
        snapshot=$(vx_domain_connection_native_snapshot) || return 1
        row=$(<"$snapshot/row")
        payload=$(/usr/bin/jq --arg artifact "${snapshot##*/}" '.CLEANUP.NATIVE_SNAPSHOT=$artifact' "$record") || return 1
        vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    fi
    for file in "$HOMEDIR/$VX_DC_OWNER/conf/web/$VX_DC_HOSTNAME."{nginx,apache2}.{conf,ssl.conf} \
        "$HOMEDIR/$VX_DC_OWNER/conf/web/ssl.$VX_DC_HOSTNAME."{crt,key,pem,ca} \
        "$VESTA/data/users/$VX_DC_OWNER/ssl/$VX_DC_HOSTNAME."{crt,key,pem,ca}; do
        [[ ! -e "$file" && ! -L "$file" ]] || artifacts=true
    done
    if [[ "$present" == false && ( "$artifacts" == true || -n "$snapshot" ) ]]; then
        # The native delete adapter removes the row before its files. Recreate
        # only its saved exact row so the same adapter can finish after a lost
        # response or interruption; a new namespace owner always wins refusal.
        [[ -n "$snapshot" ]] || return 1
        vx_domain_connection_native_hostname_in_use "$VX_DC_HOSTNAME" || return 1
        printf '%s\n' "$row" >>"$VESTA/data/users/$VX_DC_OWNER/web.conf" || return 1
        present=true
    fi
    if [[ "$present" == true ]]; then
        VX_DOMAIN_CONNECTION_RECORD="$record" VX_DOMAIN_CONNECTION_INTERNAL_CLEANUP=1 \
            "$BIN/v-delete-web-domain" "$VX_DC_OWNER" "$VX_DC_HOSTNAME" no >/dev/null 2>&1 || return 1
    fi
    vx_domain_connection_native_row "$VX_DC_OWNER" "$VX_DC_HOSTNAME" && return 1
    "$BIN/v-update-user-counters" "$VX_DC_OWNER" >/dev/null 2>&1 || return 1
    vx_domain_connection_native_configtest && vx_domain_connection_native_restart || return 1
    payload=$(/usr/bin/jq '.CLEANUP.NATIVE_SNAPSHOT=null' "$record") || return 1
    vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    [[ -z "$snapshot" ]] || /usr/bin/rm -rf -- "$snapshot"
)

# Registry owns the hostname mapping. Public commands call this after loading
# main.sh; only the root worker may perform the two TLS transitions.
vx_domain_connection_native_guard() {
    local owner=$1 hostname=$2 action=$3
    hostname=${hostname,,}; hostname=${hostname%.}
    [[ ! -L "$VESTA/data/users/$owner" && ! -L "$VESTA/data/users/$owner/web.conf" ]] || return 1
    declare -F vx_domain_connection_is_native_child >/dev/null || return 0
    if ! vx_domain_connection_is_native_child "$owner" "$hostname"; then
        # Native markers remain guarded even when registry material is missing.
        if vx_domain_connection_native_row "$owner" "$hostname" \
            && [[ -n $(vx_domain_connection_native_value "$VX_DC_ROW" VX_CONNECTION_ID) ]]; then return 1; fi
        # Another owner's reservation must also block native primary creation.
        if [[ "$action" == create && -e "$(vx_domain_connection_record_path "$hostname")" ]]; then
            vx_domain_connection_record_read "$hostname" | /usr/bin/jq -e '.STATE=="disconnected"' >/dev/null 2>&1 || return 1
        fi
        return 0
    fi
    if [[ "$action" == backend ]] && vx_domain_connection_native_row "$owner" "$hostname" \
        && [[ "${template:-}" == "$(vx_domain_connection_native_value "$VX_DC_ROW" BACKEND)" ]]; then
        return 0
    fi
    vx_domain_connection_native_context "${VX_DOMAIN_CONNECTION_RECORD:-}" || return 1
    case "$action" in
        create)
            [[ "${VX_DOMAIN_CONNECTION_NATIVE_CREATE:-}" == 1 \
                && "${VX_DOMAIN_CONNECTION_RECORD:-}" != '' ]] || return 1
            vx_domain_connection_native_record_load "$VX_DOMAIN_CONNECTION_RECORD" || return 1
            vx_domain_connection_authorize_native_tls "$owner" "$hostname" "$VX_DC_CONNECTION_ID" "$VX_DC_GENERATION"
            ;;
        issue|renew)
            [[ "${VX_DOMAIN_CONNECTION_NATIVE_TLS:-}" == 1 \
                && "${VX_DOMAIN_CONNECTION_RECORD:-}" != '' ]] || return 1
            vx_domain_connection_native_record_load "$VX_DOMAIN_CONNECTION_RECORD" || return 1
            vx_domain_connection_authorize_native_tls "$owner" "$hostname" \
                "$VX_DC_CONNECTION_ID" "$VX_DC_GENERATION" \
                && vx_domain_connection_native_marker_matches
            ;;
        delete)
            [[ "${VX_DOMAIN_CONNECTION_INTERNAL_CLEANUP:-}" == 1 && "$VX_DC_STATE" == disconnecting ]] || return 1
            VX_DC_GENERATION=$(/usr/bin/jq -r '.CLEANUP.NATIVE_GENERATION // .GENERATION' "$VX_DOMAIN_CONNECTION_RECORD")
            vx_domain_connection_native_marker_matches ;;
        backend)
            if [[ "${VX_DOMAIN_CONNECTION_INTERNAL_CLEANUP:-}" == 1 && "$VX_DC_STATE" == disconnecting ]]; then
                VX_DC_GENERATION=$(/usr/bin/jq -r '.CLEANUP.NATIVE_GENERATION // .GENERATION' "$VX_DOMAIN_CONNECTION_RECORD")
                vx_domain_connection_native_marker_matches
            else
                [[ "${VX_DOMAIN_CONNECTION_NATIVE_CREATE:-}" == 1 ]]
            fi ;;

        *) return 1 ;;
    esac
}

vx_domain_connection_native_parent_has_children() {
    local owner=$1 parent=$2 root
    local -a records
    declare -F vx_domain_connection_hostname_root >/dev/null || return 1
    root=$(vx_domain_connection_hostname_root)
    mapfile -d '' -t records < <(/usr/bin/find "$root" -type f -name '*.json' -print0 2>/dev/null)
    if ((${#records[@]})); then
        /usr/bin/jq -s -e --arg owner "$owner" --arg parent "$parent" \
            'any(.[]; .OWNER==$owner and .TECHNICAL_FQDN==$parent and .STATE!="disconnected")' "${records[@]}" >/dev/null && return 0
    fi
    /usr/bin/grep -Fq " VX_CONNECTION_PARENT='$parent'" "$VESTA/data/users/$owner/web.conf" 2>/dev/null
}

vx_domain_connection_native_owner_has_connections() {
    local owner=$1 root
    local -a records
    declare -F vx_domain_connection_hostname_root >/dev/null || return 1
    root=$(vx_domain_connection_hostname_root)
    mapfile -d '' -t records < <(/usr/bin/find "$root" -type f -name '*.json' -print0 2>/dev/null)
    if ((${#records[@]})); then
        /usr/bin/jq -s -e --arg owner "$owner" \
            'any(.[]; .OWNER==$owner and .STATE!="disconnected")' "${records[@]}" >/dev/null && return 0
    fi
    /usr/bin/grep -q " VX_CONNECTION_ID='[^']" "$VESTA/data/users/$owner/web.conf" 2>/dev/null
}

# Save only this child's authority and TLS/rendered files. Recovery never copies
# a whole owner's web.conf over concurrent unrelated native domain changes.
vx_domain_connection_native_snapshot() {
    local path file
    path=$(/usr/bin/mktemp -d "$(vx_domain_connection_root)/.native-tls.XXXXXXXX") || return 1
    /usr/bin/chmod 700 "$path"
    /usr/bin/mkdir "$path/data" "$path/web"
    vx_domain_connection_native_marker_matches || return 1
    printf '%s\n' "$VX_DC_ROW" >"$path/row"
    for file in "$VESTA/data/users/$VX_DC_OWNER/ssl/$VX_DC_HOSTNAME."{crt,key,pem,ca}; do
        [[ ! -L "$file" ]] || return 1
        [[ ! -f "$file" ]] || /usr/bin/cp -a -- "$file" "$path/data/" || return 1
    done
    for file in "$HOMEDIR/$VX_DC_OWNER/conf/web/ssl.$VX_DC_HOSTNAME."{crt,key,pem,ca} \
        "$HOMEDIR/$VX_DC_OWNER/conf/web/$VX_DC_HOSTNAME."{nginx,apache2}.{conf,ssl.conf}; do
        [[ ! -L "$file" ]] || return 1
        [[ ! -f "$file" ]] || /usr/bin/cp -a -- "$file" "$path/web/" || return 1
    done
    printf '%s\n' "$path"
}

vx_domain_connection_native_restore_snapshot() (
    local snapshot=$1 file user=$VX_DC_OWNER domain=$VX_DC_HOSTNAME
    USER_DATA="$VESTA/data/users/$user"
    [[ -d "$snapshot" && ! -L "$snapshot" && $(/usr/bin/stat -c '%u:%a' "$snapshot") == 0:700 ]] || return 1
    /usr/bin/python3 - "$USER_DATA/web.conf" "$snapshot/row" "$domain" <<'PY'
import pathlib, sys
path, saved, domain = map(str, sys.argv[1:])
p=pathlib.Path(path)
rows=p.read_text().splitlines(True)
old=pathlib.Path(saved).read_text()
if sum(row.startswith("DOMAIN='"+domain+"' ") for row in rows)!=1: raise SystemExit(1)
p.write_text(''.join(old if row.startswith("DOMAIN='"+domain+"' ") else row for row in rows))
PY
    [[ $? == 0 ]] || return 1
    for file in "$USER_DATA/ssl/$domain."{crt,key,pem,ca}; do /usr/bin/rm -f -- "$file" || return 1; done
    /usr/bin/cp -a "$snapshot/data/." "$USER_DATA/ssl/" || return 1
    source "$VESTA/func/domain.sh"
    get_domain_values web
    if [[ "$SSL" != yes ]]; then
        del_web_config "$WEB_SYSTEM" "$TPL.stpl"
        del_web_config "$PROXY_SYSTEM" "$PROXY.stpl"
    fi
    for file in "$HOMEDIR/$user/conf/web/ssl.$domain."{crt,key,pem,ca} \
        "$HOMEDIR/$user/conf/web/$domain."{nginx,apache2}.{conf,ssl.conf}; do /usr/bin/rm -f -- "$file" || return 1; done
    /usr/bin/cp -a "$snapshot/web/." "$HOMEDIR/$user/conf/web/" || return 1
    "$BIN/v-update-user-counters" "$user" >/dev/null 2>&1 || return 1
    vx_domain_connection_native_configtest && vx_domain_connection_native_restart
)

vx_domain_connection_native_issue() (
    local record=$1 snapshot result=0 recovery=false payload issue_pid
    vx_domain_connection_native_context "$record" || return 1
    vx_domain_connection_authorize_native_tls "$VX_DC_OWNER" "$VX_DC_HOSTNAME" "$VX_DC_CONNECTION_ID" "$VX_DC_GENERATION" || return 1
    vx_domain_connection_native_marker_matches || return 1
    [[ -z $(vx_domain_connection_native_value "$VX_DC_ROW" ALIAS) ]] || return 1
    snapshot=$(vx_domain_connection_native_snapshot) || return 1
    payload=$(vx_domain_connection_record_read "$VX_DC_HOSTNAME") || return 1
    payload=$(/usr/bin/jq --arg artifact "${snapshot##*/}" '.RECOVERY={required:true,artifact:$artifact,operation:"certificate_install"}' <<<"$payload")
    vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    export VX_DOMAIN_CONNECTION_RECORD="$record" VX_DOMAIN_CONNECTION_NATIVE_TLS=1
    # timeout owns a separate process group. Forward worker cancellation to
    # that group so neither the ACME client nor its descendants outlive it.
    /usr/bin/timeout --signal=TERM --kill-after=5 300 "$BIN/v-add-letsencrypt-domain" "$VX_DC_OWNER" "$VX_DC_HOSTNAME" '' >/dev/null 2>&1 &
    issue_pid=$!
    trap '
        trap "" TERM INT
        kill -TERM -- "-$issue_pid" 2>/dev/null || :
        /usr/bin/sleep 1
        kill -KILL -- "-$issue_pid" 2>/dev/null || :
        wait "$issue_pid" 2>/dev/null || :
        exit 143
    ' TERM INT
    wait "$issue_pid" || result=$?
    trap - TERM INT
    if (( result == 0 )); then
        vx_domain_connection_native_configtest && vx_domain_connection_native_restart || result=1
    fi
    if (( result != 0 )); then
        vx_domain_connection_native_restore_snapshot "$snapshot" || recovery=true
        payload=$(vx_domain_connection_record_read "$VX_DC_HOSTNAME") || return 1
        payload=$(/usr/bin/jq --argjson recovery "$recovery" --arg artifact "${snapshot##*/}" \
            '.REASON="certificate_install_failed" | .RECOVERY={required:$recovery,artifact:(if $recovery then $artifact else null end)} | if $recovery then .STATE="recovery_required" else . end' <<<"$payload")
        vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    fi
    if (( result == 0 )); then
        payload=$(vx_domain_connection_record_read "$VX_DC_HOSTNAME") || return 1
        payload=$(/usr/bin/jq '.RECOVERY={required:false,artifact:null}' <<<"$payload")
        vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    fi
    [[ "$recovery" == true ]] || /usr/bin/rm -rf -- "$snapshot"
    return "$result"
)

# The existing v-update-letsencrypt-ssl cron is the sole caller. The worker
# only issues the initial certificate; these locks serialize both paths.
vx_domain_connection_native_renew() (
    local owner=$1 hostname=$2 record generation result=0
    vx_domain_connection_owner_lock "$owner" || return 1
    vx_domain_connection_lock "$hostname" || return 1
    record=$(vx_domain_connection_record_path "$hostname")
    vx_domain_connection_native_context "$record" || return 1
    [[ "$VX_DC_OWNER" == "$owner" && ( "$VX_DC_STATE" == connected || "$VX_DC_STATE" == degraded ) ]] || return 1
    generation=$VX_DC_GENERATION
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    record=$(/usr/bin/jq --arg now "$(vx_domain_connection_now)" '.OPERATION={KIND:"renew",GENERATION:.GENERATION,STARTED_AT:$now}' <<<"$record")
    vx_domain_connection_record_write "$hostname" "$record" || return 1
    record=$(vx_domain_connection_record_path "$hostname")
    vx_domain_connection_native_issue "$record" || result=$?
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    [[ $(/usr/bin/jq -r .STATE <<<"$record") != recovery_required ]] || return 1
    record=$(/usr/bin/jq --arg now "$(vx_domain_connection_now)" --argjson result "$result" \
        '.RENEWAL={lastAttemptAt:$now,successful:($result==0)} | del(.OPERATION) | if $result!=0 then .STATE="degraded" | .REASON="renewal_failed" else . end' <<<"$record")
    vx_domain_connection_record_write "$hostname" "$record" || return 1
    return "$result"
)

vx_domain_connection_native_render_guard() {
    local owner=$1 hostname=$2 record path
    path=$(vx_domain_connection_record_path "$hostname")
    vx_domain_connection_native_record_load "$path" || return 1
    [[ "$VX_DC_OWNER" == "$owner" && "$VX_DC_STATE" != disconnected ]] || return 1
    if [[ "${VX_DOMAIN_CONNECTION_NATIVE_CREATE:-}" == 1 ]] && ! vx_domain_connection_native_row "$owner" "$hostname"; then
        vx_domain_connection_native_context "$path" || return 1
    else
        vx_domain_connection_native_marker_matches || return 1
    fi
    [[ -z "${ALIAS:-}" && "${PROXY:-${PROXY_TEMPLATE:-}}" == vx-proxy \
        && "$VX_CONNECTION_ID" == "$VX_DC_CONNECTION_ID" \
        && "$VX_CONNECTION_PARENT" == "$VX_DC_TECHNICAL_FQDN" ]] || return 1
    [[ ! -e "$(vx_cf_record_path "$owner" "$hostname")" \
        && ! -L "$(vx_cf_record_path "$owner" "$hostname")" \
        && ! -e "$(vx_cf_certificate_path "$owner" "$hostname")" \
        && ! -L "$(vx_cf_certificate_path "$owner" "$hostname")" ]] || return 1
    if [[ "${SSL:-no}" != yes || "$VX_DC_STATE" == pending_verification || "$VX_DC_STATE" == pending_dns ]] \
        || [[ $(/usr/bin/jq -r '.REASON // empty' "$path") == restored_recovery_required ]]; then
        PROXY_MODE=holding
    fi
}

# HTTPS transport is kept separate for fixture tests; production always uses the
# fixed system curl with normal trust verification and an admitted pinned IP.
vx_domain_connection_native_https_identity() (
    set -o pipefail
    /usr/bin/curl --noproxy '*' --fail --silent --show-error --max-time 10 \
        --max-redirs 0 --resolve "$1:443:$2" \
        "https://$1/.well-known/vx-domain-connection" 2>/dev/null | /usr/bin/head -c 257
)

vx_domain_connection_native_recover() (
    local record=$1 snapshot row payload
    vx_domain_connection_native_context "$record" || return 1
    /usr/bin/jq -e '.RECOVERY.required==true and (.RECOVERY.artifact|type=="string")' "$record" >/dev/null || return 1
    snapshot=$(/usr/bin/jq -r .RECOVERY.artifact "$record")
    [[ "$snapshot" =~ ^\.native-tls\.[A-Za-z0-9]+$ ]] || return 1
    snapshot="$(vx_domain_connection_root)/$snapshot"
    [[ -f "$snapshot/row" && ! -L "$snapshot/row" ]] || return 1
    row=$(<"$snapshot/row")
    [[ "$row" == "DOMAIN='$VX_DC_HOSTNAME' "* \
        && $(vx_domain_connection_native_value "$row" VX_CONNECTION_ID) == "$VX_DC_CONNECTION_ID" \
        && $(vx_domain_connection_native_value "$row" VX_CONNECTION_PARENT) == "$VX_DC_TECHNICAL_FQDN" \
        && $(vx_domain_connection_native_value "$row" VX_CONNECTION_GENERATION) == "$VX_DC_GENERATION" ]] || return 1
    vx_domain_connection_native_restore_snapshot "$snapshot" || return 1
    payload=$(vx_domain_connection_record_read "$VX_DC_HOSTNAME") || return 1
    payload=$(/usr/bin/jq '.RECOVERY={required:false,artifact:null} | .REASON="certificate_state_recovered"' <<<"$payload")
    vx_domain_connection_record_write "$VX_DC_HOSTNAME" "$payload" || return 1
    /usr/bin/rm -rf -- "$snapshot"
)

vx_domain_connection_native_rendered_binding_valid() (
    local row=$1 rendered=$2 line
    # Native rows are the existing Vesta authority parsed by get_domain_values.
    # Compare the whole generated proxy block, including inherited header values,
    # without copying those values into argv, metadata or observation output.
    eval "$row"
    docroot="$HOMEDIR/$VX_DC_OWNER/web/$VX_DC_HOSTNAME/public_html"
    PROXY_TEMPLATE=$PROXY
    declare -F vx_proxy_prepare_template_values >/dev/null || source "$VESTA/func/vx/proxy.sh"
    vx_proxy_prepare_template_values
    while IFS= read -r line; do
        [[ -z "$line" ]] || printf '%s\n' "$line" | /usr/bin/grep -Fxq -f - "$rendered" || return 1
    done <<<"$VX_PROXY_LOCATION_BLOCK"
)

vx_domain_connection_native_write_challenge() {
    local token=$1 thumbprint=$2
    vx_domain_connection_native_context "$VX_DOMAIN_CONNECTION_RECORD" || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]{1,256}$ && "$thumbprint" =~ ^[A-Za-z0-9_-]{1,256}$ ]] || return 1
    # Walk all components without following symlinks and replace an exclusive
    # temporary file relative to the opened directory. Tenant-writable web
    # directories must not redirect a root ACME write outside this child.
    printf '%s.%s\n' "$token" "$thumbprint" | /usr/bin/python3 -c '
import os, secrets, sys
root, token = sys.argv[1:]
fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
try:
    for part in root.strip("/").split("/"):
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        os.close(fd); fd = child
    for part in (".well-known", "acme-challenge"):
        try: os.mkdir(part, 0o755, dir_fd=fd)
        except FileExistsError: pass
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        # The registry writer leaves umask 077 in the worker. HTTP-01 needs
        # these public directories traversable even on an interrupted retry.
        os.fchmod(child, 0o755)
        os.close(fd); fd = child
    temp = ".vx-acme-" + secrets.token_hex(16)
    out = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=fd)
    try:
        os.write(out, sys.stdin.buffer.read(1024)); os.fchmod(out, 0o644)
    finally: os.close(out)
    os.replace(temp, token, src_dir_fd=fd, dst_dir_fd=fd)
finally: os.close(fd)
' "$HOMEDIR/$VX_DC_OWNER/web/$VX_DC_HOSTNAME/public_html" "$token" 2>/dev/null
}

# Called by the native ACME client after it has obtained certificate material.
# The outer issue transaction owns the recovery snapshot and service validation.
vx_domain_connection_native_install_certificate() {
    local ssl_dir=$1 ssl_home
    vx_domain_connection_native_context "$VX_DOMAIN_CONNECTION_RECORD" || return 1
    vx_domain_connection_native_guard "$VX_DC_OWNER" "$VX_DC_HOSTNAME" issue || return 1
    vx_domain_connection_native_marker_matches || return 1
    ssl_home=$(vx_domain_connection_native_value "$VX_DC_ROW" SSL_HOME)
    if [[ $(vx_domain_connection_native_value "$VX_DC_ROW" SSL) == yes ]]; then
        "$BIN/v-change-web-domain-sslcert" "$VX_DC_OWNER" "$VX_DC_HOSTNAME" "$ssl_dir" no
    else
        "$BIN/v-add-web-domain-ssl" "$VX_DC_OWNER" "$VX_DC_HOSTNAME" "$ssl_dir" "${ssl_home:-same}" no
    fi
}
