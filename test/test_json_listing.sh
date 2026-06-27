#!/bin/bash

if [ ! -f /etc/profile.d/vesta.sh ]; then
    echo "SKIP: /etc/profile.d/vesta.sh is unavailable on this host."
    exit 0
fi

source /etc/profile.d/vesta.sh

if [ -z "$VESTA" ] || [ ! -d "$VESTA/bin" ]; then
    echo "SKIP: Vesta runtime is unavailable on this host."
    exit 0
fi

set -o pipefail

V_BIN="$VESTA/bin"
V_TEST="$VESTA/test"
TMP_ROOT="${TMPDIR:-/tmp}"
DOCKER_TEST_IMAGE="${DOCKER_TEST_IMAGE:-busybox:latest}"
FAILED=0

random() {
    local matrix='0123456789'
    local length="$1"
    local value=''
    local n=0

    while [ "$n" -lt "$length" ]; do
        value="${value}${matrix:$((RANDOM % ${#matrix})):1}"
        n=$((n + 1))
    done

    echo "$value"
}

write_spec() {
    local path="$1"
    local name="$2"

    cat >"$path" <<EOF
NAME='$name'
IMAGE='$DOCKER_TEST_IMAGE'
COMMAND='sleep 3600'
ENV='MODE=json-list'
MOUNTS='data:/data'
CONTAINER_PORT='8080'
DOMAIN=''
ROUTE_PATH=''
AUTO_START='no'
RESTART_POLICY='unless-stopped'
HEALTHCHECK_TYPE='none'
HEALTHCHECK_TARGET=''
HEALTHCHECK_INTERVAL='60'
CPU_ALERT_PCT='85'
MEM_ALERT_MB='1024'
NET_ALERT_MBPS='50'
ALERT_EMAIL='yes'
EOF
}

cleanup() {
    if [ -n "${json_user:-}" ] && [ -d "$VESTA/data/users/$json_user" ]; then
        "$V_BIN/v-delete-user" "$json_user" yes >/dev/null 2>&1 || true
    fi

    if [ -n "${json_package:-}" ] && [ -f "$VESTA/data/packages/${json_package}.pkg" ]; then
        "$V_BIN/v-delete-user-package" "$json_package" >/dev/null 2>&1 || true
    fi

    [ -n "${json_tmpdir:-}" ] && rm -rf "$json_tmpdir"
}

trap cleanup EXIT

commands='v_list_cron_jobs admin json
v_list_databases admin json
v_list_database admin admin_vesta json
v_list_database_server mysql localhost json
v_list_database_servers mysql json
v_check_docker_engine json
v_list_dns_domains admin json
v_list_mail_domains admin json
v_list_dns_templates json
v_list_mail_domains admin json
v_list_sys_config json
v_list_sys_interfaces json
v_list_sys_ips json
v_list_sys_rrd json
v_list_user admin json
v_list_user_backups admin json
v_list_user_ips admin json
v_list_user_ns admin json
v_list_user_packages json
v_list_users json
v_list_docker_containers admin json
v_list_web_domains admin json
v_list_web_domain admin default.vesta.domain json
v_list_web_templates admin json
v_list_web_templates_nginx admin json'

docker_owner=''
docker_name=''
docker_commands_added='no'
for docker_conf in "$VESTA"/data/users/*/docker.conf; do
    [ -s "$docker_conf" ] || continue
    docker_owner=$(basename "$(dirname "$docker_conf")")
    docker_name=$(awk -F"'" '/^NAME=/{print $2; exit}' "$docker_conf")
    if [ -n "$docker_owner" ] && [ -n "$docker_name" ]; then
        break
    fi
done

if [ -z "$docker_owner" ] || [ -z "$docker_name" ]; then
    if "$V_BIN/v-check-docker-engine" >/dev/null 2>&1; then
        json_tmpdir="$(mktemp -d -p "$TMP_ROOT")"
        suffix="$(random 4)"
        json_package="jsond${suffix}"
        json_user="jsonu${suffix}"
        json_pass="T3st-${suffix}-J!"
        json_mail="${json_user}@local.test"
        docker_owner="$json_user"
        docker_name="json${suffix}"
        json_spec="${json_tmpdir}/${docker_name}.spec"

        cp "$VESTA/data/packages/default.pkg" "$json_tmpdir/${json_package}.pkg"
        if grep -q "^DOCKER_CONTAINERS=" "$json_tmpdir/${json_package}.pkg"; then
            sed -i "s/^DOCKER_CONTAINERS=.*/DOCKER_CONTAINERS='1'/" "$json_tmpdir/${json_package}.pkg"
        else
            echo "DOCKER_CONTAINERS='1'" >>"$json_tmpdir/${json_package}.pkg"
        fi

        "$V_BIN/v-add-user-package" "$json_tmpdir" "$json_package" >/dev/null 2>&1 || exit 1
        "$V_BIN/v-add-user" "$json_user" "$json_pass" "$json_mail" "$json_package" Json Listing >/dev/null 2>&1 || exit 1
        write_spec "$json_spec" "$docker_name"
        "$V_BIN/v-add-docker-container" "$json_user" "$json_spec" >/dev/null 2>&1 || exit 1
    fi
fi

if [ -n "$docker_owner" ] && [ -n "$docker_name" ]; then
    docker_commands_added='yes'
    commands="$commands
v_list_docker_containers $docker_owner json
v_list_docker_container $docker_owner $docker_name json
v_list_docker_container_health $docker_owner $docker_name json
v_list_docker_container_alerts $docker_owner $docker_name json
v_list_docker_container_stats $docker_owner $docker_name 5m json"
fi

IFS=$'\n'
for cmd in $commands; do
    IFS=' ' read -r -a cmd_parts <<< "$cmd"
    script="${cmd_parts[0]}"
    "$V_BIN/$script" "${cmd_parts[@]:1}" | $V_TEST/json.sh >/dev/null 2>/dev/null
    retval="$?"
    echo -en  "$cmd"
    echo -en '\033[60G'
    echo -n '['

    if [ "$retval" -ne 0 ]; then
        FAILED=1
        echo -n 'FAILED'
        echo -n ']'
        echo -ne '\r\n'
        "$V_BIN/$script" "${cmd_parts[@]:1}" | $V_TEST/json.sh
    else
        echo -n '  OK  '
        echo -n ']'
    fi
    echo -ne '\r\n'

done

if [ "$docker_commands_added" != 'yes' ]; then
    echo "SKIP: Docker JSON listing coverage was not exercised because no container fixture was available."
fi

exit "$FAILED"
