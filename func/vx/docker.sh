#!/bin/bash

VX_DOCKER_PORT_START=21000
VX_DOCKER_PORT_END=29999
VX_DOCKER_LABEL_MANAGED_KEY='vx.managed'
VX_DOCKER_LABEL_MANAGED_VALUE='yes'
VX_DOCKER_LABEL_USER_KEY='vx.user'
VX_DOCKER_LABEL_NAME_KEY='vx.name'
VX_DOCKER_DEFAULT_RESTART_POLICY='unless-stopped'
VX_DOCKER_DEFAULT_HEALTHCHECK_TYPE='http'
VX_DOCKER_DEFAULT_HEALTHCHECK_INTERVAL='60'
VX_DOCKER_DEFAULT_CPU_ALERT_PCT='85'
VX_DOCKER_DEFAULT_MEM_ALERT_MB='1024'
VX_DOCKER_DEFAULT_NET_ALERT_MBPS='50'
VX_DOCKER_DEFAULT_ALERT_EMAIL='yes'
VX_DOCKER_DEFAULT_AUTO_START='yes'
VX_DOCKER_HEALTHCHECK_TIMEOUT='10'

vx_docker_metadata_path() {
    echo "$VESTA/data/users/$1/docker.conf"
}

vx_docker_managed_name() {
    echo "vx-$1-$2"
}

vx_docker_bind_root() {
    echo "$HOMEDIR/$1/docker/$2"
}

vx_docker_metadata_exists() {
    [ -s "$(vx_docker_metadata_path "$1")" ]
}

vx_docker_reset_record_vars() {
    unset NAME CTN_NAME OWNER IMAGE COMMAND ENV MOUNTS HOST_PORT CONTAINER_PORT DOMAIN
    unset ROUTE_PATH PROXY_MODE PROXY_TARGET AUTO_START RESTART_POLICY HEALTHCHECK_TYPE
    unset HEALTHCHECK_TARGET HEALTHCHECK_INTERVAL HEALTH_STATUS LAST_HEALTH_AT CPU_ALERT_PCT
    unset MEM_ALERT_MB NET_ALERT_MBPS ALERT_EMAIL STATUS CREATED UPDATED
}

vx_docker_now() {
    date +'%Y-%m-%d %H:%M:%S'
}

vx_docker_shell_quote_free() {
    if [[ "$1" == *"'"* ]] || [[ "$1" == *$'\n'* ]]; then
        check_result "$E_INVALID" "invalid docker value :: $2"
    fi
}

vx_docker_json_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"

    printf '%s' "$value"
}

vx_docker_metadata_touch() {
    local owner="$1"
    local conf

    conf="$(vx_docker_metadata_path "$owner")"
    touch "$conf"
    chmod 660 "$conf"
}

vx_docker_parse_record() {
    vx_docker_reset_record_vars
    parse_object_kv_list_non_eval "$1"
}

vx_docker_record_line_by_name() {
    local owner="$1"
    local name="$2"
    local conf line

    conf="$(vx_docker_metadata_path "$owner")"
    [ -f "$conf" ] || return 1

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        vx_docker_parse_record "$line"
        if [ "$NAME" = "$name" ]; then
            echo "$line"
            return 0
        fi
    done < "$conf"

    return 1
}

vx_docker_load_record() {
    local owner="$1"
    local name="$2"

    VX_DOCKER_RECORD_LINE="$(vx_docker_record_line_by_name "$owner" "$name")" || return 1
    vx_docker_parse_record "$VX_DOCKER_RECORD_LINE"
}

vx_docker_list_owner_records() {
    local owner="$1"
    local conf

    conf="$(vx_docker_metadata_path "$owner")"
    [ -f "$conf" ] || return 0
    cat "$conf"
}

vx_docker_list_all_records() {
    local user_dir owner

    for user_dir in "$VESTA"/data/users/*; do
        [ -d "$user_dir" ] || continue
        owner="$(basename "$user_dir")"
        vx_docker_list_owner_records "$owner"
    done
}

vx_docker_count_owner_records() {
    local owner="$1"
    local count=0
    local line

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        count=$((count + 1))
    done < <(vx_docker_list_owner_records "$owner")

    echo "$count"
}

vx_docker_ensure_bind_root() {
    local owner="$1"
    local name="$2"
    local bind_root

    bind_root="$(vx_docker_bind_root "$owner" "$name")"
    mkdir -p "$bind_root"
    if id -u "$owner" >/dev/null 2>&1; then
        chown "$owner:$owner" "$HOMEDIR/$owner/docker" "$bind_root" 2>/dev/null
    fi
}

vx_docker_port_is_allocated() {
    local port="$1"

    if grep -Rqs "HOST_PORT='$port'" "$VESTA/data/users"/*/docker.conf 2>/dev/null; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
        return $?
    fi

    return 1
}

vx_docker_allocate_host_port() {
    local port

    for ((port=VX_DOCKER_PORT_START; port<=VX_DOCKER_PORT_END; port++)); do
        if ! vx_docker_port_is_allocated "$port"; then
            echo "$port"
            return 0
        fi
    done

    check_result "$E_LIMIT" "no docker host ports available in reserved range"
}

vx_docker_assert_actor_can_access_owner() {
    local actor="$1"
    local owner="$2"

    if [ "$actor" != 'admin' ] && [ "$actor" != "$owner" ]; then
        check_result "$E_FORBIDEN" "$actor can't access docker containers owned by $owner"
    fi
}

vx_docker_owner_domain_exists() {
    local owner="$1"
    local domain_name="$2"
    local web_conf="$VESTA/data/users/$owner/web.conf"

    [ -n "$domain_name" ] || return 0
    [ -f "$web_conf" ] || return 1
    grep -q "DOMAIN='$domain_name'" "$web_conf"
}

vx_docker_domain_proxy_target() {
    local owner="$1"
    local domain_name="$2"
    local web_conf line

    web_conf="$VESTA/data/users/$owner/web.conf"
    [ -f "$web_conf" ] || return 1
    line="$(grep "DOMAIN='$domain_name'" "$web_conf" 2>/dev/null)"
    [ -n "$line" ] || return 1
    parse_object_kv_list_non_eval "$line"
    [ -n "$PROXY_TARGET" ] || return 1
    echo "$PROXY_TARGET"
}

vx_docker_domain_route_name() {
    local owner="$1"
    local domain_name="$2"
    local conf line

    conf="$(vx_docker_metadata_path "$owner")"
    [ -n "$domain_name" ] || return 1
    [ -f "$conf" ] || return 1
    line="$(grep " DOMAIN='$domain_name'" "$conf" 2>/dev/null | head -n 1)"
    [ -n "$line" ] || return 1
    echo "$line" | sed -n "s/.* NAME='\([^']*\)'.*/\1/p"
}

vx_docker_domain_route_target() {
    local owner="$1"
    local domain_name="$2"
    local conf line

    conf="$(vx_docker_metadata_path "$owner")"
    [ -n "$domain_name" ] || return 1
    [ -f "$conf" ] || return 1
    line="$(grep " DOMAIN='$domain_name'" "$conf" 2>/dev/null | head -n 1)"
    [ -n "$line" ] || return 1
    echo "$line" | sed -n "s/.* PROXY_TARGET='\([^']*\)'.*/\1/p"
}

vx_docker_domain_route_matches_proxy_options() {
    local owner="$1"
    local domain_name="$2"
    local mode="$3"
    local target="$4"
    local profile="$5"
    local preserve_host="$6"
    local timeout="$7"
    local headers="$8"
    local route_target

    route_target="$(vx_docker_domain_route_target "$owner" "$domain_name")" || return 1
    [ "$mode" = 'proxy' ] || return 1
    [ "$target" = "$route_target" ] || return 1
    [ "$profile" = 'application' ] || return 1
    [ "$preserve_host" = 'yes' ] || return 1
    [ "$timeout" = '60' ] || return 1
    [ -z "$headers" ] || return 1
}

vx_docker_domain_route_is_active() {
    local owner="$1"
    local domain_name="$2"
    local live_target metadata_target web_conf line

    metadata_target="$(vx_docker_domain_route_target "$owner" "$domain_name")" || return 1
    live_target="$(vx_docker_domain_proxy_target "$owner" "$domain_name")" || return 1
    [ "$live_target" = "$metadata_target" ] || return 1

    web_conf="$VESTA/data/users/$owner/web.conf"
    [ -f "$web_conf" ] || return 1
    line="$(grep "DOMAIN='$domain_name'" "$web_conf" 2>/dev/null)"
    [ -n "$line" ] || return 1
    parse_object_kv_list_non_eval "$line"
    [ "$PROXY" = "$VX_PROXY_TEMPLATE" ] || return 1
    [ "${PROXY_MODE:-proxy}" = 'proxy' ] || return 1
    [ "${PROXY_PROFILE:-standard}" = 'application' ] || return 1
    [ "${PROXY_PRESERVE_HOST:-yes}" = 'yes' ] || return 1
    [ "${PROXY_TIMEOUT:-60}" = '60' ] || return 1
    [ -z "$PROXY_HEADERS" ] || return 1
}

vx_docker_domain_matches_record_route() {
    local owner="$1"
    local name="$2"
    local route_target

    vx_docker_load_record "$owner" "$name" || return 1
    [ -n "$DOMAIN" ] || return 1
    route_target="$(vx_docker_domain_proxy_target "$owner" "$DOMAIN")" || return 1
    [ "$route_target" = "http://127.0.0.1:${HOST_PORT}" ]
}

vx_docker_domain_matches_target() {
    local owner="$1"
    local domain_name="$2"
    local host_port="$3"
    local route_target

    [ -n "$domain_name" ] || return 1
    [ -n "$host_port" ] || return 1
    route_target="$(vx_docker_domain_proxy_target "$owner" "$domain_name")" || return 1
    [ "$route_target" = "http://127.0.0.1:${host_port}" ]
}

vx_docker_runtime_label_tuple() {
    docker inspect --format "{{ index .Config.Labels \"$VX_DOCKER_LABEL_MANAGED_KEY\" }}|{{ index .Config.Labels \"$VX_DOCKER_LABEL_USER_KEY\" }}|{{ index .Config.Labels \"$VX_DOCKER_LABEL_NAME_KEY\" }}" "$1" 2>/dev/null
}

vx_docker_runtime_labels_match() {
    local ctn_name="$1"
    local owner="$2"
    local name="$3"
    local labels

    is_docker_engine_available || return 0
    docker container inspect "$ctn_name" >/dev/null 2>&1 || return 0

    labels="$(vx_docker_runtime_label_tuple "$ctn_name")" || return 1
    [ "$labels" = "${VX_DOCKER_LABEL_MANAGED_VALUE}|$owner|$name" ]
}

vx_docker_assert_runtime_labels_match() {
    local owner="$1"
    local name="$2"
    local ctn_name="${3:-$(vx_docker_managed_name "$owner" "$name")}"

    if ! vx_docker_runtime_labels_match "$ctn_name" "$owner" "$name"; then
        check_result "$E_FORBIDEN" "docker container labels do not match metadata for $owner/$name"
    fi
}

vx_docker_sync_route() {
    local owner="$1"
    local name="$2"
    local saved_user="$user"
    local saved_user_data="$USER_DATA"

    vx_docker_load_record "$owner" "$name" || check_result "$E_NOTEXIST" "docker container $name doesn't exist"
    [ -n "$DOMAIN" ] || return 0

    user="$owner"
    USER_DATA="$VESTA/data/users/$user"
    domain="$DOMAIN"
    PROXY_MODE='proxy'
    PROXY_TARGET="http://127.0.0.1:${HOST_PORT}"

    "$BIN/v-change-web-domain-proxy-options" "$user" "$domain" \
        'proxy' "http://127.0.0.1:${HOST_PORT}" 'application' 'yes' '60' '' no >/dev/null

    user="$saved_user"
    USER_DATA="$saved_user_data"
}

vx_docker_clear_route() {
    local owner="$1"
    local name="$2"
    local saved_user="$user"
    local saved_user_data="$USER_DATA"

    vx_docker_load_record "$owner" "$name" || check_result "$E_NOTEXIST" "docker container $name doesn't exist"
    [ -n "$DOMAIN" ] || return 0

    user="$owner"
    USER_DATA="$VESTA/data/users/$user"
    domain="$DOMAIN"

    if vx_docker_owner_domain_exists "$user" "$domain" && vx_docker_domain_matches_record_route "$user" "$name"; then
        "$BIN/v-delete-web-domain-proxy" "$user" "$domain" no >/dev/null
        check_result $? "docker proxy route removal failed"
    fi

    user="$saved_user"
    USER_DATA="$saved_user_data"
}

vx_docker_remove_bind_root() {
    local owner="$1"
    local name="$2"
    local bind_root

    bind_root="$(vx_docker_bind_root "$owner" "$name")"
    case "$bind_root" in
        "$HOMEDIR/$owner/docker/$name")
            rm -rf "$bind_root"
            ;;
        *)
            check_result "$E_FORBIDEN" "refusing to delete unmanaged docker path"
            ;;
    esac
}

vx_docker_validate_name() {
    vx_docker_shell_quote_free "$NAME" 'NAME'
    if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
        check_result "$E_INVALID" "invalid docker name format :: $NAME"
    fi
    case "$NAME" in
        admin|*-)
            check_result "$E_INVALID" "invalid docker name format :: $NAME"
            ;;
    esac
}

vx_docker_validate_image() {
    vx_docker_shell_quote_free "$IMAGE" 'IMAGE'
    if [ -z "$IMAGE" ] || [[ "$IMAGE" =~ [[:space:]] ]]; then
        check_result "$E_INVALID" "invalid docker image :: $IMAGE"
    fi
}

vx_docker_validate_command() {
    vx_docker_shell_quote_free "$COMMAND" 'COMMAND'
}

vx_docker_validate_env() {
    local entry

    [ -n "$ENV" ] || return 0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        vx_docker_shell_quote_free "$entry" 'ENV'
        if ! [[ "$entry" =~ ^[A-Z0-9_][A-Z0-9_]*=.*$ ]]; then
            check_result "$E_INVALID" "invalid docker env entry :: $entry"
        fi
    done <<< "${ENV//||/$'\n'}"
}

vx_docker_validate_mounts() {
    local entry mount_name mount_path

    [ -n "$MOUNTS" ] || return 0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        vx_docker_shell_quote_free "$entry" 'MOUNTS'
        mount_name="${entry%%:*}"
        mount_path="${entry#*:}"
        if [ -z "$mount_name" ] || [ -z "$mount_path" ] || [ "$mount_name" = "$mount_path" ]; then
            check_result "$E_INVALID" "invalid docker mount entry :: $entry"
        fi
        if ! [[ "$mount_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
            check_result "$E_INVALID" "invalid docker mount name :: $mount_name"
        fi
        if ! [[ "$mount_path" =~ ^/ ]]; then
            check_result "$E_INVALID" "invalid docker mount path :: $mount_path"
        fi
    done <<< "${MOUNTS//||/$'\n'}"
}

vx_docker_validate_container_port() {
    is_int_format_valid "$CONTAINER_PORT" 'container port'
    if [ "$CONTAINER_PORT" -lt 1 ] || [ "$CONTAINER_PORT" -gt 65535 ]; then
        check_result "$E_INVALID" "invalid container port :: $CONTAINER_PORT"
    fi
}

vx_docker_normalize_route_path() {
    [ "$ROUTE_PATH" = '/' ] && ROUTE_PATH=''
}

vx_docker_validate_route_path() {
    vx_docker_shell_quote_free "$ROUTE_PATH" 'ROUTE_PATH'
    [ -z "$ROUTE_PATH" ] && return 0
    if [[ ! "$ROUTE_PATH" =~ ^/ ]] || [[ "$ROUTE_PATH" =~ [[:space:]#\?] ]]; then
        check_result "$E_INVALID" "invalid docker route path :: $ROUTE_PATH"
    fi
    check_result "$E_INVALID" "docker route path routing is not available yet"
}

vx_docker_validate_auto_start() {
    case "$AUTO_START" in
        yes|no) ;;
        *) check_result "$E_INVALID" "invalid docker auto start :: $AUTO_START" ;;
    esac
}

vx_docker_validate_restart_policy() {
    case "$RESTART_POLICY" in
        no|on-failure|always|unless-stopped) ;;
        *) check_result "$E_INVALID" "invalid docker restart policy :: $RESTART_POLICY" ;;
    esac
}

vx_docker_validate_healthcheck() {
    case "$HEALTHCHECK_TYPE" in
        http|tcp|docker|none) ;;
        *) check_result "$E_INVALID" "invalid docker healthcheck type :: $HEALTHCHECK_TYPE" ;;
    esac

    if [ "$HEALTHCHECK_TYPE" = 'http' ] && [ -z "$HEALTHCHECK_TARGET" ]; then
        HEALTHCHECK_TARGET="http://127.0.0.1:${CONTAINER_PORT}/health"
    fi

    case "$HEALTHCHECK_TYPE" in
        none)
            HEALTHCHECK_TARGET=''
            ;;
        docker)
            ;;
        http)
            if ! [[ "$HEALTHCHECK_TARGET" =~ ^https?://[^[:space:]]+$ ]]; then
                check_result "$E_INVALID" "invalid docker healthcheck target :: $HEALTHCHECK_TARGET"
            fi
            ;;
        tcp)
            if ! [[ "$HEALTHCHECK_TARGET" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]; then
                check_result "$E_INVALID" "invalid docker healthcheck target :: $HEALTHCHECK_TARGET"
            fi
            ;;
    esac

    is_int_format_valid "$HEALTHCHECK_INTERVAL" 'healthcheck interval'
    if [ "$HEALTHCHECK_INTERVAL" -lt 15 ] || [ "$HEALTHCHECK_INTERVAL" -gt 3600 ]; then
        check_result "$E_INVALID" "invalid docker healthcheck interval :: $HEALTHCHECK_INTERVAL"
    fi
}

vx_docker_validate_alert_thresholds() {
    is_int_format_valid "$CPU_ALERT_PCT" 'cpu alert pct'
    is_int_format_valid "$MEM_ALERT_MB" 'mem alert mb'
    is_int_format_valid "$NET_ALERT_MBPS" 'net alert mbps'
    if [ "$CPU_ALERT_PCT" -lt 1 ] || [ "$CPU_ALERT_PCT" -gt 1000 ]; then
        check_result "$E_INVALID" "invalid docker cpu alert pct :: $CPU_ALERT_PCT"
    fi
    if [ "$MEM_ALERT_MB" -lt 1 ] || [ "$MEM_ALERT_MB" -gt 1048576 ]; then
        check_result "$E_INVALID" "invalid docker mem alert mb :: $MEM_ALERT_MB"
    fi
    if [ "$NET_ALERT_MBPS" -lt 1 ] || [ "$NET_ALERT_MBPS" -gt 100000 ]; then
        check_result "$E_INVALID" "invalid docker net alert mbps :: $NET_ALERT_MBPS"
    fi
    case "$ALERT_EMAIL" in
        yes|no) ;;
        *) check_result "$E_INVALID" "invalid docker alert email :: $ALERT_EMAIL" ;;
    esac
}

vx_docker_validate_domain() {
    [ -z "$DOMAIN" ] && return 0
    vx_docker_shell_quote_free "$DOMAIN" 'DOMAIN'
    is_domain_format_valid "$DOMAIN"
}

vx_docker_spec_defaults() {
    COMMAND="${COMMAND-}"
    ENV="${ENV-}"
    MOUNTS="${MOUNTS-}"
    DOMAIN="${DOMAIN-}"
    ROUTE_PATH="${ROUTE_PATH-}"
    AUTO_START="${AUTO_START-$VX_DOCKER_DEFAULT_AUTO_START}"
    RESTART_POLICY="${RESTART_POLICY-$VX_DOCKER_DEFAULT_RESTART_POLICY}"
    HEALTHCHECK_TYPE="${HEALTHCHECK_TYPE-$VX_DOCKER_DEFAULT_HEALTHCHECK_TYPE}"
    HEALTHCHECK_TARGET="${HEALTHCHECK_TARGET-}"
    HEALTHCHECK_INTERVAL="${HEALTHCHECK_INTERVAL-$VX_DOCKER_DEFAULT_HEALTHCHECK_INTERVAL}"
    CPU_ALERT_PCT="${CPU_ALERT_PCT-$VX_DOCKER_DEFAULT_CPU_ALERT_PCT}"
    MEM_ALERT_MB="${MEM_ALERT_MB-$VX_DOCKER_DEFAULT_MEM_ALERT_MB}"
    NET_ALERT_MBPS="${NET_ALERT_MBPS-$VX_DOCKER_DEFAULT_NET_ALERT_MBPS}"
    ALERT_EMAIL="${ALERT_EMAIL-$VX_DOCKER_DEFAULT_ALERT_EMAIL}"
}

vx_docker_unescape_double_quoted_spec_value() {
    local value="$1"

    value="${value//\\\\/---VX_DOCKER_BSLASH---}"
    value="${value//\\\"/\"}"
    value="${value//\\\$/\$}"
    value="${value//\\\`/\`}"
    value="${value//---VX_DOCKER_BSLASH---/\\}"
    echo "$value"
}

vx_docker_parse_spec_file() {
    local spec_file="$1"
    local line key raw_value value

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        raw_value="${line#*=}"

        if [ -z "$key" ] || [ "$key" = "$line" ]; then
            check_result "$E_INVALID" "invalid docker spec line :: $line"
        fi

        if ! [[ "$key" =~ ^[[:alnum:]][_[:alnum:]]{0,64}[[:alnum:]]$ ]]; then
            check_result "$E_INVALID" "Invalid key format [$key]"
        fi

        case "$raw_value" in
            \"*\")
                value="${raw_value#\"}"
                value="${value%\"}"
                value="$(vx_docker_unescape_double_quoted_spec_value "$value")"
                ;;
            \'*\')
                value="${raw_value#\'}"
                value="${value%\'}"
                value="${value//\\\'/\'}"
                ;;
            *)
                check_result "$E_INVALID" "invalid docker spec value :: $key"
                ;;
        esac

        declare -g "$key"="$value"
    done < "$spec_file"
}

vx_docker_load_spec() {
    local spec_file="$1"

    [ -f "$spec_file" ] || check_result "$E_NOTEXIST" "docker spec file doesn't exist"
    vx_docker_reset_record_vars
    vx_docker_parse_spec_file "$spec_file"
    vx_docker_spec_defaults
    [ -n "$NAME" ] || check_result "$E_ARGS" "docker spec missing NAME"
    [ -n "$IMAGE" ] || check_result "$E_ARGS" "docker spec missing IMAGE"
    [ -n "$CONTAINER_PORT" ] || check_result "$E_ARGS" "docker spec missing CONTAINER_PORT"
    vx_docker_validate_name
    vx_docker_validate_image
    vx_docker_validate_command
    vx_docker_validate_env
    vx_docker_validate_mounts
    vx_docker_validate_container_port
    vx_docker_validate_domain
    vx_docker_normalize_route_path
    vx_docker_validate_route_path
    vx_docker_validate_auto_start
    vx_docker_validate_restart_policy
    vx_docker_validate_healthcheck
    vx_docker_validate_alert_thresholds
}

vx_docker_derive_proxy_fields() {
    if [ -n "$DOMAIN" ]; then
        PROXY_MODE='proxy'
        PROXY_TARGET="http://127.0.0.1:${HOST_PORT}"
    else
        PROXY_MODE=''
        PROXY_TARGET=''
    fi
}

vx_docker_derive_persisted_health_target() {
    if [ "$HEALTHCHECK_TYPE" = 'http' ] && [ "$HEALTHCHECK_TARGET" = "http://127.0.0.1:${CONTAINER_PORT}/health" ]; then
        HEALTHCHECK_TARGET="http://127.0.0.1:${HOST_PORT}/health"
    fi
}

vx_docker_package_allows_container() {
    local owner="$1"
    local excluded_count="${2-0}"
    local user_conf="$VESTA/data/users/$owner/user.conf"
    local package_name package_file package_limit current_count

    package_name="$(grep "^PACKAGE=" "$user_conf" | cut -f 2 -d \')"
    [ -n "$package_name" ] || return 0
    package_file="$VESTA/data/packages/$package_name.pkg"
    [ -f "$package_file" ] || return 0
    package_limit="$(grep "^DOCKER_CONTAINERS=" "$package_file" | cut -f 2 -d \')"
    [ -n "$package_limit" ] || return 0
    [ "$package_limit" = 'unlimited' ] && return 0
    is_int_format_valid "$package_limit" 'docker containers'
    current_count="$(vx_docker_count_owner_records "$owner")"
    current_count=$((current_count - excluded_count))
    [ "$current_count" -lt 0 ] && current_count=0
    if [ "$current_count" -ge "$package_limit" ]; then
        check_result "$E_LIMIT" "DOCKER_CONTAINERS limit is reached :: upgrade user package"
    fi
}

vx_docker_build_record() {
    echo "NAME='$NAME' CTN_NAME='$CTN_NAME' OWNER='$OWNER' IMAGE='$IMAGE' COMMAND='$COMMAND' \
ENV='$ENV' MOUNTS='$MOUNTS' HOST_PORT='$HOST_PORT' CONTAINER_PORT='$CONTAINER_PORT' DOMAIN='$DOMAIN' ROUTE_PATH='$ROUTE_PATH' \
PROXY_MODE='$PROXY_MODE' PROXY_TARGET='$PROXY_TARGET' AUTO_START='$AUTO_START' RESTART_POLICY='$RESTART_POLICY' \
HEALTHCHECK_TYPE='$HEALTHCHECK_TYPE' HEALTHCHECK_TARGET='$HEALTHCHECK_TARGET' HEALTHCHECK_INTERVAL='$HEALTHCHECK_INTERVAL' \
HEALTH_STATUS='$HEALTH_STATUS' LAST_HEALTH_AT='$LAST_HEALTH_AT' CPU_ALERT_PCT='$CPU_ALERT_PCT' MEM_ALERT_MB='$MEM_ALERT_MB' \
NET_ALERT_MBPS='$NET_ALERT_MBPS' ALERT_EMAIL='$ALERT_EMAIL' STATUS='$STATUS' CREATED='$CREATED' UPDATED='$UPDATED'"
}

vx_docker_insert_record() {
    local owner="$1"

    vx_docker_metadata_touch "$owner"
    echo "$(vx_docker_build_record)" >> "$(vx_docker_metadata_path "$owner")"
}

vx_docker_replace_record() {
    local owner="$1"
    local name="$2"
    local conf tmp line new_record current_name

    conf="$(vx_docker_metadata_path "$owner")"
    tmp="$(mktemp)"
    new_record="$(vx_docker_build_record)"
    vx_docker_metadata_touch "$owner"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        vx_docker_parse_record "$line"
        current_name="$NAME"
        if [ "$current_name" != "$name" ]; then
            echo "$line" >> "$tmp"
        fi
    done < "$conf"
    echo "$new_record" >> "$tmp"
    mv "$tmp" "$conf"
    chmod 660 "$conf"
}

vx_docker_delete_record() {
    local owner="$1"
    local name="$2"
    local conf tmp line current_name

    conf="$(vx_docker_metadata_path "$owner")"
    [ -f "$conf" ] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        vx_docker_parse_record "$line"
        current_name="$NAME"
        if [ "$current_name" != "$name" ]; then
            echo "$line" >> "$tmp"
        fi
    done < "$conf"
    mv "$tmp" "$conf"
    chmod 660 "$conf"
}

vx_docker_adjust_user_counter() {
    local owner="$1"
    local action="$2"
    local key='U_DOCKER_CONTAINERS'

    if grep -q "^${key}=" "$VESTA/data/users/$owner/user.conf" 2>/dev/null; then
        case "$action" in
            increase) increase_user_value "$owner" "\$${key}" ;;
            decrease) decrease_user_value "$owner" "\$${key}" ;;
        esac
    fi
}

vx_docker_runtime_args() {
    local owner="$1"
    local mount_entry mount_name mount_path host_mount env_entry

    VX_DOCKER_RUNTIME_ARGS=(
        --name "$CTN_NAME"
        --label "${VX_DOCKER_LABEL_MANAGED_KEY}=${VX_DOCKER_LABEL_MANAGED_VALUE}"
        --label "${VX_DOCKER_LABEL_USER_KEY}=${owner}"
        --label "${VX_DOCKER_LABEL_NAME_KEY}=${NAME}"
        --restart "$RESTART_POLICY"
        -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}"
    )

    if [ -n "$ENV" ]; then
        while IFS= read -r env_entry; do
            [ -n "$env_entry" ] || continue
            VX_DOCKER_RUNTIME_ARGS+=(-e "$env_entry")
        done <<< "${ENV//||/$'\n'}"
    fi

    if [ -n "$MOUNTS" ]; then
        while IFS= read -r mount_entry; do
            [ -n "$mount_entry" ] || continue
            mount_name="${mount_entry%%:*}"
            mount_path="${mount_entry#*:}"
            host_mount="$(vx_docker_bind_root "$owner" "$NAME")/$mount_name"
            mkdir -p "$host_mount"
            if id -u "$owner" >/dev/null 2>&1; then
                chown "$owner:$owner" "$host_mount" 2>/dev/null
            fi
            VX_DOCKER_RUNTIME_ARGS+=(-v "${host_mount}:${mount_path}")
        done <<< "${MOUNTS//||/$'\n'}"
    fi
}

vx_docker_create_runtime() {
    local owner="$1"
    local mode="$2"

    vx_docker_runtime_args "$owner"
    if [ "$mode" = 'create' ]; then
        if [ -n "$COMMAND" ]; then
            docker create "${VX_DOCKER_RUNTIME_ARGS[@]}" "$IMAGE" /bin/sh -lc "$COMMAND" >/dev/null
        else
            docker create "${VX_DOCKER_RUNTIME_ARGS[@]}" "$IMAGE" >/dev/null
        fi
    else
        if [ -n "$COMMAND" ]; then
            docker run -d "${VX_DOCKER_RUNTIME_ARGS[@]}" "$IMAGE" /bin/sh -lc "$COMMAND" >/dev/null
        else
            docker run -d "${VX_DOCKER_RUNTIME_ARGS[@]}" "$IMAGE" >/dev/null
        fi
    fi
}

vx_docker_remove_runtime_if_present() {
    local ctn_name="$1"

    if docker container inspect "$ctn_name" >/dev/null 2>&1; then
        docker rm -f "$ctn_name" >/dev/null
    fi
}

vx_docker_owner_is_suspended() {
    local owner="$1"
    local user_conf="$VESTA/data/users/$owner/user.conf"

    [ -f "$user_conf" ] || return 1
    grep -q "^SUSPENDED='yes'" "$user_conf"
}

vx_docker_refresh_runtime_metadata() {
    local owner="$1"
    local name="$2"

    vx_docker_load_record "$owner" "$name" || check_result "$E_NOTEXIST" "docker container $name doesn't exist"
    STATUS="$(vx_docker_runtime_state "$CTN_NAME")"
    UPDATED="$(vx_docker_now)"
    vx_docker_replace_record "$owner" "$NAME"

    if [ -n "$DOMAIN" ] && vx_docker_owner_domain_exists "$owner" "$DOMAIN"; then
        $BIN/v-sync-docker-container-route "$owner" "$NAME"
        check_result $? "docker route sync failed"
    fi
}

vx_docker_rehydrate_runtime() {
    local owner="$1"
    local name="$2"
    local mode='create'

    vx_docker_load_record "$owner" "$name" || check_result "$E_NOTEXIST" "docker container $name doesn't exist"
    vx_docker_ensure_bind_root "$owner" "$NAME"

    if docker container inspect "$CTN_NAME" >/dev/null 2>&1; then
        vx_docker_assert_runtime_labels_match "$owner" "$NAME" "$CTN_NAME"
    else
        case "$STATUS" in
            running|restarting)
                mode='run'
                ;;
            created|exited|paused|dead)
                mode='create'
                ;;
            *)
                if [ "$AUTO_START" = 'yes' ]; then
                    mode='run'
                fi
                ;;
        esac

        if vx_docker_owner_is_suspended "$owner"; then
            mode='create'
        fi

        vx_docker_create_runtime "$owner" "$mode"
        check_result $? "docker container recreate failed"
        vx_docker_assert_runtime_labels_match "$owner" "$NAME" "$CTN_NAME"
    fi

    STATUS="$(vx_docker_runtime_state "$CTN_NAME")"
    HEALTH_STATUS='unknown'
    LAST_HEALTH_AT=''
    UPDATED="$(vx_docker_now)"
    vx_docker_replace_record "$owner" "$NAME"

    if [ -n "$DOMAIN" ] && vx_docker_owner_domain_exists "$owner" "$DOMAIN"; then
        $BIN/v-sync-docker-container-route "$owner" "$NAME"
        check_result $? "docker route sync failed"
    fi
}

vx_docker_runtime_state() {
    local ctn_name="$1"

    if docker container inspect "$ctn_name" >/dev/null 2>&1; then
        docker inspect --format '{{.State.Status}}' "$ctn_name"
    else
        echo 'unknown'
    fi
}

is_docker_engine_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

ensure_docker_engine_available() {
    if ! is_docker_engine_available; then
        echo "Error: Docker is not installed"
        exit "$E_DISABLED"
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "Error: Docker daemon is not available"
        exit "$E_DISABLED"
    fi
}

ensure_docker_container_name_provided() {
    local container_name="$1"

    if [ -z "$container_name" ]; then
        echo "Error: Container name is required"
        exit "$E_ARGS"
    fi
}

ensure_docker_container_exists() {
    local container_name="$1"

    if ! docker container inspect "$container_name" >/dev/null 2>&1; then
        echo "Error: Container $container_name does not exist"
        exit "$E_NOTEXIST"
    fi
}

vx_docker_rrd_dir() {
    echo "$RRD/docker"
}

vx_docker_rrd_slug() {
    echo "${1}_${2}"
}

vx_docker_rrd_path() {
    echo "$(vx_docker_rrd_dir)/$(vx_docker_rrd_slug "$1" "$2").rrd"
}

vx_docker_rrd_png_path() {
    echo "$(vx_docker_rrd_dir)/$3-$(vx_docker_rrd_slug "$1" "$2").png"
}

vx_docker_alerts_path() {
    echo "$VESTA/data/users/$1/docker-alerts.conf"
}

vx_docker_alerts_lock_path() {
    echo "$(vx_docker_alerts_path "$1").lock"
}

vx_docker_alerts_touch() {
    local owner="$1"
    local conf lock_path

    conf="$(vx_docker_alerts_path "$owner")"
    lock_path="$(vx_docker_alerts_lock_path "$owner")"
    touch "$conf"
    touch "$lock_path"
    chmod 660 "$conf"
    chmod 660 "$lock_path"
}

vx_docker_alerts_lock() {
    local owner="$1"

    vx_docker_alerts_touch "$owner"
    VX_DOCKER_ALERTS_LOCK_PATH="$(vx_docker_alerts_lock_path "$owner")"
    exec {VX_DOCKER_ALERTS_LOCK_FD}>>"$VX_DOCKER_ALERTS_LOCK_PATH"
    flock -x "$VX_DOCKER_ALERTS_LOCK_FD"
}

vx_docker_alerts_unlock() {
    if [ -n "${VX_DOCKER_ALERTS_LOCK_FD-}" ]; then
        flock -u "$VX_DOCKER_ALERTS_LOCK_FD" >/dev/null 2>&1 || true
        eval "exec ${VX_DOCKER_ALERTS_LOCK_FD}>&-"
        unset VX_DOCKER_ALERTS_LOCK_FD VX_DOCKER_ALERTS_LOCK_PATH
    fi
}

vx_docker_healthcheck_due() {
    local owner="$1"
    local name="$2"
    local now_epoch last_epoch interval

    vx_docker_load_record "$owner" "$name" || return 0

    if [ -z "$LAST_HEALTH_AT" ] || [ -z "$HEALTHCHECK_INTERVAL" ]; then
        return 0
    fi

    if ! [[ "$HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    last_epoch="$(date -d "$LAST_HEALTH_AT" +%s 2>/dev/null)" || return 0
    now_epoch="$(date +%s)"
    interval="$HEALTHCHECK_INTERVAL"

    [ $((now_epoch - last_epoch)) -ge "$interval" ]
}

vx_docker_reset_alert_vars() {
    unset AID NAME OWNER LEVEL TYPE STATUS TITLE MESSAGE STARTED LAST_SEEN ACK
}

vx_docker_parse_alert_record() {
    vx_docker_reset_alert_vars
    parse_object_kv_list_non_eval "$1"
}

vx_docker_is_numeric() {
    [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

vx_docker_float_to_json_number() {
    awk -v value="$1" 'BEGIN {
        if (value == "" || value == "U" || value == "-nan" || value == "nan") {
            exit 1
        }
        number = value + 0
        if (number == int(number)) {
            printf "%d", number
        } else {
            printf "%.6f", number
        }
    }'
}

vx_docker_ts_utc() {
    date -u -d "@$1" +'%Y-%m-%dT%H:%M:%SZ'
}

vx_docker_human_size_to_bytes() {
    local value="${1// /}"
    local number unit

    if [ -z "$value" ] || [ "$value" = '--' ]; then
        echo ''
        return 1
    fi

    if ! [[ "$value" =~ ^([0-9]+([.][0-9]+)?)([A-Za-z]+)$ ]]; then
        echo ''
        return 1
    fi

    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"

    awk -v number="$number" -v unit="$unit" 'BEGIN {
        mult = 0
        if (unit == "B") mult = 1
        else if (unit == "kB" || unit == "KB") mult = 1000
        else if (unit == "MB") mult = 1000 * 1000
        else if (unit == "GB") mult = 1000 * 1000 * 1000
        else if (unit == "TB") mult = 1000 * 1000 * 1000 * 1000
        else if (unit == "KiB") mult = 1024
        else if (unit == "MiB") mult = 1024 * 1024
        else if (unit == "GiB") mult = 1024 * 1024 * 1024
        else if (unit == "TiB") mult = 1024 * 1024 * 1024 * 1024
        if (mult == 0) {
            exit 1
        }
        printf "%.0f", number * mult
    }'
}

vx_docker_bytes_to_mb() {
    awk -v bytes="$1" 'BEGIN { printf "%.6f", bytes / 1048576 }'
}

vx_docker_mbps_from_bytes_per_second() {
    awk -v bytes="$1" 'BEGIN { printf "%.6f", bytes / 1048576 }'
}

vx_docker_sample_live_stats() {
    local ctn_name="$1"
    local sample cpu_raw mem_raw net_raw mem_used rx_raw tx_raw

    VX_DOCKER_SAMPLE_CPU_PCT=''
    VX_DOCKER_SAMPLE_MEM_MB=''
    VX_DOCKER_SAMPLE_RX_BYTES=''
    VX_DOCKER_SAMPLE_TX_BYTES=''

    if ! is_docker_engine_available; then
        return 1
    fi

    if ! docker container inspect "$ctn_name" >/dev/null 2>&1; then
        return 1
    fi

    sample="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' "$ctn_name" 2>/dev/null | head -n 1)"
    [ -n "$sample" ] || return 1

    cpu_raw="$(echo "$sample" | cut -d '|' -f 2)"
    mem_raw="$(echo "$sample" | cut -d '|' -f 3)"
    net_raw="$(echo "$sample" | cut -d '|' -f 4)"

    VX_DOCKER_SAMPLE_CPU_PCT="${cpu_raw%\%}"
    mem_used="${mem_raw%% / *}"
    VX_DOCKER_SAMPLE_MEM_MB="$(vx_docker_bytes_to_mb "$(vx_docker_human_size_to_bytes "$mem_used")")" || VX_DOCKER_SAMPLE_MEM_MB=''

    rx_raw="${net_raw%% / *}"
    tx_raw="${net_raw##* / }"
    VX_DOCKER_SAMPLE_RX_BYTES="$(vx_docker_human_size_to_bytes "$rx_raw")" || VX_DOCKER_SAMPLE_RX_BYTES=''
    VX_DOCKER_SAMPLE_TX_BYTES="$(vx_docker_human_size_to_bytes "$tx_raw")" || VX_DOCKER_SAMPLE_TX_BYTES=''

    vx_docker_is_numeric "$VX_DOCKER_SAMPLE_CPU_PCT" || VX_DOCKER_SAMPLE_CPU_PCT=''
    vx_docker_is_numeric "$VX_DOCKER_SAMPLE_MEM_MB" || VX_DOCKER_SAMPLE_MEM_MB=''
    vx_docker_is_numeric "$VX_DOCKER_SAMPLE_RX_BYTES" || VX_DOCKER_SAMPLE_RX_BYTES=''
    vx_docker_is_numeric "$VX_DOCKER_SAMPLE_TX_BYTES" || VX_DOCKER_SAMPLE_TX_BYTES=''
}

vx_docker_rrd_period_graph_window() {
    case "$1" in
        daily)   VX_DOCKER_RRD_START='-1d'; VX_DOCKER_RRD_END='now'; VX_DOCKER_RRD_GRID='MINUTE:30:HOUR:1:HOUR:4:0:%H:%M' ;;
        weekly)  VX_DOCKER_RRD_START='-7d'; VX_DOCKER_RRD_END='now'; VX_DOCKER_RRD_GRID='HOUR:8:DAY:1:DAY:1:0:%a %d' ;;
        monthly) VX_DOCKER_RRD_START='-1m'; VX_DOCKER_RRD_END='now'; VX_DOCKER_RRD_GRID='WEEK:1:WEEK:1:WEEK:1:0:%b %d' ;;
        yearly)  VX_DOCKER_RRD_START='-1y'; VX_DOCKER_RRD_END='now'; VX_DOCKER_RRD_GRID='MONTH:1:YEAR:1:MONTH:2:2419200:%b' ;;
        *) return 1 ;;
    esac
}

vx_docker_stats_period_fetch_start() {
    case "$1" in
        5m) echo '-5m' ;;
        1h) echo '-1h' ;;
        1d) echo '-1d' ;;
        7d) echo '-7d' ;;
        *) return 1 ;;
    esac
}

vx_docker_ensure_rrd_dir() {
    local dir

    dir="$(vx_docker_rrd_dir)"
    [ -d "$dir" ] || mkdir -p "$dir"
}

vx_docker_ensure_rrd_file() {
    local owner="$1"
    local name="$2"
    local rrd_path

    vx_docker_ensure_rrd_dir
    rrd_path="$(vx_docker_rrd_path "$owner" "$name")"
    if [ ! -e "$rrd_path" ]; then
        rrdtool create "$rrd_path" --step "$RRD_STEP" \
            DS:CPU:GAUGE:600:U:U \
            DS:MEM:GAUGE:600:U:U \
            DS:RX:DERIVE:600:0:U \
            DS:TX:DERIVE:600:0:U \
            RRA:AVERAGE:0.5:1:600 \
            RRA:AVERAGE:0.5:6:700 \
            RRA:AVERAGE:0.5:24:775 \
            RRA:AVERAGE:0.5:288:797 \
            RRA:MAX:0.5:1:600 \
            RRA:MAX:0.5:6:700 \
            RRA:MAX:0.5:24:775 \
            RRA:MAX:0.5:288:797 >/dev/null
    else
        touch "$rrd_path"
    fi
}

vx_docker_update_rrd_sample() {
    local owner="$1"
    local name="$2"
    local cpu="${3-U}"
    local mem="${4-U}"
    local rx="${5-U}"
    local tx="${6-U}"
    local rrd_path

    vx_docker_ensure_rrd_file "$owner" "$name"
    rrd_path="$(vx_docker_rrd_path "$owner" "$name")"
    rrdtool update "$rrd_path" "N:${cpu}:${mem}:${rx}:${tx}" >/dev/null
}

vx_docker_graph_rrd() {
    local owner="$1"
    local name="$2"
    local period="$3"
    local rrd_path png_path title

    vx_docker_rrd_period_graph_window "$period" || return 1
    vx_docker_ensure_rrd_file "$owner" "$name"
    rrd_path="$(vx_docker_rrd_path "$owner" "$name")"
    png_path="$(vx_docker_rrd_png_path "$owner" "$name" "$period")"
    title="Docker ${owner}/${name}"

    rrdtool graph "$png_path" \
        --start "$VX_DOCKER_RRD_START" \
        --end "$VX_DOCKER_RRD_END" \
        --slope-mode \
        --title "$title" \
        --width 800 \
        --height 154 \
        --vertical-label "CPU/MEM/MBps" \
        --x-grid "$VX_DOCKER_RRD_GRID" \
        DEF:cpu="$rrd_path":CPU:AVERAGE \
        DEF:mem="$rrd_path":MEM:AVERAGE \
        DEF:rx="$rrd_path":RX:AVERAGE \
        DEF:tx="$rrd_path":TX:AVERAGE \
        CDEF:rxmbps=rx,1048576,/ \
        CDEF:txmbps=tx,1048576,/ \
        LINE1:cpu#1d3557:"CPU %" \
        GPRINT:cpu:LAST:"Current\\:%6.2lf" \
        GPRINT:cpu:AVERAGE:"Avg\\:%6.2lf" \
        GPRINT:cpu:MAX:"Max\\:%6.2lf\\n" \
        LINE1:mem#e76f51:"MEM MB" \
        GPRINT:mem:LAST:"Current\\:%6.2lf" \
        GPRINT:mem:AVERAGE:"Avg\\:%6.2lf" \
        GPRINT:mem:MAX:"Max\\:%6.2lf\\n" \
        LINE1:rxmbps#2a9d8f:"RX MB/s" \
        GPRINT:rxmbps:LAST:"Current\\:%6.2lf" \
        GPRINT:rxmbps:AVERAGE:"Avg\\:%6.2lf" \
        GPRINT:rxmbps:MAX:"Max\\:%6.2lf\\n" \
        LINE1:txmbps#264653:"TX MB/s" \
        GPRINT:txmbps:LAST:"Current\\:%6.2lf" \
        GPRINT:txmbps:AVERAGE:"Avg\\:%6.2lf" \
        GPRINT:txmbps:MAX:"Max\\:%6.2lf\\n" >/dev/null
}

vx_docker_rrd_fetch_rows() {
    local owner="$1"
    local name="$2"
    local period="$3"
    local start rrd_path line ts cpu mem rx tx rx_mb tx_mb

    start="$(vx_docker_stats_period_fetch_start "$period")" || return 1
    rrd_path="$(vx_docker_rrd_path "$owner" "$name")"
    [ -f "$rrd_path" ] || return 0

    while IFS= read -r line; do
        case "$line" in
            *:*)
                ts="${line%%:*}"
                ts="${ts// /}"
                [ -n "$ts" ] || continue
                if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
                    continue
                fi
                cpu="$(echo "$line" | awk '{print $2}')"
                mem="$(echo "$line" | awk '{print $3}')"
                rx="$(echo "$line" | awk '{print $4}')"
                tx="$(echo "$line" | awk '{print $5}')"
                if [ "$rx" = '-nan' ] || [ "$rx" = 'nan' ] || [ -z "$rx" ]; then
                    rx_mb=''
                else
                    rx_mb="$(vx_docker_mbps_from_bytes_per_second "$rx")"
                fi
                if [ "$tx" = '-nan' ] || [ "$tx" = 'nan' ] || [ -z "$tx" ]; then
                    tx_mb=''
                else
                    tx_mb="$(vx_docker_mbps_from_bytes_per_second "$tx")"
                fi
                echo "${ts}|${cpu}|${mem}|${rx_mb}|${tx_mb}"
                ;;
        esac
    done < <(rrdtool fetch "$rrd_path" AVERAGE --start "$start" --end now 2>/dev/null)
}

vx_docker_rrd_latest_rates() {
    local owner="$1"
    local name="$2"
    local last_line

    VX_DOCKER_LATEST_RX_MBPS=''
    VX_DOCKER_LATEST_TX_MBPS=''

    while IFS= read -r last_line; do
        [ -n "$last_line" ] || continue
        rx="${last_line##*|}"
        tx="${rx#*|}"
    done < <(vx_docker_rrd_fetch_rows "$owner" "$name" '5m')

    if [ -n "$last_line" ]; then
        VX_DOCKER_LATEST_RX_MBPS="$(echo "$last_line" | cut -d '|' -f 4)"
        VX_DOCKER_LATEST_TX_MBPS="$(echo "$last_line" | cut -d '|' -f 5)"
    fi
}

vx_docker_docker_native_health() {
    local ctn_name="$1"
    local health

    VX_DOCKER_NATIVE_HEALTH=''
    if ! is_docker_engine_available; then
        return 1
    fi

    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$ctn_name" 2>/dev/null)"
    [ -n "$health" ] || return 1

    case "$health" in
        healthy|starting|unhealthy)
            VX_DOCKER_NATIVE_HEALTH="$health"
            return 0
            ;;
    esac

    return 1
}

vx_docker_health_target_check() {
    local type="$1"
    local target="$2"
    local host port

    case "$type" in
        http)
            curl -fsS --max-time "$VX_DOCKER_HEALTHCHECK_TIMEOUT" "$target" >/dev/null 2>&1
            return $?
            ;;
        tcp)
            host="${target%%:*}"
            port="${target##*:}"
            nc -z -w "$VX_DOCKER_HEALTHCHECK_TIMEOUT" "$host" "$port" >/dev/null 2>&1
            return $?
            ;;
    esac

    return 1
}

vx_docker_evaluate_health_status() {
    local owner="$1"
    local name="$2"
    local runtime_status previous_health

    vx_docker_load_record "$owner" "$name" || return 1
    runtime_status="$(vx_docker_runtime_state "$CTN_NAME")"
    previous_health="${HEALTH_STATUS:-unknown}"

    if vx_docker_docker_native_health "$CTN_NAME"; then
        case "$VX_DOCKER_NATIVE_HEALTH" in
            healthy) VX_DOCKER_HEALTH_RESULT='healthy' ;;
            starting) VX_DOCKER_HEALTH_RESULT='starting' ;;
            unhealthy) VX_DOCKER_HEALTH_RESULT='unhealthy' ;;
        esac
        return 0
    fi

    case "$HEALTHCHECK_TYPE" in
        http|tcp)
            if vx_docker_health_target_check "$HEALTHCHECK_TYPE" "$HEALTHCHECK_TARGET"; then
                VX_DOCKER_HEALTH_RESULT='healthy'
            else
                if [ "$runtime_status" != 'running' ] || [ "$previous_health" = 'degraded' ] || [ "$previous_health" = 'unhealthy' ]; then
                    VX_DOCKER_HEALTH_RESULT='unhealthy'
                else
                    VX_DOCKER_HEALTH_RESULT='degraded'
                fi
            fi
            ;;
        *)
            VX_DOCKER_HEALTH_RESULT='unknown'
            ;;
    esac
}

vx_docker_build_alert_record() {
    echo "AID='$AID' NAME='$NAME' OWNER='$OWNER' LEVEL='$LEVEL' TYPE='$TYPE' STATUS='$STATUS' TITLE='$TITLE' MESSAGE='$MESSAGE' STARTED='$STARTED' LAST_SEEN='$LAST_SEEN' ACK='$ACK'"
}

vx_docker_next_alert_id() {
    local owner="$1"
    local path next_id

    path="$(vx_docker_alerts_path "$owner")"
    next_id=1
    if [ -f "$path" ]; then
        next_id="$(grep -o "AID='[0-9]*'" "$path" 2>/dev/null | cut -d "'" -f 2 | sort -n | tail -n 1)"
        if [ -n "$next_id" ]; then
            next_id=$((next_id + 1))
        else
            next_id=1
        fi
    fi

    echo "$next_id"
}

vx_docker_sync_alert_record() {
    local owner="$1"
    local name="$2"
    local type="$3"
    local level="$4"
    local title="$5"
    local message="$6"
    local active="$7"
    local notify_topic="$8"
    local notify_type="$9"
    local path tmp line matched_open existing_ack updated opened now

    path="$(vx_docker_alerts_path "$owner")"
    vx_docker_alerts_lock "$owner"
    tmp="$(mktemp)"
    now="$(vx_docker_now)"
    matched_open='no'
    updated='no'
    opened='no'

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        vx_docker_parse_alert_record "$line"
        if [ "$OWNER" = "$owner" ] && [ "$NAME" = "$name" ] && [ "$TYPE" = "$type" ] && [ "$STATUS" = 'open' ]; then
            matched_open='yes'
            if [ "$active" = 'yes' ]; then
                existing_ack="${ACK-no}"
                AID="$AID"
                NAME="$name"
                OWNER="$owner"
                LEVEL="$level"
                TYPE="$type"
                STATUS='open'
                TITLE="$title"
                MESSAGE="$message"
                STARTED="${STARTED-$now}"
                LAST_SEEN="$now"
                ACK="${existing_ack:-no}"
                echo "$(vx_docker_build_alert_record)" >> "$tmp"
                updated='yes'
            else
                AID="$AID"
                NAME="$name"
                OWNER="$owner"
                LEVEL="${LEVEL-$level}"
                TYPE="$type"
                STATUS='closed'
                TITLE="${TITLE-$title}"
                MESSAGE="$message"
                STARTED="${STARTED-$now}"
                LAST_SEEN="$now"
                ACK="${ACK-no}"
                echo "$(vx_docker_build_alert_record)" >> "$tmp"
                updated='yes'
            fi
        else
            echo "$line" >> "$tmp"
        fi
    done < "$path"

    if [ "$active" = 'yes' ] && [ "$matched_open" = 'no' ]; then
        AID="$(vx_docker_next_alert_id "$owner")"
        NAME="$name"
        OWNER="$owner"
        LEVEL="$level"
        TYPE="$type"
        STATUS='open'
        TITLE="$title"
        MESSAGE="$message"
        STARTED="$now"
        LAST_SEEN="$now"
        ACK='no'
        echo "$(vx_docker_build_alert_record)" >> "$tmp"
        opened='yes'
        updated='yes'
    fi

    mv "$tmp" "$path"
    chmod 660 "$path"
    vx_docker_alerts_unlock

    if [ "$opened" = 'yes' ] && [ "$ALERT_EMAIL" = 'yes' ] && [ -n "$notify_topic" ]; then
        "$BIN/v-add-user-notification" "$owner" "$notify_topic" '/list/docker/' "$notify_type" >/dev/null 2>&1
    fi

    [ "$updated" = 'yes' ]
}

vx_docker_sync_threshold_alerts() {
    local owner="$1"
    local name="$2"
    local cpu="$3"
    local mem="$4"
    local rx_mbps="$5"
    local tx_mbps="$6"
    local net_peak active network_message

    vx_docker_load_record "$owner" "$name" || return 1

    if [ -n "$cpu" ] && awk -v current="$cpu" -v limit="$CPU_ALERT_PCT" 'BEGIN { exit !(current > limit) }'; then
        vx_docker_sync_alert_record "$owner" "$name" 'cpu' 'warning' \
            'CPU threshold exceeded' \
            "CPU usage ${cpu}% exceeds threshold ${CPU_ALERT_PCT}%." \
            'yes' \
            "Docker alert: ${name} CPU high" \
            'warning'
    else
        vx_docker_sync_alert_record "$owner" "$name" 'cpu' 'warning' \
            'CPU threshold exceeded' \
            "CPU usage is within threshold ${CPU_ALERT_PCT}%." \
            'no' '' ''
    fi

    if [ -n "$mem" ] && awk -v current="$mem" -v limit="$MEM_ALERT_MB" 'BEGIN { exit !(current > limit) }'; then
        vx_docker_sync_alert_record "$owner" "$name" 'memory' 'warning' \
            'Memory threshold exceeded' \
            "Memory usage ${mem} MB exceeds threshold ${MEM_ALERT_MB} MB." \
            'yes' \
            "Docker alert: ${name} memory high" \
            'warning'
    else
        vx_docker_sync_alert_record "$owner" "$name" 'memory' 'warning' \
            'Memory threshold exceeded' \
            "Memory usage is within threshold ${MEM_ALERT_MB} MB." \
            'no' '' ''
    fi

    net_peak=''
    network_message=''
    if [ -n "$rx_mbps" ] && awk -v current="$rx_mbps" -v limit="$NET_ALERT_MBPS" 'BEGIN { exit !(current > limit) }'; then
        net_peak="$rx_mbps"
        network_message="RX ${rx_mbps} MB/s exceeds threshold ${NET_ALERT_MBPS} MB/s."
    fi
    if [ -n "$tx_mbps" ] && awk -v current="$tx_mbps" -v limit="$NET_ALERT_MBPS" 'BEGIN { exit !(current > limit) }'; then
        if [ -n "$network_message" ]; then
            network_message="${network_message} TX ${tx_mbps} MB/s exceeds threshold ${NET_ALERT_MBPS} MB/s."
        else
            network_message="TX ${tx_mbps} MB/s exceeds threshold ${NET_ALERT_MBPS} MB/s."
        fi
        if [ -z "$net_peak" ] || awk -v current="$tx_mbps" -v peak="$net_peak" 'BEGIN { exit !(current > peak) }'; then
            net_peak="$tx_mbps"
        fi
    fi

    if [ -n "$network_message" ]; then
        vx_docker_sync_alert_record "$owner" "$name" 'network' 'warning' \
            'Network threshold exceeded' \
            "$network_message" \
            'yes' \
            "Docker alert: ${name} network high" \
            'warning'
    else
        vx_docker_sync_alert_record "$owner" "$name" 'network' 'warning' \
            'Network threshold exceeded' \
            "Network usage is within threshold ${NET_ALERT_MBPS} MB/s." \
            'no' '' ''
    fi
}

vx_docker_sync_health_alert() {
    local owner="$1"
    local name="$2"
    local health_status="$3"

    vx_docker_load_record "$owner" "$name" || return 1

    case "$health_status" in
        degraded)
            vx_docker_sync_alert_record "$owner" "$name" 'health' 'warning' \
                'Health check degraded' \
                "Health status for ${name} is degraded." \
                'yes' \
                "Docker alert: ${name} degraded" \
                'warning'
            ;;
        unhealthy)
            vx_docker_sync_alert_record "$owner" "$name" 'health' 'critical' \
                'Health check unhealthy' \
                "Health status for ${name} is unhealthy." \
                'yes' \
                "Docker alert: ${name} unhealthy" \
                'error'
            ;;
        *)
            vx_docker_sync_alert_record "$owner" "$name" 'health' 'warning' \
                'Health check healthy' \
                "Health status for ${name} is ${health_status}." \
                'no' '' ''
            ;;
    esac
}

vx_docker_acknowledge_alert() {
    local owner="$1"
    local aid="$2"
    local path tmp line found

    path="$(vx_docker_alerts_path "$owner")"
    [ -f "$path" ] || return 1
    vx_docker_alerts_lock "$owner"
    tmp="$(mktemp)"
    found='no'

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        vx_docker_parse_alert_record "$line"
        if [ "$AID" = "$aid" ]; then
            ACK='yes'
            echo "$(vx_docker_build_alert_record)" >> "$tmp"
            found='yes'
        else
            echo "$line" >> "$tmp"
        fi
    done < "$path"

    mv "$tmp" "$path"
    chmod 660 "$path"
    vx_docker_alerts_unlock

    [ "$found" = 'yes' ]
}
