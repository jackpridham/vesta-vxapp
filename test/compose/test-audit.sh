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

vx_compose_audit_actor_push alice
vx_compose_audit "$project_root" update succeeded
vx_compose_audit_actor_pop
[[ -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]] \
    || fail "private audit actor context was not cleared"
jq -e 'select(.ACTION == "update") | .ACTOR == "alice"' \
    "$project_root/audit.log" >/dev/null \
    || fail "validated owner actor was not recorded"
export VX_COMPOSE_AUDIT_ACTOR='admin'
export _VX_COMPOSE_AUDIT_ACTOR='intruder'
vx_compose_audit "$project_root" start succeeded
unset VX_COMPOSE_AUDIT_ACTOR _VX_COMPOSE_AUDIT_ACTOR
jq -e 'select(.ACTION == "start") | .ACTOR == "root"' \
    "$project_root/audit.log" >/dev/null \
    || fail "untrusted public/private actor injection was not reduced to root"

# Invoke an ordinary public command through a minimal Vesta harness. Both
# caller-controlled actor variables must be cleared by the public helper
# loader before the real audit writer observes them.
public_vesta="$test_root/public-vesta"
public_root="$public_vesta/data/users/alice/docker-projects/app"
mkdir -p "$public_vesta/func/vx/compose" "$public_root/runtime"
printf "OWNER='alice'\nPROJECT='app'\nREVISION='1'\n" \
    >"$public_root/project.conf"
printf '%s\n' '#!/usr/bin/env bash
E_ARGS=1
E_RESTART=2
OK=0
check_args() { :; }
check_result() { return "$1"; }
is_format_valid() { :; }
is_object_valid() { :; }
is_object_unsuspended() { :; }
log_history() { :; }
log_event() { :; }' >"$public_vesta/func/main.sh"
printf '%s\n' '#!/usr/bin/env bash
unset _VX_COMPOSE_AUDIT_ACTOR
source "$PUBLIC_REPO_ROOT/func/vx/compose/storage.sh"
source "$PUBLIC_REPO_ROOT/func/vx/compose/audit.sh"
vx_compose_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
vx_compose_start() {
    vx_compose_audit \
        "$VESTA/data/users/$1/docker-projects/$2" start succeeded
}' >"$public_vesta/func/vx/compose/main.sh"
export PUBLIC_REPO_ROOT="$repo_root"
export VX_COMPOSE_AUDIT_ACTOR='admin'
export _VX_COMPOSE_AUDIT_ACTOR='admin'
VESTA="$public_vesta" HOMEDIR="$test_root/public-home" \
    bash "$repo_root/bin/v-start-docker-project" alice app
unset VX_COMPOSE_AUDIT_ACTOR _VX_COMPOSE_AUDIT_ACTOR PUBLIC_REPO_ROOT
jq -e '.ACTOR == "root" and .OWNER == "alice" and .ACTION == "start"' \
    "$public_root/audit.log" >/dev/null \
    || fail "ordinary public command accepted injected audit actor"

echo "Compose audit tests passed."
