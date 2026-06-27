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

echo_result() {
    echo -en "$1"
    echo -en '\033[72G'
    echo -n '['

    if [ "$2" -ne 0 ]; then
        FAILED=1
        echo -n 'FAILED'
        echo -n ']'
        echo -ne '\r\n'
        echo ">>> $4"
        echo ">>> RETURN VALUE $2"
        cat "$3"
    else
        echo -n '  OK  '
        echo -n ']'
    fi

    echo -ne '\r\n'
}

json_field() {
    local file="$1"
    local key="$2"

    php -r '
        $payload = json_decode(file_get_contents($argv[1]), true);
        $key = $argv[2];
        $value = null;
        if (is_array($payload)) {
            $first = reset($payload);
            if (is_array($first) && array_key_exists($key, $first)) {
                $value = $first[$key];
            } elseif (array_key_exists($key, $payload)) {
                $value = $payload[$key];
            }
        }
        if (is_array($value)) {
            echo json_encode($value);
        } elseif ($value !== null) {
            echo $value;
        }
    ' "$file" "$key"
}

run_cmd() {
    local cmd="$1"
    local stdout_file="$2"
    local stderr_file="$3"

    bash -lc "$cmd" >"$stdout_file" 2>"$stderr_file"
    return $?
}

expect_ok() {
    local label="$1"
    local cmd="$2"

    run_cmd "$cmd" "$stdout_file" "$stderr_file"
    echo_result "$label" "$?" "$stderr_file" "$cmd"
}

expect_code() {
    local label="$1"
    local expected="$2"
    local cmd="$3"

    run_cmd "$cmd" "$stdout_file" "$stderr_file"
    local rc=$?
    local verdict=1
    if [ "$rc" -eq "$expected" ]; then
        verdict=0
    fi
    printf 'Expected exit code %s\nActual exit code %s\n' "$expected" "$rc" >"$tmpfile"
    cat "$stderr_file" >>"$tmpfile"
    echo_result "$label" "$verdict" "$tmpfile" "$cmd"
}

write_spec() {
    local path="$1"
    local name="$2"
    local domain="$3"
    local auto_start="$4"

    cat >"$path" <<EOF
NAME='$name'
IMAGE='$DOCKER_TEST_IMAGE'
COMMAND='sleep 3600'
ENV='MODE=test'
MOUNTS='data:/data'
CONTAINER_PORT='8080'
DOMAIN='$domain'
ROUTE_PATH=''
AUTO_START='$auto_start'
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
    local backup_file_path=''

    if [ -n "${backup_name:-}" ]; then
        backup_file_path="/backup/${backup_name}"
        [ -f "$backup_file_path" ] && rm -f "$backup_file_path"
    fi

    if [ -n "${user_one:-}" ] && [ -d "$VESTA/data/users/$user_one" ]; then
        $V_BIN/v-delete-user "$user_one" yes >/dev/null 2>&1 || true
    fi
    if [ -n "${user_two:-}" ] && [ -d "$VESTA/data/users/$user_two" ]; then
        $V_BIN/v-delete-user "$user_two" yes >/dev/null 2>&1 || true
    fi
    if [ -n "${package_name:-}" ] && [ -f "$VESTA/data/packages/${package_name}.pkg" ]; then
        $V_BIN/v-delete-user-package "$package_name" >/dev/null 2>&1 || true
    fi

    [ -n "${tmpdir:-}" ] && rm -rf "$tmpdir"
    [ -n "${tmpfile:-}" ] && rm -f "$tmpfile"
    [ -n "${stdout_file:-}" ] && rm -f "$stdout_file"
    [ -n "${stderr_file:-}" ] && rm -f "$stderr_file"
}

tmpdir="$(mktemp -d -p "$TMP_ROOT")"
tmpfile="$(mktemp -p "$TMP_ROOT")"
stdout_file="$(mktemp -p "$TMP_ROOT")"
stderr_file="$(mktemp -p "$TMP_ROOT")"
trap cleanup EXIT

suffix="$(random 4)"
package_name="dockert${suffix}"
user_one="dockera${suffix}"
user_two="dockerb${suffix}"
pass_one="T3st-${suffix}-A!"
pass_two="T3st-${suffix}-B!"
mail_one="${user_one}@local.test"
mail_two="${user_two}@local.test"
container_one="app${suffix}"
container_two="other${suffix}"
domain_one="${container_one}.local.test"
domain_two="${container_two}.local.test"
spec_one="${tmpdir}/${container_one}.spec"
spec_two="${tmpdir}/${container_two}.spec"
restore_marker_path="/home/${user_one}/docker/${container_one}/data/restore-marker.txt"

write_spec "$spec_one" "$container_one" "$domain_one" 'yes'
write_spec "$spec_two" "$container_two" "$domain_two" 'yes'

if ! "$V_BIN/v-check-docker-engine" >/dev/null 2>&1; then
    echo "SKIP: Docker engine is unavailable on this host."
    exit 0
fi

expect_ok "DOCKER: Engine availability check" "$V_BIN/v-check-docker-engine json | $V_TEST/json.sh >/dev/null"

cp "$VESTA/data/packages/default.pkg" "$tmpdir/${package_name}.pkg"
if grep -q "^DOCKER_CONTAINERS=" "$tmpdir/${package_name}.pkg"; then
    sed -i "s/^DOCKER_CONTAINERS=.*/DOCKER_CONTAINERS='1'/" "$tmpdir/${package_name}.pkg"
else
    echo "DOCKER_CONTAINERS='1'" >>"$tmpdir/${package_name}.pkg"
fi
expect_ok "DOCKER: Creating scratch package ${package_name}" "$V_BIN/v-add-user-package $tmpdir $package_name"

expect_ok "DOCKER: Adding owner user ${user_one}" "$V_BIN/v-add-user $user_one $pass_one $mail_one $package_name Docker One"
expect_ok "DOCKER: Adding second user ${user_two}" "$V_BIN/v-add-user $user_two $pass_two $mail_two $package_name Docker Two"

ip_one="$($V_BIN/v-list-user-ips "$user_one" plain | awk 'NR==1 {print $1}')"
ip_two="$($V_BIN/v-list-user-ips "$user_two" plain | awk 'NR==1 {print $1}')"

expect_ok "DOCKER: Adding routed web domain ${domain_one}" "$V_BIN/v-add-web-domain $user_one $domain_one $ip_one no none no"
expect_ok "DOCKER: Adding routed web domain ${domain_two}" "$V_BIN/v-add-web-domain $user_two $domain_two $ip_two no none no"

expect_ok "DOCKER: User creates first managed container within quota" "$V_BIN/v-add-docker-container $user_one $spec_one"
expect_code "DOCKER: User create blocked when package limit is exhausted" 11 "$V_BIN/v-add-docker-container $user_one $spec_one"

expect_ok "DOCKER: Second user creates owned container" "$V_BIN/v-add-docker-container $user_two $spec_two"

expect_code "DOCKER: Wrong owner lookup fails for foreign container record" 3 "$V_BIN/v-list-docker-container $user_one $container_two json"
expect_code "DOCKER: Wrong owner inspect fails for foreign container record" 3 "$V_BIN/v-list-docker-container-inspect $user_one $container_two >/dev/null"
expect_code "DOCKER: Wrong owner start fails for foreign container record" 3 "$V_BIN/v-start-docker-container $user_one $container_two"
expect_code "DOCKER: Wrong owner stop fails for foreign container record" 3 "$V_BIN/v-stop-docker-container $user_one $container_two"
expect_code "DOCKER: Wrong owner delete fails for foreign container record" 3 "$V_BIN/v-delete-docker-container $user_one $container_two"

expect_code "DOCKER: Non-admin actor helper blocks foreign owner scope" 10 "source $VESTA/func/main.sh; source $VESTA/func/vx/docker.sh; vx_docker_assert_actor_can_access_owner $user_one $user_two"
expect_ok "DOCKER: Admin actor helper allows foreign owner scope" "source $VESTA/func/main.sh; source $VESTA/func/vx/docker.sh; vx_docker_assert_actor_can_access_owner admin $user_two"
expect_ok "DOCKER: Admin shell can inspect another user's container" "$V_BIN/v-list-docker-container-inspect $user_two $container_two >/dev/null"
expect_ok "DOCKER: Admin shell can stop another user's container" "$V_BIN/v-stop-docker-container $user_two $container_two"
expect_ok "DOCKER: Admin shell can start another user's container" "$V_BIN/v-start-docker-container $user_two $container_two"

cat >"$VESTA/data/users/$user_one/docker-alerts.conf" <<EOF
AID='1' NAME='$container_one' OWNER='$user_one' LEVEL='warning' TYPE='health' STATUS='open' TITLE='Owner alert' MESSAGE='Owner alert message' STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'
EOF
cat >"$VESTA/data/users/$user_two/docker-alerts.conf" <<EOF
AID='1' NAME='$container_two' OWNER='$user_two' LEVEL='warning' TYPE='health' STATUS='open' TITLE='Other alert' MESSAGE='Other alert message' STARTED='2026-06-27 14:01:00' LAST_SEEN='2026-06-27 14:03:00' ACK='no'
EOF

expect_ok "DOCKER: User acknowledges own alert only" "$V_BIN/v-acknowledge-docker-container-alert $user_one 1"

if grep -q "ACK='yes'" "$VESTA/data/users/$user_one/docker-alerts.conf" \
    && grep -q "ACK='no'" "$VESTA/data/users/$user_two/docker-alerts.conf"; then
    echo_result "DOCKER: Alert acknowledgement is owner-scoped" 0 "$tmpfile" "ACK state check"
else
    printf 'Owner alert file:\n' >"$tmpfile"
    cat "$VESTA/data/users/$user_one/docker-alerts.conf" >>"$tmpfile"
    printf '\nOther alert file:\n' >>"$tmpfile"
    cat "$VESTA/data/users/$user_two/docker-alerts.conf" >>"$tmpfile"
    echo_result "DOCKER: Alert acknowledgement is owner-scoped" 1 "$tmpfile" "ACK state check"
fi

expect_ok "DOCKER: Docker container JSON output is valid" "$V_BIN/v-list-docker-container $user_one $container_one json | $V_TEST/json.sh >/dev/null"
expect_ok "DOCKER: Web domain JSON output is valid" "$V_BIN/v-list-web-domain $user_one $domain_one json | $V_TEST/json.sh >/dev/null"

run_cmd "$V_BIN/v-list-docker-container $user_one $container_one json" "$stdout_file" "$stderr_file"
cp "$stdout_file" "$tmpdir/docker.json"
run_cmd "$V_BIN/v-list-web-domain $user_one $domain_one json" "$stdout_file" "$stderr_file"
cp "$stdout_file" "$tmpdir/domain.json"

docker_proxy_target="$(json_field "$tmpdir/docker.json" 'PROXY_TARGET')"
domain_proxy_target="$(json_field "$tmpdir/domain.json" 'PROXY_TARGET')"
if [ -n "$docker_proxy_target" ] && [ "$docker_proxy_target" = "$domain_proxy_target" ]; then
    echo_result "DOCKER: Web and container JSON agree on PROXY_TARGET" 0 "$tmpfile" "PROXY_TARGET comparison"
else
    printf 'Container PROXY_TARGET=%s\nDomain PROXY_TARGET=%s\n' "$docker_proxy_target" "$domain_proxy_target" >"$tmpfile"
    echo_result "DOCKER: Web and container JSON agree on PROXY_TARGET" 1 "$tmpfile" "PROXY_TARGET comparison"
fi

mkdir -p "/home/${user_one}/docker/${container_one}/data"
echo "before-backup" >"$restore_marker_path"
chown -R "$user_one:$user_one" "/home/${user_one}/docker"

expect_ok "DOCKER: User backup completes with Docker data" "$V_BIN/v-backup-user $user_one no"
backup_name="$(awk -F"'" '/^BACKUP=/{print $2; exit}' "$VESTA/data/users/$user_one/backup.conf")"

if [ -z "$backup_name" ] || [ ! -f "/backup/${backup_name}" ]; then
    printf 'Unable to locate backup tarball for %s\n' "$user_one" >"$tmpfile"
    echo_result "DOCKER: Backup artifact created" 1 "$tmpfile" "backup lookup"
    exit 1
fi
echo_result "DOCKER: Backup artifact created" 0 "$tmpfile" "backup lookup"

if tar -tf "/backup/${backup_name}" | grep -q '^./docker/vesta/docker.conf$' \
    && tar -tf "/backup/${backup_name}" | grep -q '^./docker/vesta/docker-alerts.conf$' \
    && tar -tf "/backup/${backup_name}" | grep -q '^./docker/home/docker/' \
    && tar -tf "/backup/${backup_name}" | grep -q "^./web/${domain_one}/vesta/web.conf$"; then
    echo_result "DOCKER: Backup archive includes Docker metadata, alerts, bind root, and route data" 0 "$tmpfile" "tar -tf /backup/${backup_name}"
else
    tar -tf "/backup/${backup_name}" >"$tmpfile"
    echo_result "DOCKER: Backup archive includes Docker metadata, alerts, bind root, and route data" 1 "$tmpfile" "tar -tf /backup/${backup_name}"
fi

expect_ok "DOCKER: Remove routed proxy before restore" "$V_BIN/v-delete-web-domain-proxy $user_one $domain_one no"
rm -f "$VESTA/data/users/$user_one/docker.conf" "$VESTA/data/users/$user_one/docker-alerts.conf"
rm -rf "/home/${user_one}/docker"

expect_ok "DOCKER: Restore repopulates Docker metadata" "$V_BIN/v-restore-user $user_one $backup_name no no no no no no yes no"

if [ -f "$VESTA/data/users/$user_one/docker.conf" ] \
    && [ -f "$VESTA/data/users/$user_one/docker-alerts.conf" ] \
    && [ -f "$restore_marker_path" ]; then
    echo_result "DOCKER: Restore returns docker.conf, alert data, and bind-root files" 0 "$tmpfile" "restore file checks"
else
    printf 'docker.conf exists: %s\ndocker-alerts.conf exists: %s\nbind file exists: %s\n' \
        "$(test -f "$VESTA/data/users/$user_one/docker.conf" && echo yes || echo no)" \
        "$(test -f "$VESTA/data/users/$user_one/docker-alerts.conf" && echo yes || echo no)" \
        "$(test -f "$restore_marker_path" && echo yes || echo no)" >"$tmpfile"
    echo_result "DOCKER: Restore returns docker.conf, alert data, and bind-root files" 1 "$tmpfile" "restore file checks"
fi

run_cmd "$V_BIN/v-list-web-domain $user_one $domain_one json" "$stdout_file" "$stderr_file"
cp "$stdout_file" "$tmpdir/restored-domain.json"
restored_proxy_target="$(json_field "$tmpdir/restored-domain.json" 'PROXY_TARGET')"
if [ -n "$docker_proxy_target" ] && [ "$restored_proxy_target" = "$docker_proxy_target" ]; then
    echo_result "DOCKER: Restore re-establishes the routed PROXY_TARGET" 0 "$tmpfile" "restored PROXY_TARGET comparison"
else
    printf 'Expected restored PROXY_TARGET=%s\nActual restored PROXY_TARGET=%s\n' "$docker_proxy_target" "$restored_proxy_target" >"$tmpfile"
    echo_result "DOCKER: Restore re-establishes the routed PROXY_TARGET" 1 "$tmpfile" "restored PROXY_TARGET comparison"
fi

exit "$FAILED"
