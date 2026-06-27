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

vx_docker_domain_matches_record_route() {
    local owner="$1"
    local name="$2"
    local route_target

    vx_docker_load_record "$owner" "$name" || return 1
    [ -n "$DOMAIN" ] || return 1
    route_target="$(vx_docker_domain_proxy_target "$owner" "$DOMAIN")" || return 1
    [ "$route_target" = "http://127.0.0.1:${HOST_PORT}" ]
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
            if ! [[ "$HEALTHCHECK_TARGET" =~ ^https?:// ]]; then
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
}

vx_docker_validate_alert_thresholds() {
    is_int_format_valid "$CPU_ALERT_PCT" 'cpu alert pct'
    is_int_format_valid "$MEM_ALERT_MB" 'mem alert mb'
    is_int_format_valid "$NET_ALERT_MBPS" 'net alert mbps'
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

vx_docker_load_spec() {
    local spec_file="$1"
    local parse_double_quotes_var_backup="${PARSE_DOUBLE_QUOTES_VAR-}"

    [ -f "$spec_file" ] || check_result "$E_NOTEXIST" "docker spec file doesn't exist"
    vx_docker_reset_record_vars
    PARSE_DOUBLE_QUOTES_VAR='yes'
    parse_object_kv_list_non_eval "$(cat "$spec_file")"
    if [ -n "$parse_double_quotes_var_backup" ]; then
        PARSE_DOUBLE_QUOTES_VAR="$parse_double_quotes_var_backup"
    else
        unset PARSE_DOUBLE_QUOTES_VAR
    fi
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
    command -v docker >/dev/null 2>&1
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
