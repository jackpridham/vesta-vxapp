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
            name: "vx_alice_app_default",
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

[[ "$(vx_compose_network_runtime_name alice app default)" == vx_alice_app_default ]] \
    || fail "stable network name is wrong"

echo "Compose network policy tests passed."
