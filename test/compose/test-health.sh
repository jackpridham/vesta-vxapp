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
    'if [[ "$mode" == unavailable ]]; then exit 1; fi' \
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
          RestartCount:3,
          State:{
            Status:"running",
            StartedAt:"2026-01-01T00:00:00Z",
            OOMKilled:false,
            Health:{
              Status:$wh,
              FailingStreak:(if $wh == "healthy" then 0 else 4 end),
              Log:[{Output:"synthetic-health-detail-must-not-leak"}]
            }
          }
        },
        {
          Id:"bbbbbbbbbbbb",
          Config:{Labels:{
            "vx.managed":"yes","vx.user":"alice","vx.project":"app",
            "com.docker.compose.project":"vx-alice-app",
            "com.docker.compose.service":"worker"
          }},
          RestartCount:1,
          State:{
            Status:$ws,
            StartedAt:"2026-01-02T00:00:00.123456789Z",
            OOMKilled:(if $ws == "running" then false else true end)
          }
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
    and .SERVICES.web.RESTART_COUNT == 3
    and .SERVICES.web.STARTED_AT == "2026-01-01T00:00:00Z"
    and (.SERVICES.web.UPTIME_SECONDS | type == "number")
    and .SERVICES.web.OOM_KILLED == false
    and .SERVICES.web.FAILING_STREAK == 0
    and .SERVICES.web.HEALTH_OUTPUT == "[redacted health check output]"
    and .SERVICES.worker.HEALTH == "healthy"
    and .SERVICES.worker.HEALTHCHECK == false
    and .OBSERVED_AT != ""
    and .UPDATED == .OBSERVED_AT
    and .SOURCE == "docker"
    and .AGE_SECONDS == 0
    and .FRESHNESS == "fresh"
' <<<"$health" >/dev/null || fail "healthy multi-service state was not normalized"
grep -Fq synthetic-health-detail-must-not-leak <<<"$health" \
    && fail "health output was not redacted"
[[ "$(stat -c '%a' "$project_root/runtime/last-health.json")" == 640 ]] \
    || fail "health snapshot mode is wrong"

printf '%s\n' unhealthy >"$test_root/health-mode"
health="$(vx_compose_health_collect alice app)"
jq -e '
    .STATUS == "unhealthy"
    and .SERVICES.web.HEALTH == "unhealthy"
    and .SERVICES.web.FAILING_STREAK == 4
    and .SERVICES.worker.RUNTIME_STATE == "exited"
    and .SERVICES.worker.OOM_KILLED == true
' <<<"$health" >/dev/null || fail "unhealthy service state was not aggregated"

printf '%s\n' unavailable >"$test_root/health-mode"
health="$(vx_compose_health_collect alice app)"
jq -e '
    .STATUS == "unknown"
    and .SOURCE == "docker-unavailable"
    and .FRESHNESS == "unavailable"
    and .OBSERVED_AT != ""
    and all(.SERVICES[];
        .RUNTIME_STATE == "missing"
        and .RESTART_COUNT == 0
        and .UPTIME_SECONDS == 0
        and .OOM_KILLED == false
    )
' <<<"$health" >/dev/null \
    || fail "unavailable Docker observation was not freshly persisted"

jq '.OBSERVED_AT = "2026-01-01T00:00:00Z"
    | .UPDATED = "1999-01-01T00:00:00Z"
    | .FRESHNESS = "fresh"' \
    "$project_root/runtime/last-health.json" \
    >"$project_root/runtime/last-health.json.tmp"
mv "$project_root/runtime/last-health.json.tmp" \
    "$project_root/runtime/last-health.json"
health="$(vx_compose_health_observation_json alice app 1)"
jq -e '
    .AGE_SECONDS > 1
    and .FRESHNESS == "unavailable"
    and .OBSERVED_AT == "2026-01-01T00:00:00Z"
' <<<"$health" >/dev/null \
    || fail "health freshness used project UPDATED instead of observation time"

echo "Compose health tests passed."
