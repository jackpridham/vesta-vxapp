#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
cleanup() {
    find "$test_root" -type d -exec chmod u+rwx {} + 2>/dev/null || :
    find "$test_root" -type f -exec chmod u+rw {} + 2>/dev/null || :
    rm -rf -- "$test_root"
}
trap cleanup EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice/docker/app/binds/config"
printf 'bind-data\n' >"$HOMEDIR/alice/docker/app/binds/config/value.txt"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

(
    vx_compose_prepare_candidate() {
        [[ "$6" == yes ]]
    }
    vx_compose_restore_prepare_candidate \
        alice app "$test_root/stored-labels" \
        "$test_root/stored-labels-candidate" standard \
        "$test_root/stored-labels-secrets"
) || fail "restore did not require strict stored ownership-label validation"

project_root="$(vx_compose_project_root alice app)"
mkdir -p "$project_root/runtime" "$project_root/revisions/000001" "$project_root/secrets"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf '{"services":{},"volumes":{}}\n' >"$project_root/runtime/canonical.json"
printf "OWNER='alice'\nPROJECT='app'\nREVISION='1'\nSTATE='stopped'\nPROFILE='standard'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='abc'\n" \
    >"$project_root/project.conf"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"
printf '{}\n' >"$project_root/secrets.json"
printf '{}\n' >"$project_root/secret-integrity.json"
chmod 0600 "$project_root/secrets.json" "$project_root/secret-integrity.json"
printf '{}\n' >"$project_root/images.json"
printf '{"CPU_PCT":85,"MEMORY_PCT":90,"NETWORK_MBPS":50,"NOTIFY":true}\n' \
    >"$project_root/alerts.conf"
cp "$project_root/alerts.conf" \
    "$project_root/revisions/000001/alerts.conf"
(
    cd "$project_root/revisions/000001"
    sha256sum alerts.conf >manifest.sha256
)
printf 'audit without canary\n' >"$project_root/audit.log"
printf '%s\n' \
    '{"GENERATED":true,"OWNER":"alice","NAME":"app","IMAGE":"example.test/app:v1","COMMAND":"","ENV":"","MOUNTS":"","HOST_PORT":"18080","CONTAINER_PORT":"8080","DOMAIN":"","ROUTE_PATH":"","AUTO_START":"no","RESTART_POLICY":"unless-stopped","HEALTHCHECK_TYPE":"none","HEALTHCHECK_TARGET":"","HEALTHCHECK_INTERVAL":"60","CPU_ALERT_PCT":"85","MEM_ALERT_MB":"1024","NET_ALERT_MBPS":"50","ALERT_EMAIL":"yes"}' \
    >"$project_root/simple.json"
chmod 0600 "$project_root/simple.json"
mkdir -m 0700 "$project_root/runtime/workload-secrets" \
    "$project_root/runtime/workload-secrets/current"
printf 'runtime-copy-must-not-back-up\n' \
    >"$project_root/runtime/workload-secrets/current/credential"
chmod 0444 "$project_root/runtime/workload-secrets/current/credential"

archive="$test_root/app.tar.gz"
vx_compose_backup_project alice app "$archive"
[[ -s "$archive" ]] || fail "project backup was not created"
vx_compose_restore_archive_validate alice app "$archive" "$test_root/validated"
[[ "$(cat "$test_root/validated/binds/config/value.txt")" == bind-data ]] \
    || fail "managed bind data was not preserved"
[[ -f "$test_root/validated/control/secrets.json" ]] \
    || fail "secret manifest was omitted"
[[ -f "$test_root/validated/control/secret-integrity.json" ]] \
    || fail "private secret integrity manifest was omitted"
[[ -f "$test_root/validated/control/simple.json" ]] \
    || fail "simple-form provenance was omitted"
cmp -s "$project_root/alerts.conf" \
    "$test_root/validated/control/alerts.conf" \
    && cmp -s "$project_root/revisions/000001/alerts.conf" \
        "$test_root/validated/control/revisions/000001/alerts.conf" \
    || fail "active or revisioned alert policy was omitted"
if tar -tzf "$archive" | grep -Eq 'secrets/api_key|docker-registry|config.json$'; then
    fail "backup contains plaintext secrets or registry auth"
fi
if tar -tzf "$archive" | grep -Fq 'workload-secrets' \
    || grep -R -Fq 'runtime-copy-must-not-back-up' "$test_root/validated"; then
    fail 'backup retained a disposable runtime secret copy'
fi

managed_archive="$(vx_compose_backup_allocate_path alice app)"
vx_compose_backup_project alice app "$managed_archive"
managed_backup_root="$VESTA/data/users/alice/docker-project-backups/app"
[[ "$managed_archive" == "$managed_backup_root/"*.tar.gz ]] \
    || fail "managed backup escaped the retained owner backup root"
[[ "$(stat -c '%a' "$managed_backup_root")" == 700 ]] \
    || fail "managed backup directory mode is not protected"
vx_compose_backup_list_json alice app | jq -e \
    --arg archive "$(basename -- "$managed_archive")" '
        length == 1
        and .[0].ARCHIVE == $archive
        and .[0].BYTES > 0
        and (.[] | has("PATH") | not)
    ' >/dev/null \
    || fail "managed backup inventory is unsafe or incomplete"
[[ "$(vx_compose_backup_resolve_managed alice app \
    "$(basename -- "$managed_archive")")" == "$managed_archive" ]] \
    || fail "managed backup resolution returned the wrong archive"
if vx_compose_backup_resolve_managed alice app '../app.tar.gz' 2>/dev/null; then
    fail "managed backup resolution accepted path traversal"
fi
ln -s -- "$managed_archive" "$managed_backup_root/linked.tar.gz"
if vx_compose_backup_resolve_managed alice app linked.tar.gz 2>/dev/null; then
    fail "managed backup resolution accepted a symlink"
fi

# A real cold-backup path interrupted during volume export recovers the
# previously running workload, releases its lock, and removes scoped staging.
original_stop="$(declare -f vx_compose_stop)"
original_deploy="$(declare -f vx_compose_deploy)"
original_volume_export="$(declare -f vx_compose_volume_export)"
original_runtime_identity_preflight="$(declare -f \
    vx_compose_runtime_identity_preflight)"
original_network_verify_runtime="$(declare -f \
    vx_compose_network_verify_runtime)"
original_volume_verify_runtime="$(declare -f \
    vx_compose_volume_verify_runtime)"
original_health_collect="$(declare -f vx_compose_health_collect)"
original_routes_apply="$(declare -f vx_compose_routes_apply)"
original_project_resolve_images="$(declare -f \
    vx_compose_project_resolve_images)"
canonical_sha="$(sha256sum "$project_root/runtime/canonical.json" \
    | awk '{print $1}')"
chmod 0750 "$project_root" "$project_root/runtime" \
    "$project_root/revisions" "$project_root/revisions/000001"
printf "OWNER='alice'\nPROJECT='app'\nCOMPOSE_PROJECT='vx-alice-app'\nPROFILE='standard'\nSTATE='stopped'\nREVISION='1'\nSCHEMA='1'\nCANONICAL_SHA256='%s'\nCREATED='2026-01-01T00:00:00Z'\nUPDATED='2026-01-01T00:00:00Z'\n" \
    "$canonical_sha" >"$project_root/project.conf"
install -m 0640 \
    "$repo_root/test/compose/fixtures/image-evidence/production-five-field.json" \
    "$project_root/images.json"
for revision_member in compose.yaml policy.conf images.json simple.json; do
    install -m 0640 "$project_root/$revision_member" \
        "$project_root/revisions/000001/$revision_member"
done
install -m 0640 "$project_root/runtime/canonical.json" \
    "$project_root/revisions/000001/canonical.json"
rm -f -- "$project_root/revisions/000001/manifest.sha256"
vx_compose_revision_manifest_write "$project_root/revisions/000001"
vx_compose_update_state alice app running
jq '.volumes={state:{}}' "$project_root/runtime/canonical.json" \
    >"$project_root/runtime/.canonical.interruption"
mv -- "$project_root/runtime/.canonical.interruption" \
    "$project_root/runtime/canonical.json"
canonical_sha="$(sha256sum "$project_root/runtime/canonical.json" \
    | awk '{print $1}')"
sed -i "s/^CANONICAL_SHA256='[^']*'/CANONICAL_SHA256='$canonical_sha'/" \
    "$project_root/project.conf"
install -m 0640 "$project_root/runtime/canonical.json" \
    "$project_root/revisions/000001/canonical.json"
rm -f -- "$project_root/revisions/000001/manifest.sha256"
(
    cd "$project_root/revisions/000001"
    sha256sum canonical.json >manifest.sha256
    chmod 0640 manifest.sha256
)
current_images="$test_root/current-images.json"
jq -S 'with_entries(.value = (.value + {
    SCHEMA:2,
    IMMUTABLE_REFERENCE:(.value.REPO_DIGESTS[0] // ""),
    REGISTRY_DIGEST:(
        if (.value.REPO_DIGESTS | length) > 0
        then (.value.REPO_DIGESTS[0] | split("@")[1]) else "" end
    ),
    OCI_LABELS:{created:"",revision:"",source:"",vendor:"",version:""},
    TRUST:{
        MODE:"disabled",DECISION:"disabled",EXCEPTION:false,
        PROFILE:"standard",PROFILE_VERSION:1,POLICY_VERSION:2,
        SIGNATURE:{STATE:"not-run"},VULNERABILITY:{STATE:"not-run"}
    }
}))' "$project_root/images.json" >"$current_images"
vx_compose_lock_acquire alice app
vx_compose_image_evidence_migration_authority_create \
    alice app "$project_root" "$project_root/images.json" "$current_images"
install -m 0640 "$current_images" "$project_root/images.json"
vx_compose_lock_release
vx_compose_stop() {
    vx_compose_update_state "$1" "$2" stopped
    printf 'stopped\n' >>"$test_root/backup-lifecycle.log"
}
vx_compose_deploy() {
    [[ "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}" \
        == "$project_root/images.json" ]] || return 1
    printf 'deploy\n' >>"$test_root/backup-deploy.log"
    vx_compose_update_state "$1" "$2" running
    printf 'running\n' >>"$test_root/backup-lifecycle.log"
}
vx_compose_runtime_identity_preflight() {
    printf 'runtime\n' >>"$test_root/postcondition.log"
    if [[ "$(vx_compose_meta_get \
        "$project_root/project.conf" STATE)" == running ]]; then
        printf 'complete\n'
    else
        printf 'incomplete\n'
    fi
}
vx_compose_test_verifier_result() {
    local name="$1" mode_file="$test_root/$1.mode" mode

    printf '%s\n' "$name" >>"$test_root/postcondition.log"
    mode="$(cat "$mode_file" 2>/dev/null || printf pass)"
    case "$mode" in
        fail-once)
            printf 'pass\n' >"$mode_file"
            return 1
            ;;
        fail) return 1 ;;
        *) return 0 ;;
    esac
}
vx_compose_network_verify_runtime() {
    [[ "$4" == yes ]] || return 1
    vx_compose_test_verifier_result network
}
vx_compose_volume_verify_runtime() {
    [[ "$4" == yes ]] || return 1
    vx_compose_test_verifier_result volume
}
vx_compose_health_collect() {
    vx_compose_test_verifier_result health || return 1
    jq -n '{STATUS:"healthy",FRESHNESS:"fresh",SERVICES:{fixture:{
        RUNTIME_STATE:"running",HEALTH:"healthy"}}}'
}
vx_compose_routes_apply() {
    vx_compose_test_verifier_result routes
}
vx_compose_project_resolve_images() {
    printf 'resolve-images\n' >>"$test_root/resolve-images.log"
    return 1
}

# A marker write interrupted before its atomic rename leaves neither a marker
# nor partial authority and never stops the healthy workload.
original_fsync="$(declare -f vx_compose_fsync_path)"
eval "${original_fsync/vx_compose_fsync_path ()/vx_compose_fsync_original ()}"
vx_compose_fsync_path() {
    [[ "$1" != */.backup-recovery.* ]] || return 1
    vx_compose_fsync_original "$@"
}
vx_compose_lock_acquire alice app
if vx_compose_backup_recovery_write alice app; then
    fail "interrupted recovery-marker write reported success"
fi
vx_compose_lock_release
[[ ! -e "$(vx_compose_backup_recovery_path alice app)"
    && -z "$(find "$project_root/runtime" -maxdepth 1 -type f \
        -name '.backup-recovery.*' -print -quit)"
    && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running ]] \
    || fail "interrupted marker write changed runtime or left partial state"
unset -f vx_compose_fsync_path
eval "$original_fsync"
unset -f vx_compose_fsync_original

# A failure after the exact workload stopped remains a backup failure, but
# automatically restores the same healthy revision and clears its marker.
revision_manifest_before="$(sha256sum \
    "$project_root/revisions/000001/manifest.sha256")"
revision_images_before="$(sha256sum \
    "$project_root/revisions/000001/images.json")"
cp "$project_root/revisions/000001/manifest.sha256" \
    "$test_root/revision-manifest.authoritative"
vx_compose_volume_export() { return 1; }
forced_archive="$managed_backup_root/app-forced-failure.tar.gz"
if vx_compose_backup_project alice app "$forced_archive"; then
    fail "post-stop backup failure was reported as success"
fi
[[ "$(cat "$test_root/backup-lifecycle.log")" == $'stopped\nrunning'
    && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 1
    && "$(sha256sum \
        "$project_root/revisions/000001/manifest.sha256")" \
        == "$revision_manifest_before"
    && "$(sha256sum "$project_root/revisions/000001/images.json")" \
        == "$revision_images_before"
    && ! -e "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$forced_archive"
    && ! -e "$test_root/resolve-images.log" ]] \
    || fail "post-stop failure did not restore the exact prior revision"
tail -n +2 "$project_root/audit.log" | jq -e \
    'select(.ACTION == "backup" and .RESULT == "failed"
    and .REVISION == 1 and .DETAILS == "recovery=succeeded revision=1")' \
    >/dev/null \
    || fail "post-stop recovery result was not recorded truthfully"
jq -e '
    .ACTION == "backup" and .RESULT == "failed" and .REVISION == 1
    and .DETAILS == "recovery=succeeded revision=1"
    and (.DETAILS | length > 0 and length <= 256)
' "$project_root/runtime/last-operation.json" >/dev/null \
    || fail "failed backup operation did not retain bounded recovery success"

# A running-looking fast path still converges when network, volume, or route
# verification fails once. Recovery uses the marker-verified image file and
# never depends on registry/trust resolution after stop.
for fast_verifier in network volume routes; do
    vx_compose_lock_acquire alice app
    vx_compose_backup_recovery_write alice app
    vx_compose_lock_release
    printf 'fail-once\n' >"$test_root/$fast_verifier.mode"
    deploy_count_before="$(wc -l <"$test_root/backup-deploy.log")"
    vx_compose_lock_acquire alice app
    vx_compose_backup_recover alice app
    vx_compose_lock_release
    [[ "$(wc -l <"$test_root/backup-deploy.log")" \
            -eq $((deploy_count_before + 1))
        && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" \
            == running
        && ! -e "$(vx_compose_backup_recovery_path alice app)"
        && ! -e "$test_root/resolve-images.log" ]] \
        || fail "$fast_verifier fast-path drift did not converge exactly"
done
for required_verifier in runtime network volume health routes; do
    grep -Fxq "$required_verifier" "$test_root/postcondition.log" \
        || fail "recovery did not call $required_verifier verification"
done
: >"$test_root/backup-lifecycle.log"

backup_barrier="$test_root/backup-volume.fifo"
mkfifo "$backup_barrier"
exec {backup_barrier_fd}<>"$backup_barrier"
vx_compose_volume_export() {
    : >"$test_root/backup-volume.ready"
    IFS= read -r _ <&"$backup_barrier_fd"
}
interrupted_archive="$managed_backup_root/app-interrupted.tar.gz"
vx_compose_backup_project alice app "$interrupted_archive" &
interrupted_pid=$!
for _ in {1..1000}; do
    [[ -f "$test_root/backup-volume.ready" ]] && break
    sleep 0.01
done
[[ -f "$test_root/backup-volume.ready" ]] \
    || fail "real backup interruption fixture did not reach volume export"
recovery_marker="$(vx_compose_backup_recovery_path alice app)"
[[ "$(vx_compose_meta_get "$recovery_marker" SCHEMA)" == 2
    && "$(vx_compose_meta_get "$recovery_marker" REVISION)" == 1
    && "$(vx_compose_meta_get "$recovery_marker" IMAGE_AUTHORITY)" \
        == legacy-migration-v1
    && "$(vx_compose_meta_get \
        "$recovery_marker" REVISION_MANIFEST_SHA256)" \
        == "${revision_manifest_before%% *}"
    && "$(vx_compose_meta_get \
        "$recovery_marker" REVISION_IMAGES_SHA256)" \
        == "${revision_images_before%% *}"
    && "$(stat -c '%a' "$recovery_marker")" == 600 ]] \
    || fail "recovery marker did not bind exact production-shaped authority"
kill -TERM "$interrupted_pid"
wait "$interrupted_pid" 2>/dev/null || :
exec {backup_barrier_fd}>&-
[[ "$(cat "$test_root/backup-lifecycle.log")" == $'stopped\nrunning'
    && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$interrupted_archive" ]] \
    || fail "interrupted cold backup did not recover the running workload"
if find "$managed_backup_root" -maxdepth 1 -type d \
    -name '.compose-backup.*' -print -quit | grep -q .; then
    fail "interrupted backup left scoped staging"
fi

# SIGKILL cannot run traps; the next invocation's exact marker cleanup
# recovers runtime and removes only scoped orphan state.
vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
mkdir -p "$managed_backup_root/.compose-backup.stale"
: >"$project_root/runtime/.backup-validation.stale"
vx_compose_lock_acquire alice app
vx_compose_backup_orphan_cleanup alice app
vx_compose_lock_release
[[ ! -e "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$managed_backup_root/.compose-backup.stale"
    && ! -e "$project_root/runtime/.backup-validation.stale" ]] \
    || fail "next-run orphan recovery left stale backup state"

# A later invocation that cannot verify the marker-bound authority after a
# SIGKILL records genuine restore-required state. Restoring that authority
# makes the same orphan cleanup idempotently recover the exact runtime.
vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
printf '# later-invocation drift\n' \
    >>"$project_root/revisions/000001/manifest.sha256"
vx_compose_update_state alice app stopped
mkdir -p "$managed_backup_root/.compose-backup.retry"
vx_compose_lock_acquire alice app
if vx_compose_backup_orphan_cleanup alice app 2>/dev/null; then
    fail "next-run orphan cleanup accepted unverifiable recovery authority"
fi
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" \
        == restore-required
    && -f "$(vx_compose_backup_recovery_path alice app)"
    && -d "$managed_backup_root/.compose-backup.retry" ]] \
    || fail "failed next-run orphan recovery did not require restore"
install -m 0640 "$test_root/revision-manifest.authoritative" \
    "$project_root/revisions/000001/manifest.sha256"
vx_compose_lock_acquire alice app
vx_compose_backup_orphan_cleanup alice app
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$managed_backup_root/.compose-backup.retry" ]] \
    || fail "next-run orphan recovery retry was not idempotent"

# A persistent full-postcondition failure is the genuine automatic recovery
# failure boundary: only then does the backup caller retain restore-required.
: >"$test_root/backup-lifecycle.log"
vx_compose_stop() {
    vx_compose_update_state "$1" "$2" stopped
    printf 'stopped\n' >>"$test_root/backup-lifecycle.log"
    printf 'fail\n' >"$test_root/network.mode"
}
vx_compose_volume_export() { return 1; }
network_failure_archive="$managed_backup_root/app-network-failure.tar.gz"
if vx_compose_backup_project \
    alice app "$network_failure_archive" 2>/dev/null; then
    fail "backup ignored persistent network recovery failure"
fi
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" \
        == restore-required
    && -f "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$network_failure_archive" ]] \
    || fail "persistent postcondition failure did not require restore"
printf 'pass\n' >"$test_root/network.mode"
vx_compose_update_state alice app stopped
vx_compose_lock_acquire alice app
vx_compose_backup_recover alice app
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)" ]] \
    || fail "persistent postcondition recovery did not retry idempotently"

# If immutable revision evidence drifts after stop, automatic recovery fails
# closed and the caller retains both the marker and restore-required state.
cp "$project_root/revisions/000001/images.json" \
    "$test_root/revision-images.authoritative"
: >"$test_root/backup-lifecycle.log"
vx_compose_stop() {
    vx_compose_update_state "$1" "$2" stopped
    printf 'stopped\n' >>"$test_root/backup-lifecycle.log"
    chmod 0600 "$project_root/revisions/000001/images.json"
    jq '.api.IMAGE_ID =
        "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
        "$test_root/revision-images.authoritative" \
        >"$project_root/revisions/000001/images.json"
    chmod 0640 "$project_root/revisions/000001/images.json"
}
vx_compose_volume_export() { return 1; }
drift_archive="$managed_backup_root/app-drift-failure.tar.gz"
if vx_compose_backup_project alice app "$drift_archive" 2>/dev/null; then
    fail "backup accepted revision image drift during recovery"
fi
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" \
        == restore-required
    && -f "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$drift_archive"
    && "$(cat "$test_root/backup-lifecycle.log")" == stopped ]] \
    || fail "genuine recovery failure did not retain scoped recovery state"
install -m 0640 "$test_root/revision-images.authoritative" \
    "$project_root/revisions/000001/images.json"
vx_compose_update_state alice app stopped
vx_compose_lock_acquire alice app
vx_compose_backup_recover alice app
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)" ]] \
    || fail "restored authority could not complete idempotent recovery"

vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
printf '# interrupted\n' >>"$project_root/revisions/000001/manifest.sha256"
vx_compose_update_state alice app stopped
vx_compose_lock_acquire alice app
if vx_compose_backup_recover alice app 2>/dev/null; then
    fail "backup recovery accepted revision manifest drift"
fi
vx_compose_lock_release
[[ -f "$(vx_compose_backup_recovery_path alice app)" ]] \
    || fail "manifest drift discarded recovery authority"
install -m 0640 "$test_root/revision-manifest.authoritative" \
    "$project_root/revisions/000001/manifest.sha256"
vx_compose_lock_acquire alice app
vx_compose_backup_recover alice app
vx_compose_lock_release

# Informational OCI labels may change without changing the stable recovery
# identity. Trust identity may not: it fails closed until exact bytes return.
vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
cp "$project_root/images.json" "$test_root/current-images.authoritative"
jq '.api.OCI_LABELS.version = "informational-update"' \
    "$test_root/current-images.authoritative" \
    >"$project_root/images.json"
chmod 0640 "$project_root/images.json"
vx_compose_update_state alice app stopped
vx_compose_lock_acquire alice app
vx_compose_backup_recover alice app
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)" ]] \
    || fail "informational image metadata incorrectly blocked recovery"
install -m 0640 "$test_root/current-images.authoritative" \
    "$project_root/images.json"

vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
jq '.api.TRUST.POLICY_VERSION += 1' \
    "$test_root/current-images.authoritative" \
    >"$project_root/images.json"
chmod 0640 "$project_root/images.json"
vx_compose_update_state alice app stopped
vx_compose_lock_acquire alice app
if vx_compose_backup_recover alice app 2>/dev/null; then
    fail "backup recovery accepted trust identity drift"
fi
vx_compose_lock_release
[[ -f "$(vx_compose_backup_recovery_path alice app)" ]] \
    || fail "trust drift discarded recovery authority"
install -m 0640 "$test_root/current-images.authoritative" \
    "$project_root/images.json"
vx_compose_lock_acquire alice app
vx_compose_backup_recover alice app
vx_compose_lock_release

# Terminal audit failure leaves an idempotent marker but never downgrades an
# already restored runtime to restore-required. A later retry completes it.
original_audit="$(declare -f vx_compose_audit)"
recovery_canary='backup-recovery-sensitive-canary'
printf '%s\n' "$recovery_canary" >"$project_root/secrets/recovery-canary"
chmod 0600 "$project_root/secrets/recovery-canary"
vx_compose_lock_acquire alice app
vx_compose_backup_recovery_write alice app
vx_compose_lock_release
vx_compose_update_state alice app stopped
eval "${original_audit/vx_compose_audit ()/vx_compose_audit_original ()}"
vx_compose_audit() {
    if [[ "$2" == backup-recovery && "$3" == succeeded ]]; then
        return 1
    fi
    vx_compose_audit_original "$@"
}
mkdir -p "$managed_backup_root/.compose-backup.audit-retry"
vx_compose_lock_acquire alice app
if vx_compose_backup_orphan_cleanup alice app; then
    audit_recovery_result=0
else
    audit_recovery_result=$?
fi
vx_compose_lock_release
[[ "$audit_recovery_result" -eq 2
    && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && -f "$(vx_compose_backup_recovery_path alice app)"
    && -d "$managed_backup_root/.compose-backup.audit-retry" ]] \
    || fail "terminal audit failure falsely marked restored runtime unrestored"
unset -f vx_compose_audit
eval "$original_audit"
unset -f vx_compose_audit_original
vx_compose_lock_acquire alice app
vx_compose_backup_orphan_cleanup alice app
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && ! -e "$(vx_compose_backup_recovery_path alice app)"
    && ! -e "$managed_backup_root/.compose-backup.audit-retry" ]] \
    || fail "terminal evidence retry was not idempotent"
tail -n +2 "$project_root/audit.log" | jq -e '
    select(.ACTION == "backup-recovery" and .RESULT == "succeeded"
        and .REVISION == 1 and (.DETAILS | length > 0 and length <= 256))
' >/dev/null \
    || fail "terminal backup recovery audit is missing or unbounded"
jq -e '
    .ACTION == "backup-recovery" and .RESULT == "succeeded"
    and .REVISION == 1 and (.DETAILS | length > 0 and length <= 256)
' "$project_root/runtime/last-operation.json" >/dev/null \
    || fail "terminal backup recovery operation is not succeeded and bounded"
if grep -Fq "$recovery_canary" "$project_root/audit.log" \
    || grep -Fq "$recovery_canary" \
        "$project_root/runtime/last-operation.json"; then
    fail "backup recovery audit or operation exposed protected data"
fi

jq '.volumes={}' "$project_root/runtime/canonical.json" \
    >"$project_root/runtime/.canonical.interruption"
mv -- "$project_root/runtime/.canonical.interruption" \
    "$project_root/runtime/canonical.json"
vx_compose_update_state alice app stopped
eval "$original_stop"
eval "$original_deploy"
eval "$original_volume_export"
eval "$original_runtime_identity_preflight"
eval "$original_network_verify_runtime"
eval "$original_volume_verify_runtime"
eval "$original_health_collect"
eval "$original_routes_apply"
eval "$original_project_resolve_images"
unset -f vx_compose_test_verifier_result

# A legacy SHA-only source is projected into a digest-free public manifest and
# a private integrity manifest without rewriting the source during backup.
legacy_control="$test_root/legacy-control"
legacy_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
jq -n --arg sha "$legacy_sha" '{
    api_key: {
        NAME: "api_key",
        TARGET: "/run/secrets/api_key",
        SHA256: $sha,
        CREATED: "2026-01-01T00:00:00Z",
        ROTATED: "2026-01-02T00:00:00Z"
    }
}' >"$project_root/secrets.json"
printf '{}\n' >"$project_root/secret-integrity.json"
legacy_source_before="$(sha256sum "$project_root/secrets.json")"
vx_compose_backup_copy_control "$project_root" "$legacy_control"
[[ "$(sha256sum "$project_root/secrets.json")" == "$legacy_source_before" ]] \
    || fail "legacy backup rewrote source secret metadata"
jq -e '
    .api_key.NAME == "api_key"
    and (.api_key | has("SHA256") | not)
' "$legacy_control/secrets.json" >/dev/null \
    || fail "legacy backup exposed a digest in the public secret manifest"
jq -e --arg sha "$legacy_sha" '.api_key.SHA256 == $sha' \
    "$legacy_control/secret-integrity.json" >/dev/null \
    || fail "legacy backup discarded private secret integrity"
legacy_archive="$test_root/legacy-app.tar.gz"
vx_compose_backup_project alice app "$legacy_archive"
vx_compose_restore_archive_validate \
    alice app "$legacy_archive" "$test_root/legacy-validated"
jq -e 'all(.[]; has("SHA256") | not)' \
    "$test_root/legacy-validated/control/secrets.json" >/dev/null \
    || fail "validated legacy backup exposed a public digest"
jq -e --arg sha "$legacy_sha" '.api_key.SHA256 == $sha' \
    "$test_root/legacy-validated/control/secret-integrity.json" >/dev/null \
    || fail "validated legacy backup lost private integrity"

encrypted_fixture="$test_root/encrypted-fixture"
mkdir -p "$encrypted_fixture/control" "$encrypted_fixture/plain"
printf 'encrypted-restore-canary\n' >"$encrypted_fixture/plain/api_key"
chmod 0600 "$encrypted_fixture/plain/api_key"
secret_sha="$(sha256sum "$encrypted_fixture/plain/api_key" | awk '{print $1}')"
jq -n --arg sha "$secret_sha" \
    '{api_key: {SHA256: $sha}}' \
    >"$encrypted_fixture/control/secret-integrity.json"
jq -n \
    '{api_key: {
        NAME: "api_key",
        TARGET: "/run/secrets/api_key",
        STATUS: "available",
        VERSION: "00000000000000000000000000000001",
        CREATED: "2026-01-01T00:00:00Z",
        ROTATED: ""
    }}' >"$encrypted_fixture/control/secrets.json"
tar -czf "$encrypted_fixture/encrypted-secrets.age" \
    -C "$encrypted_fixture/plain" .
identity_file="$test_root/identity.txt"
printf 'synthetic identity\n' >"$identity_file"
chmod 0600 "$identity_file"
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
# The single-quoted lines intentionally write a separate test executable.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'output=' \
    'input=' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output) output=$2; shift 2 ;;' \
    '    --identity) shift 2 ;;' \
    '    --decrypt) shift ;;' \
    '    *) input=$1; shift ;;' \
    '  esac' \
    'done' \
    'cp -- "$input" "$output"' >"$fake_bin/age"
chmod 0755 "$fake_bin/age"
old_path="$PATH"
PATH="$fake_bin:$PATH"
VX_DOCKER_AGE_IDENTITY_FILE="$identity_file"
vx_compose_restore_prepare_secrets \
    alice app "$encrypted_fixture" "$test_root/restored-secrets"
legacy_fixture="$test_root/legacy-encrypted-fixture"
cp -a -- "$encrypted_fixture" "$legacy_fixture"
jq -n --arg sha "$secret_sha" \
    '{api_key: {NAME: "api_key", SHA256: $sha}}' \
    >"$legacy_fixture/control/secrets.json"
printf '{}\n' >"$legacy_fixture/control/secret-integrity.json"
vx_compose_restore_prepare_secrets \
    alice app "$legacy_fixture" "$test_root/legacy-restored-secrets"
PATH="$old_path"
unset VX_DOCKER_AGE_IDENTITY_FILE
[[ "$(cat "$test_root/restored-secrets/api_key")" == encrypted-restore-canary ]] \
    || fail "encrypted secret payload was not restored"
[[ "$(stat -c '%a' "$test_root/restored-secrets/api_key")" == 600 ]] \
    || fail "restored encrypted secret mode is wrong"
[[ "$(cat "$test_root/legacy-restored-secrets/api_key")" \
    == encrypted-restore-canary ]] \
    || fail "legacy restore preferred empty private integrity metadata"

# Applying the same legacy transition moves the digest into private metadata
# and leaves no digest in the installed public metadata.
legacy_install_root="$test_root/legacy-install"
mkdir -p "$legacy_install_root/secrets" "$legacy_install_root/incoming"
printf 'prior\n' >"$legacy_install_root/secrets/prior"
cp "$encrypted_fixture/plain/api_key" "$legacy_install_root/incoming/api_key"
vx_compose_restore_install_secrets \
    "$legacy_install_root" "$legacy_install_root/incoming" \
    "$legacy_fixture/control/secrets.json" \
    "$legacy_fixture/control/secret-integrity.json"
jq -e 'all(.[]; has("SHA256") | not)' \
    "$legacy_install_root/secrets.json" >/dev/null \
    || fail "legacy restore installed a public integrity digest"
jq -e --arg sha "$secret_sha" '.api_key.SHA256 == $sha' \
    "$legacy_install_root/secret-integrity.json" >/dev/null \
    || fail "legacy restore transition discarded private integrity"

# Restoring after rollback/history selects max finalized + 1 and never nests
# into or mutates an existing immutable revision directory.
mkdir -p "$project_root/revisions/000005"
printf 'historical\n' >"$project_root/revisions/000005/marker"
restore_candidate="$test_root/restore-candidate"
restore_extracted="$test_root/restore-extracted"
mkdir -p "$restore_candidate" "$restore_extracted/control" \
    "$restore_extracted/restore-secrets"
cp "$project_root/compose.yaml" "$restore_candidate/compose.yaml"
cp "$project_root/runtime/canonical.json" "$restore_candidate/canonical.json"
cp "$project_root/policy.conf" "$restore_candidate/policy.conf"
printf '{}\n' >"$restore_candidate/images.json"
printf '{}\n' >"$restore_candidate/routes.conf"
sha256sum "$restore_candidate/canonical.json" \
    >"$restore_candidate/canonical.sha256"
printf '{}\n' >"$restore_extracted/control/images.json"
printf '{}\n' >"$restore_extracted/control/routes.conf"
printf '{}\n' >"$restore_extracted/control/secrets.json"
vx_compose_lock_acquire alice app
vx_compose_restore_install_active \
    alice app "$restore_candidate" "$restore_extracted"
vx_compose_lock_release
[[ "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 6
    && -f "$project_root/revisions/000006/manifest.sha256"
    && "$(cat "$project_root/revisions/000005/marker")" == historical ]] \
    || fail "restore collided with or mutated historical revisions"

printf '{}\n' >"$project_root/runtime/routes.pending.json"
vx_compose_restore_pending_routes_clear "$project_root"
[[ ! -e "$project_root/runtime/routes.pending.json" ]] \
    || fail "successful restore retained stale pending route intent"

# Apply revalidation and installation share the same project+owner-quota lock.
# A competing mutation cannot enter while restore preparation is blocked.
restore_barrier="$test_root/restore.fifo"
mkfifo "$restore_barrier"
: >"$test_root/restore.ready"
rm -f -- "$test_root/restore-competitor.entered"
vx_compose_restore_archive_validate() {
    mkdir -p "$4"
    jq -n '{STATE:"stopped"}' >"$4/manifest.json"
}
vx_compose_restore_prepare() {
    printf 'ready\n' >"$test_root/restore.ready"
    IFS= read -r _ <"$restore_barrier"
    mkdir -p "$4"
}
original_restore_project_existing="$(declare -f vx_compose_restore_project_existing)"
vx_compose_restore_project_existing() { :; }
vx_compose_refresh_counters() { :; }
vx_compose_restore_project alice app "$archive" apply &
restore_pid=$!
for _ in {1..100}; do
    [[ -s "$test_root/restore.ready" ]] && break
    sleep 0.01
done
(
    vx_compose_lock_acquire alice app
    printf 'entered\n' >"$test_root/restore-competitor.entered"
    vx_compose_lock_release
) &
restore_competitor_pid=$!
sleep 0.1
[[ ! -e "$test_root/restore-competitor.entered" ]] \
    || fail "competing mutation crossed restore apply barrier"
printf 'release\n' >"$restore_barrier"
wait "$restore_pid" "$restore_competitor_pid"
[[ -s "$test_root/restore-competitor.entered"
    && -z "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]] \
    || fail "restore did not release serialized locks after apply"

# A restore into an absent control root treats retained binds/volumes as prior
# data: audit failure restores them exactly, while success replaces them
# exactly and installs the archived variables file.
new_candidate="$test_root/new-candidate"
new_extracted="$test_root/new-extracted"
mkdir -p "$new_candidate" "$new_extracted/control" \
    "$new_extracted/restore-secrets" "$new_extracted/binds/config" \
    "$new_extracted/volumes" "$test_root/new-volume"
printf 'ARCHIVE_VALUE=yes\n' >"$new_candidate/variables.env"
printf '{"services":{},"volumes":{"state":{}}}\n' \
    >"$new_candidate/canonical.json"
printf '{}\n' >"$new_candidate/images.json"
printf 'new-bind\n' >"$new_extracted/binds/config/value.txt"
printf 'new-volume\n' >"$test_root/new-volume/value.txt"
tar -czf "$new_extracted/volumes/state.tar.gz" \
    -C "$test_root/new-volume" .
printf "PROFILE='standard'\n" >"$new_extracted/control/project.conf"
printf '{}\n' >"$new_extracted/control/secrets.json"
new_data_root="$(vx_compose_project_data_root alice restored)"
mkdir -p "$new_data_root/binds/config" "$test_root/fake-volume"
printf 'old-bind\n' >"$new_data_root/binds/config/value.txt"
printf 'old-volume\n' >"$test_root/fake-volume/value.txt"
printf 'stale-volume\n' >"$test_root/fake-volume/stale.txt"
fake_restore_docker="$test_root/fake-restore-docker"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ " $* " != *" volume inspect "* ]] || exit 0' \
    'exit 0' >"$fake_restore_docker"
chmod 0755 "$fake_restore_docker"
vx_compose_store_new() {
    local root
    root="$(vx_compose_project_root "$1" "$2")"
    mkdir -p "$root/runtime" "$root/secrets"
    cp "$4/canonical.json" "$root/runtime/canonical.json"
    cp "$4/images.json" "$root/images.json"
    : >"$root/variables.env"
}
vx_compose_restore_install_secrets() { :; }
vx_compose_volume_export() {
    tar -czf "$4" -C "$test_root/fake-volume" .
}
vx_compose_volume_create() { mkdir -p "$test_root/fake-volume"; }
vx_compose_volume_clear() {
    find "$test_root/fake-volume" -mindepth 1 -delete
}
vx_compose_volume_import() {
    tar -xzf "$4" -C "$test_root/fake-volume"
}
vx_compose_volume_inspect() { [[ -d "$test_root/fake-volume" ]]; }
vx_compose_volume_remove() { rm -rf -- "$test_root/fake-volume"; }
vx_compose_deploy() { :; }
vx_compose_stop() { :; }
vx_compose_runtime_identity_preflight() { printf 'incomplete\n'; }
vx_compose_invoke() { :; }
vx_compose_remove_control_root() {
    rm -rf -- "$(vx_compose_project_root "$1" "$2")"
}
vx_compose_docker_bin() { printf '%s\n' "$fake_restore_docker"; }
vx_compose_audit() { return 1; }
if vx_compose_restore_project_new \
    alice restored "$new_extracted" "$new_candidate" running; then
    fail "new restore ignored terminal evidence failure"
fi
[[ "$(cat "$new_data_root/binds/config/value.txt")" == old-bind
    && "$(cat "$test_root/fake-volume/value.txt")" == old-volume
    && -f "$test_root/fake-volume/stale.txt"
    && ! -e "$(vx_compose_project_root alice restored)" ]] \
    || fail "failed new restore did not preserve retained data exactly"
vx_compose_audit() { :; }
vx_compose_restore_project_new \
    alice restored "$new_extracted" "$new_candidate" running
[[ "$(cat "$new_data_root/binds/config/value.txt")" == new-bind
    && "$(cat "$test_root/fake-volume/value.txt")" == new-volume
    && ! -e "$test_root/fake-volume/stale.txt"
    && "$(cat "$(vx_compose_project_root alice restored)/variables.env")" \
        == ARCHIVE_VALUE=yes ]] \
    || fail "successful new restore was not data/control exact"

chmod 0700 "$project_root/image-evidence-migration"
chmod 0600 "$project_root/image-evidence-migration"/*
vx_compose_remove_control_root alice app
[[ ! -e "$project_root" && -s "$managed_archive" ]] \
    || fail "project removal deleted its managed backup"

# Non-simple restores secure the bind root without trying to normalize
# simple-form leaves; simple restores do both.
restore_bind_candidate="$test_root/restore-bind-candidate"
mkdir -p "$restore_bind_candidate"
printf '{}\n' >"$restore_bind_candidate/canonical.json"
restore_bind_secure_calls=0
restore_bind_normalize_calls=0
vx_compose_bind_root_secure() {
    restore_bind_secure_calls=$((restore_bind_secure_calls + 1))
}
vx_compose_simple_bind_leaves_normalize() {
    restore_bind_normalize_calls=$((restore_bind_normalize_calls + 1))
}
vx_compose_restore_candidate_binds_secure \
    alice app "$restore_bind_candidate"
[[ "$restore_bind_secure_calls" -eq 1
    && "$restore_bind_normalize_calls" -eq 0 ]] \
    || fail "non-simple restore incorrectly rejected secured bind traversal"
printf '{}\n' >"$restore_bind_candidate/simple.json"
vx_compose_restore_candidate_binds_secure \
    alice app "$restore_bind_candidate"
[[ "$restore_bind_secure_calls" -eq 2
    && "$restore_bind_normalize_calls" -eq 1 ]] \
    || fail "simple restore omitted bind-leaf normalization"

# Backup policy installation is part of the existing-project restore
# transaction. A late injected write failure takes the normal rollback path
# and preserves exact prior control, policy, runtime, and bind bytes.
eval "$original_restore_project_existing"
rollback_root="$(vx_compose_project_root alice rollback)"
rollback_data="$(vx_compose_project_data_root alice rollback)"
rollback_binds="$(vx_compose_bind_root alice rollback)"
mkdir -p "$rollback_root/runtime" "$rollback_root/revisions/000001" \
    "$rollback_root/secrets" "$rollback_data" "$rollback_binds/config"
printf 'services: {}\n' >"$rollback_root/compose.yaml"
printf '{"services":{},"volumes":{}}\n' \
    >"$rollback_root/runtime/canonical.json"
printf "OWNER='alice'\nPROJECT='rollback'\nREVISION='1'\nSTATE='stopped'\nPROFILE='standard'\nCREATED='2026-01-01T00:00:00Z'\nCANONICAL_SHA256='prior'\n" \
    >"$rollback_root/project.conf"
printf "POLICY_SCHEMA='1'\nPROFILE_VERSION='1'\nVALIDATOR_VERSION='2'\n" \
    >"$rollback_root/policy.conf"
printf 'PRIOR=yes\n' >"$rollback_root/variables.env"
printf '{}\n' >"$rollback_root/images.json"
printf '{}\n' >"$rollback_root/routes.conf"
printf 'prior-secret\n' >"$rollback_root/secrets/prior"
printf 'prior-bind\n' >"$rollback_binds/config/value.txt"
vx_compose_backup_policy_write \
    alice rollback yes daily@01:00 7 4 no none 3600 86400 ''
rollback_candidate="$test_root/rollback-candidate"
rollback_extracted="$test_root/rollback-extracted"
mkdir -p "$rollback_candidate" "$rollback_extracted/restore-secrets"
cp "$rollback_root/compose.yaml" "$rollback_candidate/compose.yaml"
cp "$rollback_root/runtime/canonical.json" "$rollback_candidate/canonical.json"
cp "$rollback_root/policy.conf" "$rollback_candidate/policy.conf"
cp "$rollback_root/images.json" "$rollback_candidate/images.json"
cp "$rollback_root/routes.conf" "$rollback_candidate/routes.conf"
printf 'CANDIDATE=yes\n' >"$rollback_candidate/variables.env"
archived_rollback_policy="$test_root/rollback-archived-policy.conf"
cp "$rollback_root/backup-policy.conf" "$archived_rollback_policy"
sed -i "s/SCHEDULE='daily@01:00'/SCHEDULE='daily@02:00'/" \
    "$archived_rollback_policy"
vx_compose_backup_policy_sanitize_to \
    "$archived_rollback_policy" "$rollback_candidate/backup-policy.conf"
rollback_before="$(
    sha256sum \
        "$rollback_root/compose.yaml" "$rollback_root/project.conf" \
        "$rollback_root/policy.conf" "$rollback_root/variables.env" \
        "$rollback_root/runtime/canonical.json" \
        "$rollback_root/backup-policy.conf" "$rollback_binds/config/value.txt"
)"
vx_compose_active_revision_verify() { :; }
vx_compose_restore_next_revision() { printf '2\n'; }
vx_compose_network_verify_runtime() { :; }
vx_compose_volume_verify_runtime() { :; }
vx_compose_runtime_identity_preflight() { printf 'complete\n'; }
vx_compose_restore_candidate_binds_secure() { :; }
vx_compose_restore_install_secrets() { :; }
vx_compose_invoke() { :; }
vx_compose_deploy() { :; }
vx_compose_stop() { :; }
vx_compose_audit() { :; }
vx_compose_restore_install_active() {
    fail "restore committed revision after policy installation failure"
}
VX_COMPOSE_TEST_RESTORE_BACKUP_POLICY_FAIL=yes
export VX_COMPOSE_TEST_RESTORE_BACKUP_POLICY_FAIL
if vx_compose_restore_project_existing \
    alice rollback "$rollback_extracted" "$rollback_candidate" stopped; then
    fail "restore ignored injected backup policy write failure"
fi
unset VX_COMPOSE_TEST_RESTORE_BACKUP_POLICY_FAIL
[[ "$(sha256sum \
        "$rollback_root/compose.yaml" "$rollback_root/project.conf" \
        "$rollback_root/policy.conf" "$rollback_root/variables.env" \
        "$rollback_root/runtime/canonical.json" \
        "$rollback_root/backup-policy.conf" "$rollback_binds/config/value.txt"
    )" == "$rollback_before"
    && ! -e "$rollback_root/revisions/000002" ]] \
    || fail "late policy failure did not preserve exact prior project state"

# A post-commit failure recovers with snapshotted active routes while pending
# intent stays absent, then reinstates the exact pending bytes and metadata.
printf '{"prior":{"HOST_PORT":18080}}\n' >"$rollback_root/routes.conf"
printf '{}\n' >"$rollback_root/runtime/routes.pending.json"
chmod 0640 "$rollback_root/runtime/routes.pending.json"
sed -i "s/STATE='stopped'/STATE='running'/" "$rollback_root/project.conf"
printf '{"candidate":{"HOST_PORT":18081}}\n' \
    >"$rollback_candidate/routes.conf"
postcommit_before="$(
    sha256sum \
        "$rollback_root/compose.yaml" "$rollback_root/project.conf" \
        "$rollback_root/policy.conf" "$rollback_root/variables.env" \
        "$rollback_root/runtime/canonical.json" \
        "$rollback_root/routes.conf" \
        "$rollback_root/runtime/routes.pending.json" \
        "$rollback_root/backup-policy.conf" "$rollback_binds/config/value.txt"
)"
postcommit_pending_stat="$(stat -c '%u:%g:%a' \
    "$rollback_root/runtime/routes.pending.json")"
restore_deploy_calls=0
restore_recovery_routes_exact=no
vx_compose_deploy() {
    restore_deploy_calls=$((restore_deploy_calls + 1))
    if [[ "$restore_deploy_calls" -eq 2 \
        && "${VX_COMPOSE_ROUTES_FILE_OVERRIDE:-}" \
            == "$rollback_root/routes.conf" \
        && -f "${VX_COMPOSE_ROUTES_ACTIVE_FILE_OVERRIDE:-}" \
        && "$(cat "$VX_COMPOSE_ROUTES_ACTIVE_FILE_OVERRIDE")" \
            == "$(cat "$rollback_candidate/routes.conf")" \
        && "${VX_COMPOSE_ROUTES_DEFER_COMMIT:-}" == yes \
        && ! -e "$rollback_root/runtime/routes.pending.json" ]]; then
        restore_recovery_routes_exact=yes
    fi
}
vx_compose_restore_install_active() {
    install -d -m 0750 "$rollback_root/revisions/000002"
    install -m 0640 "$rollback_candidate/routes.conf" \
        "$rollback_root/routes.conf"
}
restore_audit_calls=0
vx_compose_audit() {
    restore_audit_calls=$((restore_audit_calls + 1))
    [[ "$restore_audit_calls" -ne 1 ]]
}
if vx_compose_restore_project_existing \
    alice rollback "$rollback_extracted" "$rollback_candidate" running; then
    fail "restore ignored injected post-commit evidence failure"
fi
[[ "$(sha256sum \
        "$rollback_root/compose.yaml" "$rollback_root/project.conf" \
        "$rollback_root/policy.conf" "$rollback_root/variables.env" \
        "$rollback_root/runtime/canonical.json" \
        "$rollback_root/routes.conf" \
        "$rollback_root/runtime/routes.pending.json" \
        "$rollback_root/backup-policy.conf" "$rollback_binds/config/value.txt"
    )" == "$postcommit_before"
    && "$(stat -c '%u:%g:%a' \
        "$rollback_root/runtime/routes.pending.json")" \
        == "$postcommit_pending_stat"
    && "$restore_recovery_routes_exact" == yes \
    && "$restore_deploy_calls" -eq 2 \
    && ! -e "$rollback_root/revisions/000002" ]] \
    || fail "post-commit failure did not recover exact routes and pending intent"

echo "Compose project backup tests passed."
