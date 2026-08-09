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
chmod 0660 "$api_socket"
VX_HARBOR_SOCKET_UID="$EUID"
VX_HARBOR_SOCKET_GID="$(id -g)"

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
  "duration":-1,
  "level":"system",
  "permissions":[
    {"kind":"system","namespace":"/","access":[
      {"resource":"project","action":"create"},
      {"resource":"quota","action":"read"},
      {"resource":"quota","action":"update"},
      {"resource":"system-volumes","action":"read"}
    ]},
    {"kind":"project","namespace":"*","access":[
      {"resource":"project","action":"read"},
      {"resource":"artifact","action":"read"},
      {"resource":"repository","action":"read"},
      {"resource":"repository","action":"list"},
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

vx_harbor_api_health | jq -e '.status=="healthy"' >/dev/null
vx_harbor_api_project_create vx-alice
project="$(vx_harbor_api_project_get vx-alice)"
[[ "$(jq -r .name <<<"$project")" == vx-alice ]]
project_id="$(jq -r .project_id <<<"$project")"
quota="$(jq -r .quota_id <<<"$project")"
vx_harbor_api_quota_set_bytes "$quota" 1048576
[[ "$(vx_harbor_api_quota_get "$quota" | jq -r .hard.storage)" == 1048576 ]]

robot_body="$(vx_harbor_root)/secrets/robot-body.json"
printf '%s\n' '{"name":"runtime-1","description":"vesta-managed:vesta-harbor:alice:runtime:0123456789abcdef0123456789abcdef","duration":-1,"level":"project","permissions":[{"kind":"project","namespace":"vx-alice","access":[{"resource":"repository","action":"pull"}]}]}' >"$robot_body"
chmod 0600 "$robot_body"
! _vx_harbor_api_call POST /api/v2.0/robots 201 empty "$robot_body"
rm -f -- "$robot_body"
marker='vesta-managed:vesta-harbor:alice:runtime:0123456789abcdef0123456789abcdef'
robot="$(_vx_harbor_api_project_robot_create_secret_once \
    "$project_id" vx-alice runtime-1 "$marker" pull)"
jq -e 'keys==["creation_time","expires_at","id","name","secret"] and
    .expires_at==-1 and (.secret|type=="string" and length>=8)' \
    <<<"$robot" >/dev/null || fail 'secret-bearing create did not validate RobotCreated'
robot_id="$(jq -r .id <<<"$robot")"
robot_username="$(jq -r .name <<<"$robot")"
robot_secret="$(jq -r .secret <<<"$robot")"
[[ "$robot_username" == vxrobot-vx-alice+runtime-1 ]]
printf %s "$robot_secret" | vx_harbor_api_credential_probe "$robot_username"
! printf %s wrong-runtime-secret-canary | vx_harbor_api_credential_probe "$robot_username"
robot_list="$(vx_harbor_api_project_robots_list "$project_id")"
jq -e --argjson id "$robot_id" 'length==1 and .[0].id==$id and
    (.[0]|has("secret")|not)' <<<"$robot_list" >/dev/null \
    || fail 'project robot list was not bounded and redacted'
jq --argjson project_id "$project_id" '
  .robots += [range(1000;1100) | {
    id:.,name:("vxrobot-page-"+tostring),description:("page-"+tostring),
    disable:false,disabled:false,duration:-1,expires_at:-1,level:"project",
    project_id:$project_id,permissions:[]
  }]
' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
robot_list="$(vx_harbor_api_project_robots_list "$project_id")"
jq -e --argjson id "$robot_id" 'length==101 and any(.id==$id)' \
  <<<"$robot_list" >/dev/null || fail 'project robot pagination truncated a live page'
jq '.robots |= map(select(.id < 1000 or .id >= 1100))' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
robot_found="$(vx_harbor_api_project_robot_find "$project_id" "$marker")"
[[ "$(jq -r .id <<<"$robot_found")" == "$robot_id" ]] \
    || fail 'exact marked child was not found'
robot_read="$(vx_harbor_api_project_robot_get "$project_id" "$robot_id" "$marker")"
jq -e 'has("secret") | not' <<<"$robot_read" >/dev/null
! vx_harbor_api_project_robot_delete "$project_id" "$robot_id" \
    'vesta-managed:vesta-harbor:alice:runtime:ffffffffffffffffffffffffffffffff'
vx_harbor_api_project_robot_get "$project_id" "$robot_id" "$marker" >/dev/null
vx_harbor_api_project_robot_delete "$project_id" "$robot_id" "$marker"
vx_harbor_api_project_robot_delete "$project_id" "$robot_id" "$marker"
! vx_harbor_api_project_robot_get "$project_id" "$robot_id" "$marker" >/dev/null 2>&1

duplicate_one="$(_vx_harbor_api_project_robot_create_secret_once \
    "$project_id" vx-alice runtime-2 "$marker" pull)"
duplicate_two="$(_vx_harbor_api_project_robot_create_secret_once \
    "$project_id" vx-alice runtime-3 "$marker" pull)"
! vx_harbor_api_project_robot_find "$project_id" "$marker" >/dev/null
jq --argjson id "$(jq -r .id <<<"$duplicate_two")" \
    '.robots |= map(select(.id != $id))' "$state" >"$state.tmp"
mv "$state.tmp" "$state"
duplicate_id="$(jq -r .id <<<"$duplicate_one")"
vx_harbor_api_project_robot_delete "$project_id" "$duplicate_id" "$marker"

! vx_harbor_local_api_guard "$api_socket" GET /api/v2.0/configurations
! vx_harbor_local_api_guard "$api_socket" GET \
    "/api/v2.0/robots?q=Level%3Dproject%2CProjectID%3D${project_id}&page=1&page_size=1000"
vx_harbor_local_api_guard "$api_socket" GET \
    "/api/v2.0/robots?q=Level%3Dproject%2CProjectID%3D${project_id}&page=10&page_size=100"
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
! grep -q 'fixture-password\|wrong-runtime-secret-canary' "$log"
! grep -Fq "$integration_secret" "$log"
! grep -Fq "$robot_secret" "$log"

printf 'PASS: protected Harbor API adapter\n'
