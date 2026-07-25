#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice" \
    "$VESTA/data/users/bob/docker-projects/other/runtime" \
    "$HOMEDIR/alice" "$HOMEDIR/bob"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

model="$test_root/model.json"
jq -n '{
    services: {
        app: {
            ports: [
                {host_ip: "127.0.0.1", published: "19010", target: 8010, protocol: "tcp", mode: "ingress"},
                {host_ip: "127.0.0.1", published: "19011", target: 8011, protocol: "udp", mode: "ingress"}
            ]
        }
    }
}' >"$model"
vx_compose_policy_check_ports "$model" standard \
    || fail "valid localhost TCP/UDP mappings were rejected"

empty="$test_root/empty.json"
printf '{"services":{"app":{}}}\n' >"$empty"
vx_compose_policy_check_ports "$empty" standard \
    || fail "zero-port workload was rejected"

expect_rejection() {
    local name="$1"
    local profile="$2"
    local filter="$3"
    local fixture="$test_root/$name.json"

    jq "$filter" "$model" >"$fixture"
    if vx_compose_policy_check_ports "$fixture" "$profile" 2>/dev/null; then
        fail "$name port mapping was accepted"
    fi
}

expect_rejection omitted_host standard \
    'del(.services.app.ports[0].host_ip)'
expect_rejection public_standard standard \
    '.services.app.ports[0].host_ip = "0.0.0.0"'
public_model="$test_root/public-admin.json"
jq '.services.app.ports[0].host_ip = "0.0.0.0"' "$model" >"$public_model"
vx_compose_policy_check_ports "$public_model" admin-approved \
    || fail "administrator profile rejected an approved public binding"
expect_rejection unsupported_ip standard \
    '.services.app.ports[0].host_ip = "192.0.2.10"'
expect_rejection invalid_protocol standard \
    '.services.app.ports[0].protocol = "sctp"'
expect_rejection invalid_port standard \
    '.services.app.ports[0].published = "0"'
expect_rejection duplicate standard \
    '.services.app.ports += [.services.app.ports[0]]'

cp "$model" "$VESTA/data/users/bob/docker-projects/other/runtime/canonical.json"
if vx_compose_ports_check_metadata_conflicts alice app "$model" 2>/dev/null; then
    fail "cross-project port conflict was accepted"
fi
jq '
    .services.app.ports[0].published = "19110"
    | .services.app.ports[1].published = "19111"
' "$model" >"$test_root/free.json"
vx_compose_ports_check_metadata_conflicts alice app "$test_root/free.json" \
    || fail "non-conflicting port set was rejected"

fake_ss="$test_root/fake-ss"
fake_docker="$test_root/fake-docker"
# The single-quoted lines intentionally write a separate test executable.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ " $* " == *" -lnt "* ]]; then' \
    '  printf "LISTEN 0 4096 127.0.0.1:19110 0.0.0.0:*\\n"' \
    'elif [[ " $* " == *" -lnu "* ]]; then' \
    '  printf "UNCONN 0 0 127.0.0.1:19111 0.0.0.0:*\\n"' \
    'fi' >"$fake_ss"
chmod 0755 "$fake_ss"
VX_COMPOSE_SS_BIN="$fake_ss"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then' \
    '  exit 0' \
    'fi' >"$fake_docker"
chmod 0755 "$fake_docker"
VX_COMPOSE_DOCKER_BIN="$fake_docker"
if vx_compose_ports_check_live_conflicts \
    alice app "$test_root/free.json" 2>/dev/null; then
    fail "unmanaged live-listener conflict was accepted"
fi
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then' \
    '  printf "aaaaaaaaaaaa\\n"' \
    'elif [[ "$1" == inspect ]]; then' \
    '  printf '\''[{"NetworkSettings":{"Ports":{"8010/tcp":[{"HostPort":"19110"}],"8011/udp":[{"HostPort":"19111"}]}}}]\n'\''' \
    'fi' >"$fake_docker"
chmod 0755 "$fake_docker"
vx_compose_ports_check_live_conflicts alice app "$test_root/free.json" \
    || fail "current project listener was treated as unrelated"

vx_compose_ports_lock_acquire
[[ -n "${VX_COMPOSE_PORTS_LOCK_FD:-}" ]] \
    || fail "global port allocation lock was not acquired"
vx_compose_ports_lock_release
[[ -z "${VX_COMPOSE_PORTS_LOCK_FD:-}" ]] \
    || fail "global port allocation lock was not released"

echo "Compose port policy tests passed."
