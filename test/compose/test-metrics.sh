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
    "$HOMEDIR/alice/docker/app"

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
printf "DOCKER_STORAGE_MB='128'\n" >"$VESTA/data/users/alice/user.conf"

# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then' \
    '  printf "aaaaaaaaaaaa\nbbbbbbbbbbbb\n"' \
    'elif [[ "$1" == inspect ]]; then' \
    '  jq -n '\''[
      {Id:"aaaaaaaaaaaa",Config:{Labels:{"vx.managed":"yes","vx.user":"alice","vx.project":"app","com.docker.compose.project":"vx-alice-app","com.docker.compose.service":"web"}}},
      {Id:"bbbbbbbbbbbb",Config:{Labels:{"vx.managed":"yes","vx.user":"alice","vx.project":"app","com.docker.compose.project":"vx-alice-app","com.docker.compose.service":"worker"}}}
    ]'\''' \
    'elif [[ "$1" == stats ]]; then' \
    '  if [[ -f "$(dirname -- "$0")/second-sample" ]]; then' \
    '    printf "%s\n" '\''{"ID":"aaaaaaaaaaaa","CPUPerc":"12.5%","MemUsage":"64MiB / 128MiB","NetIO":"2MiB / 3MiB","PIDs":"3"}'\''' \
    '    printf "%s\n" '\''{"ID":"bbbbbbbbbbbb","CPUPerc":"7.5%","MemUsage":"32MiB / 64MiB","NetIO":"4MiB / 5MiB","PIDs":"5"}'\''' \
    '  else' \
    '    printf "%s\n" '\''{"ID":"aaaaaaaaaaaa","CPUPerc":"12.5%","MemUsage":"64MiB / 128MiB","NetIO":"1MiB / 2MiB","PIDs":"3"}'\''' \
    '    printf "%s\n" '\''{"ID":"bbbbbbbbbbbb","CPUPerc":"7.5%","MemUsage":"32MiB / 64MiB","NetIO":"3MiB / 4MiB","PIDs":"5"}'\''' \
    '  fi' \
    'fi' >"$VX_COMPOSE_DOCKER_BIN"
chmod 0755 "$VX_COMPOSE_DOCKER_BIN"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

sample="$(vx_compose_metrics_sample alice app)"
jq -e '
    .OWNER == "alice"
    and .PROJECT == "app"
    and .CPU_PCT == 20
    and .MEMORY_MB == 96
    and .PIDS == 8
    and .RX_BYTES == 4194304
    and .TX_BYTES == 6291456
    and (.STORAGE_MB | type == "number")
    and .SERVICES.web.CPU_PCT == 12.5
    and .SERVICES.worker.PIDS == 5
' <<<"$sample" >/dev/null || fail "per-service metrics were not aggregated"
[[ "$(stat -c '%a' "$project_root/runtime/metrics.jsonl")" == 640 ]] \
    || fail "metrics history mode is wrong"

touch "$test_root/second-sample"
sleep 1
second_sample="$(vx_compose_metrics_sample alice app)"
jq -e '.RX_MBPS > 0 and .TX_MBPS > 0' <<<"$second_sample" >/dev/null \
    || fail "network counter deltas were not converted to rates"

history="$(vx_compose_metrics_history alice app 5m)"
jq -e '
    .OWNER == "alice"
    and .PROJECT == "app"
    and .PERIOD == "5m"
    and (.SAMPLES | length) == 2
    and .LATEST.CPU_PCT == 20
' <<<"$history" >/dev/null || fail "metrics history shape is wrong"
grep -Fq "U_DOCKER_RUNTIME_MEMORY_MB='96'" \
    "$VESTA/data/users/alice/user.conf" \
    || fail "owner runtime memory counter was not refreshed"
grep -Fq "U_DOCKER_RUNTIME_PIDS='8'" \
    "$VESTA/data/users/alice/user.conf" \
    || fail "owner runtime PID counter was not refreshed"

echo "Compose metric tests passed."
