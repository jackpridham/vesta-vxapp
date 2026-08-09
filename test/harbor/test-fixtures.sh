#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test/harbor/lib.sh
source "$test_dir/lib.sh"

if [[ -n "${HARBOR_TEST_RUN_ROOT:-}" ]]; then
    HARBOR_TEST_ROOT="$(dirname "$HARBOR_TEST_RUN_ROOT")"
    VESTA="$HARBOR_TEST_RUN_ROOT"
    export HARBOR_TEST_ROOT VESTA
    mkdir -p "$VESTA"
else
    new_vesta_root
fi

api_pid=
cleanup() {
    if [[ -n "$api_pid" ]]; then
        kill "$api_pid" 2>/dev/null || true
        wait "$api_pid" 2>/dev/null || true
    fi
    if [[ -z "${HARBOR_TEST_RUN_ROOT:-}" ]]; then
        cleanup_vesta_root
    fi
}
trap cleanup EXIT

state_file="$HARBOR_TEST_ROOT/api-state.json"
log_file="$HARBOR_TEST_ROOT/api.log"
ready_file="$HARBOR_TEST_ROOT/api.ready"
credential_file="$HARBOR_TEST_ROOT/api-credential.json"
curl_config="$HARBOR_TEST_ROOT/curl.conf"
username=admin
password='fixture-credential-canary'
printf '{"username":"%s","password":"%s"}\n' "$username" "$password" >"$credential_file"
printf 'silent\nshow-error\nuser = "%s:%s"\n' "$username" "$password" >"$curl_config"
chmod 0600 "$credential_file" "$curl_config"

start_api() {
    : >"$ready_file"
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
            [[ "$port" =~ ^[0-9]+$ ]] || fail 'fake Harbor API published an invalid port'
            return
        fi
        if ! kill -0 "$api_pid" 2>/dev/null; then
            wait "$api_pid" || true
            fail 'fake Harbor API exited before publishing readiness'
        fi
        [[ "$attempt" -lt 50 ]] || fail 'fake Harbor API readiness timed out'
        sleep 0.1
    done
}

stop_api() {
    kill "$api_pid"
    wait "$api_pid" 2>/dev/null || true
    api_pid=
}

api_call() {
    local method="$1"
    local path="$2"
    local output="$3"
    shift 3
    curl --config "$curl_config" \
        --request "$method" \
        --output "$output" \
        --write-out '%{http_code}' \
        "$@" "http://127.0.0.1:$port$path"
}

assert_json() {
    local file="$1"
    local expression="$2"
    python3 -c "import json, sys; value=json.load(open(sys.argv[1], encoding='utf-8')); assert $expression" "$file"
}

start_api

response="$HARBOR_TEST_ROOT/response.json"
status="$(curl --silent --show-error --output "$response" --write-out '%{http_code}' \
    "http://127.0.0.1:$port/api/v2.0/health")"
[[ "$status" == 401 ]] || fail "unauthenticated API request returned $status"

status="$(api_call GET /api/v2.0/configurations "$response")"
[[ "$status" == 200 ]] || fail 'configuration GET failed'
assert_json "$response" 'value == {}'
status="$(api_call PUT /api/v2.0/configurations "$response" \
    --header 'Content-Type: application/json' \
    --data-binary '{"auth_mode":"db_auth","robot_name_prefix":"vxrobot-"}')"
[[ "$status" == 200 ]] || fail 'configuration PUT failed'
status="$(api_call GET /api/v2.0/configurations "$response")"
assert_json "$response" 'value["auth_mode"] == "db_auth"'

status="$(api_call POST /api/v2.0/projects "$response" \
    --header 'Content-Type: application/json' --data-binary '{"project_name":"vx-alice"}')"
[[ "$status" == 201 ]] || fail 'project create failed'
status="$(api_call POST /api/v2.0/projects "$response" \
    --header 'Content-Type: application/json' --data-binary '{"project_name":"vx-alice"}')"
[[ "$status" == 409 ]] || fail 'duplicate project was not rejected'
status="$(api_call GET /api/v2.0/projects/vx-alice "$response")"
[[ "$status" == 200 ]] || fail 'project read by name failed'
assert_json "$response" 'value["id"] == 1 and "quota_id" not in value'
status="$(api_call PUT /api/v2.0/projects/1 "$response" \
    --header 'Content-Type: application/json' --data-binary '{"metadata":{"public":"false"}}')"
[[ "$status" == 200 ]] || fail 'project update failed'
status="$(api_call GET /api/v2.0/projects/1 "$response")"
assert_json "$response" 'value["metadata"] == {"public":"false"}'
status="$(api_call PUT /api/v2.0/projects/1 "$response" \
    --header 'Content-Type: application/json' \
    --data-binary '{"metadata":{"public":"false","owner":"alice"}}')"
[[ "$status" == 400 ]] || fail 'unsupported project metadata was accepted'

status="$(api_call GET /api/v2.0/quotas/1 "$response")"
[[ "$status" == 200 ]] || fail 'quota read failed'
status="$(api_call PUT /api/v2.0/quotas/1 "$response" \
    --header 'Content-Type: application/json' --data-binary '{"hard":{"storage":1048576}}')"
[[ "$status" == 200 ]] || fail 'quota update failed'
status="$(api_call GET /api/v2.0/quotas/1 "$response")"
assert_json "$response" 'value["hard"]["storage"] == 1048576'

requested_secret='fixture-request-secret-must-be-ignored'
integration_body="$(jq -cn --arg secret "$requested_secret" '{
  name:"vesta-integration",secret:$secret,duration:-1,level:"system",permissions:[
    {kind:"system",namespace:"/",access:[
      {resource:"project",action:"create"},
      {resource:"quota",action:"read"},
      {resource:"quota",action:"update"},
      {resource:"system-volumes",action:"read"}
    ]},
    {kind:"project",namespace:"*",access:[
      {resource:"project",action:"read"},
      {resource:"repository",action:"list"},
      {resource:"repository",action:"read"},
      {resource:"repository",action:"pull"},
      {resource:"repository",action:"push"},
      {resource:"robot",action:"create"},
      {resource:"robot",action:"read"},
      {resource:"robot",action:"list"},
      {resource:"robot",action:"delete"},
      {resource:"artifact",action:"read"}
    ]}
  ]
}')"
status="$(api_call POST /api/v2.0/robots "$response" \
    --header 'Content-Type: application/json' --data-binary "$integration_body")"
[[ "$status" == 201 ]] || fail 'integration robot create failed'
integration_username="$(jq -er .name "$response")"
integration_secret="$(jq -er .secret "$response")"
[[ "$integration_username" == vxrobot-vesta-integration \
    && "$integration_secret" != "$requested_secret" ]] \
    || fail 'integration robot did not use generated secret and configured prefix'
status="$(api_call GET /api/v2.0/robots/1 "$response")"
[[ "$status" == 200 ]] || fail 'integration robot read failed'
assert_json "$response" '"secret" not in value'
printf 'silent\nshow-error\nuser = "%s:%s"\n' \
    "$integration_username" "$integration_secret" >"$curl_config"
chmod 0600 "$curl_config"

child_body='{"name":"publisher","description":"vesta-managed:candidate:fixture","secret":"ignored-child-secret-canary","disable":false,"duration":-1,"level":"project","permissions":[{"kind":"project","namespace":"vx-alice","access":[{"resource":"repository","action":"pull"},{"resource":"repository","action":"push"}]}]}'
status="$(api_call POST /api/v2.0/robots "$response" \
    --header 'Content-Type: application/json' --data-binary "$child_body")"
[[ "$status" == 201 ]] || fail 'project child robot create failed'
assert_json "$response" 'value["id"] == 2 and value["name"] == "vxrobot-vx-alice+publisher" and "secret" in value'
child_secret="$(jq -er .secret "$response")"
status="$(api_call GET /api/v2.0/robots/2 "$response")"
[[ "$status" == 200 ]] || fail 'project child robot read failed'
assert_json "$response" '"secret" not in value and value["level"] == "project"'
child_update_body="$(jq -c '.disable = true' "$response")"
status="$(api_call PUT /api/v2.0/robots/2 "$response" \
    --header 'Content-Type: application/json' --data-binary '{"disable":true}')"
[[ "$status" == 400 ]] || fail 'malformed robot update bypassed validation'
status="$(api_call PUT /api/v2.0/robots/2 "$response" \
    --header 'Content-Type: application/json' --data-binary "$child_update_body")"
[[ "$status" == 403 ]] || fail 'routine robot update did not require robot:update'
status="$(api_call PATCH /api/v2.0/robots/2 "$response" \
    --header 'Content-Type: application/json' --data-binary '{}')"
[[ "$status" == 403 ]] || fail 'routine robot refresh did not require robot:update'
status="$(api_call DELETE /api/v2.0/robots/2 "$response")"
[[ "$status" == 200 ]] || fail 'child robot delete failed'
status="$(api_call GET /api/v2.0/robots/2 "$response")"
[[ "$status" == 404 ]] || fail 'deleted child robot remained visible'
! grep -Fq "$requested_secret" "$state_file" \
    || fail 'ignored RobotCreate.secret reached fixture state'

pids=()
for number in $(seq -w 1 16); do
    api_call POST /api/v2.0/projects "$HARBOR_TEST_ROOT/concurrent-$number.out" \
        --header 'Content-Type: application/json' \
        --data-binary "{\"project_name\":\"vx-concurrent-$number\"}" \
        >"$HARBOR_TEST_ROOT/concurrent-$number.status" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do
    wait "$pid" || fail 'concurrent project request failed'
done
for number in $(seq -w 1 16); do
    [[ "$(<"$HARBOR_TEST_ROOT/concurrent-$number.status")" == 201 ]] \
        || fail "concurrent project $number was not created"
done
python3 -c 'import json, sys
state=json.load(open(sys.argv[1], encoding="utf-8"))
projects=state["projects"]
assert len(projects) == 17
assert len({item["id"] for item in projects}) == 17
assert len(state["quotas"]) == 17
assert state["next_project_id"] == 18
assert state["next_quota_id"] == 18
assert len(state["robots"]) == 1
assert state["robots"][0]["name"] == "vxrobot-vesta-integration"
assert "secret" in state["robots"][0]' "$state_file"

python3 - "$credential_file" "$port" "$state_file" <<'PY'
import base64
import json
import socket
import sys
import time
import urllib.request

credential = json.load(open(sys.argv[1], encoding="utf-8"))
port = int(sys.argv[2])
state_path = sys.argv[3]
authorization = base64.b64encode(
    f'{credential["username"]}:{credential["password"]}'.encode()
).decode()
partial = socket.create_connection(("127.0.0.1", port), timeout=1)
partial.sendall(
    (
        "POST /api/v2.0/projects HTTP/1.1\r\n"
        f"Host: 127.0.0.1:{port}\r\n"
        f"Authorization: Basic {authorization}\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 100\r\n"
        "Connection: close\r\n\r\n"
    ).encode()
    + b"{"
)
request = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/v2.0/health",
    headers={"Authorization": f"Basic {authorization}"},
)
started = time.monotonic()
with urllib.request.urlopen(request, timeout=1) as response:
    assert response.status == 200
    assert json.load(response)["status"] == "healthy"
assert time.monotonic() - started < 1
partial.settimeout(2)
reply = b""
while True:
    chunk = partial.recv(4096)
    if not chunk:
        break
    reply += chunk
partial.close()
assert b" 408 " in reply.split(b"\r\n", 1)[0]
assert b"REQUEST_TIMEOUT" in reply
assert len(reply) < 512
state = json.load(open(state_path, encoding="utf-8"))
assert len(state["projects"]) == 17
assert state["next_project_id"] == 18
PY
grep -Fxq 'POST /api/v2.0/projects 408' "$log_file" \
    || fail 'partial-body timeout was not logged as method/path/status'

for method in HEAD OPTIONS BREW; do
    body_file="$HARBOR_TEST_ROOT/${method}.body"
    status="$(api_call "$method" /api/v2.0/health "$body_file")"
    [[ "$status" == 404 ]] || fail "$method returned $status instead of 404"
    [[ ! -s "$body_file" ]] || fail "$method 404 leaked a response body"
done
body_file="$HARBOR_TEST_ROOT/PATCH.body"
status="$(api_call PATCH /api/v2.0/health "$body_file")"
[[ "$status" == 404 ]] || fail "PATCH returned $status instead of 404"
[[ "$(wc -c <"$body_file")" -le 128 ]] || fail 'PATCH 404 response was unbounded'
for method in PATCH BREW; do
    body_file="$HARBOR_TEST_ROOT/${method}.oversized.body"
    status="$(head -c 1048577 /dev/zero | api_call "$method" /api/v2.0/health "$body_file" --data-binary @-)"
    [[ "$status" == 413 ]] || fail "oversized $method returned $status instead of 413"
    [[ "$(wc -c <"$body_file")" -le 128 ]] || fail "oversized $method response was unbounded"
done
status="$(api_call POST /api/v2.0/projects "$response" \
    --header 'Content-Type: application/json' --data-binary '{')"
[[ "$status" == 400 ]] || fail 'malformed allowed-method JSON was not rejected'

stop_api
python3 -c 'import json, sys
path=sys.argv[1]
state=json.load(open(path, encoding="utf-8"))
assert state["configurations"]["auth_mode"] == "db_auth"
state["artifacts"]["vx-alice/app@sha256:abc"]={"digest":"sha256:abc","size":123}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":")); handle.write("\n")' "$state_file"
start_api
status="$(api_call GET /api/v2.0/projects/vx-alice/repositories "$response")"
[[ "$status" == 200 ]] || fail 'repository list failed'
assert_json "$response" 'value == [{"name":"vx-alice/app"}]'
status="$(api_call GET /api/v2.0/projects/vx-alice/repositories/app/artifacts/sha256:abc "$response")"
[[ "$status" == 200 ]] || fail 'artifact lookup failed'
assert_json "$response" 'value["digest"] == "sha256:abc" and value["size"] == 123'
stop_api

awk 'NF != 3 || $1 !~ /^[A-Z]+$/ || $2 !~ /^\// || $3 !~ /^[0-9][0-9][0-9]$/ { exit 1 }' "$log_file" \
    || fail 'API log contains fields other than method/path/status'
python3 -c 'import json, sys
credential=json.load(open(sys.argv[1], encoding="utf-8"))
log=open(sys.argv[2], encoding="utf-8").read()
assert credential["username"] not in log
assert credential["password"] not in log' "$credential_file" "$log_file" \
    || fail 'API log contains credential material'
for secret in "$integration_secret" "$child_secret"; do
    if grep -Fq "$secret" "$log_file"; then fail 'API log contains generated robot secret'; fi
done

docker_log="$HARBOR_TEST_ROOT/docker.log"
docker_state="$HARBOR_TEST_ROOT/docker-state"
compose_file="$HARBOR_TEST_ROOT/compose.yaml"
printf 'services:\n  registry: {}\n' >"$compose_file"
fake_docker() {
    FAKE_DOCKER_LOG="$docker_log" FAKE_DOCKER_STATE="$docker_state" \
        "$test_dir/fixtures/fake-docker.sh" "$@"
}
fake_docker compose -p harbor -f "$compose_file" config >/dev/null
fake_docker compose -p harbor up
[[ "$(fake_docker compose -p harbor ps)" == running ]] || fail 'fake Docker up/ps failed'
fake_docker compose -p harbor restart
[[ "$(fake_docker compose -p harbor ps)" == running ]] || fail 'fake Docker restart failed'
fake_docker compose -p harbor stop
[[ "$(fake_docker compose -p harbor ps)" == stopped ]] || fail 'fake Docker stop failed'
fake_docker compose -p harbor start
[[ "$(fake_docker compose -p harbor ps)" == running ]] || fail 'fake Docker start failed'
fake_docker compose -p harbor down
[[ "$(fake_docker compose -p harbor ps)" == stopped ]] || fail 'fake Docker down failed'
for invalid_project in '../escape' 'bad/name' '' '-leading' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    if fake_docker compose -p "$invalid_project" up >/dev/null 2>&1; then
        fail "fake Docker accepted invalid project: $invalid_project"
    fi
done
[[ ! -e "$HARBOR_TEST_ROOT/escape.service" ]] || fail 'fake Docker project escaped state root'
[[ "$(find "$docker_state" -type f -printf '%f\n')" == harbor.service ]] \
    || fail 'fake Docker created state outside the validated project'
if fake_docker compose --password=docker-log-canary >/dev/null 2>&1; then
    fail 'fake Docker accepted a secret-bearing argument'
fi
if grep -Fq docker-log-canary "$docker_log"; then fail 'fake Docker logged a secret canary'; fi

systemctl_log="$HARBOR_TEST_ROOT/systemctl.log"
systemctl_state="$HARBOR_TEST_ROOT/systemctl-state"
fake_systemctl() {
    FAKE_SYSTEMCTL_LOG="$systemctl_log" FAKE_SYSTEMCTL_STATE="$systemctl_state" \
        "$test_dir/fixtures/fake-systemctl.sh" "$@"
}
fake_systemctl daemon-reload
fake_systemctl enable vesta-harbor.service
fake_systemctl is-enabled vesta-harbor.service
fake_systemctl start vesta-harbor.service
fake_systemctl is-active vesta-harbor.service
[[ "$(fake_systemctl status vesta-harbor.service)" == active ]] || fail 'systemctl start failed'
fake_systemctl restart vesta-harbor.service
fake_systemctl stop vesta-harbor.service
[[ "$(fake_systemctl status vesta-harbor.service)" == inactive ]] || fail 'systemctl stop failed'
fake_systemctl disable vesta-harbor.service
if fake_systemctl is-enabled vesta-harbor.service; then fail 'systemctl disable failed'; fi
for invalid_unit in '../escape.service' 'bad/unit.service' '' '-leading.service' "$(printf 'a%.0s' $(seq 1 129)).service"; do
    if fake_systemctl start "$invalid_unit" >/dev/null 2>&1; then
        fail "fake systemctl accepted invalid unit: $invalid_unit"
    fi
done
if fake_systemctl start vesta-harbor.service --password=systemctl-secret-canary >/dev/null 2>&1; then
    fail 'fake systemctl accepted a secret-bearing argument'
fi
if grep -Fq systemctl-secret-canary "$systemctl_log"; then fail 'fake systemctl logged a secret canary'; fi
if find "$systemctl_state" -type f ! -name 'vesta-harbor.service.state' -print -quit | grep -q .; then
    fail 'fake systemctl created state for an invalid unit'
fi

printf 'Harbor fixture tests passed.\n'
