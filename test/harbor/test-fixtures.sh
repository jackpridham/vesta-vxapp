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

port="$(python3 -c 'import socket; sock = socket.socket(); sock.bind(("127.0.0.1", 0)); print(sock.getsockname()[1]); sock.close()')"
state_file="$HARBOR_TEST_ROOT/api-state.json"
log_file="$HARBOR_TEST_ROOT/api.log"
username=integration
password='fixture-secret-not-for-logs'

python3 "$test_dir/fixtures/fake-harbor-api.py" \
    --port "$port" \
    --state "$state_file" \
    --log "$log_file" \
    --username "$username" \
    --password "$password" &
api_pid=$!

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl --silent --show-error --output /dev/null \
        --user "$username:$password" \
        "http://127.0.0.1:$port/api/v2.0/health" 2>/dev/null; then
        break
    fi
    [[ "$attempt" -lt 10 ]] || fail 'fake Harbor API did not become ready'
    sleep 0.1
done

: >"$log_file"
for method in HEAD PATCH OPTIONS BREW; do
    body_file="$HARBOR_TEST_ROOT/${method}.body"
    status="$(curl --silent --show-error \
        --request "$method" \
        --user "$username:$password" \
        --output "$body_file" \
        --write-out '%{http_code}' \
        "http://127.0.0.1:$port/api/v2.0/health")"
    [[ "$status" == 404 ]] || fail "$method returned $status instead of 404"
    [[ ! -s "$body_file" ]] || fail "$method 404 leaked a response body"
done

for method in PATCH BREW; do
    body_file="$HARBOR_TEST_ROOT/${method}.oversized.body"
    status="$(head -c 1048577 /dev/zero | curl --silent --show-error \
        --request "$method" \
        --user "$username:$password" \
        --data-binary @- \
        --output "$body_file" \
        --write-out '%{http_code}' \
        "http://127.0.0.1:$port/api/v2.0/health")"
    [[ "$status" == 413 ]] || fail "oversized $method returned $status instead of 413"
    [[ "$(wc -c <"$body_file")" -le 128 ]] || fail "oversized $method response was unbounded"
    grep -Fq 'PAYLOAD_TOO_LARGE' "$body_file" \
        || fail "oversized $method response omitted the bounded error code"
done

malformed_body="$HARBOR_TEST_ROOT/malformed.body"
status="$(curl --silent --show-error \
    --request POST \
    --user "$username:$password" \
    --header 'Content-Type: application/json' \
    --data-binary '{' \
    --output "$malformed_body" \
    --write-out '%{http_code}' \
    "http://127.0.0.1:$port/api/v2.0/projects")"
[[ "$status" == 400 ]] || fail "malformed allowed-method JSON returned $status instead of 400"
grep -Fq 'BAD_REQUEST' "$malformed_body" || fail 'malformed JSON omitted the bounded error code'

expected_log="$HARBOR_TEST_ROOT/expected.log"
printf '%s\n' \
    'HEAD /api/v2.0/health 404' \
    'PATCH /api/v2.0/health 404' \
    'OPTIONS /api/v2.0/health 404' \
    'BREW /api/v2.0/health 404' \
    'PATCH /api/v2.0/health 413' \
    'BREW /api/v2.0/health 413' \
    'POST /api/v2.0/projects 400' >"$expected_log"
cmp -s "$expected_log" "$log_file" || fail 'unsupported-method log is not method/path/status only'
if grep -Fq "$password" "$log_file"; then
    fail 'fixture log contains Basic-auth credential material'
fi

printf 'Harbor fixture tests passed.\n'
