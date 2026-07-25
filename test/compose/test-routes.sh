#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/app/runtime" \
    "$VESTA/data/users/bob" \
    "$HOMEDIR/alice"
printf "DOMAIN='app.example.test' IP='192.0.2.10' SUSPENDED='no'\n" \
    >"$VESTA/data/users/alice/web.conf"
printf "OWNER='alice'\nPROJECT='app'\nSTATE='running'\n" \
    >"$VESTA/data/users/alice/docker-projects/app/project.conf"
printf 'services: {}\n' \
    >"$VESTA/data/users/alice/docker-projects/app/compose.yaml"
printf "POLICY_SCHEMA='1'\n" \
    >"$VESTA/data/users/alice/docker-projects/app/policy.conf"
jq -n '{
    services: {
        web: {
            ports: [
                {host_ip: "127.0.0.1", published: "19030", target: 8080, protocol: "tcp"}
            ]
        },
        dns: {
            ports: [
                {host_ip: "127.0.0.1", published: "19031", target: 5353, protocol: "udp"}
            ]
        }
    }
}' >"$VESTA/data/users/alice/docker-projects/app/runtime/canonical.json"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

route_log="$test_root/route.log"
probe_log="$test_root/probe.log"
export VX_COMPOSE_ROUTE_COMMAND="$test_root/fake-route-command"
export VX_COMPOSE_ROUTE_PROBE_COMMAND="$test_root/fake-probe-command"
export VX_COMPOSE_ROUTE_CONFIGTEST_COMMAND="$test_root/fake-configtest-command"
export VX_COMPOSE_ROUTE_RELOAD_COMMAND="$test_root/fake-reload-command"
# The single-quoted lines intentionally write separate test executables.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/route.log"' \
    >"$VX_COMPOSE_ROUTE_COMMAND"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/probe.log"' \
    >"$VX_COMPOSE_ROUTE_PROBE_COMMAND"
chmod 0755 "$VX_COMPOSE_ROUTE_COMMAND" "$VX_COMPOSE_ROUTE_PROBE_COMMAND"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "configtest\n" >>"$(dirname -- "$0")/route.log"' \
    >"$VX_COMPOSE_ROUTE_CONFIGTEST_COMMAND"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "reload\n" >>"$(dirname -- "$0")/route.log"' \
    >"$VX_COMPOSE_ROUTE_RELOAD_COMMAND"
chmod 0755 \
    "$VX_COMPOSE_ROUTE_CONFIGTEST_COMMAND" \
    "$VX_COMPOSE_ROUTE_RELOAD_COMMAND"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(VX_COMPOSE_ROUTE_PROBE_URL='' \
    vx_compose_route_probe_url alice app.example.test)" == \
    'http://192.0.2.10' ]] \
    || fail "route probe did not resolve the domain's local Vesta IP"

vx_compose_route_add \
    alice app app.example.test web 8080 http /api
routes="$(vx_compose_route_list_json alice app)"
jq -e '
    ."app.example.test".OWNER == "alice"
    and ."app.example.test".PROJECT == "app"
    and ."app.example.test".SERVICE == "web"
    and ."app.example.test".CONTAINER_PORT == 8080
    and ."app.example.test".HOST_PORT == 19030
    and ."app.example.test".PATH == "/api"
' <<<"$routes" >/dev/null || fail "route metadata is wrong"

vx_compose_routes_apply alice app
grep -Fq 'ARG=http://127.0.0.1:19030' "$route_log" \
    || fail "route target was not passed to the adapter"
grep -Fq 'app.example.test' "$probe_log" \
    || fail "Host-header probe was not executed"
grep -Fq 'ARG=--retry-all-errors' "$probe_log" \
    || fail "route probe does not tolerate nginx reload convergence"
grep -Fq 'configtest' "$route_log" \
    || fail "proxy configuration was not tested"
grep -Fq 'reload' "$route_log" \
    || fail "proxy was not explicitly reloaded"

jq '."app.example.test".HOST_PORT = 65535' \
    "$VESTA/data/users/alice/docker-projects/app/routes.conf" \
    >"$test_root/tampered-routes.json"
if vx_compose_routes_validate_file \
    alice app \
    "$VESTA/data/users/alice/docker-projects/app/runtime/canonical.json" \
    "$test_root/tampered-routes.json" 2>/dev/null; then
    fail "route metadata with a mismatched host port was accepted"
fi

original_web_conf="$(cat "$VESTA/data/users/alice/web.conf")"
failing_route="$test_root/failing-route-command"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "mutated\n" >"$VESTA/data/users/alice/web.conf"' \
    'exit 1' >"$failing_route"
chmod 0755 "$failing_route"
VX_COMPOSE_ROUTE_COMMAND="$failing_route"
export VESTA
if vx_compose_routes_apply alice app 2>/dev/null; then
    fail "failed route render was accepted"
fi
[[ "$(cat "$VESTA/data/users/alice/web.conf")" == "$original_web_conf" ]] \
    || fail "failed route render did not restore web metadata"
VX_COMPOSE_ROUTE_COMMAND="$test_root/fake-route-command"

# shellcheck source=func/vx/proxy.sh
source "$repo_root/func/vx/proxy.sh"
PROXY='vx-proxy'
PROXY_TEMPLATE='vx-proxy'
PROXY_MODE='proxy'
PROXY_TARGET='http://127.0.0.1:19030'
PROXY_PROFILE='application'
PROXY_PRESERVE_HOST='yes'
PROXY_TIMEOUT='60'
PROXY_HEADERS=''
PROXY_PATH='/api'
vx_proxy_prepare_template_values
grep -Fq 'location /api {' <<<"$VX_PROXY_LOCATION_BLOCK" \
    || fail "vx-proxy did not render the managed route path"

if vx_compose_route_add \
    bob app app.example.test web 8080 http / 2>/dev/null; then
    fail "cross-owner route was accepted"
fi
if vx_compose_route_add \
    alice app missing.example.test web 8080 http / 2>/dev/null; then
    fail "unowned domain route was accepted"
fi
if vx_compose_route_add \
    alice app app.example.test dns 5353 http / 2>/dev/null; then
    fail "UDP service route was accepted"
fi
if vx_compose_route_add \
    alice app app.example.test web 9999 http / 2>/dev/null; then
    fail "unpublished target route was accepted"
fi

other_root="$VESTA/data/users/alice/docker-projects/other"
mkdir -p "$other_root/runtime"
printf "OWNER='alice'\nPROJECT='other'\nSTATE='running'\n" \
    >"$other_root/project.conf"
printf 'services: {}\n' >"$other_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$other_root/policy.conf"
cp "$VESTA/data/users/alice/docker-projects/app/runtime/canonical.json" \
    "$other_root/runtime/canonical.json"
printf '{}\n' >"$other_root/routes.conf"
if vx_compose_route_add \
    alice other app.example.test web 8080 http / 2>/dev/null; then
    fail "domain was assigned to two Compose projects"
fi

vx_compose_route_delete alice app app.example.test
jq -e 'length == 0' \
    <<<"$(vx_compose_route_list_json alice app)" >/dev/null \
    || fail "route deletion retained metadata"

echo "Compose route tests passed."
