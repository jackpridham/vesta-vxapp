#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

if vx_compose_profile_require_authorized \
    alice invalid-app invalid-profile 2>/dev/null; then
    fail "unknown profile passed authorization"
fi
if vx_compose_profile_require_authorized \
    alice public-app admin-approved 2>/dev/null; then
    fail "unassigned administrator profile was authorized"
fi
expires="$(date -u -d '+1 hour' +'%Y-%m-%dT%H:%M:%SZ')"
vx_compose_profile_assignment_add alice public-app admin-approved "$expires"

if vx_compose_profile_require_authorized \
    alice compatibility-app restricted-compatibility 2>/dev/null; then
    fail "unassigned restricted-compatibility profile was authorized"
fi
vx_compose_profile_assignment_add alice compatibility-app restricted-compatibility "$expires"
vx_compose_profile_require_authorized alice compatibility-app restricted-compatibility \
    || fail "valid restricted-compatibility profile assignment was rejected"
compatibility_assignment="$(vx_compose_profile_assignment_path alice compatibility-app)"
jq -e '
    .PROFILE == "restricted-compatibility"
    and .PROFILE_VERSION == 2
    and .ACTOR == "root"
' "$compatibility_assignment" >/dev/null \
    || fail "restricted-compatibility assignment omitted authority metadata"

cat >"$test_root/restricted-compatibility.compose.yaml" <<'EOF'
services:
  app:
    image: alpine:3.20
    init: true
    cap_drop: [ALL]
    cap_add: [CHOWN, DAC_OVERRIDE, KILL, SETGID, SETUID]
    security_opt:
      - no-new-privileges:true
    cpus: 0.25
    mem_limit: 64m
    pids_limit: 32
    ports:
      - target: 8080
        published: "19001"
        host_ip: 127.0.0.1
        protocol: tcp
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
EOF
vx_compose_prepare_candidate \
    alice compatibility-app "$test_root/restricted-compatibility.compose.yaml" \
    "$test_root/compatibility-candidate" restricted-compatibility \
    || fail "assigned restricted-compatibility candidate was rejected"
if vx_compose_prepare_candidate \
    alice compatibility-unassigned "$test_root/restricted-compatibility.compose.yaml" \
    "$test_root/compatibility-unassigned" restricted-compatibility 2>/dev/null; then
    fail "restricted-compatibility candidate was accepted without assignment"
fi
vx_compose_profile_require_authorized alice public-app admin-approved \
    || fail "valid administrator profile assignment was rejected"
assignment="$(vx_compose_profile_assignment_path alice public-app)"
[[ "$(stat -c '%a' "$assignment")" == 600 ]] \
    || fail "profile assignment mode is wrong"
jq -e '
    .PROFILE == "admin-approved"
    and .PROFILE_VERSION == 3
    and .ACTOR == "root"
' "$assignment" >/dev/null \
    || fail "profile assignment omitted actor or profile version"
vx_compose_profile_assignment_delete alice public-app
[[ ! -e "$assignment" ]] \
    || fail "profile assignment deletion left stale authority"
if vx_compose_profile_require_authorized \
    alice public-app admin-approved 2>/dev/null; then
    fail "deleted profile assignment still authorized the project"
fi
vx_compose_profile_assignment_add alice public-app admin-approved "$expires"

jq '.EXPIRES = "2000-01-01T00:00:00Z"' "$assignment" >"$test_root/expired"
mv "$test_root/expired" "$assignment"
chmod 0600 "$assignment"
if vx_compose_profile_require_authorized \
    alice public-app admin-approved 2>/dev/null; then
    fail "expired administrator profile assignment was authorized"
fi

if vx_compose_prepare_candidate \
    alice public-candidate \
    "$repo_root/test/compose/fixtures/public-http.compose.yaml" \
    "$test_root/public-unassigned" admin-approved 2>/dev/null; then
    fail "public candidate was accepted without administrator assignment"
fi
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$test_root/fake-ss"
chmod 0755 "$test_root/fake-ss"
export VX_COMPOSE_SS_BIN="$test_root/fake-ss"
vx_compose_prepare_candidate \
    alice public-preview \
    "$repo_root/test/compose/fixtures/public-http.compose.yaml" \
    "$test_root/public-preview" admin-approved no '' '' preview \
    || fail "administrator validation preview required durable authority"
public_expires="$(date -u -d '+1 hour' +'%Y-%m-%dT%H:%M:%SZ')"
vx_compose_profile_assignment_add \
    alice public-candidate admin-approved "$public_expires"
vx_compose_prepare_candidate \
    alice public-candidate \
    "$repo_root/test/compose/fixtures/public-http.compose.yaml" \
    "$test_root/public-candidate" admin-approved \
    || fail "assigned administrator public candidate was rejected"
jq -e '.services.web.ports[0].host_ip == "0.0.0.0"' \
    "$test_root/public-candidate/canonical.json" >/dev/null \
    || fail "approved public binding was not canonicalized"
if vx_compose_prepare_candidate \
    alice public-standard \
    "$repo_root/test/compose/fixtures/public-http.compose.yaml" \
    "$test_root/public-standard" standard 2>/dev/null; then
    fail "standard profile accepted a public binding"
fi

vx_compose_profile_assignment_add \
    alice host-candidate admin-approved "$public_expires"
if vx_compose_prepare_candidate \
    alice host-candidate \
    "$repo_root/test/compose/fixtures/host-network.compose.yaml" \
    "$test_root/host-candidate" admin-approved 2>/dev/null; then
    fail "general administrator profile accepted host networking"
fi

host_model="$test_root/host.json"
printf '{"services":{"app":{"network_mode":"host"}}}\n' >"$host_model"
if vx_compose_policy_check_host_network \
    "$host_model" standard 2>/dev/null; then
    fail "standard profile accepted host networking"
fi

echo "Compose profile assignment tests passed."
