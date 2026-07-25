#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_COMPOSE_DOCKER_BIN="$test_root/fake-docker"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/app/runtime" \
    "$VESTA/data/users/alice/docker-projects/app/secrets" \
    "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

project_root="$VESTA/data/users/alice/docker-projects/app"
printf "OWNER='alice'\nPROJECT='app'\nSTATE='running'\n" \
    >"$project_root/project.conf"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"
printf '{"services":{"web":{},"worker":{}}}\n' \
    >"$project_root/runtime/canonical.json"
printf '%s\n' 'log-secret-canary' >"$project_root/secrets/api_key"
chmod 0600 "$project_root/secrets/api_key"
printf '\n' >"$project_root/variables.env"

# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/docker.log"' \
    'if [[ " $* " == *" logs "* ]]; then' \
    '  printf "\033[2Ksafe line\nleaked=log-secret-canary\n"' \
    'fi' >"$VX_COMPOSE_DOCKER_BIN"
chmod 0755 "$VX_COMPOSE_DOCKER_BIN"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

output="$(vx_compose_logs alice app web 25)"
grep -Fq 'safe line' <<<"$output" || fail "safe log line was omitted"
grep -Fq '[REDACTED]' <<<"$output" || fail "managed secret was not redacted"
if grep -Fq 'log-secret-canary' <<<"$output"; then
    fail "managed secret leaked through logs"
fi
[[ "$output" != *$'\033'* ]] || fail "terminal control sequences were retained"
grep -Fq 'ARG=--tail' "$test_root/docker.log" \
    || fail "bounded tail option was not passed to Compose"
grep -Fq 'ARG=25' "$test_root/docker.log" \
    || fail "requested bounded log count was not passed"
grep -Fq 'ARG=web' "$test_root/docker.log" \
    || fail "service scope was not passed to Compose"

calls_before="$(wc -l <"$test_root/docker.log")"
if vx_compose_logs alice app 'web;id' 25 2>/dev/null; then
    fail "hostile service scope was accepted"
fi
calls_after="$(wc -l <"$test_root/docker.log")"
[[ "$calls_before" -eq "$calls_after" ]] \
    || fail "hostile service scope reached Docker"
if vx_compose_logs alice app web 50000 2>/dev/null; then
    fail "unbounded log request was accepted"
fi

echo "Compose log tests passed."
