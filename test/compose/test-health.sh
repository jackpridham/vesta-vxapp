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
jq -n '{
    services: {
        web: {healthcheck: {test: ["CMD", "true"]}},
        worker: {}
    }
}' >"$project_root/runtime/canonical.json"
printf '%s\n' healthy >"$test_root/health-mode"

# The single-quoted lines intentionally write a separate test executable.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'mode="$(cat "$(dirname -- "$0")/health-mode")"' \
    'if [[ "$1" == ps ]]; then' \
    '  printf "aaaaaaaaaaaa\nbbbbbbbbbbbb\n"' \
    'elif [[ "$1" == inspect ]]; then' \
    '  if [[ "$mode" == healthy ]]; then web_health=healthy; worker_status=running; else web_health=unhealthy; worker_status=exited; fi' \
    '  jq -n --arg wh "$web_health" --arg ws "$worker_status" '\''[
        {
          Id:"aaaaaaaaaaaa",
          Config:{Labels:{
            "vx.managed":"yes","vx.user":"alice","vx.project":"app",
            "com.docker.compose.project":"vx-alice-app",
            "com.docker.compose.service":"web"
          }},
          State:{Status:"running",Health:{Status:$wh}}
        },
        {
          Id:"bbbbbbbbbbbb",
          Config:{Labels:{
            "vx.managed":"yes","vx.user":"alice","vx.project":"app",
            "com.docker.compose.project":"vx-alice-app",
            "com.docker.compose.service":"worker"
          }},
          State:{Status:$ws}
        }
      ]'\''' \
    'fi' >"$VX_COMPOSE_DOCKER_BIN"
chmod 0755 "$VX_COMPOSE_DOCKER_BIN"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

health="$(vx_compose_health_collect alice app)"
jq -e '
    .OWNER == "alice"
    and .PROJECT == "app"
    and .STATUS == "healthy"
    and .SERVICES.web.HEALTH == "healthy"
    and .SERVICES.web.HEALTHCHECK == true
    and .SERVICES.worker.HEALTH == "healthy"
    and .SERVICES.worker.HEALTHCHECK == false
' <<<"$health" >/dev/null || fail "healthy multi-service state was not normalized"
[[ "$(stat -c '%a' "$project_root/runtime/last-health.json")" == 640 ]] \
    || fail "health snapshot mode is wrong"

printf '%s\n' unhealthy >"$test_root/health-mode"
health="$(vx_compose_health_collect alice app)"
jq -e '
    .STATUS == "unhealthy"
    and .SERVICES.web.HEALTH == "unhealthy"
    and .SERVICES.worker.RUNTIME_STATE == "exited"
' <<<"$health" >/dev/null || fail "unhealthy service state was not aggregated"

echo "Compose health tests passed."
