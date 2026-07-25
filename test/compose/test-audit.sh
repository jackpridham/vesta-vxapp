#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/app/runtime" \
    "$VESTA/data/users/alice/docker-projects/app/secrets" \
    "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

project_root="$VESTA/data/users/alice/docker-projects/app"
printf "OWNER='alice'\nPROJECT='app'\nSTATE='running'\nREVISION='1'\n" \
    >"$project_root/project.conf"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"
printf '{"services":{"web":{}}}\n' >"$project_root/runtime/canonical.json"
printf '%s\n' 'audit-secret-canary' >"$project_root/secrets/api_key"
chmod 0600 "$project_root/secrets/api_key"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

vx_compose_audit \
    "$project_root" deploy failed \
    'failure included audit-secret-canary' 125 '["web"]'
audit="$(vx_compose_audit_list_json alice app)"
jq -e '
    length == 1
    and .[0].OWNER == "alice"
    and .[0].PROJECT == "app"
    and .[0].ACTION == "deploy"
    and .[0].RESULT == "failed"
    and .[0].DURATION_MS == 125
    and .[0].SERVICES == ["web"]
    and (. [0].DETAILS | contains("[REDACTED]"))
' <<<"$audit" >/dev/null || fail "structured audit event is incomplete"
if grep -Fq 'audit-secret-canary' "$project_root/audit.log"; then
    fail "audit event leaked a managed secret"
fi
[[ "$(stat -c '%a' "$project_root/audit.log")" == 640 ]] \
    || fail "audit log mode is wrong"

echo "Compose audit tests passed."
