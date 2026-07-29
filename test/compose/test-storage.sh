#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" "$HOMEDIR/alice" "$HOMEDIR/bob"
for owner in alice bob; do
    {
        printf "DOCKER_PROJECTS='4'\n"
        printf "DOCKER_SERVICES='8'\n"
        printf "DOCKER_CPUS='4.000'\n"
        printf "DOCKER_MEMORY_MB='4096'\n"
        printf "DOCKER_PIDS='512'\n"
        printf "DOCKER_STORAGE_MB='128'\n"
        printf "DOCKER_PORTS='8'\n"
        printf "DOCKER_SECRETS='0'\n"
        printf "DOCKER_VOLUMES='0'\n"
    } >"$VESTA/data/users/$owner/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(vx_compose_runtime_name alice app)" == "vx-alice-app" ]] \
    || fail "stable runtime project name is wrong"
vx_compose_project_is_valid app || fail "valid project key was rejected"
if vx_compose_project_is_valid 'Bad/App'; then
    fail "unsafe project key was accepted"
fi

candidate="$test_root/candidate"
mkdir -p "$candidate"
printf '%s\n' 'services: {}' >"$candidate/compose.yaml"
printf '%s\n' \
    '{"name":"vx-alice-app","services":{"web":{"image":"example.test/web:v1"}}}' \
    >"$candidate/canonical.json"
sha256sum "$candidate/canonical.json" >"$candidate/canonical.sha256"
{
    printf "POLICY_SCHEMA='1'\n"
    printf "VALIDATOR_VERSION='2'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='2'\n"
    printf "SERVICES='1'\n"
    printf "CPUS_MILLI='0'\n"
    printf "MEMORY_MB='0'\n"
    printf "PIDS='0'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"
printf '{}\n' >"$candidate/images.json"
printf '{"CPU_PCT":81,"MEMORY_PCT":82,"NETWORK_MBPS":83,"NOTIFY":true}\n' \
    >"$candidate/alerts.conf"
printf '%s\n' \
    '{"GENERATED":true,"OWNER":"alice","NAME":"app","IMAGE":"example.test/web:v1"}' \
    >"$candidate/simple.json"
chmod 0600 "$candidate/simple.json"

vx_compose_store_new alice app standard "$candidate"
project_root="$(vx_compose_project_root alice app)"

[[ -f "$project_root/compose.yaml" ]] || fail "canonical Compose file was not stored"
[[ -f "$project_root/runtime/canonical.json" ]] || fail "canonical JSON was not stored"
[[ -f "$project_root/revisions/000001/compose.yaml" ]] || fail "first revision was not stored"
(
    cd "$project_root/revisions/000001"
    sha256sum --strict -c manifest.sha256 >/dev/null
) || fail "first revision manifest is not complete and verifiable"
manifest_members="$(awk '{print $2}' \
    "$project_root/revisions/000001/manifest.sha256" | paste -sd ' ' -)"
[[ "$manifest_members" == \
    "alerts.conf canonical.json compose.yaml images.json policy.conf routes.conf simple.json" ]] \
    || fail "first revision manifest members are incomplete or unsorted"
cmp -s "$project_root/alerts.conf" \
    "$project_root/revisions/000001/alerts.conf" \
    || fail "active alert policy was not revisioned atomically"
[[ -f "$project_root/simple.json"
    && -f "$project_root/revisions/000001/simple.json" ]] \
    || fail "simple-form provenance was not revisioned"
vx_compose_inspect_json alice app | jq -e \
    '.SIMPLE.GENERATED == true and .SIMPLE.IMAGE == "example.test/web:v1"' \
    >/dev/null \
    || fail "simple-form provenance is missing from safe project inspection"
[[ "$(vx_compose_meta_get "$project_root/project.conf" OWNER)" == alice ]] \
    || fail "owner metadata is wrong"
[[ "$(vx_compose_meta_get "$project_root/project.conf" COMPOSE_PROJECT)" == vx-alice-app ]] \
    || fail "runtime name metadata is wrong"
[[ "$(stat -c '%a' "$project_root")" == 750 ]] || fail "project directory mode is wrong"
[[ "$(stat -c '%a' "$project_root/variables.env")" == 600 ]] \
    || fail "controlled env file mode is wrong"
[[ "$(stat -c '%a' "$project_root/project.conf")" == 640 ]] \
    || fail "metadata mode is wrong"
[[ "$(stat -c '%a' "$project_root/secrets")" == 700 ]] \
    || fail "protected secrets directory mode is wrong"
[[ -f "$(vx_compose_lock_path alice app)" ]] \
    || fail "project lock was not created"

[[ ! -e "$(vx_compose_project_root bob app)" ]] \
    || fail "project leaked into another owner's storage"
if vx_compose_require_project bob app 2>/dev/null; then
    fail "cross-owner project lookup succeeded"
fi

if VX_COMPOSE_TEST_STORE_NEW_FAIL_DATA_ROOT=yes \
    vx_compose_store_new alice fail-create standard "$candidate"; then
    fail "post-publish data-root failure reported create success"
fi
failed_create_root="$(vx_compose_project_root alice fail-create)"
[[ -d "$failed_create_root"
    && "$(vx_compose_meta_get "$failed_create_root/project.conf" STATE)" \
        == restore-required
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}"
    && -z "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]] \
    || fail "failed create did not retain explicit recovery state/release locks"

printf '%s\n' 'services: {web: {image: example.test/web:v2}}' >"$candidate/compose.yaml"
printf '%s\n' '{"name":"vx-alice-app","services":{"web":{"image":"example.test/web:v2"}}}' \
    >"$candidate/canonical.json"
sha256sum "$candidate/canonical.json" >"$candidate/canonical.sha256"
printf '{"CPU_PCT":71,"MEMORY_PCT":72,"NETWORK_MBPS":73,"NOTIFY":false}\n' \
    >"$candidate/alerts.conf"
rm -f -- "$candidate/simple.json"

# Critical global lock acquisition failures are terminal and release every
# previously acquired lock without publishing a revision.
ports_lock_definition="$(declare -f vx_compose_ports_lock_acquire)"
vx_compose_ports_lock_acquire() { return 1; }
if vx_compose_store_revision alice app "$candidate" validated; then
    fail "failed global port-lock acquisition was ignored"
fi
unset -f vx_compose_ports_lock_acquire
eval "$ports_lock_definition"
[[ ! -e "$project_root/revisions/000002"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}" ]] \
    || fail "port-lock acquisition failure published state or leaked a lock"

quota_lock_definition="$(declare -f vx_compose_owner_quota_lock_acquire)"
vx_compose_owner_quota_lock_acquire() { return 1; }
if vx_compose_store_revision alice app "$candidate" validated; then
    fail "failed owner-quota lock acquisition was ignored"
fi
unset -f vx_compose_owner_quota_lock_acquire
eval "$quota_lock_definition"
[[ ! -e "$project_root/revisions/000002"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}"
    && -z "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]] \
    || fail "quota-lock acquisition failure published state or leaked a lock"

vx_compose_store_revision alice app "$candidate" validated

[[ "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 2 ]] \
    || fail "revision did not increment"
[[ -f "$project_root/revisions/000002/compose.yaml" ]] \
    || fail "second immutable revision is missing"
cmp -s "$candidate/alerts.conf" "$project_root/alerts.conf" \
    && cmp -s "$project_root/alerts.conf" \
        "$project_root/revisions/000002/alerts.conf" \
    || fail "candidate alert policy did not commit with its revision"
(
    cd "$project_root/revisions/000002"
    sha256sum --strict -c manifest.sha256 >/dev/null
) || fail "second revision manifest is not verifiable"
if touch "$project_root/revisions/000002/.mutation-probe" \
    && vx_compose_revision_manifest_verify \
        "$project_root/revisions/000002" 2>/dev/null; then
    fail "finalized revision accepted an unmanifested member"
fi
rm -f -- "$project_root/revisions/000002/.mutation-probe"
[[ -f "$project_root/revisions/000001/compose.yaml" ]] \
    || fail "first revision was overwritten"
[[ ! -e "$project_root/simple.json"
    && ! -e "$project_root/revisions/000002/simple.json" ]] \
    || fail "advanced revision retained stale simple-form provenance"

created="$(vx_compose_meta_get "$project_root/project.conf" CREATED)"
cp -p -- "$project_root/revisions/000001/compose.yaml" \
    "$project_root/compose.yaml"
cp -p -- "$project_root/revisions/000001/canonical.json" \
    "$project_root/runtime/canonical.json"
cp -p -- "$project_root/revisions/000001/policy.conf" \
    "$project_root/policy.conf"
cp -p -- "$project_root/revisions/000001/routes.conf" \
    "$project_root/routes.conf"
cp -p -- "$project_root/revisions/000001/images.json" \
    "$project_root/images.json"
cp -p -- "$project_root/revisions/000001/alerts.conf" \
    "$project_root/alerts.conf"
cp -p -- "$project_root/revisions/000001/simple.json" \
    "$project_root/simple.json"
rollback_sha="$(sha256sum "$project_root/runtime/canonical.json" | awk '{print $1}')"
vx_compose_write_metadata \
    "$project_root" alice app standard rolling-back 1 \
    "$created" "$(vx_compose_now)" "$rollback_sha"
printf '%s\n' 'services: {web: {image: example.test/web:v3}}' \
    >"$candidate/compose.yaml"
printf '%s\n' \
    '{"name":"vx-alice-app","services":{"web":{"image":"example.test/web:v3"}}}' \
    >"$candidate/canonical.json"
sha256sum "$candidate/canonical.json" >"$candidate/canonical.sha256"
printf '{"CPU_PCT":61,"MEMORY_PCT":62,"NETWORK_MBPS":63,"NOTIFY":true}\n' \
    >"$candidate/alerts.conf"
vx_compose_store_revision alice app "$candidate" validated
[[ "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 3
    && -f "$project_root/revisions/000003/compose.yaml" ]] \
    || fail "post-rollback update did not preserve immutable revision history"

# A failure after candidate active files begin switching restores the complete
# prior active set before transaction recovery is allowed to converge it.
snapshot="$test_root/active-snapshot"
mkdir -p "$snapshot/runtime"
for name in \
    compose.yaml project.conf policy.conf routes.conf images.json alerts.conf; do
    [[ ! -f "$project_root/$name" ]] \
        || cp -p -- "$project_root/$name" "$snapshot/$name"
done
cp -p -- "$project_root/runtime/canonical.json" "$snapshot/runtime/canonical.json"
transaction_root="$project_root/runtime/.storage-test-transaction"
vx_compose_lock_acquire alice app
vx_compose_stage_candidate_revision \
    alice app "$candidate" "$transaction_root" "$project_root/routes.conf"
if VX_COMPOSE_TEST_COMMIT_FAIL_AFTER_ACTIVE=yes \
    vx_compose_commit_staged_revision \
        alice app "$transaction_root" 4 running; then
    fail "injected post-switch commit failure reported success"
fi
vx_compose_lock_release
for name in \
    compose.yaml project.conf policy.conf routes.conf images.json alerts.conf; do
    [[ ! -f "$snapshot/$name" ]] \
        || cmp -s "$snapshot/$name" "$project_root/$name" \
        || fail "post-switch failure did not restore prior $name"
done
cmp -s "$snapshot/runtime/canonical.json" \
    "$project_root/runtime/canonical.json" \
    || fail "post-switch failure did not restore prior canonical JSON"
[[ "$(vx_compose_meta_get "$project_root/project.conf" REVISION)" == 3 ]] \
    || fail "post-switch failure published candidate metadata"
[[ ! -e "$project_root/revisions/000004"
    && -z "$(find "$project_root" "$project_root/runtime" -maxdepth 1 \
        \( -name '*.new' -o -name '.active-snapshot.*' \) -print -quit)" ]] \
    || fail "failed commit retained an unpublished revision or temp files"

echo "Compose storage tests passed."
