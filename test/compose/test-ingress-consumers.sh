#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/tenant-a/docker-projects/app/runtime" \
    "$VESTA/data/users/tenant-b" \
    "$HOMEDIR/tenant-a/conf/web" \
    "$HOMEDIR/tenant-b/conf/web" \
    "$test_root/bin"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

project_root="$VESTA/data/users/tenant-a/docker-projects/app"
printf "OWNER='tenant-a'\nPROJECT='app'\nSTATE='running'\n" \
    >"$project_root/project.conf"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"
jq -n '{
    services: {
        api: {
            ports: [
                {host_ip:"127.0.0.1", published:"8420", target:8420,
                 protocol:"tcp"},
                {host_ip:"127.0.0.1", published:"8530", target:53,
                 protocol:"udp"}
            ]
        },
        ranged: {
            ports: [
                {host_ip:"127.0.0.1", published:"8600-8602",
                 target:"80-82", protocol:"tcp"}
            ]
        }
    }
}' >"$project_root/runtime/canonical.json"

printf "%s\n" \
    "DOMAIN='app.example.test' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:8420' PROXY_PATH='/' PROXY_HEADERS='X-Protected-Canary: forbidden-value||X-Trace-Name: private-value' SSL='yes'" \
    "DOMAIN='unrelated.example.test' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:9999' PROXY_PATH='/' PROXY_HEADERS='X-Unrelated: not-visible' SSL='no'" \
    "DOMAIN='range.example.test' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:8601' PROXY_PATH='/' PROXY_HEADERS='' SSL='no'" \
    >"$VESTA/data/users/tenant-a/web.conf"
printf "%s\n" \
    "DOMAIN='consumer.example.test' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:8420/' PROXY_PATH='/api' PROXY_HEADERS='X-Cross-Owner: hidden-value' SSL='no'" \
    "DOMAIN='redirect.example.test' PROXY='vx-proxy' PROXY_MODE='redirect' PROXY_TARGET='http://127.0.0.1:8420' PROXY_PATH='/' PROXY_HEADERS='' SSL='no'" \
    >"$VESTA/data/users/tenant-b/web.conf"

printf 'rendered current\n' \
    >"$HOMEDIR/tenant-a/conf/web/app.example.test.nginx.conf"
printf 'rendered stale\n' \
    >"$HOMEDIR/tenant-b/conf/web/consumer.example.test.nginx.conf"
touch -d '2026-01-01T00:00:00Z' \
    "$VESTA/data/users/tenant-a/web.conf" \
    "$HOMEDIR/tenant-b/conf/web/consumer.example.test.nginx.conf"
touch -d '2026-01-02T00:00:00Z' \
    "$HOMEDIR/tenant-a/conf/web/app.example.test.nginx.conf" \
    "$VESTA/data/users/tenant-b/web.conf"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "$*" == *127.0.0.1:8420* ]]' \
    >"$test_root/bin/curl"
chmod 0755 "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH"

user=tenant-a
# shellcheck source=func/main.sh
set +u
source "$repo_root/func/main.sh"
HOMEDIR="$test_root/home"
# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

consumers="$(vx_compose_ingress_consumers_json tenant-a app)"
jq -e '
    length == 3
    and .[0] == {
        OWNER:"tenant-a",
        DOMAIN:"app.example.test",
        SCHEME:"https",
        PATH:"/",
        TARGET:"http://127.0.0.1:8420",
        HEALTH:"healthy",
        CONFIG_FRESHNESS:"current",
        HEADER_NAMES:["X-Protected-Canary","X-Trace-Name"]
    }
    and .[1].DOMAIN == "range.example.test"
    and .[1].TARGET == "http://127.0.0.1:8601"
    and .[2].OWNER == "tenant-b"
    and .[2].DOMAIN == "consumer.example.test"
    and .[2].PATH == "/api"
    and .[2].CONFIG_FRESHNESS == "stale"
    and .[2].HEADER_NAMES == ["X-Cross-Owner"]
' <<<"$consumers" >/dev/null \
    || fail 'native ingress consumers were not matched and redacted'

for forbidden in forbidden-value private-value hidden-value not-visible; do
    if grep -Fq "$forbidden" <<<"$consumers"; then
        fail 'native ingress output disclosed protected header data'
    fi
done
if grep -Fq unrelated.example.test <<<"$consumers" \
    || grep -Fq redirect.example.test <<<"$consumers"; then
    fail 'unrelated native proxy records were included'
fi

endpoints="$(vx_compose_ingress_published_endpoints_json tenant-a app)"
jq -e '
    [
        .[]
        | select(.SERVICE == "ranged")
        | .HOST_PORT
    ] == [8600, 8601, 8602]
' <<<"$endpoints" >/dev/null \
    || fail 'matching published TCP range was not expanded safely'

vx_compose_ingress_actor_can_view_metadata admin tenant-a app \
    || fail 'explicit administrator actor lost redacted metadata access'
if vx_compose_ingress_actor_can_view_metadata tenant-a tenant-a app; then
    fail 'ordinary owner received full cross-owner ingress metadata'
fi
if vx_compose_ingress_actor_can_view_metadata '' tenant-a app; then
    fail 'missing explicit actor received full ingress metadata'
fi
vx_compose_actor_has_project_capability() {
    [[ "$1" == tenant-b
        && "$2" == tenant-a
        && "$3" == app
        && "$4" == view-ingress-consumers ]]
}
vx_compose_ingress_actor_can_view_metadata tenant-b tenant-a app \
    || fail 'real viewer capability was ignored'

echo 'Compose ingress consumer tests passed.'
