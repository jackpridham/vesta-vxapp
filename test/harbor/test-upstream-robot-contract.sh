#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Behavioral parity fixture for Harbor v2.15.0 at commit
# e2b5ce92728f86c4b02f6a9a667741c1e5b62678. This test is intentionally
# network-free. The pinned upstream source paths that define these assertions
# are:
#   src/controller/robot/controller.go       generated secret and prefixed name
#   src/server/v2.0/handler/robot.go         one-time create response, delegated
#                                             subset check, update/refresh RBAC
#   src/server/v2.0/handler/model/robot.go   GET/list secret redaction
#   src/common/rbac/const.go                 quota scope and omitted robot:update

test_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/harbor/lib.sh
source "$test_dir/lib.sh"

new_vesta_root
api_pid=
cleanup() {
    if [[ -n "$api_pid" ]]; then
        kill "$api_pid" 2>/dev/null || true
        wait "$api_pid" 2>/dev/null || true
    fi
    cleanup_vesta_root
}
trap cleanup EXIT

state_file="$HARBOR_TEST_ROOT/api-state.json"
log_file="$HARBOR_TEST_ROOT/api.log"
ready_file="$HARBOR_TEST_ROOT/api.ready"
credential_file="$HARBOR_TEST_ROOT/bootstrap-credential.json"
bootstrap_config="$HARBOR_TEST_ROOT/bootstrap.curl"
integration_config="$HARBOR_TEST_ROOT/integration.curl"
runtime_config="$HARBOR_TEST_ROOT/runtime.curl"
publisher_config="$HARBOR_TEST_ROOT/publisher.curl"
response="$HARBOR_TEST_ROOT/response.json"
request="$HARBOR_TEST_ROOT/request.json"

write_curl_config() {
    local path="$1" username="$2" password="$3"
    printf 'silent\nshow-error\nuser = "%s:%s"\n' "$username" "$password" >"$path"
    chmod 0600 "$path"
}

api_call() {
    local config="$1" method="$2" path="$3" output="$4"
    shift 4
    curl --config "$config" --request "$method" --output "$output" \
        --write-out '%{http_code}' "$@" "http://127.0.0.1:$port$path"
}

json_request() {
    local config="$1" method="$2" path="$3" json="$4" output="$5"
    printf '%s\n' "$json" >"$request"
    api_call "$config" "$method" "$path" "$output" \
        --header 'Content-Type: application/json' --data-binary @"$request"
}

assert_status() {
    local actual="$1" expected="$2" context="$3"
    [[ "$actual" == "$expected" ]] || fail "$context returned $actual, expected $expected"
}

bootstrap_user=admin
bootstrap_password='fixture-bootstrap-canary'
printf '{"username":"%s","password":"%s"}\n' \
    "$bootstrap_user" "$bootstrap_password" >"$credential_file"
chmod 0600 "$credential_file"
write_curl_config "$bootstrap_config" "$bootstrap_user" "$bootstrap_password"

python3 "$test_dir/fixtures/fake-harbor-api.py" \
    --port 0 \
    --state "$state_file" \
    --log "$log_file" \
    --credential-file "$credential_file" \
    --ready-file "$ready_file" &
api_pid=$!
for attempt in $(seq 1 50); do
    if [[ -s "$ready_file" ]]; then
        port="$(<"$ready_file")"
        break
    fi
    kill -0 "$api_pid" 2>/dev/null || fail 'fake Harbor API exited before readiness'
    [[ "$attempt" -lt 50 ]] || fail 'fake Harbor API readiness timed out'
    sleep 0.1
done
[[ "$port" =~ ^[0-9]+$ ]] || fail 'fake Harbor API published an invalid port'

status="$(json_request "$bootstrap_config" PUT /api/v2.0/configurations \
    '{"robot_name_prefix":"vxrobot-","self_registration":false,"project_creation_restriction":"adminonly"}' \
    "$response")"
assert_status "$status" 200 'bootstrap configuration'

status="$(api_call "$bootstrap_config" GET /api/v2.0/permissions "$response")"
assert_status "$status" 200 'robot permission catalog'
jq -e '
    ([.system[], .project[]] | any(.resource == "robot" and .action == "update") | not)
    and ([.system[] | select(.resource == "robot") | .action] | sort
         == ["create", "delete", "list", "read"])
    and ([.project[] | select(.resource == "robot") | .action] | sort
         == ["create", "delete", "list", "read"])
    and ([.system[] | select(.resource == "quota") | .action] | sort
         == ["list", "read", "update"])
    and ([.project[] | select(.resource == "quota") | .action] == ["read"])
' "$response" >/dev/null || fail 'robot RBAC catalog does not match pinned Harbor'

status="$(json_request "$bootstrap_config" POST /api/v2.0/projects \
    '{"project_name":"vx-alice","metadata":{"public":"false"}}' "$response")"
assert_status "$status" 201 'private project create'
status="$(json_request "$bootstrap_config" POST /api/v2.0/projects \
    '{"project_name":"vx-unsupported","metadata":{"public":"false","owner":"alice"}}' \
    "$response")"
assert_status "$status" 400 'unsupported project metadata'

integration_request_secret='CallerSecretMustBeIgnored9'
integration_body="$(jq -cn --arg secret "$integration_request_secret" '{
    name:"vesta-integration",
    description:"vesta-managed:vesta-harbor",
    secret:$secret,
    duration:-1,
    level:"system",
    permissions:[
      {kind:"system",namespace:"/",access:[
        {resource:"project",action:"create"},
        {resource:"project",action:"list"},
        {resource:"quota",action:"update"},
        {resource:"system-volumes",action:"read"}
      ]},
      {kind:"project",namespace:"*",access:[
        {resource:"project",action:"read"},
        {resource:"project",action:"update"},
        {resource:"quota",action:"read"},
        {resource:"repository",action:"list"},
        {resource:"repository",action:"pull"},
        {resource:"repository",action:"push"},
        {resource:"repository",action:"read"},
        {resource:"robot",action:"create"},
        {resource:"robot",action:"read"},
        {resource:"robot",action:"list"},
        {resource:"robot",action:"delete"}
      ]}
    ]
  }')"
status="$(json_request "$bootstrap_config" POST /api/v2.0/robots \
    "$integration_body" "$response")"
assert_status "$status" 201 'integration robot create'
integration_id="$(jq -er '.id' "$response")"
integration_username="$(jq -er '.name' "$response")"
integration_secret="$(jq -er '.secret' "$response")"
[[ "$integration_username" == vxrobot-vesta-integration ]] \
    || fail 'system robot username omitted configured prefix'
[[ "$integration_secret" != "$integration_request_secret" \
    && "$integration_secret" =~ [a-z] \
    && "$integration_secret" =~ [A-Z] \
    && "$integration_secret" =~ [0-9] \
    && ${#integration_secret} -ge 8 \
    && ${#integration_secret} -le 128 ]] \
    || fail 'Harbor did not generate a valid replacement create secret'
write_curl_config "$integration_config" "$integration_username" "$integration_secret"
status="$(api_call "$integration_config" GET /api/v2.0/configurations "$response")"
assert_status "$status" 403 'routine integration bootstrap-only configuration access'

status="$(api_call "$bootstrap_config" GET "/api/v2.0/robots/$integration_id" "$response")"
assert_status "$status" 200 'integration robot read'
jq -e '
    .level == "system"
    and .permissions == [
      {kind:"system",namespace:"/",access:[
        {resource:"project",action:"create"},
        {resource:"project",action:"list"},
        {resource:"quota",action:"update"},
        {resource:"system-volumes",action:"read"}
      ]},
      {kind:"project",namespace:"*",access:[
        {resource:"project",action:"read"},
        {resource:"project",action:"update"},
        {resource:"quota",action:"read"},
        {resource:"repository",action:"list"},
        {resource:"repository",action:"pull"},
        {resource:"repository",action:"push"},
        {resource:"repository",action:"read"},
        {resource:"robot",action:"create"},
        {resource:"robot",action:"read"},
        {resource:"robot",action:"list"},
        {resource:"robot",action:"delete"}
      ]}
    ]
    and (has("secret") | not)
' "$response" >/dev/null \
    || fail 'integration robot levels, scopes, permissions, or redaction drifted'
status="$(api_call "$bootstrap_config" GET /api/v2.0/robots "$response")"
assert_status "$status" 200 'robot list'
jq -e 'all(.[]; has("secret") | not)' "$response" >/dev/null \
    || fail 'robot list disclosed a one-time secret'
! grep -Fq "$integration_request_secret" "$state_file" \
    || fail 'ignored RobotCreate.secret reached fixture state'

runtime_body='{
  "name":"runtime-1",
  "description":"vesta-managed:candidate:runtime-op-1",
  "secret":"AnotherCallerSecretIgnored9",
  "duration":-1,
  "level":"project",
  "permissions":[{"kind":"project","namespace":"vx-alice","access":[
    {"resource":"repository","action":"pull"}
  ]}]
}'
status="$(json_request "$integration_config" POST /api/v2.0/robots \
    "$runtime_body" "$response")"
assert_status "$status" 201 'delegated runtime robot create'
runtime_id="$(jq -er '.id' "$response")"
runtime_username="$(jq -er '.name' "$response")"
runtime_secret="$(jq -er '.secret' "$response")"
[[ "$runtime_username" == vxrobot-vx-alice+runtime-1 ]] \
    || fail 'project robot username omitted prefix or PROJECT+ROBOT_BASENAME'
write_curl_config "$runtime_config" "$runtime_username" "$runtime_secret"
status="$(api_call "$runtime_config" GET /v2/ "$response")"
assert_status "$status" 200 'generated runtime credential probe'

status="$(api_call "$integration_config" GET "/api/v2.0/robots/$runtime_id" "$response")"
assert_status "$status" 200 'runtime robot verification'
jq -e '
    .level == "project"
    and .permissions == [{
      kind:"project", namespace:"vx-alice",
      access:[{resource:"repository",action:"pull"}]
    }]
    and (has("secret") | not)
' "$response" >/dev/null || fail 'runtime robot level, scope, or redaction drifted'
runtime_update_body="$(jq -c '.disable = true' "$response")"
jq -e '
    .name == "vxrobot-vx-alice+runtime-1"
    and .description == "vesta-managed:candidate:runtime-op-1"
    and .disable == true
    and .duration == -1
    and .level == "project"
    and .permissions == [{
      kind:"project", namespace:"vx-alice",
      access:[{resource:"repository",action:"pull"}]
    }]
' <<<"$runtime_update_body" >/dev/null \
    || fail 'runtime update body did not preserve the current valid robot shape'

status="$(json_request "$integration_config" POST /api/v2.0/robots \
    '{"name":"too-broad","duration":-1,"level":"project","permissions":[{"kind":"project","namespace":"vx-alice","access":[{"resource":"artifact","action":"read"}]}]}' \
    "$response")"
assert_status "$status" 403 'delegated permission subset enforcement'

status="$(json_request "$integration_config" PUT "/api/v2.0/robots/$runtime_id" \
    '{"disable":true}' "$response")"
assert_status "$status" 400 'malformed integration robot child update'
jq -e '.errors == [{code:"BAD_REQUEST"}]' "$response" >/dev/null \
    || fail 'malformed robot update did not fail validation before authorization'
status="$(json_request "$integration_config" PUT "/api/v2.0/robots/$runtime_id" \
    "$runtime_update_body" "$response")"
assert_status "$status" 403 'integration robot child update'
jq -e '.errors == [{code:"FORBIDDEN"}]' "$response" >/dev/null \
    || fail 'valid robot update was not denied specifically by robot:update RBAC'
status="$(json_request "$integration_config" PATCH "/api/v2.0/robots/$runtime_id" \
    '{}' "$response")"
assert_status "$status" 403 'integration robot child refresh'
status="$(json_request "$runtime_config" PATCH "/api/v2.0/robots/$runtime_id" \
    '{}' "$response")"
assert_status "$status" 403 'child robot self-refresh'

publisher_body='{
  "name":"publisher-1",
  "description":"vesta-managed:candidate:publisher-op-1",
  "duration":-1,
  "level":"project",
  "permissions":[{"kind":"project","namespace":"vx-alice","access":[
    {"resource":"repository","action":"pull"},
    {"resource":"repository","action":"push"}
  ]}]
}'
status="$(json_request "$integration_config" POST /api/v2.0/robots \
    "$publisher_body" "$response")"
assert_status "$status" 201 'delegated publisher robot create'
publisher_id="$(jq -er '.id' "$response")"
publisher_username="$(jq -er '.name' "$response")"
publisher_secret="$(jq -er '.secret' "$response")"
[[ "$publisher_username" == vxrobot-vx-alice+publisher-1 ]] \
    || fail 'publisher username does not match configured project robot form'
write_curl_config "$publisher_config" "$publisher_username" "$publisher_secret"
status="$(api_call "$publisher_config" GET /v2/ "$response")"
assert_status "$status" 200 'generated publisher credential probe'
status="$(api_call "$integration_config" GET "/api/v2.0/robots/$publisher_id" "$response")"
assert_status "$status" 200 'publisher robot verification'
jq -e '
    .level == "project"
    and .permissions == [{
      kind:"project", namespace:"vx-alice",
      access:[
        {resource:"repository",action:"pull"},
        {resource:"repository",action:"push"}
      ]
    }]
    and (has("secret") | not)
' "$response" >/dev/null || fail 'publisher robot level, scope, or redaction drifted'
python3 - "$state_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state["artifacts"]["vx-alice/app@sha256:fixture"] = {
    "digest": "sha256:fixture",
    "size": 1,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY

status="$(api_call "$integration_config" DELETE "/api/v2.0/robots/$publisher_id" "$response")"
assert_status "$status" 200 'publisher revocation delete'
status="$(api_call "$integration_config" DELETE "/api/v2.0/robots/$publisher_id" "$response")"
assert_status "$status" 404 'publisher repeated revocation delete'
status="$(api_call "$integration_config" GET "/api/v2.0/robots/$publisher_id" "$response")"
assert_status "$status" 404 'publisher revocation validation'
jq -e '
    any(.projects[]; .name == "vx-alice")
    and (.artifacts["vx-alice/app@sha256:fixture"].size == 1)
' "$state_file" >/dev/null || fail 'publisher revocation removed project or artifacts'

python3 - "$state_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state["fault"] = {
    "path": "/api/v2.0/robots",
    "method": "POST",
    "mode": "lost-response",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
lost_body='{
  "name":"publisher-lost",
  "description":"vesta-managed:candidate:publisher-op-lost",
  "duration":-1,
  "level":"project",
  "permissions":[{"kind":"project","namespace":"vx-alice","access":[
    {"resource":"repository","action":"pull"},
    {"resource":"repository","action":"push"}
  ]}]
}'
printf '%s\n' "$lost_body" >"$request"
if curl --config "$integration_config" --request POST \
    --header 'Content-Type: application/json' --data-binary @"$request" \
    --output "$response" "http://127.0.0.1:$port/api/v2.0/robots" 2>/dev/null; then
    fail 'lost-response injection returned a create response'
fi
lost_id="$(jq -er '.robots[] | select(.description == "vesta-managed:candidate:publisher-op-lost") | .id' \
    "$state_file")"
status="$(api_call "$integration_config" GET /api/v2.0/robots "$response")"
assert_status "$status" 200 'candidate discovery after lost response'
jq -e --argjson id "$lost_id" '
    any(.[]; .id == $id
        and .description == "vesta-managed:candidate:publisher-op-lost"
        and (has("secret") | not))
' "$response" >/dev/null || fail 'lost-response candidate is not discoverable and redacted'
status="$(api_call "$integration_config" DELETE "/api/v2.0/robots/$lost_id" "$response")"
assert_status "$status" 200 'lost-response candidate cleanup'

status="$(api_call "$integration_config" DELETE "/api/v2.0/robots/$runtime_id" "$response")"
assert_status "$status" 200 'runtime generation delete'
status="$(api_call "$integration_config" GET "/api/v2.0/robots/$runtime_id" "$response")"
assert_status "$status" 404 'runtime generation delete validation'

for secret in \
    "$integration_request_secret" "$integration_secret" \
    "$runtime_secret" "$publisher_secret"
do
    ! grep -Fq "$secret" "$log_file" || fail 'API log contains robot secret material'
done

printf 'PASS: pinned Harbor upstream robot contract\n'
