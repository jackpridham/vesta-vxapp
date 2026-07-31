#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users"/{alice,bob,carol,dave} "$HOMEDIR"/{alice,bob,carol,dave}
for actor in alice bob carol dave; do
    printf "SUSPENDED='no'\n" >"$VESTA/data/users/$actor/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

root="$VESTA/data/users/alice/docker-projects/app"
mkdir -p "$root/runtime" "$root/revisions/000001" "$root/revisions/000002" \
    "$root/secrets"
printf '%s\n' 'operator-secret-canary' >"$root/secrets/api"
chmod 0600 "$root/secrets/api"
printf '%s\n' \
    "OWNER='alice'" "PROJECT='app'" "COMPOSE_PROJECT='vx-alice-app'" \
    "PROFILE='standard'" "STATE='running'" "REVISION='2'" \
    "CANONICAL_SHA256='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'" \
    "CREATED='2026-07-31T00:00:00Z'" "UPDATED='2026-07-31T00:00:00Z'" \
    >"$root/project.conf"
printf '%s\n' \
    "POLICY_SCHEMA='1'" "PROFILE_VERSION='2'" "VALIDATOR_VERSION='2'" \
    "SERVICES='1'" "CPUS_MILLI='250'" "MEMORY_MB='64'" "PIDS='32'" \
    "STORAGE_MB='0'" >"$root/policy.conf"
printf '%s\n' 'services:' '  web:' '    image: example.test/web:v2' \
    >"$root/compose.yaml"
printf '%s\n' '{
  "services": {
    "web": {
      "image": "example.test/web:v2",
      "ports": [{"host_ip":"127.0.0.1","published":8080,"target":80,"protocol":"tcp"}],
      "networks": ["default"],
      "volumes": [{"source":"data","target":"/data","read_only":false}],
      "cpus": 0.25,
      "mem_limit": "64m",
      "pids_limit": 32,
      "logging": {"driver":"json-file","options":{"max-size":"10m"}}
    }
  },
  "networks": {"default": {}},
  "volumes": {"data": {}},
  "secrets": {"api": {"external": true}}
}' >"$root/runtime/canonical.json"
printf '%s\n' '{
  "web": {
    "REFERENCE":"example.test/web:v2",
    "IMAGE_ID":"sha256:2222",
    "REPO_DIGESTS":[],
    "OS":"linux",
    "ARCHITECTURE":"amd64"
  }
}' >"$root/images.json"
for revision in 1 2; do
    revision_root="$root/revisions/$(printf '%06d' "$revision")"
    if [[ "$revision" -eq 1 ]]; then
        printf '%s\n' '{"services":{"api":{"image":"example.test/api:v1"}},"networks":{},"volumes":{},"secrets":{}}' \
            >"$revision_root/canonical.json"
    else
        cp "$root/runtime/canonical.json" "$revision_root/canonical.json"
    fi
    printf 'services: {}\n' >"$revision_root/compose.yaml"
    cp "$root/policy.conf" "$revision_root/policy.conf"
    (
        cd "$revision_root"
        sha256sum canonical.json compose.yaml policy.conf >manifest.sha256
    )
done

fake_docker="$test_root/fake-docker"
printf exact >"$test_root/docker-mode"
cat >"$fake_docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
base="$(dirname -- "$0")"
mode="$(cat "$base/docker-mode")"
if [[ " $* " == *" ps -aq "* ]]; then
    case "$mode" in
        missing) ;;
        extra) printf '%s\n' aaaaaaaaaaaa bbbbbbbbbbbb ;;
        *) printf '%s\n' aaaaaaaaaaaa ;;
    esac
    exit
fi
if [[ " $* " == *" inspect "* ]]; then
    [[ "$mode" != race ]] || exit 44
    owner=alice revision=2 image=sha256:2222 state=running network=vx-alice-app_default
    network_mode=vx-alice-app_default
    mount=vx-alice-app_data published=8080 privileged=false service=web
    case "$mode" in
        owner) owner=bob ;;
        revision) revision=1 ;;
        image) image=sha256:bad ;;
        stopped) state=exited ;;
        network) network=foreign ;;
        mount) mount=foreign ;;
        port) published=9999 ;;
        security) privileged=true ;;
    esac
    item() {
        local id="$1" name="$2"
        printf '{"Id":"%s","Image":"%s","Config":{"Labels":{' "$id" "$image"
        printf '"com.docker.compose.project":"vx-alice-app",'
        printf '"com.docker.compose.service":"%s",' "$name"
        printf '"vx.managed":"yes","vx.user":"%s","vx.project":"app",' "$owner"
        printf '"vx.revision":"%s","vx.image-id":"%s"' "$revision" "$image"
        printf '}},"State":{"Status":"%s"},' "$state"
        printf '"NetworkSettings":{"Networks":{"%s":{}},"Ports":{"80/tcp":[{"HostIp":"127.0.0.1","HostPort":"%s"}]}},' "$network" "$published"
        printf '"Mounts":[{"Name":"%s","Destination":"/data","RW":true}],' "$mount"
        printf '"HostConfig":{"Privileged":%s,"CapAdd":[],"NetworkMode":"%s","PidMode":"","IpcMode":"","Devices":[]}}' "$privileged" "$network_mode"
    }
    printf '['
    item aaaaaaaaaaaa "$service"
    if [[ "$mode" == extra ]]; then
        printf ','
        item bbbbbbbbbbbb orphan
    fi
    printf ']\n'
    exit
fi
exit 1
EOF
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

# Fine-grained roles, owner/admin override, immediate revocation and actor state.
vx_compose_role_set alice alice app bob viewer
[[ "$(stat -c '%a' "$root/roles.json")" == 600 ]] \
    || fail 'role metadata mode is not 0600'
vx_compose_authorize bob alice app view \
    || fail 'viewer lacks view'
if vx_compose_authorize bob alice app lifecycle 2>/dev/null; then
    fail 'viewer gained lifecycle'
fi
vx_compose_role_set alice alice app bob operator
for capability in view lifecycle reconcile; do
    vx_compose_authorize bob alice app "$capability" \
        || fail "operator lacks $capability"
done
if vx_compose_authorize bob alice app deploy 2>/dev/null; then
    fail 'operator gained deploy'
fi
vx_compose_role_set admin alice app carol deployer
for capability in preview deploy rollback; do
    vx_compose_authorize carol alice app "$capability" \
        || fail "deployer lacks $capability"
done
vx_compose_role_set alice alice app dave backup-operator
if ! vx_compose_authorize dave alice app backup \
    || ! vx_compose_authorize dave alice app restore; then
    fail 'backup operator matrix is incomplete'
fi
vx_compose_role_set alice alice app dave secret-manager
vx_compose_authorize dave alice app secret \
    || fail 'secret manager lacks secret capability'
vx_compose_role_delete alice alice app bob
if vx_compose_authorize bob alice app view 2>/dev/null; then
    fail 'revoked actor retained access'
fi
vx_compose_role_set alice alice app bob viewer
printf "SUSPENDED='yes'\n" >"$VESTA/data/users/bob/user.conf"
if vx_compose_authorize bob alice app view 2>/dev/null; then
    fail 'suspended actor retained access'
fi
printf "SUSPENDED='no'\n" >"$VESTA/data/users/bob/user.conf"
jq '.ASSIGNMENTS.bob.ROLE="legacy-root"' "$root/roles.json" \
    >"$root/.roles.tmp" && mv "$root/.roles.tmp" "$root/roles.json"
chmod 0600 "$root/roles.json"
if vx_compose_authorize bob alice app view 2>/dev/null; then
    fail 'unknown legacy role failed open'
fi
if ! vx_compose_authorize alice alice app secret \
    || ! vx_compose_authorize admin alice app deploy; then
    fail 'owner/admin compatibility regressed'
fi

# Revision comparison and rollback preview are manifest- and revision-bound.
compare="$(vx_compose_revision_compare_json admin alice app 1 2)"
jq -e '
    .SERVICES.ADDED==["web"] and .SERVICES.REMOVED==["api"]
    and (.FROM_MANIFEST_SHA256|test("^[a-f0-9]{64}$"))
    and (.TO_MANIFEST_SHA256|test("^[a-f0-9]{64}$"))
    and .DEFINITION_FACTS.SECRET_NAMES_AFTER==["api"]
    and (.SERVICE_CHANGES[]|select(.SERVICE=="web")
        | .AFTER.RESOURCES.CPUS==0.25
        and .AFTER.RESOURCES.MEMORY=="64m"
        and .AFTER.RESOURCES.PIDS==32
        and .AFTER.RESOURCES.LOGGING.driver=="json-file")
' <<<"$compare" >/dev/null || fail 'revision comparison is incomplete'
preview="$(vx_compose_rollback_preview_json admin alice app 1)"
jq -e '
    .ACTION=="rollback" and .BOUND_CURRENT_REVISION==2
    and .BOUND_TARGET_REVISION==1 and .DATA_IMPACT=="retained"
' <<<"$preview" >/dev/null || fail 'rollback preview is not bound'
cp "$root/revisions/000001/manifest.sha256" "$test_root/manifest"
printf '#tamper\n' >>"$root/revisions/000001/canonical.json"
if vx_compose_rollback_preview_json admin alice app 1 >/dev/null 2>&1; then
    fail 'tampered rollback manifest was accepted'
fi
sed -i '$d' "$root/revisions/000001/canonical.json"
if vx_compose_rollback_bound admin alice app 1 1 \
    "$(jq -r .FROM_MANIFEST_SHA256 <<<"$preview")" \
    "$(jq -r .TO_MANIFEST_SHA256 <<<"$preview")" >/dev/null 2>&1; then
    fail 'stale rollback current revision was accepted'
fi
if vx_compose_rollback_bound admin alice app 1 2 \
    "$(printf '0%.0s' {1..64})" \
    "$(jq -r .TO_MANIFEST_SHA256 <<<"$preview")" >/dev/null 2>&1; then
    fail 'stale rollback manifest was accepted'
fi
vx_compose_rollback() {
    local mocked_root
    mocked_root="$(vx_compose_project_root "$1" "$2")"
    : >"$test_root/rollback-called"
    vx_compose_audit "$mocked_root" rollback started \
        'nested rollback audit'
}
rollback_output="$(vx_compose_rollback_bound admin alice app 1 2 \
    "$(jq -r .FROM_MANIFEST_SHA256 <<<"$preview")" \
    "$(jq -r .TO_MANIFEST_SHA256 <<<"$preview")")" \
    || fail 'valid bound rollback did not reach mutation'
if ! grep -Eq '^OPERATION_ID=[a-f0-9]{32}$' <<<"$rollback_output" \
    || ! grep -Fq 'PHASE=converging PERCENT=50 RESULT=running' \
        <<<"$rollback_output" \
    || ! grep -Fq 'PHASE=complete PERCENT=100 RESULT=succeeded' \
        <<<"$rollback_output"; then
    fail 'rollback watcher output omitted typed progress'
fi
[[ -f "$test_root/rollback-called" ]] \
    || fail 'bound rollback did not call the mutation'
jq -e '.ACTION=="rollback" and .RESULT=="succeeded"
    and .TARGET_REVISION==1' "$root/runtime/last-operation.json" >/dev/null \
    || fail 'rollback operation did not survive nested audit'

# Typed operation records redact messages and retain an opaque identifier.
operation_id="$(vx_compose_operation_begin "$root" alice deploy 2)"
vx_compose_operation_update "$root" "$operation_id" converging 50 \
    'operator-secret-canary is hidden'
vx_compose_audit "$root" deploy started 'nested lifecycle audit'
jq -e --arg id "$operation_id" \
    '.OPERATION_ID==$id and .RESULT=="running"' \
    "$root/runtime/last-operation.json" >/dev/null \
    || fail 'nested deploy audit destroyed the running operation record'
vx_compose_operation_finish "$root" "$operation_id" succeeded complete
operation="$(vx_compose_operation_list_json alice alice app)"
jq -e --arg id "$operation_id" '
    .OPERATION_ID==$id and .PHASE=="complete" and .PERCENT==100
    and .RESULT=="succeeded" and .CURRENT_REVISION==2
' <<<"$operation" >/dev/null || fail 'typed operation record is incomplete'
if rg -F 'operator-secret-canary' "$root/runtime/last-operation.json"; then
    fail 'typed operation leaked a managed secret'
fi

# Exact drift and every canonical drift class.
exact="$(vx_compose_drift_observe_json alice app)"
jq -e '.MATCH==true and (.DRIFT_DIGEST|test("^[a-f0-9]{64}$"))
    and (.EXCLUDED_VOLATILE_FIELDS|length)>=8' <<<"$exact" >/dev/null \
    || fail 'exact runtime did not match'
[[ "$(vx_compose_drift_observe_json alice app | jq -r .DRIFT_DIGEST)" \
    == "$(jq -r .DRIFT_DIGEST <<<"$exact")" ]] \
    || fail 'drift digest is not deterministic'
for expectation in \
    'missing:.MISSING_SERVICES==["web"]' \
    'extra:.EXTRA_SERVICES==["orphan"]' \
    'owner:any(.CHANGED_SERVICES[];.CHANGES|index("ownership"))' \
    'revision:any(.CHANGED_SERVICES[];.CHANGES|index("revision"))' \
    'image:any(.CHANGED_SERVICES[];.CHANGES|index("image"))' \
    'network:any(.CHANGED_SERVICES[];.CHANGES|index("network"))' \
    'mount:any(.CHANGED_SERVICES[];.CHANGES|index("mount"))' \
    'port:any(.CHANGED_SERVICES[];.CHANGES|index("port"))' \
    'security:any(.CHANGED_SERVICES[];.CHANGES|index("security"))' \
    'stopped:any(.CHANGED_SERVICES[];.CHANGES|index("state"))'; do
    mode="${expectation%%:*}"
    expression="${expectation#*:}"
    printf '%s' "$mode" >"$test_root/docker-mode"
    vx_compose_drift_observe_json alice app | jq -e "$expression" >/dev/null \
        || fail "$mode drift was not classified"
done
printf race >"$test_root/docker-mode"
if vx_compose_drift_observe_json alice app >/dev/null 2>&1; then
    fail 'inspect race produced accepted evidence'
fi

# Reconcile denies stale evidence after re-observation under the project lock.
printf missing >"$test_root/docker-mode"
stale="$(vx_compose_reconcile_preview_json dave alice app 2>/dev/null || :)"
[[ -z "$stale" ]] || fail 'secret-manager gained reconcile capability'
vx_compose_role_set alice alice app bob operator
drift_preview="$(vx_compose_reconcile_preview_json bob alice app)"
printf exact >"$test_root/docker-mode"
if vx_compose_reconcile bob alice app \
    "$(jq -r .DRIFT_DIGEST <<<"$drift_preview")" 2 2>"$test_root/stale.err"; then
    fail 'stale drift digest was accepted'
fi
grep -Fq 'stale' "$test_root/stale.err" \
    || fail 'stale digest returned the wrong diagnostic'
exact="$(vx_compose_reconcile_preview_json bob alice app)"
reconcile_output="$(vx_compose_reconcile \
    bob alice app "$(jq -r .DRIFT_DIGEST <<<"$exact")" 2)" \
    || fail 'exact reconcile did not complete safely'
if ! grep -Eq '^OPERATION_ID=[a-f0-9]{32}$' <<<"$reconcile_output" \
    || ! grep -Fq 'PHASE=complete PERCENT=100 RESULT=succeeded' \
        <<<"$reconcile_output"; then
    fail 'reconcile watcher output omitted typed progress'
fi

# Typed notification routes fan out only through approved destinations.
export VX_COMPOSE_NOTIFICATION_COMMAND="$test_root/notify"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$(dirname -- "$0")/notify.log"' \
    >"$VX_COMPOSE_NOTIFICATION_COMMAND"
chmod 0755 "$VX_COMPOSE_NOTIFICATION_COMMAND"
vx_compose_notification_route_set alice alice app health panel
vx_compose_notification_route_set alice alice app health account-email
routes="$(vx_compose_notification_routes_list_json alice alice app)"
jq -e '.ROUTES==[
    {"DESTINATION":"account-email","TYPE":"health"},
    {"DESTINATION":"panel","TYPE":"health"}
]' <<<"$routes" >/dev/null || fail 'typed notification routes are wrong'
vx_compose_alert_notify alice app health unhealthy \
    || fail 'approved notification fan-out failed'
[[ "$(wc -l <"$test_root/notify.log")" -eq 2 ]] \
    || fail 'notification fan-out count is wrong'
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"$(dirname -- "$0")/notify-failure.log"' \
    '[[ "${5-}" != account-email ]]' \
    >"$VX_COMPOSE_NOTIFICATION_COMMAND"
chmod 0755 "$VX_COMPOSE_NOTIFICATION_COMMAND"
if vx_compose_alert_notify alice app health unhealthy 2>/dev/null; then
    fail 'notification delivery failure was reported as success'
fi
[[ "$(wc -l <"$test_root/notify-failure.log")" -eq 2 ]] \
    || fail 'one failed destination prevented notification fan-out'
if vx_compose_notification_route_set alice alice app health \
    'https://secret.example/token' 2>/dev/null; then
    fail 'secret notification endpoint was accepted'
fi
if rg -F 'operator-secret-canary' "$root"/{roles.json,notification-routes.json} \
    "$test_root/notify.log"; then
    fail 'operator metadata leaked a managed secret'
fi

echo 'Compose operator control tests passed.'
