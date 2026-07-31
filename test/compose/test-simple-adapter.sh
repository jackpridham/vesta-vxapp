#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

# Globals intentionally model vx_docker_load_spec output consumed by the
# compatibility helper.
# shellcheck disable=SC2034
declare -g \
    NAME=site \
    IMAGE=nginx:alpine \
    COMMAND='' \
    ENV='NODE_ENV=production' \
    MOUNTS='data:/data' \
    CONTAINER_PORT=8080 \
    RESTART_POLICY=unless-stopped \
    HEALTHCHECK_TYPE=none \
    HEALTHCHECK_TARGET='' \
    HEALTHCHECK_INTERVAL=60
vx_compose_simple_render_loaded alice 18080 "$test_root/compose.yaml"
grep -Fq '127.0.0.1:18080:8080' "$test_root/compose.yaml"
grep -Fq 'NODE_ENV=production' "$test_root/compose.yaml"
grep -Fq 'cap_drop: [ALL]' "$test_root/compose.yaml"
grep -Fq 'create_host_path: false' "$test_root/compose.yaml"
mkdir -p "$HOMEDIR/alice/docker/site/binds/data"
docker compose --project-name vx-simple-adapter-test \
    --file "$test_root/compose.yaml" config --format json \
    >"$test_root/canonical.json"
vx_compose_policy_check_supported_keys "$test_root/canonical.json" \
    || {
        echo 'FAIL: safe simple bind render was rejected' >&2
        exit 1
    }
jq '.services.site.volumes[0].bind.create_host_path = true' \
    "$test_root/canonical.json" >"$test_root/unsafe-bind.json"
if vx_compose_policy_check_supported_keys \
    "$test_root/unsafe-bind.json" 2>/dev/null; then
    echo 'FAIL: automatic bind-path creation was accepted' >&2
    exit 1
fi
mkdir "$test_root/candidate"
vx_compose_simple_metadata_write_candidate \
    alice 18080 "$test_root/candidate"
CPU_ALERT_PCT=72
MEM_ALERT_MB=640
NET_ALERT_MBPS=25
ALERT_EMAIL=no
vx_compose_simple_alerts_write_candidate "$test_root/candidate"
jq -e '
    .OWNER == "alice"
    and .NAME == "site"
    and .IMAGE == "nginx:alpine"
    and .ENV == "NODE_ENV=production"
    and .HOST_PORT == "18080"
    and .CONTAINER_PORT == "8080"
' "$test_root/candidate/simple.json" >/dev/null \
    || {
        echo 'FAIL: safe simple-form metadata was not rendered' >&2
        exit 1
    }

jq -e '
    .CPU_PCT == 72
    and .MEMORY_PCT == 500
    and .NETWORK_MBPS == 25
    and .NOTIFY == false
' "$test_root/candidate/alerts.conf" >/dev/null \
    || {
        echo 'FAIL: simple alert intent was not staged in the candidate' >&2
        exit 1
    }
[[ "$(stat -c '%a' "$test_root/candidate/alerts.conf")" == 640 ]] \
    || {
        echo 'FAIL: candidate alert intent mode is not protected' >&2
        exit 1
    }
[[ "$(stat -c '%a' "$test_root/candidate/simple.json")" == 600 ]] \
    || {
        echo 'FAIL: simple-form metadata mode is not protected' >&2
        exit 1
    }

project_root="$VESTA/data/users/alice/docker-projects/site"
mkdir -p "$project_root/runtime"
cp "$test_root/candidate/simple.json" "$project_root/simple.json"
chmod 0600 "$project_root/simple.json"
cat >"$project_root/project.conf" <<'EOF'
OWNER='alice'
PROJECT='site'
COMPOSE_PROJECT='vx-alice-site'
PROFILE='standard'
STATE='running'
REVISION='1'
CREATED='2026-07-25T00:00:00Z'
UPDATED='2026-07-25T00:01:00Z'
EOF
cat >"$project_root/policy.conf" <<'EOF'
SERVICES='1'
EOF
cp "$test_root/compose.yaml" "$project_root/compose.yaml"
cat >"$project_root/runtime/canonical.json" <<'EOF'
{"services":{"site":{"image":"nginx:alpine"}}}
EOF
cat >"$project_root/routes.conf" <<'EOF'
{"site.example.test":{"SCHEME":"http","HOST_PORT":18080}}
EOF
jq '.DOMAIN = "site.example.test"' \
    "$project_root/simple.json" >"$project_root/.simple.json.new"
mv "$project_root/.simple.json.new" "$project_root/simple.json"
chmod 0600 "$project_root/simple.json"
vx_compose_runtime_containers_json() {
    printf '%s\n' \
        '[{"Name":"/vx-alice-site-site-1","State":{"Status":"running"}}]'
}
vx_compose_simple_load_legacy_record alice site
[[ "$NAME" == site
    && "$CTN_NAME" == vx-alice-site-site-1
    && "$OWNER" == alice
    && "$PROXY_MODE" == proxy
    && "$PROXY_TARGET" == http://127.0.0.1:18080
    && "$STATUS" == running ]] \
    || {
        echo 'FAIL: simple Compose metadata was not loaded as a legacy record' >&2
        exit 1
    }

for command_name in add change start stop restart delete; do
    command_path="$repo_root/bin/v-${command_name}-docker-container"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
for command_name in \
    list-docker-container \
    list-docker-container-inspect \
    list-docker-container-health \
    list-docker-container-alerts \
    list-docker-container-stats \
    list-docker-container-logs
do
    command_path="$repo_root/bin/v-${command_name}"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
if grep -En 'vx_docker_create_runtime|docker (run|create)' \
    "$repo_root/bin/v-add-docker-container"; then
    echo 'FAIL: simple add still creates a direct container' >&2
    exit 1
fi
grep -Fq 'advanced Compose projects cannot use the simple editor' \
    "$repo_root/bin/v-change-docker-container" \
    || {
        echo 'FAIL: simple change adapter does not enforce provenance' >&2
        exit 1
    }
[[ "$(grep -Fc 'vx_compose_routes_stage_simple' \
    "$repo_root/func/vx/compose/simple.sh")" -eq 2
    && "$(grep -Fc 'vx_compose_transaction_update' \
        "$repo_root/func/vx/compose/simple.sh")" -eq 1 ]] \
    || {
        echo 'FAIL: simple route intent is outside the project transaction' >&2
        exit 1
    }
simple_add_body="$(sed -n \
    '/^vx_compose_simple_add_loaded()/,/^vx_compose_simple_change_loaded()/p' \
    "$repo_root/func/vx/compose/simple.sh")"
lock_line="$(grep -n 'vx_compose_lock_acquire' <<<"$simple_add_body" \
    | head -1 | cut -d: -f1)"
store_line="$(grep -n 'vx_compose_store_new' <<<"$simple_add_body" \
    | head -1 | cut -d: -f1)"
deploy_line="$(grep -n 'vx_compose_deploy' <<<"$simple_add_body" \
    | head -1 | cut -d: -f1)"
release_line="$(grep -n 'vx_compose_lock_release' <<<"$simple_add_body" \
    | tail -1 | cut -d: -f1)"
ports_line="$(grep -n 'vx_compose_ports_lock_acquire' <<<"$simple_add_body" \
    | head -1 | cut -d: -f1)"
quota_line="$(grep -n 'vx_compose_owner_quota_lock_acquire' \
    <<<"$simple_add_body" | head -1 | cut -d: -f1)"
routes_line="$(grep -n 'vx_compose_routes_lock_acquire' \
    <<<"$simple_add_body" | head -1 | cut -d: -f1)"
[[ "$lock_line" -lt "$store_line"
    && "$ports_line" -lt "$quota_line"
    && "$quota_line" -lt "$routes_line"
    && "$routes_line" -lt "$store_line"
    && "$store_line" -lt "$deploy_line"
    && "$deploy_line" -lt "$release_line" ]] \
    || {
        echo 'FAIL: simple add lock does not span store and convergence' >&2
        exit 1
    }

# Two new simple projects cannot both cross the domain reservation recheck.
# The first caller pauses between observing a free domain and reserving it;
# the second must remain outside that route-critical section.
simple_route_barrier="$test_root/simple-route.fifo"
mkfifo "$simple_route_barrier"
: >"$test_root/simple-route.ready"
: >"$test_root/simple-route.store"
rm -f -- "$test_root/simple-route.reserved"
vx_compose_simple_prepare_binds() { :; }
vx_compose_simple_render_loaded() { printf 'services: {}\n' >"$3"; }
vx_compose_prepare_candidate() { mkdir -p "$4"; }
vx_compose_simple_metadata_write_candidate() { :; }
vx_compose_simple_alerts_write_candidate() { :; }
vx_compose_routes_stage_simple() {
    printf '{}\n' >"$8"
}
vx_compose_routes_validate_reservations() {
    if [[ ! -e "$test_root/simple-route.reserved" ]]; then
        printf 'ready\n' >"$test_root/simple-route.ready"
        IFS= read -r _ <"$simple_route_barrier"
        : >"$test_root/simple-route.reserved"
        return 0
    fi
    return 1
}
vx_compose_store_new() {
    printf 'store:%s\n' "$2" >>"$test_root/simple-route.store"
}
vx_compose_deploy() { :; }
vx_compose_audit() { :; }
run_simple_add() {
    local project="$1" status=0
    NAME="$project" AUTO_START=yes DOMAIN=shared.example.test \
        vx_compose_simple_add_loaded alice 18081 || status=$?
    printf '%s\n' "$status" >"$test_root/$project.simple-status"
}
run_simple_add first &
first_simple_pid=$!
for _ in {1..100}; do
    [[ -s "$test_root/simple-route.ready" ]] && break
    sleep 0.01
done
run_simple_add second &
second_simple_pid=$!
sleep 0.1
[[ "$(wc -l <"$test_root/simple-route.ready")" == 1
    && ! -s "$test_root/simple-route.store" ]] || {
    echo 'FAIL: concurrent simple add crossed the route reservation barrier' >&2
    exit 1
}
printf 'release\n' >"$simple_route_barrier"
wait "$first_simple_pid" "$second_simple_pid"
[[ "$(cat "$test_root/first.simple-status")" == 0
    && "$(cat "$test_root/second.simple-status")" != 0
    && "$(cat "$test_root/simple-route.store")" == store:first ]] || {
    echo 'FAIL: concurrent simple adds both reserved one domain' >&2
    exit 1
}

# An alert-intent rendering fault happens before storage publication. It
# cannot partially accept a project or enter the global transaction locks.
NAME=alert-failure
AUTO_START=no
rm -f -- "$test_root/alerts-failure.stored" \
    "$test_root/alerts-failure.removed"
vx_compose_simple_prepare_binds() { :; }
vx_compose_simple_render_loaded() { printf 'services: {}\n' >"$3"; }
vx_compose_prepare_candidate() { mkdir -p "$4"; }
vx_compose_simple_metadata_write_candidate() { :; }
vx_compose_simple_alerts_write_candidate() { return 1; }
vx_compose_routes_stage_simple() { :; }
vx_compose_routes_validate_reservations() { :; }
vx_compose_store_new() {
    printf 'stored\n' >"$test_root/alerts-failure.stored"
}
vx_compose_remove() {
    printf 'removed\n' >"$test_root/alerts-failure.removed"
}
if vx_compose_simple_add_loaded alice 18081; then
    echo 'FAIL: alerts-write failure reported simple add success' >&2
    exit 1
fi
[[ ! -e "$test_root/alerts-failure.stored"
    && ! -e "$test_root/alerts-failure.removed"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}"
    && -z "${VX_COMPOSE_QUOTA_LOCK_FD:-}"
    && -z "${VX_COMPOSE_ROUTES_LOCK_FD:-}" ]] \
    || {
        echo 'FAIL: alert-intent failure partially stored a project' >&2
        exit 1
    }

# AUTO_START=no is handed to the transaction itself. Runtime validation,
# stopping, and stopped-state revision commit must occur under one project
# lock; the simple adapter must not stop after the commit window.
simple_change_body="$(sed -n \
    '/^vx_compose_simple_change_loaded()/,$p' \
    "$repo_root/func/vx/compose/simple.sh")"
grep -Fq '"$final_state"' <<<"$simple_change_body" \
    || {
        echo 'FAIL: simple change does not bind desired stopped state' >&2
        exit 1
    }
if grep -Fq 'vx_compose_stop' <<<"$simple_change_body"; then
    echo 'FAIL: simple change retains a post-commit stop window' >&2
    exit 1
fi

echo "Compose simple-adapter tests passed."
