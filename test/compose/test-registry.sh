#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" "$HOMEDIR/alice" "$HOMEDIR/bob"
printf "DOCKER_PROJECTS='0'\n" >"$VESTA/data/users/alice/user.conf"
printf "DOCKER_PROJECTS='0'\n" >"$VESTA/data/users/bob/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_docker="$test_root/fake-docker"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/docker.log"'
    printf '%s\n' 'if [[ " $* " == *" login "* ]]; then'
    printf '%s\n' '  IFS= read -r password'
    # The generated fake expands Docker's controlled environment when it runs.
    # shellcheck disable=SC2016
    printf '%s\n' '  mkdir -p "$DOCKER_CONFIG"'
    # shellcheck disable=SC2016
    printf '%s\n' '  printf '"'"'{"auths":{"registry.example.test":{"auth":"encoded"}}}\n'"'"' >"$DOCKER_CONFIG/config.json"'
    printf '%s\n' 'fi'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

password_file="$test_root/password"
printf 'registry-canary-must-not-leak\n' >"$password_file"
chmod 0600 "$password_file"
vx_compose_registry_add alice registry.example.test deploy "$password_file" \
    >"$test_root/add.stdout" 2>"$test_root/add.stderr"

registry_root="$(vx_compose_registry_root alice)"
[[ "$(stat -c '%a' "$registry_root")" == 700 ]] || fail "registry directory mode is wrong"
[[ "$(stat -c '%a' "$registry_root/config.json")" == 600 ]] || fail "Docker config mode is wrong"
vx_compose_registry_list_json alice >"$test_root/list.json"
jq -e '
    ."registry.example.test".USERNAME == "deploy"
    and ."registry.example.test".LAST_VALIDATION == "succeeded"
' "$test_root/list.json" >/dev/null || fail "redacted registry metadata is wrong"

if grep -F 'registry-canary-must-not-leak' \
    "$test_root/docker.log" \
    "$test_root/list.json" \
    "$test_root/add.stdout" \
    "$test_root/add.stderr" \
    "$registry_root/registries.json"; then
    fail "registry credential leaked into args or metadata"
fi
if vx_compose_registry_list_json bob | jq -e 'length != 0' >/dev/null; then
    fail "registry metadata crossed owners"
fi
vx_compose_registry_delete bob registry.example.test
jq -e '."registry.example.test" != null' \
    < <(vx_compose_registry_list_json alice) >/dev/null \
    || fail "cross-owner registry deletion changed Alice metadata"

vx_compose_registry_delete alice registry.example.test
jq -e 'length == 0' < <(vx_compose_registry_list_json alice) >/dev/null \
    || fail "registry deletion retained metadata"

echo "Compose registry tests passed."
