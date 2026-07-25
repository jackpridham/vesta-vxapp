#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_COMPOSE_NOTIFICATION_COMMAND="$test_root/fake-notification"
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
printf "POLICY_SCHEMA='1'\nMEMORY_MB='100'\n" >"$project_root/policy.conf"
printf '{"services":{"web":{}}}\n' >"$project_root/runtime/canonical.json"
printf '%s\n' 'alert-secret-canary' >"$project_root/secrets/api_key"
chmod 0600 "$project_root/secrets/api_key"
printf '%s\n' '{
  "CPU_PCT": 10,
  "MEMORY_PCT": 50,
  "NETWORK_MBPS": 1,
  "NOTIFY": true
}' >"$project_root/alerts.conf"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$(dirname -- "$0")/notifications.log"' \
    >"$VX_COMPOSE_NOTIFICATION_COMMAND"
chmod 0755 "$VX_COMPOSE_NOTIFICATION_COMMAND"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

health="$test_root/health.json"
metrics="$test_root/metrics.json"
printf '{"STATUS":"unhealthy"}\n' >"$health"
printf '{"CPU_PCT":20,"MEMORY_MB":75,"RX_MBPS":2,"TX_MBPS":0}\n' >"$metrics"
vx_compose_alerts_evaluate alice app "$health" "$metrics"
alerts="$(vx_compose_alerts_list_json alice app)"
jq -e '
    [.ALERTS[] | select(.STATUS == "open") | .TYPE] | sort
    == ["cpu", "health", "memory", "network"]
' <<<"$alerts" >/dev/null || fail "threshold and health alerts did not open"
[[ "$(wc -l <"$test_root/notifications.log")" -eq 4 ]] \
    || fail "new alerts did not fan out exactly once"

aid="$(jq -r '.ALERTS[] | select(.TYPE == "health") | .AID' <<<"$alerts")"
vx_compose_alert_acknowledge alice app "$aid"
jq -e --argjson aid "$aid" \
    '.ALERTS[] | select(.AID == $aid) | .ACK == true' \
    <<<"$(vx_compose_alerts_list_json alice app)" >/dev/null \
    || fail "alert acknowledgement was not persisted"

printf '{"STATUS":"healthy"}\n' >"$health"
printf '{"CPU_PCT":1,"MEMORY_MB":1,"RX_MBPS":0,"TX_MBPS":0}\n' >"$metrics"
vx_compose_alerts_evaluate alice app "$health" "$metrics"
jq -e 'all(.ALERTS[]; .STATUS == "closed")' \
    <<<"$(vx_compose_alerts_list_json alice app)" >/dev/null \
    || fail "alert recovery did not close open alerts"
[[ "$(wc -l <"$test_root/notifications.log")" -eq 4 ]] \
    || fail "recovery generated duplicate opening notifications"
if rg -F 'alert-secret-canary' "$project_root/alerts.json" \
    "$test_root/notifications.log"; then
    fail "alert surface leaked a managed secret"
fi

echo "Compose alert tests passed."
