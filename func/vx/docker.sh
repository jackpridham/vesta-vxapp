#!/bin/bash

VX_DOCKER_PORT_START=21000
VX_DOCKER_PORT_END=29999
VX_DOCKER_LABEL_MANAGED_KEY='vx.managed'
VX_DOCKER_LABEL_MANAGED_VALUE='yes'
VX_DOCKER_LABEL_USER_KEY='vx.user'
VX_DOCKER_LABEL_NAME_KEY='vx.name'

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

    source "$VESTA/func/vx/proxy.sh"
    vx_proxy_update_web_conf

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

    source "$VESTA/func/vx/proxy.sh"
    vx_proxy_clear_web_conf

    user="$saved_user"
    USER_DATA="$saved_user_data"
}

is_docker_engine_available() {
    command -v docker >/dev/null 2>&1
}

ensure_docker_engine_available() {
    if ! is_docker_engine_available; then
        echo "Error: Docker is not installed"
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
