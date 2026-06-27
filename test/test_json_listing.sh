#!/bin/bash

source /etc/profile.d/vesta.sh

V_BIN="$VESTA/bin"
V_TEST="$VESTA/test"

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
for docker_conf in "$VESTA"/data/users/*/docker.conf; do
    [ -s "$docker_conf" ] || continue
    docker_owner=$(basename "$(dirname "$docker_conf")")
    docker_name=$(awk -F"'" '/^NAME=/{print $2; exit}' "$docker_conf")
    if [ -n "$docker_owner" ] && [ -n "$docker_name" ]; then
        break
    fi
done

if [ -n "$docker_owner" ] && [ -n "$docker_name" ]; then
    commands="$commands
v_list_docker_containers $docker_owner json
v_list_docker_container $docker_owner $docker_name json
v_list_docker_container_health $docker_owner $docker_name json
v_list_docker_container_alerts $docker_owner $docker_name json
v_list_docker_container_stats $docker_owner $docker_name 5m json"
fi

IFS=$'\n'
for cmd in $commands; do
    script=$(echo $cmd |cut -f 1 -d ' ')
    arg1=$(echo $cmd |cut -f 2 -d ' ')
    arg2=$(echo $cmd |cut -f 3 -d ' ')
    arg3=$(echo $cmd |cut -f 4 -d ' ')
    $V_BIN/$script $arg1 $arg2 $arg3 | $V_TEST/json.sh >/dev/null 2>/dev/null
    retval="$?"
    echo -en  "$cmd"
    echo -en '\033[60G'
    echo -n '['

    if [ "$retval" -ne 0 ]; then
        echo -n 'FAILED'
        echo -n ']'
        echo -ne '\r\n'
        $V_BIN/$script $arg1 $arg2 $arg3 | $V_TEST/json.sh
    else
        echo -n '  OK  '
        echo -n ']'
    fi
    echo -ne '\r\n'

done

exit
