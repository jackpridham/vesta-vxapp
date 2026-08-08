#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap '[[ -z "${api_pid:-}" ]] || kill "$api_pid" 2>/dev/null || :; cleanup_vesta_root' EXIT
new_vesta_root; install_harbor_helpers; source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_require_root(){ return 0; }; _vx_harbor_authority_uid(){ printf '%s\n' "$EUID"; }; _vx_harbor_authority_gid(){ /usr/bin/id -g; }; _vx_harbor_secure_file_set(){ /usr/bin/chmod "$2" "$1"; }
vx_harbor_provider_prepare
api_socket="$HARBOR_TEST_ROOT/harbor.sock"; state="$HARBOR_TEST_ROOT/state.json"; log="$HARBOR_TEST_ROOT/api.log"; ready="$HARBOR_TEST_ROOT/ready"; credential="$HARBOR_TEST_ROOT/credential.json"
printf '%s\n' '{"username":"admin","password":"fixture-password"}' >"$credential"; chmod 0600 "$credential"
printf '%s\n' silent show-error 'user = "admin:fixture-password"' >"$(vx_harbor_root)/secrets/integration.curl"; chmod 0600 "$(vx_harbor_root)/secrets/integration.curl"
python3 "$HARBOR_REPO_ROOT/test/harbor/fixtures/fake-harbor-api.py" --unix-socket "$api_socket" --state "$state" --log "$log" --credential-file "$credential" --ready-file "$ready" & api_pid=$!
for _ in {1..50}; do [[ -S "$api_socket" ]] && break; sleep .02; done; chmod 0600 "$api_socket"
_vx_harbor_api_socket(){ printf '%s\n' "$api_socket"; }; vx_harbor_local_socket_path(){ printf '%s\n' "$api_socket"; }; vx_harbor_socket_path(){ printf '%s\n' "$api_socket"; }
vx_harbor_socket_validate(){ [[ -S "$api_socket" && ! -L "$api_socket" ]]; }
vx_harbor_api_health | jq -e '.status=="healthy"' >/dev/null
vx_harbor_api_project_create vx-alice; project="$(vx_harbor_api_project_get vx-alice)"; [[ "$(jq -r .name <<<"$project")" == vx-alice ]]
quota="$(jq -r .quota_id <<<"$project")"; vx_harbor_api_quota_set_bytes "$quota" 1048576; [[ "$(vx_harbor_api_quota_get "$quota"|jq -r .hard.storage)" == 1048576 ]]
secret=0123456789abcdef0123456789abcdef; robot="$(printf %s "$secret" | vx_harbor_api_robot_create vx-alice vx-alice-runtime pull)"; robot_id="$(jq -r .id <<<"$robot")"
printf %s "$secret" | vx_harbor_api_credential_probe vx-alice-runtime
! printf %s wrong-wrong-wrong-wrong | vx_harbor_api_credential_probe vx-alice-runtime
vx_harbor_api_robot_disable "$robot_id"
! vx_harbor_local_api_guard "$api_socket" GET /api/v2.0/configurations
! vx_harbor_api_project_get '../admin'
printf '{}\n' >"$HARBOR_TEST_ROOT/caller-body.json"; chmod 0600 "$HARBOR_TEST_ROOT/caller-body.json"; ! _vx_harbor_api_call POST /api/v2.0/projects 201 empty "$HARBOR_TEST_ROOT/caller-body.json"
printf '{}\n' >"$(vx_harbor_root)/secrets/body.json"; chmod 0600 "$(vx_harbor_root)/secrets/body.json"; ln "$(vx_harbor_root)/secrets/body.json" "$(vx_harbor_root)/secrets/body-hardlink.json"; ! _vx_harbor_api_call POST /api/v2.0/projects 201 empty "$(vx_harbor_root)/secrets/body.json"; unlink "$(vx_harbor_root)/secrets/body-hardlink.json"; unlink "$(vx_harbor_root)/secrets/body.json"
jq '.fault={path:"/api/v2.0/health",mode:"malformed"}' "$state" >"$state.tmp"; mv "$state.tmp" "$state"; ! vx_harbor_api_health >/dev/null
jq '.fault={path:"/api/v2.0/health",status:503}' "$state" >"$state.tmp"; mv "$state.tmp" "$state"; ! vx_harbor_api_health >/dev/null
jq '.fault={path:"/api/v2.0/health",mode:"oversize"}' "$state" >"$state.tmp"; mv "$state.tmp" "$state"; ! vx_harbor_api_health >/dev/null
jq '.fault={path:"/api/v2.0/robots",mode:"delay",seconds:1}' "$state" >"$state.tmp"; mv "$state.tmp" "$state"
process_secret=process-secret-0123456789abcdef
(printf %s "$process_secret" | vx_harbor_api_robot_create vx-alice vx-alice-process pull >/dev/null) & create_pid=$!
sleep .1
! tr '\0' '\n' </proc/$create_pid/environ 2>/dev/null | grep -F "$process_secret"
! ps -eo args | grep -F "$process_secret" | grep -v grep
wait "$create_pid"
kill "$api_pid"; wait "$api_pid" || :; api_pid=
! vx_harbor_api_health >/dev/null 2>&1
! grep -q 'fixture-password\|0123456789abcdef' "$log"
printf 'PASS: protected Harbor API adapter\n'
