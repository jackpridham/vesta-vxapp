#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$test_dir/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root
install_harbor_helpers
source "$VESTA/func/vx/harbor/main.sh"
_vx_harbor_authority_uid() { printf '%s\n' "$EUID"; }
_vx_harbor_authority_gid() { id -g; }
_vx_harbor_require_root() { return 0; }
_vx_harbor_secure_file_set() { chmod "$2" "$1"; }
rm -rf -- "$VESTA/data/harbor"
before="$(find "$VESTA/data" -mindepth 1 -printf '%P\n' | sort)"
mkdir -p "$VESTA/conf"
cat >"$VESTA/func/main.sh" <<'EOF'
check_args() { (( $2 >= $1 )); }
check_result() { local result="$1"; (( result == 0 )) || exit "$result"; }
EOF
: >"$VESTA/conf/vesta.conf"
command_status="$(VESTA="$VESTA" "$HARBOR_REPO_ROOT/bin/v-list-harbor-registry" json)"
after_command="$(find "$VESTA/data" -mindepth 1 -printf '%P\n' | sort)"
[[ "$before" == "$after_command" ]] || fail 'v-list-harbor-registry mutated absent authority'
jq -e '.MODE=="disabled" and .HEALTH=="uninitialized"' <<<"$command_status" >/dev/null \
  || fail 'v-list-harbor-registry did not emit uninitialized status'
vx_harbor_origin_json() { return 1; }
uninitialized="$(vx_harbor_status_json)"
after="$(find "$VESTA/data" -mindepth 1 -printf '%P\n' | sort)"
[[ "$before" == "$after" ]] || fail 'read-only status created provider authority'
jq -e '.MODE=="disabled" and .PINNED_VERSION=="v2.15.0" and
  .RUNNING_VERSION==null and .ORIGIN==null and .HEALTH=="uninitialized" and
  .PENDING_OPERATIONS==0 and .FAILED_OPERATIONS==0 and
  .BACKUP_AGE_SECONDS==null and .CERTIFICATE_STATE=="unavailable"' \
  <<<"$uninitialized" >/dev/null || fail 'uninitialized status incorrect'
vx_harbor_provider_prepare
vx_harbor_origin_json() { printf '{"ORIGIN":"https://panel.example.com:8083"}\n'; }
status="$(vx_harbor_status_json)"
[[ "$(jq -r 'keys|join(",")' <<<"$status")" == 'BACKUP_AGE_SECONDS,CERTIFICATE_STATE,FAILED_OPERATIONS,HEALTH,MODE,ORIGIN,PENDING_OPERATIONS,PINNED_VERSION,RUNNING_VERSION,STORAGE_TOTAL_BYTES,STORAGE_USED_BYTES' ]] || fail 'status schema changed'
jq -e '.MODE=="disabled" and .PINNED_VERSION=="v2.15.0" and .RUNNING_VERSION==null and .ORIGIN=="https://panel.example.com:8083" and .HEALTH=="disabled" and .PENDING_OPERATIONS==0 and .FAILED_OPERATIONS==0 and .BACKUP_AGE_SECONDS==null and .CERTIFICATE_STATE=="valid"' <<<"$status" >/dev/null || fail 'disabled status incorrect'
if grep -Eqi 'password|secret|/run/|/usr/|api/v2|environment' <<<"$status"; then fail 'status leaked protected detail'; fi
vx_harbor_local_api_guard /run/vesta-harbor/proxy.sock GET /api/v2.0/health || fail 'fixed local API rejected'
vx_harbor_local_api_guard /run/vesta-harbor/proxy.sock GET /api/v2.0/projects || fail 'pinned project API rejected'
for value in '/tmp/proxy.sock GET /api/v2.0/health' '/run/vesta-harbor/proxy.sock POST /api/v2.0/health' '/run/vesta-harbor/proxy.sock GET /api/v2.0/configurations'; do
  read -r socket method path <<<"$value"; if vx_harbor_local_api_guard "$socket" "$method" "$path"; then fail 'unsafe local API accepted'; fi
done
vx_harbor_public_endpoint_guard GET /v2/ || fail '/v2/ rejected'
vx_harbor_public_endpoint_guard GET /service/token || fail 'token endpoint rejected'
for path in /v2 /v2/x '/service/token/' '/service/token?x=1' /api/v2.0/health; do if vx_harbor_public_endpoint_guard GET "$path"; then fail "unsafe public path accepted: $path"; fi; done
printf 'PASS: Harbor redacted status and endpoint guards\n'
