#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice"
printf "DOCKER_PROJECTS='4'\n" >"$VESTA/data/users/alice/user.conf"
printf 'services:\n  web:\n    image: example.test/web:v1\n' >"$test_root/source.yaml"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
vx_compose_prepare_candidate() {
    mkdir -p "$4"
    printf '{"services":{"web":{"image":"example.test/web:v1"}}}\n' \
        >"$4/canonical.json"
    printf 'services: {}\n' >"$4/compose.yaml"
    printf "POLICY_SCHEMA='1'\n" >"$4/policy.conf"
}
vx_compose_adopt_runtime_json() { printf '[]\n'; }
report="$(vx_compose_adopt alice imported "$test_root/source.yaml" dry-run standard)"
jq -e '
    .MODE == "dry-run"
    and .MUTATED == false
    and .SERVICES == ["web"]
    and .RUNTIME_CONTAINERS == 0
' \
    <<<"$report" >/dev/null
[[ ! -e "$VESTA/data/users/alice/docker-projects/imported" ]]

echo "Compose adoption tests passed."
