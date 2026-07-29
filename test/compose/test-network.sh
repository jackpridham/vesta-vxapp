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

model="$test_root/network.json"
jq -n '{
    networks: {
        default: {
            name: "vx-alice-app_default",
            driver: "bridge",
            labels: {
                "vx.managed": "yes",
                "vx.user": "alice",
                "vx.project": "app",
                "vx.network": "default"
            }
        }
    },
    services: {app: {networks: {default: null}}}
}' >"$model"
vx_compose_policy_check_networks "$model" alice app standard \
    || fail "managed project bridge was rejected"

expect_rejection() {
    local name="$1"
    local filter="$2"

    jq "$filter" "$model" >"$test_root/$name.json"
    if vx_compose_policy_check_networks \
        "$test_root/$name.json" alice app standard 2>/dev/null; then
        fail "$name network was accepted"
    fi
}

expect_rejection external '.networks.default.external = true'
expect_rejection wrong_name '.networks.default.name = "shared"'
expect_rejection wrong_owner '.networks.default.labels["vx.user"] = "bob"'
expect_rejection host_driver '.networks.default.driver = "host"'
expect_rejection unmanaged_reference \
    '.services.app.networks = {"other": null}'
expect_rejection custom_ipam \
    '.networks.default.ipam = {config: [{subnet: "172.30.0.0/16"}]}'

[[ "$(vx_compose_network_runtime_name alice app default)" == vx-alice-app_default ]] \
    || fail "stable network name is wrong"
[[ "$(vx_compose_network_runtime_name vxsscp12 selfservice default)" \
    == vx-vxsscp12-selfservice_default ]] \
    || fail "self-service default network does not match Compose naming"

# Exercise the runtime inspection seam used by lifecycle/preview convergence.
runtime_root="$(vx_compose_project_root vxsscp12 selfservice)"
mkdir -p "$runtime_root/runtime/home" "$runtime_root/runtime/docker-config"
printf '{"networks":{"default":{"name":"vx-vxsscp12-selfservice_default"}},"services":{}}\n' \
    >"$runtime_root/runtime/canonical.json"
runtime_docker="$test_root/runtime-docker"
cat >"$runtime_docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == 'network rm' ]]; then
    printf 'rm:%s\n' "$3" >>"$(dirname -- "$0")/network-rm.log"
    exit 0
fi
[[ "$1 $2" == 'network inspect' ]] || exit 9
network_name="$3"
[[ "$network_name" == vx-vxsscp12-selfservice_default \
    || "$network_name" == vx_vxsscp12_selfservice_default \
    || "$network_name" == vx-vxsscp12-selfservice_aux ]] || exit 9
if [[ "$network_name" == *_aux \
    && -f "$(dirname -- "$0")/network-absent" ]]; then
    exit 1
fi
network="${network_name##*_}"
owner=vxsscp12
[[ ! -f "$(dirname -- "$0")/network-foreign" ]] || owner=mallory
printf '%s\n' '[{
  "Name":"'"$network_name"'",
  "Driver":"bridge",
  "Labels":{
    "com.docker.compose.project":"vx-vxsscp12-selfservice",
    "com.docker.compose.network":"'"$network"'",
    "vx.managed":"yes",
    "vx.user":"'"$owner"'",
    "vx.project":"selfservice",
    "vx.network":"'"$network"'"
  }
}]'
EOF
chmod 0755 "$runtime_docker"
VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime vxsscp12 selfservice \
    || fail "lifecycle convergence rejected Compose's hyphenated network"

sed -i 's/vx-vxsscp12-selfservice_default/vx_vxsscp12_selfservice_default/' \
    "$runtime_root/runtime/canonical.json"
VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime vxsscp12 selfservice \
    || fail "existing legacy stored network was rejected"
sed -i 's/vx_vxsscp12_selfservice_default/shared-host-network/' \
    "$runtime_root/runtime/canonical.json"
if VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime vxsscp12 selfservice 2>/dev/null; then
    fail "arbitrary explicit stored network name was accepted"
fi
sed -i 's/shared-host-network/vx_vxsscp12_selfservice_default/' \
    "$runtime_root/runtime/canonical.json"

# Candidate verification must use the candidate declaration, including a
# newly added deterministic network. Absence is permitted only before Compose;
# an existing foreign object is never treated as candidate-owned.
candidate_network="$test_root/candidate-network.json"
jq '.networks.aux = {
    name: "vx-vxsscp12-selfservice_aux",
    driver: "bridge",
    labels: {
        "vx.managed": "yes",
        "vx.user": "vxsscp12",
        "vx.project": "selfservice",
        "vx.network": "aux"
    }
}' "$runtime_root/runtime/canonical.json" >"$candidate_network"
: >"$test_root/network-absent"
VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime \
        vxsscp12 selfservice "$candidate_network" no \
    || fail "absent candidate-added network failed pre-mutation verification"
if VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime \
        vxsscp12 selfservice "$candidate_network" yes 2>/dev/null; then
    fail "absent candidate network passed post-convergence verification"
fi
rm -f -- "$test_root/network-absent"
: >"$test_root/network-foreign"
if VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_verify_runtime \
        vxsscp12 selfservice "$candidate_network" no 2>/dev/null; then
    fail "foreign deterministic candidate network passed preflight"
fi
rm -f -- "$test_root/network-foreign"

prior_canonical="$test_root/prior-network.json"
current_canonical="$test_root/current-network.json"
cp "$runtime_root/runtime/canonical.json" "$prior_canonical"
sed 's/vx_vxsscp12_selfservice_default/vx-vxsscp12-selfservice_default/' \
    "$prior_canonical" >"$current_canonical"
: >"$test_root/network-rm.log"
VX_COMPOSE_DOCKER_BIN="$runtime_docker" \
    vx_compose_network_cleanup_replaced \
        vxsscp12 selfservice "$prior_canonical" "$current_canonical" \
    || fail "legacy-to-new managed network cleanup failed"
[[ "$(cat "$test_root/network-rm.log")" \
    == rm:vx_vxsscp12_selfservice_default ]] \
    || fail "legacy cleanup did not remove the exact owned old network"

echo "Compose network policy tests passed."
