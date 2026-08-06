#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice/docker-projects/app/runtime"
root="$VESTA/data/users/alice/docker-projects/app"
printf "OWNER='alice'\nPROJECT='app'\nPROFILE='standard'\nSTATE='running'\nREVISION='1'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='old'\n" >"$root/project.conf"
printf '{}\n' >"$root/runtime/canonical.json"
printf 'services: {}\n' >"$root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$root/policy.conf"

mkdir -p "$VESTA/data/users/alice/docker-projects/.locks"
inherited_lock="$VESTA/data/users/alice/docker-projects/.locks/app.lock"
exec {VX_COMPOSE_LOCK_FD}>"$inherited_lock"
flock -x "$VX_COMPOSE_LOCK_FD"
inherited_fd="$VX_COMPOSE_LOCK_FD"
unrelated_lock="$test_root/unrelated.lock"
exec {unrelated_fd}>"$unrelated_lock"
export VX_COMPOSE_LOCK_FD VX_COMPOSE_LOCK_KEY='alice/app'
export VX_COMPOSE_LOCK_DEPTH=999
# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
[[ -z "${VX_COMPOSE_LOCK_FD:-}" && -z "${VX_COMPOSE_LOCK_KEY:-}"
    && -z "${VX_COMPOSE_LOCK_DEPTH:-}" ]]
[[ ! -e "/proc/$$/fd/$inherited_fd" ]]
(
    exec {probe_fd}>"$inherited_lock"
    flock -n "$probe_fd"
) || {
    echo 'FAIL: public loader retained an inherited project lock' >&2
    exit 1
}
[[ -e "/proc/$$/fd/$unrelated_fd" ]] || {
    echo 'FAIL: public loader closed an unrelated descriptor' >&2
    exit 1
}
exec {unrelated_fd}>&-

# Caller metadata must never close stdout/stderr or an unrelated open file.
loader_output="$(
    VX_COMPOSE_LOCK_FD=1 VX_COMPOSE_LOCK_KEY=alice/app \
        VX_COMPOSE_LOCK_DEPTH=1 VESTA="$VESTA" HOMEDIR="$HOMEDIR" \
        bash -c 'source "$1"; printf "stdout-open\n"; printf "stderr-open\n" >&2' \
        _ "$repo_root/func/vx/compose/main.sh" 2>"$test_root/loader.stderr"
)"
[[ "$loader_output" == stdout-open
    && "$(cat "$test_root/loader.stderr")" == stderr-open ]] || {
    echo 'FAIL: public loader polluted or closed stdout/stderr' >&2
    exit 1
}
VESTA="$VESTA" HOMEDIR="$HOMEDIR" \
    bash -c '
        exec {foreign_fd}>"$1"
        export VX_COMPOSE_LOCK_FD="$foreign_fd"
        export VX_COMPOSE_LOCK_KEY=alice/app VX_COMPOSE_LOCK_DEPTH=1
        source "$2"
        [[ -e "/proc/$$/fd/$foreign_fd"
            && -z "${VX_COMPOSE_LOCK_FD:-}" ]]
    ' _ "$test_root/foreign.lock" "$repo_root/func/vx/compose/main.sh" || {
    echo 'FAIL: public loader closed a caller-owned unrelated descriptor' >&2
    exit 1
}

# Project locks are re-entrant only for the exact same owner/project.
vx_compose_lock_acquire alice app
[[ "$VX_COMPOSE_LOCK_DEPTH" == 1 ]]
# Re-sourcing inside one initialized process must preserve a legitimate lock.
source "$repo_root/func/vx/compose/main.sh"
[[ "$VX_COMPOSE_LOCK_DEPTH" == 1 && "$VX_COMPOSE_LOCK_KEY" == alice/app ]]
vx_compose_lock_acquire alice app
[[ "$VX_COMPOSE_LOCK_DEPTH" == 2 ]]
if vx_compose_lock_acquire alice other; then
    echo 'FAIL: nested lock accepted a different project' >&2
    exit 1
fi
[[ "$VX_COMPOSE_LOCK_DEPTH" == 2 ]]
vx_compose_lock_release
[[ "$VX_COMPOSE_LOCK_DEPTH" == 1 ]]
vx_compose_lock_release
[[ -z "${VX_COMPOSE_LOCK_FD:-}" && -z "${VX_COMPOSE_LOCK_KEY:-}"
    && -z "${VX_COMPOSE_LOCK_DEPTH:-}" ]]

# Global port allocation is re-entrant and always precedes the owner quota
# lock, preventing ports↔quota deadlocks across project transactions.
vx_compose_ports_lock_acquire
vx_compose_ports_lock_acquire
[[ "$VX_COMPOSE_PORTS_LOCK_DEPTH" == 2 ]]
vx_compose_ports_lock_release
vx_compose_ports_lock_release
[[ -z "${VX_COMPOSE_PORTS_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_DEPTH:-}" ]]
port_barrier="$test_root/port-order.fifo"
mkfifo "$port_barrier"
: >"$test_root/port-order.ready"
(
    vx_compose_ports_lock_acquire
    printf 'ready\n' >"$test_root/port-order.ready"
    IFS= read -r _ <"$port_barrier"
    vx_compose_owner_quota_lock_acquire alice
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
) &
ordered_first=$!
for _ in {1..100}; do
    [[ -s "$test_root/port-order.ready" ]] && break
    sleep 0.01
done
(
    vx_compose_ports_lock_acquire
    vx_compose_owner_quota_lock_acquire alice
    vx_compose_owner_quota_lock_release
    vx_compose_ports_lock_release
) &
ordered_second=$!
printf 'release\n' >"$port_barrier"
timeout 5 tail --pid="$ordered_first" --pid="$ordered_second" -f /dev/null
wait "$ordered_first" "$ordered_second"

vx_compose_quota_check_candidate() { :; }
vx_compose_ports_check_conflicts() { :; }
vx_compose_owner_quota_lock_acquire() { :; }
vx_compose_owner_quota_lock_release() { :; }
vx_compose_routes_validate_reservations() { :; }
vx_compose_resolve_images_to_file() {
    printf 'resolve\n' >>"$test_root/calls"
    mkdir -p "$(dirname -- "$4")"
    printf '{}\n' >"$4"
}
vx_compose_stage_candidate_revision() {
    printf 'stage\n' >>"$test_root/calls"
    mkdir -p "$4"
}
vx_compose_commit_staged_revision() {
    printf 'commit\n' >>"$test_root/calls"
}
deploy_attempt=0
vx_compose_deploy() {
    deploy_attempt=$((deploy_attempt + 1))
    printf 'deploy:%s:%s\n' \
        "$deploy_attempt" \
        "${VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE:-no}" \
        >>"$test_root/calls"
    [[ "$deploy_attempt" -gt 1 ]]
}
vx_compose_network_cleanup_replaced() { :; }
vx_compose_stop() {
    if [[ -n "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-}"
        && -n "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}"
        && -n "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
        && -n "${VX_COMPOSE_POLICY_OVERRIDE:-}"
        && -n "${VX_COMPOSE_ROUTES_FILE_OVERRIDE:-}" ]]; then
        printf 'stop:candidate\n' >>"$test_root/calls"
    else
        printf 'stop:active\n' >>"$test_root/calls"
    fi
}
if vx_compose_transaction_update alice app "$test_root/candidate"; then
    echo 'FAIL: failed update reported success after rollback' >&2
    exit 1
fi
diff -u \
    <(printf 'resolve\nstage\ndeploy:1:yes\ndeploy:2:no\n') \
    "$test_root/calls"
if vx_compose_transaction_update alice app "$test_root/candidate" 2; then
    echo 'FAIL: stale expected revision was accepted' >&2
    exit 1
fi

# A stopped simple update converges and validates the candidate, stops that
# runtime, then commits the stopped revision without releasing the transaction.
rm -f -- "$test_root/calls"
vx_compose_deploy() {
    [[ "${VX_COMPOSE_RUNTIME_PREFLIGHT_CANDIDATE:-no}" == yes ]]
    printf 'deploy\n' >>"$test_root/calls"
}
vx_compose_commit_staged_revision() {
    printf 'commit:%s\n' "$5" >>"$test_root/calls"
}
vx_compose_transaction_update \
    alice app "$test_root/candidate" 1 stopped
deploy_line="$(grep -n '^deploy$' "$test_root/calls" | cut -d: -f1)"
stop_line="$(grep -n '^stop:candidate$' "$test_root/calls" | cut -d: -f1)"
commit_line="$(grep -n '^commit:stopped$' "$test_root/calls" | cut -d: -f1)"
[[ "$deploy_line" -lt "$stop_line" && "$stop_line" -lt "$commit_line" ]] || {
    echo 'FAIL: stopped transaction did not validate, stop, then commit' >&2
    exit 1
}

# Recovery preserves a previously stopped lifecycle state after a failed
# stopped update instead of leaving the prior definition running.
sed -i "s/^STATE='running'/STATE='stopped'/" "$root/project.conf"
rm -f -- "$test_root/calls"
deploy_attempt=0
vx_compose_deploy() {
    deploy_attempt=$((deploy_attempt + 1))
    printf 'deploy:%s\n' "$deploy_attempt" >>"$test_root/calls"
    [[ "$deploy_attempt" -gt 1 ]]
}
vx_compose_commit_staged_revision() { :; }
if vx_compose_transaction_update \
    alice app "$test_root/candidate" 1 stopped; then
    echo 'FAIL: failed stopped update reported success' >&2
    exit 1
fi
grep -Fq 'stop:active' "$test_root/calls" || {
    echo 'FAIL: failed stopped update left prior runtime running' >&2
    exit 1
}
sed -i "s/^STATE='stopped'/STATE='running'/" "$root/project.conf"

# Port conflicts are revalidated under the global port lock before image
# resolution, staging, or runtime mutation.
rm -f -- "$test_root/candidate/images.json" "$test_root/port-order.calls"
vx_compose_ports_check_conflicts() {
    printf 'ports-check\n' >>"$test_root/port-order.calls"
    return 1
}
vx_compose_resolve_images_to_file() {
    printf 'resolve\n' >>"$test_root/port-order.calls"
}
if vx_compose_transaction_update alice app "$test_root/candidate" 1; then
    echo 'FAIL: transaction accepted a conflicting candidate port' >&2
    exit 1
fi
[[ "$(cat "$test_root/port-order.calls")" == ports-check ]] || {
    echo 'FAIL: port conflict did not stop before image/runtime mutation' >&2
    exit 1
}
vx_compose_ports_check_conflicts() { :; }

# Two legacy callers that both recorded revision 1 serialize on the real
# transaction lock. The first converges; the second deterministically fails
# stale without entering storage/deploy.
printf "OWNER='alice'\nPROJECT='app'\nPROFILE='standard'\nSTATE='running'\nREVISION='1'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='old'\n" \
    >"$root/project.conf"
mkdir -p "$root/revisions/000009"
barrier="$test_root/deploy.fifo"
mkfifo "$barrier"
commit_barrier="$test_root/commit.fifo"
mkfifo "$commit_barrier"
: >"$test_root/commit.ready"
: >"$test_root/parallel-calls"
vx_compose_resolve_images_to_file() {
    mkdir -p "$(dirname -- "$4")"
    printf '{}\n' >"$4"
}
vx_compose_stage_candidate_revision() {
    mkdir -p "$4"
    printf 'stage:%s\n' "$BASHPID" >>"$test_root/parallel-calls"
}
vx_compose_commit_staged_revision() {
    printf 'ready\n' >"$test_root/commit.ready"
    IFS= read -r _ <"$commit_barrier"
    sed -i "s/^REVISION='1'/REVISION='2'/" "$root/project.conf"
    printf 'commit:%s:%s\n' "$4" "$BASHPID" >>"$test_root/parallel-calls"
}
vx_compose_deploy() {
    printf 'deploy:%s\n' "$BASHPID" >>"$test_root/parallel-calls"
    IFS= read -r _ <"$barrier"
}
run_parallel_update() {
    local name="$1" status=0
    vx_compose_transaction_update \
        alice app "$test_root/candidate" 1 || status=$?
    printf '%s:%s\n' "$name" "$status" >"$test_root/$name.status"
}
run_parallel_update first &
first_pid=$!
run_parallel_update second &
second_pid=$!
for _ in {1..100}; do
    [[ "$(grep -c '^deploy:' "$test_root/parallel-calls" || :)" == 1 ]] \
        && break
    sleep 0.02
done
[[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == 1 ]] || {
    echo 'FAIL: candidate revision published before convergence completed' >&2
    exit 1
}
printf 'release\n' >"$barrier"
for _ in {1..100}; do
    [[ -s "$test_root/commit.ready" ]] && break
    sleep 0.02
done
rm -f -- "$test_root/route-competitor.entered"
(
    vx_compose_routes_lock_acquire alice
    printf 'entered\n' >"$test_root/route-competitor.entered"
    vx_compose_routes_lock_release
) &
route_competitor_pid=$!
sleep 0.1
[[ ! -e "$test_root/route-competitor.entered" ]] || {
    echo 'FAIL: route reservation lock released before revision commit' >&2
    exit 1
}
printf 'release\n' >"$commit_barrier"
wait "$first_pid" "$second_pid" "$route_competitor_pid"
[[ -s "$test_root/route-competitor.entered" ]] || {
    echo 'FAIL: route competitor did not enter after revision commit' >&2
    exit 1
}
statuses="$(cat "$test_root/first.status" "$test_root/second.status")"
[[ "$(grep -c ':0$' <<<"$statuses")" == 1
    && "$(grep -cv ':0$' <<<"$statuses")" == 1
    && "$(grep -c '^stage:' "$test_root/parallel-calls")" == 1
    && "$(grep -c '^commit:10:' "$test_root/parallel-calls")" == 1
    && "$(grep -c '^deploy:' "$test_root/parallel-calls")" == 1 ]] || {
    echo 'FAIL: parallel legacy updates were not serialized stale-safe' >&2
    exit 1
}

# Exercise the real rollback file restoration path.
unset -f vx_compose_rollback
# shellcheck source=func/vx/compose/transaction.sh
source "$repo_root/func/vx/compose/transaction.sh"
# Restore the real reservation validator after the isolated transaction stubs.
# shellcheck source=func/vx/compose/routes.sh
source "$repo_root/func/vx/compose/routes.sh"
mkdir -p "$root/revisions/000001"
chmod 0750 "$root/revisions" "$root/revisions/000001"
printf 'services:\n  web:\n    image: old\n' >"$root/revisions/000001/compose.yaml"
printf '{"services":{"web":{"image":"old"}}}\n' \
    >"$root/revisions/000001/canonical.json"
printf "POLICY_SCHEMA='1'\n" >"$root/revisions/000001/policy.conf"
printf '{}\n' >"$root/revisions/000001/routes.conf"
printf '{"GENERATED":true,"OWNER":"alice","NAME":"app","IMAGE":"old"}\n' \
    >"$root/revisions/000001/simple.json"
printf '{"CPU_PCT":70,"MEMORY_PCT":80,"NETWORK_MBPS":40,"NOTIFY":false}\n' \
    >"$root/revisions/000001/alerts.conf"
printf '{"GENERATED":true,"OWNER":"alice","NAME":"app","IMAGE":"new"}\n' \
    >"$root/simple.json"
printf '{"CPU_PCT":99,"MEMORY_PCT":99,"NETWORK_MBPS":99,"NOTIFY":true}\n' \
    >"$root/alerts.conf"
printf 'services:\n  web:\n    image: new\n' >"$root/compose.yaml"
printf '{"services":{"web":{"image":"new"}}}\n' \
    >"$root/runtime/canonical.json"
write_transaction_image_evidence() {
    local path="$1" reference="$2" image_id="$3"

    jq -n -S --arg reference "$reference" --arg image_id "$image_id" '{
        web:{
            SCHEMA:2,REFERENCE:$reference,IMMUTABLE_REFERENCE:"",
            REGISTRY_DIGEST:"",IMAGE_ID:$image_id,REPO_DIGESTS:[],
            OCI_LABELS:{created:"",revision:"",source:"",vendor:"",version:""},
            TRUST:{MODE:"disabled",DECISION:"disabled",PROFILE:"standard",
                PROFILE_VERSION:2,POLICY_VERSION:2,
                SIGNATURE:{STATE:"not-run"},VULNERABILITY:{STATE:"not-run"},
                EXCEPTION:false},
            OS:"linux",ARCHITECTURE:"amd64"
        }
    }' >"$path"
    chmod 0640 "$path"
}
write_transaction_image_evidence "$root/images.json" new \
    sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
printf '{}\n' >"$root/routes.conf"
write_transaction_image_evidence "$root/revisions/000001/images.json" old \
    sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
vx_compose_revision_manifest_write "$root/revisions/000001"
mkdir -p "$root/revisions/000002"
chmod 0750 "$root/revisions/000002"
install -m 0640 "$root/compose.yaml" \
    "$root/revisions/000002/compose.yaml"
install -m 0640 "$root/runtime/canonical.json" \
    "$root/revisions/000002/canonical.json"
install -m 0640 "$root/policy.conf" \
    "$root/revisions/000002/policy.conf"
install -m 0640 "$root/routes.conf" \
    "$root/revisions/000002/routes.conf"
install -m 0640 "$root/images.json" \
    "$root/revisions/000002/images.json"
install -m 0600 "$root/simple.json" \
    "$root/revisions/000002/simple.json"
install -m 0640 "$root/alerts.conf" \
    "$root/revisions/000002/alerts.conf"
vx_compose_revision_manifest_write "$root/revisions/000002"
current_sha="$(sha256sum "$root/runtime/canonical.json" | awk '{print $1}')"
vx_compose_write_metadata \
    "$root" alice app standard running 2 \
    2026-01-01T00:00:00Z 2026-01-01T00:00:00Z "$current_sha"

# Rollback rejects incomplete and tampered workload authority before runtime.
deploy_calls=0
vx_compose_deploy() { deploy_calls=$((deploy_calls + 1)); }
for authority_case in incomplete tampered; do
    rm -f -- "$root/revisions/000001/manifest.sha256"
    printf '{}\n' >"$root/revisions/000001/workload.json"
    chmod 0600 "$root/revisions/000001/workload.json"
    if [[ "$authority_case" == tampered ]]; then
        printf '{}\n' >"$root/revisions/000001/workload-evidence.json"
        printf '%064d  workload.json\n%064d  compose.yaml\n' 0 0 \
            >"$root/revisions/000001/workload-manifest.sha256"
        chmod 0600 "$root/revisions/000001/workload-evidence.json" \
            "$root/revisions/000001/workload-manifest.sha256"
    fi
    vx_compose_revision_manifest_write "$root/revisions/000001"
    if vx_compose_rollback alice app 1 2>/dev/null; then
        echo "FAIL: rollback accepted $authority_case workload authority" >&2
        exit 1
    fi
    [[ "$deploy_calls" == 0 ]] || {
        echo "FAIL: $authority_case rollback reached runtime" >&2
        exit 1
    }
    rm -f -- "$root/revisions/000001/manifest.sha256" \
        "$root/revisions/000001/workload.json" \
        "$root/revisions/000001/workload-evidence.json" \
        "$root/revisions/000001/workload-manifest.sha256"
    vx_compose_revision_manifest_write "$root/revisions/000001"
done

# Historical route reservations are revalidated under the owner route lock
# before rollback changes active definition, canonical state, or metadata.
claimed_domain=claimed.example.test
rm -f -- "$root/revisions/000001/manifest.sha256"
printf '{"%s":{}}\n' "$claimed_domain" \
    >"$root/revisions/000001/routes.conf"
vx_compose_revision_manifest_write "$root/revisions/000001"
other_root="$VESTA/data/users/alice/docker-projects/other"
mkdir -p "$other_root/runtime"
printf '{"%s":{}}\n' "$claimed_domain" >"$other_root/routes.conf"
cp "$root/compose.yaml" "$test_root/pre-conflict-compose.yaml"
cp "$root/runtime/canonical.json" "$test_root/pre-conflict-canonical.json"
cp "$root/project.conf" "$test_root/pre-conflict-project.conf"
deploy_calls=0
vx_compose_deploy() {
    deploy_calls=$((deploy_calls + 1))
}
if vx_compose_rollback alice app 1 2>/dev/null; then
    echo 'FAIL: rollback accepted a route claimed by another project' >&2
    exit 1
fi
cmp -s "$root/compose.yaml" "$test_root/pre-conflict-compose.yaml"
cmp -s "$root/runtime/canonical.json" \
    "$test_root/pre-conflict-canonical.json"
cmp -s "$root/project.conf" "$test_root/pre-conflict-project.conf"
[[ "$deploy_calls" == 0 ]] || {
    echo 'FAIL: conflicting rollback mutated runtime before rejection' >&2
    exit 1
}
rm -rf -- "$other_root"
rm -f -- "$root/revisions/000001/manifest.sha256"
printf '{}\n' >"$root/revisions/000001/routes.conf"
vx_compose_revision_manifest_write "$root/revisions/000001"
printf '{"stale.example.test":{}}\n' \
    >"$root/runtime/routes.pending.json"

# A rollback finalization fault restores the exact prior active authority and
# runtime before releasing the lock.
cp "$root/compose.yaml" "$test_root/pre-fault-compose.yaml"
cp "$root/runtime/canonical.json" "$test_root/pre-fault-canonical.json"
cp "$root/policy.conf" "$test_root/pre-fault-policy.conf"
cp "$root/project.conf" "$test_root/pre-fault-project.conf"
cp "$root/routes.conf" "$test_root/pre-fault-routes.conf"
cp "$root/alerts.conf" "$test_root/pre-fault-alerts.conf"
rollback_deploy_calls=0
vx_compose_runtime_identity_preflight() {
    printf 'incomplete\n'
}
vx_compose_invoke() { :; }
vx_compose_deploy() {
    rollback_deploy_calls=$((rollback_deploy_calls + 1))
    vx_compose_active_revision_verify "$1" "$2"
}
export VX_COMPOSE_TEST_ROLLBACK_COMMIT_FAIL=yes
if vx_compose_rollback alice app 1; then
    echo 'FAIL: rollback finalization fault unexpectedly succeeded' >&2
    exit 1
fi
unset VX_COMPOSE_TEST_ROLLBACK_COMMIT_FAIL
cmp -s "$root/compose.yaml" "$test_root/pre-fault-compose.yaml"
cmp -s "$root/runtime/canonical.json" "$test_root/pre-fault-canonical.json"
cmp -s "$root/policy.conf" "$test_root/pre-fault-policy.conf"
cmp -s "$root/project.conf" "$test_root/pre-fault-project.conf"
cmp -s "$root/routes.conf" "$test_root/pre-fault-routes.conf"
cmp -s "$root/alerts.conf" "$test_root/pre-fault-alerts.conf"
[[ "$rollback_deploy_calls" == 2
    && -f "$root/runtime/routes.pending.json" ]] || {
    echo 'FAIL: rollback fault did not recover exact prior authority/runtime' >&2
    exit 1
}
# Restore lifecycle helpers replaced at the fault boundary.
source "$repo_root/func/vx/compose/lifecycle.sh"

# The real active verifier must accept the untouched prior authority while the
# target converges under overrides; only then may rollback publish revision 1.
rollback_verified_prior=no
vx_compose_deploy() {
    vx_compose_active_revision_verify "$1" "$2" || return 1
    [[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == 2
        && "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-}" \
            == "$root/runtime/.rollback."*/canonical.json
        && "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}" \
            == "$root/runtime/.rollback."*/images.json
        && "${VX_COMPOSE_POLICY_OVERRIDE:-}" \
            == "$root/runtime/.rollback."*/policy.conf
        && "${VX_COMPOSE_ROUTES_FILE_OVERRIDE:-}" \
            == "$root/runtime/.rollback."*/routes.conf
        && "${VX_COMPOSE_LIFECYCLE_DEFER_COMMIT:-}" == yes ]] \
        || return 1
    rollback_verified_prior=yes
}
vx_compose_rollback alice app 1
[[ "$rollback_verified_prior" == yes ]]
vx_compose_active_revision_verify alice app
grep -Fq 'image: old' "$root/compose.yaml"
jq -e '.IMAGE == "old"' "$root/simple.json" >/dev/null
jq -e '
    .CPU_PCT == 70
    and .MEMORY_PCT == 80
    and .NETWORK_MBPS == 40
    and .NOTIFY == false
' "$root/alerts.conf" >/dev/null || {
    echo 'FAIL: rollback did not restore revision-bound alert intent' >&2
    exit 1
}
[[ ! -e "$root/runtime/routes.pending.json" ]] || {
    echo 'FAIL: successful rollback retained stale pending route intent' >&2
    exit 1
}
# shellcheck disable=SC2218
[[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == 1 ]]

# A route-less target is applied as an explicit empty desired set while the
# old active metadata still exists, then the old active metadata is removed.
rm -f -- \
    "$root/revisions/000001/routes.conf" \
    "$root/revisions/000001/manifest.sha256"
vx_compose_revision_manifest_write "$root/revisions/000001"
printf '{"old.example.test":{"DOMAIN":"old.example.test"}}\n' \
    >"$root/routes.conf"
rollback_route_override=''
vx_compose_deploy() {
    rollback_route_override="${VX_COMPOSE_ROUTES_FILE_OVERRIDE:-}"
    [[ -f "$rollback_route_override"
        && "$(jq -r 'length' "$rollback_route_override")" == 0 ]]
}
vx_compose_rollback alice app 1
[[ -n "$rollback_route_override" && ! -e "$root/routes.conf" ]] || {
    echo 'FAIL: route-less rollback retained active route metadata' >&2
    exit 1
}

# Legacy revisions without alert intent receive the deliberate safe default;
# newer active thresholds are never retained under the historical revision.
rm -f -- \
    "$root/revisions/000001/alerts.conf" \
    "$root/revisions/000001/images.json" \
    "$root/revisions/000001/manifest.sha256"
(
    cd "$root/revisions/000001"
    sha256sum canonical.json >manifest.sha256
    chmod 0640 manifest.sha256
)
printf '{"CPU_PCT":12,"MEMORY_PCT":13,"NETWORK_MBPS":14,"NOTIFY":false}\n' \
    >"$root/alerts.conf"
vx_compose_rollback alice app 1
vx_compose_active_revision_verify alice app
jq -e '
    .CPU_PCT == 90
    and .MEMORY_PCT == 90
    and .NETWORK_MBPS == 100
    and .NOTIFY == true
' "$root/alerts.conf" >/dev/null || {
    echo 'FAIL: legacy rollback retained newer alert thresholds' >&2
    exit 1
}

# Rollback retains the project lock through runtime convergence. A competing
# mutation cannot enter while the rollback deploy gate is blocked.
rollback_barrier="$test_root/rollback.fifo"
mkfifo "$rollback_barrier"
: >"$test_root/rollback.ready"
rm -f -- "$test_root/competitor.entered"
vx_compose_deploy() {
    printf 'ready\n' >"$test_root/rollback.ready"
    IFS= read -r _ <"$rollback_barrier"
}
vx_compose_rollback alice app 1 &
rollback_pid=$!
for _ in {1..100}; do
    [[ -s "$test_root/rollback.ready" ]] && break
    sleep 0.01
done
(
    vx_compose_lock_acquire alice app
    printf 'entered\n' >"$test_root/competitor.entered"
    vx_compose_lock_release
) &
competitor_pid=$!
sleep 0.1
[[ ! -e "$test_root/competitor.entered" ]] || {
    echo 'FAIL: competing mutation crossed rollback convergence barrier' >&2
    exit 1
}
printf 'release\n' >"$rollback_barrier"
wait "$rollback_pid" "$competitor_pid"
[[ -s "$test_root/competitor.entered" ]] || {
    echo 'FAIL: competing mutation did not enter after rollback released lock' >&2
    exit 1
}

# Integration fault matrix: use the real revision installer, transaction, and
# rollback helpers. Only Docker/dependent quota/port service boundaries are
# stubbed.
source "$repo_root/func/vx/compose/storage.sh"
source "$repo_root/func/vx/compose/audit.sh"
source "$repo_root/func/vx/compose/transaction.sh"
vx_compose_ports_check_conflicts() { :; }
vx_compose_quota_check_candidate() { :; }
vx_compose_refresh_counters() { :; }
vx_compose_profile_require_authorized() { :; }
candidate="$test_root/integration-candidate"
rm -rf -- "$candidate"
mkdir -p "$candidate"
printf 'services:\n  web:\n    image: candidate\n' >"$candidate/compose.yaml"
printf '{"services":{"web":{"image":"candidate"}},"networks":{"default":{"name":"vx-alice-app_default"}}}\n' \
    >"$candidate/canonical.json"
sha256sum "$candidate/canonical.json" >"$candidate/canonical.sha256"
printf "POLICY_SCHEMA='1'\n" >"$candidate/policy.conf"
printf '{}\n' >"$candidate/images.json"

reset_integration_project() {
    rm -rf -- "$root"
    mkdir -p "$root/runtime" "$root/revisions/000001" "$root/secrets"
    printf "OWNER='alice'\nPROJECT='app'\nPROFILE='standard'\nSTATE='running'\nREVISION='1'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='old'\n" \
        >"$root/project.conf"
    printf 'services:\n  web:\n    image: old\n' >"$root/compose.yaml"
    printf '{"services":{"web":{"image":"old"}},"networks":{"default":{"name":"vx_alice_app_default"}}}\n' \
        >"$root/runtime/canonical.json"
    printf "POLICY_SCHEMA='1'\n" >"$root/policy.conf"
    printf '{"route":"old"}\n' >"$root/routes.conf"
    install -m 0640 "$root/compose.yaml" \
        "$root/revisions/000001/compose.yaml"
    install -m 0640 "$root/runtime/canonical.json" \
        "$root/revisions/000001/canonical.json"
    install -m 0640 "$root/policy.conf" \
        "$root/revisions/000001/policy.conf"
    install -m 0640 "$root/routes.conf" \
        "$root/revisions/000001/routes.conf"
}

reset_integration_project
deploy_attempt=0
rollback_deploy_result=success
rm -f -- "$test_root/integration-cleanup"
vx_compose_network_cleanup_replaced() {
    printf 'cleanup\n' >>"$test_root/integration-cleanup"
}
vx_compose_deploy() {
    deploy_attempt=$((deploy_attempt + 1))
    printf 'deploy:%s\n' "$deploy_attempt" >>"$test_root/integration-deploy"
    if [[ "$deploy_attempt" -gt 1
        && "$rollback_deploy_result" == success ]]; then
        [[ "$(jq -r '.networks.default.name' \
            "$root/runtime/canonical.json")" == vx_alice_app_default ]] \
            || return 1
        vx_compose_update_state "$1" "$2" running
        return 0
    fi
    return 1
}
vx_compose_audit_actor_push alice
if vx_compose_transaction_update alice app "$candidate" 1; then
    echo 'FAIL: candidate deployment fault unexpectedly succeeded' >&2
    exit 1
fi
vx_compose_audit_actor_pop
[[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == 1
    && "$(vx_compose_meta_get "$root/project.conf" STATE)" == running
    && "$(jq -r '.services.web.image' "$root/runtime/canonical.json")" == old
    && "$(jq -r .route "$root/routes.conf")" == old
    && ! -e "$test_root/integration-cleanup"
    && -z "${VX_COMPOSE_LOCK_FD:-}" ]] || {
    echo 'FAIL: real rollback did not restore prior desired state/release lock' >&2
    exit 1
}
jq -e 'select(
        .ACTION == "transaction-update"
        and .RESULT == "failed"
        and (.DETAILS | contains("prior runtime restored"))
    ) | .ACTOR == "alice"' "$root/audit.log" >/dev/null \
    || {
        echo 'FAIL: successful real rollback audit actor is wrong' >&2
        exit 1
    }
[[ -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]]

reset_integration_project
deploy_attempt=0
: >"$test_root/integration-deploy"
rollback_deploy_result=failed
vx_compose_audit_actor_push alice
if vx_compose_transaction_update alice app "$candidate" 1; then
    echo 'FAIL: rollback deployment fault unexpectedly succeeded' >&2
    exit 1
fi
vx_compose_audit_actor_pop
[[ "$(vx_compose_meta_get "$root/project.conf" REVISION)" == 1
    && "$(vx_compose_meta_get "$root/project.conf" STATE)" == restore-required
    && "$(jq -r '.services.web.image' "$root/runtime/canonical.json")" == old
    && "$(jq -r .route "$root/routes.conf")" == old
    && "$(grep -c '^deploy:' "$test_root/integration-deploy")" == 2
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${_VX_COMPOSE_AUDIT_ACTOR:-}" ]] || {
    echo 'FAIL: failed real rollback did not retain restore-required evidence' >&2
    exit 1
}
jq -e 'select(
        .ACTION == "transaction-update"
        and .RESULT == "failed"
        and (.DETAILS | contains("prior runtime recovery failed"))
    ) | .ACTOR == "alice"' "$root/audit.log" >/dev/null \
    || {
        echo 'FAIL: failed real rollback audit actor is wrong' >&2
        exit 1
    }

# Run two real v-change command adapters that both read revision 1 before a
# preparation barrier. The transaction helper serializes them: one succeeds,
# one exits stale, and storage/deploy execute exactly once without deadlock.
cli_vesta="$test_root/cli-vesta"
cli_root="$cli_vesta/data/users/alice/docker-projects/app"
mkdir -p "$cli_vesta/func/vx/compose" "$cli_root/runtime" \
    "$test_root/cli-home/alice"
printf "OWNER='alice'\nPROJECT='app'\nPROFILE='standard'\nSTATE='running'\nREVISION='1'\nCREATED='now'\nCANONICAL_SHA256='old'\n" \
    >"$cli_root/project.conf"
printf '{}\n' >"$cli_root/runtime/canonical.json"
printf 'services: {}\n' >"$cli_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$cli_root/policy.conf"
printf 'services: {}\n' >"$test_root/change.yaml"
mkfifo "$test_root/change-prepare.fifo"
: >"$test_root/change-prepare.ready"
: >"$test_root/change-calls"
printf '%s\n' '#!/usr/bin/env bash
E_ARGS=1
E_NOTEXIST=2
E_INVALID=3
OK=0
check_args() { :; }
check_result() { exit "$1"; }
is_format_valid() { :; }
is_object_valid() { :; }
is_object_unsuspended() { :; }
log_history() { :; }
log_event() { :; }' >"$cli_vesta/func/main.sh"
printf '%s\n' '#!/usr/bin/env bash
source "$CLI_REPO_ROOT/func/vx/compose/storage.sh"
source "$CLI_REPO_ROOT/func/vx/compose/transaction.sh"
vx_compose_error() { printf "%s\n" "$*" >&2; }
vx_compose_require_owner() { [[ "$1" == alice ]]; }
vx_compose_require_project_key() { [[ "$1" == app ]]; }
vx_compose_profile_is_available() { :; }
vx_compose_require_project() {
    [[ -f "$(vx_compose_project_root "$1" "$2")/project.conf" ]]
}
vx_compose_audit() { :; }
vx_compose_network_cleanup_replaced() { :; }
vx_compose_routes_candidate_path() {
    printf "%s/runtime/routes.pending.json\n" \
        "$(vx_compose_project_root "$1" "$2")"
}
vx_compose_routes_lock_acquire() { :; }
vx_compose_routes_lock_release() { :; }
vx_compose_routes_validate_reservations() { :; }
vx_compose_owner_quota_lock_acquire() { :; }
vx_compose_owner_quota_lock_release() { :; }
vx_compose_quota_check_candidate() { :; }
vx_compose_ports_lock_acquire() { :; }
vx_compose_ports_lock_release() { :; }
vx_compose_ports_check_conflicts() { :; }
vx_compose_resolve_images_to_file() {
    printf "{}\n" >"$4"
}
vx_compose_prepare_candidate() {
    printf "ready\n" >>"$CLI_TEST_ROOT/change-prepare.ready"
    IFS= read -r _ <"$CLI_TEST_ROOT/change-prepare.fifo"
    mkdir -p "$4"
}
vx_compose_stage_candidate_revision() {
    mkdir -p "$4"
    printf "stage:%s\n" "$BASHPID" >>"$CLI_TEST_ROOT/change-calls"
}
vx_compose_commit_staged_revision() {
    local metadata
    metadata="$(vx_compose_project_root "$1" "$2")/project.conf"
    sed -i "s/^REVISION=.*/REVISION='\''2'\''/" "$metadata"
    printf "commit:%s\n" "$BASHPID" >>"$CLI_TEST_ROOT/change-calls"
}
vx_compose_deploy() {
    printf "deploy:%s\n" "$BASHPID" >>"$CLI_TEST_ROOT/change-calls"
}' >"$cli_vesta/func/vx/compose/main.sh"
export CLI_REPO_ROOT="$repo_root" CLI_TEST_ROOT="$test_root"
run_change_command() {
    local name="$1" status=0
    VESTA="$cli_vesta" HOMEDIR="$test_root/cli-home" \
        bash "$repo_root/bin/v-change-docker-project" \
            alice app "$test_root/change.yaml" || status=$?
    printf '%s:%s\n' "$name" "$status" >"$test_root/$name.change"
}
run_change_command first &
first_change_pid=$!
run_change_command second &
second_change_pid=$!
for _ in {1..100}; do
    [[ "$(wc -l <"$test_root/change-prepare.ready")" == 2 ]] && break
    sleep 0.02
done
printf 'one\ntwo\n' >"$test_root/change-prepare.fifo"
wait "$first_change_pid" "$second_change_pid"
change_statuses="$(cat "$test_root/first.change" "$test_root/second.change")"
[[ "$(grep -c ':0$' <<<"$change_statuses")" == 1
    && "$(grep -cv ':0$' <<<"$change_statuses")" == 1
    && "$(grep -c '^stage:' "$test_root/change-calls")" == 1
    && "$(grep -c '^commit:' "$test_root/change-calls")" == 1
    && "$(grep -c '^deploy:' "$test_root/change-calls")" == 1 ]] || {
    echo 'FAIL: parallel v-change commands were not serialized stale-safe' >&2
    exit 1
}
unset CLI_REPO_ROOT CLI_TEST_ROOT

echo "Compose transaction tests passed."
