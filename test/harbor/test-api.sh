#!/usr/bin/env bash

set -Eeuo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/harbor/lib.sh
source "$test_dir/lib.sh"

api_pid=
trap '[[ -z "${api_pid:-}" ]] || kill "$api_pid" 2>/dev/null || :; cleanup_vesta_root' EXIT
new_vesta_root
install_harbor_helpers
# shellcheck source=func/vx/harbor/main.sh
source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root() { return 0; }
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { /usr/bin/id -g; }
_vx_harbor_secure_file_set() { /usr/bin/chmod "$2" "$1"; }
vx_harbor_provider_prepare

api_socket="$HARBOR_TEST_ROOT/harbor.sock"
state="$HARBOR_TEST_ROOT/state.json"
log="$HARBOR_TEST_ROOT/api.log"
ready="$HARBOR_TEST_ROOT/ready"
credential="$HARBOR_TEST_ROOT/credential.json"
bootstrap_curl="$HARBOR_TEST_ROOT/bootstrap.curl"
bootstrap_response="$HARBOR_TEST_ROOT/bootstrap-response.json"
bootstrap_body="$HARBOR_TEST_ROOT/bootstrap-body.json"
printf '%s\n' '{"username":"admin","password":"fixture-password"}' >"$credential"
printf '%s\n' silent show-error 'user = "admin:fixture-password"' >"$bootstrap_curl"
chmod 0600 "$credential" "$bootstrap_curl"

python3 "$HARBOR_REPO_ROOT/test/harbor/fixtures/fake-harbor-api.py" \
    --unix-socket "$api_socket" \
    --state "$state" \
    --log "$log" \
    --credential-file "$credential" \
    --ready-file "$ready" &
api_pid=$!
for _ in {1..50}; do
    [[ -S "$api_socket" ]] && break
    sleep 0.02
done
[[ -S "$api_socket" ]] || fail 'fake Harbor API socket did not become ready'
chmod 0600 "$api_socket"

bootstrap_json_call() {
    local method="$1" path="$2" body="$3" expected="$4" status
    printf '%s\n' "$body" >"$bootstrap_body"
    status="$(curl --config "$bootstrap_curl" --unix-socket "$api_socket" \
        --request "$method" --header 'Content-Type: application/json' \
        --data-binary @"$bootstrap_body" --output "$bootstrap_response" \
        --write-out '%{http_code}' "http://localhost$path")"
    [[ "$status" == "$expected" ]] || fail "bootstrap $method $path returned $status"
}

bootstrap_json_call PUT /api/v2.0/configurations \
    '{"robot_name_prefix":"vxrobot-","self_registration":false,"project_creation_restriction":"adminonly"}' \
    200
integration_body='{
  "name":"vesta-integration",
  "description":"vesta-managed:vesta-harbor",
  "secret":"caller-create-secret-is-ignored",
  "duration":-1,
  "level":"system",
  "permissions":[
    {"kind":"system","namespace":"/","access":[
      {"resource":"project","action":"create"},
      {"resource":"project","action":"list"},
      {"resource":"quota","action":"read"},
      {"resource":"quota","action":"update"},
      {"resource":"system-volumes","action":"read"}
    ]},
    {"kind":"project","namespace":"*","access":[
      {"resource":"project","action":"read"},
      {"resource":"project","action":"update"},
      {"resource":"repository","action":"pull"},
      {"resource":"repository","action":"push"},
      {"resource":"robot","action":"create"},
      {"resource":"robot","action":"read"},
      {"resource":"robot","action":"list"},
      {"resource":"robot","action":"delete"}
    ]}
  ]
}'
bootstrap_json_call POST /api/v2.0/robots "$integration_body" 201
integration_username="$(jq -er .name "$bootstrap_response")"
integration_secret="$(jq -er .secret "$bootstrap_response")"
[[ "$integration_username" == vxrobot-vesta-integration ]] \
    || fail 'bootstrap returned an incorrectly prefixed integration username'
printf 'silent\nshow-error\nuser = "%s:%s"\n' \
    "$integration_username" "$integration_secret" \
    >"$(vx_harbor_root)/secrets/integration.curl"
chmod 0600 "$(vx_harbor_root)/secrets/integration.curl"

_vx_harbor_api_socket() { printf '%s\n' "$api_socket"; }
vx_harbor_local_socket_path() { printf '%s\n' "$api_socket"; }
vx_harbor_socket_path() { printf '%s\n' "$api_socket"; }
vx_harbor_socket_validate() { [[ -S "$api_socket" && ! -L "$api_socket" ]]; }

vx_harbor_api_health | jq -e '.status=="healthy"' >/dev/null
project_body="$(vx_harbor_root)/secrets/project-body.json"
printf '%s\n' '{"project_name":"vx-alice","metadata":{"public":"false"}}' >"$project_body"
chmod 0600 "$project_body"
_vx_harbor_api_call POST /api/v2.0/projects 201 empty "$project_body"
rm -f -- "$project_body"
project="$(vx_harbor_api_project_get vx-alice)"
[[ "$(jq -r .name <<<"$project")" == vx-alice ]]
quota="$(jq -r .quota_id <<<"$project")"
vx_harbor_api_quota_set_bytes "$quota" 1048576
[[ "$(vx_harbor_api_quota_get "$quota" | jq -r .hard.storage)" == 1048576 ]]

robot_body="$(vx_harbor_root)/secrets/robot-body.json"
printf '%s\n' '{"name":"runtime-1","description":"vesta-managed:candidate:api-test","secret":"ignored-runtime-secret-canary","duration":-1,"level":"project","permissions":[{"kind":"project","namespace":"vx-alice","access":[{"resource":"repository","action":"pull"}]}]}' >"$robot_body"
chmod 0600 "$robot_body"
robot="$(_vx_harbor_api_call POST /api/v2.0/robots 201 \
    'type=="object" and (.id|type=="number") and (.secret|type=="string")' \
    "$robot_body")"
rm -f -- "$robot_body"
robot_id="$(jq -r .id <<<"$robot")"
robot_username="$(jq -r .name <<<"$robot")"
robot_secret="$(jq -r .secret <<<"$robot")"
[[ "$robot_username" == vxrobot-vx-alice+runtime-1 ]]
printf %s "$robot_secret" | vx_harbor_api_credential_probe "$robot_username"
! printf %s ignored-runtime-secret-canary | vx_harbor_api_credential_probe "$robot_username"
robot_read="$(vx_harbor_api_robot_get "$robot_id")"
jq -e 'has("secret") | not' <<<"$robot_read" >/dev/null
! vx_harbor_api_robot_disable "$robot_id"
vx_harbor_api_robot_delete "$robot_id"
! vx_harbor_api_robot_get "$robot_id" >/dev/null 2>&1

! vx_harbor_local_api_guard "$api_socket" GET /api/v2.0/configurations
! vx_harbor_api_project_get '../admin'
printf '{}\n' >"$HARBOR_TEST_ROOT/caller-body.json"
chmod 0600 "$HARBOR_TEST_ROOT/caller-body.json"
! _vx_harbor_api_call POST /api/v2.0/projects 201 empty "$HARBOR_TEST_ROOT/caller-body.json"
printf '{}\n' >"$(vx_harbor_root)/secrets/body.json"
chmod 0600 "$(vx_harbor_root)/secrets/body.json"
ln "$(vx_harbor_root)/secrets/body.json" "$(vx_harbor_root)/secrets/body-hardlink.json"
! _vx_harbor_api_call POST /api/v2.0/projects 201 empty "$(vx_harbor_root)/secrets/body.json"
unlink "$(vx_harbor_root)/secrets/body-hardlink.json"
unlink "$(vx_harbor_root)/secrets/body.json"

jq '.fault={path:"/api/v2.0/health",mode:"malformed"}' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
! vx_harbor_api_health >/dev/null
jq '.fault={path:"/api/v2.0/health",status:503}' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
! vx_harbor_api_health >/dev/null
jq '.fault={path:"/api/v2.0/health",mode:"oversize"}' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
! vx_harbor_api_health >/dev/null
jq '.fault=null' "$state" >"$state.tmp"
mv "$state.tmp" "$state"

kill "$api_pid"
wait "$api_pid" || :
api_pid=
! vx_harbor_api_health >/dev/null 2>&1
! grep -q 'fixture-password\|caller-create-secret-is-ignored\|ignored-runtime-secret-canary' "$log"
! grep -Fq "$integration_secret" "$log"
! grep -Fq "$robot_secret" "$log"

printf 'PASS: protected Harbor API adapter\n'
