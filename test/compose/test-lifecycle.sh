#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
cleanup() {
    chmod -R u+w "$test_root" 2>/dev/null || :
    rm -rf -- "$test_root"
}
trap cleanup EXIT

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
        printf "DOCKER_SECRETS='2'\n"
        printf "DOCKER_VOLUMES='0'\n"
    } >"$VESTA/data/users/$owner/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_docker="$test_root/fake-docker"
docker_log="$test_root/docker.log"
printf '%s\n' 'sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe' >"$test_root/image-id"
printf '%s\n' amd64 >"$test_root/image-architecture"
printf '%s\n' absent >"$test_root/runtime-mode"
cat >"$fake_docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
VX_TEST_DOCKER_LOG="$(dirname -- "$0")/docker.log"
{
    printf 'ENV_HOME=%s\n' "${HOME-}"
    printf 'ENV_DOCKER_CONFIG=%s\n' "${DOCKER_CONFIG-}"
    printf 'ENV_LEAK=%s\n' "${LEAK_CANARY-}"
    printf 'ARG=%s\n' "$@"
    printf '%s\n' END
} >>"$VX_TEST_DOCKER_LOG"
previous=
for argument in "$@"; do
    if [[ "$previous" == --file && -f "$argument" ]]; then
        if jq -e '
            .services.web.image == "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"
            and .services.web.labels["vx.revision"] == "1"
            and .services.web.labels["vx.image-id"] == "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"
        ' "$argument" >/dev/null 2>&1; then
            printf '%s\n' IDENTITY_OK >>"$VX_TEST_DOCKER_LOG"
        fi
    fi
    previous="$argument"
done
if [[ -f "$(dirname -- "$0")/fail-compose" ]] \
    && [[ " $* " == *" compose "* ]] \
    && [[ " $* " == *" up "* ]]; then
    printf '%s\n' 'docker failed with lifecycle-secret-canary' >&2
    exit 42
fi
if [[ " $* " == *" compose "* ]] \
    && { [[ " $* " == *" up "* ]] \
        || [[ " $* " == *" start "* ]] \
        || [[ " $* " == *" restart "* ]]; } \
    && [[ ! -f "$(dirname -- "$0")/preserve-runtime-mode" ]]; then
    printf '%s\n' complete >"$(dirname -- "$0")/runtime-mode"
fi
if [[ " $* " == *" image inspect "* ]]; then
    image_id="$(cat "$(dirname -- "$0")/image-id")"
    architecture="$(cat "$(dirname -- "$0")/image-architecture")"
    printf \
        '{"Id":"%s","RepoTags":["example.test/web:v1"],"RepoDigests":["example.test/web@%s"],"Architecture":"%s","Os":"linux"}\n' \
        "$image_id" "$image_id" "$architecture"
elif [[ " $* " == *" ps -aq "* ]] \
    && [[ " $* " == *" label=com.docker.compose.project=vx-alice-web "* ]]; then
    mode="$(cat "$(dirname -- "$0")/runtime-mode")"
    [[ "$mode" == absent ]] || printf '%s\n' aaaaaaaaaaaa
elif [[ " $* " == *" ps -aq "* ]] \
    && [[ " $* " == *" label=com.docker.compose.project=vx-alice-legacy "* ]]; then
    mode="$(cat "$(dirname -- "$0")/runtime-mode")"
    [[ "$mode" == absent ]] || printf '%s\n' bbbbbbbbbbbb
elif [[ " $* " == *" inspect aaaaaaaaaaaa "* \
    || " $* " == *" inspect bbbbbbbbbbbb "* ]]; then
    mode="$(cat "$(dirname -- "$0")/runtime-mode")"
    user=alice
    revision=1
    project=web
    container=aaaaaaaaaaaa
    image=sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe
    if [[ " $* " == *" inspect bbbbbbbbbbbb "* ]]; then
        project=legacy
        container=bbbbbbbbbbbb
    fi
    [[ "$mode" != foreign ]] || user=bob
    [[ "$mode" != incomplete ]] || revision=
    printf '[{"Id":"%s","Image":"%s","Config":{"Labels":{' \
        "$container" "$image"
    printf '"com.docker.compose.project":"vx-alice-%s",' "$project"
    printf '"com.docker.compose.service":"web",'
    printf '"vx.managed":"yes","vx.user":"%s","vx.project":"%s",' \
        "$user" "$project"
    printf '"vx.revision":"%s","vx.image-id":"%s"' "$revision" "$image"
    printf '}},"State":{"Status":"running"},'
    printf '"NetworkSettings":{"Networks":{"vx-alice-%s_default":{}},"Ports":{}},' "$project"
    printf '"HostConfig":{"Privileged":false,"CapAdd":[],"NetworkMode":"vx-alice-%s_default","PidMode":"","IpcMode":"private","Devices":[]},' "$project"
    if [[ -f "$(dirname -- "$0")/secret-runtime" && "$project" == web ]]; then
        printf '"Mounts":[{"Source":"%s","Destination":"/run/secrets/credential","RW":false}]' \
            "$(dirname -- "$0")/vesta/data/users/alice/docker-projects/web/runtime/workload-secrets/current/credential"
    else
        printf '"Mounts":[]'
    fi
    printf '}]\n'
fi
EOF
chmod 0755 "$fake_docker"

export VX_COMPOSE_DOCKER_BIN="$fake_docker"
export LEAK_CANARY='must-not-reach-docker'
# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

candidate="$test_root/candidate"
mkdir -p "$candidate"
printf '%s\n' 'name: vx-alice-web' 'services:' '  web:' '    image: example.test/web:v1' \
    >"$candidate/compose.yaml"
printf '%s\n' '{"name":"vx-alice-web","services":{"web":{"image":"example.test/web:v1"}}}' \
    >"$candidate/canonical.json"
(
    cd "$candidate"
    sha256sum canonical.json >canonical.sha256
)
{
    printf "POLICY_SCHEMA='1'\n"
    printf "VALIDATOR_VERSION='2'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='2'\n"
    printf "SERVICES='1'\n"
    printf "CPUS_MILLI='250'\n"
    printf "MEMORY_MB='64'\n"
    printf "PIDS='32'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"
vx_compose_store_new alice web standard "$candidate"

vx_compose_deploy alice web
[[ -f "$(vx_compose_project_root alice web)/images.json" ]] \
    || fail "deploy did not record resolved image identities"
jq -e '.web.IMAGE_ID == "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"' \
    "$(vx_compose_project_root alice web)/images.json" >/dev/null \
    || fail "resolved image identity is wrong"
jq -e '.web.SCHEMA == 2' \
    "$(vx_compose_project_root alice web)/revisions/000001/images.json" \
    >/dev/null || fail "new revision image evidence did not use schema 2"

# Production-era five-field evidence must bootstrap through the real locked
# lifecycle path before strict active verification. Stop is important here:
# cold backup uses it without passing through a start-like action.
legacy_candidate="$test_root/legacy-candidate"
mkdir -p "$legacy_candidate"
printf '%s\n' 'name: vx-alice-legacy' 'services:' '  web:' \
    '    image: example.test/web:v1' >"$legacy_candidate/compose.yaml"
printf '%s\n' \
    '{"name":"vx-alice-legacy","services":{"web":{"image":"example.test/web:v1"}}}' \
    >"$legacy_candidate/canonical.json"
(
    cd "$legacy_candidate"
    sha256sum canonical.json >canonical.sha256
)
cp "$candidate/policy.conf" "$legacy_candidate/policy.conf"
vx_compose_store_new alice legacy standard "$legacy_candidate"
vx_compose_deploy alice legacy
root="$(vx_compose_project_root alice legacy)"
cat >"$test_root/production-legacy-images.json" <<'EOF'
{
  "web": {
    "ARCHITECTURE": "amd64",
    "IMAGE_ID": "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe",
    "OS": "linux",
    "REFERENCE": "example.test/web:v1",
    "REPO_DIGESTS": [
      "example.test/web@sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"
    ]
  }
}
EOF
install -m 0640 "$test_root/production-legacy-images.json" \
    "$root/images.json"
install -m 0640 "$test_root/production-legacy-images.json" \
    "$root/revisions/000001/images.json"
(
    cd "$root/revisions/000001"
    sha256sum canonical.json >manifest.sha256
    chmod 0640 manifest.sha256
)
vx_compose_active_legacy_image_migration_is_needed alice legacy \
    || fail "production legacy fixture was not eligible for lifecycle bootstrap"

runtime_mutations_before="$(grep -Ec \
    '^ARG=(up|start|stop|restart|down)$|^ARG=--force-recreate$' \
    "$docker_log" || :)"
printf '%s\n' 'sha256:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd' \
    >"$test_root/image-id"
if vx_compose_stop alice legacy 2>/dev/null; then
    fail "legacy lifecycle bootstrap accepted digest drift"
fi
printf '%s\n' 'sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe' \
    >"$test_root/image-id"
printf '%s\n' arm64 >"$test_root/image-architecture"
if vx_compose_stop alice legacy 2>/dev/null; then
    fail "legacy lifecycle bootstrap accepted platform drift"
fi
printf '%s\n' amd64 >"$test_root/image-architecture"
if VX_DOCKER_TRUST_MODE_STANDARD=enforce \
    vx_compose_stop alice legacy 2>/dev/null; then
    fail "legacy lifecycle bootstrap bypassed current trust enforcement"
fi
[[ "$(grep -Ec '^ARG=(up|start|stop|restart|down)$|^ARG=--force-recreate$' \
        "$docker_log" || :)" == "$runtime_mutations_before"
    && ! -e "$root/image-evidence-migration"
    && "$(jq -r '.web.SCHEMA // "legacy"' "$root/images.json")" \
        == legacy ]] \
    || fail "failed legacy bootstrap reached runtime or mutated authority"

vx_compose_stop alice legacy
jq -e '.web.SCHEMA == 2' "$root/images.json" >/dev/null \
    || fail "stop lifecycle did not upgrade current image evidence"
[[ -f "$root/image-evidence-migration/evidence.json" ]] \
    || fail "stop lifecycle did not create migration authority"
[[ "$(jq -s '[.[] | select(.ACTION == "resolve-images"
        and (.DETAILS | contains("schema_transition=")))] | length' \
        "$root/audit.log")" == 1 ]] \
    || fail "stop lifecycle resolved legacy evidence more than once"
vx_compose_start alice legacy

printf '%s\n' 'sha256:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd' >"$test_root/image-id"
if vx_compose_start alice web 2>"$test_root/drift.error"; then
    fail "image identity drift was accepted for the same revision"
fi
grep -Fq 'Docker image identity drifted' "$test_root/drift.error" \
    || fail "image drift returned the wrong diagnostic"
printf '%s\n' 'sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe' >"$test_root/image-id"
vx_compose_stop alice web
# No current-revision containers means start must converge instead of falsely
# reporting success from `compose start`.
printf '%s\n' absent >"$test_root/runtime-mode"
vx_compose_start alice web
tail -80 "$docker_log" | grep -Fq 'ARG=up' \
    || fail "start did not converge an absent runtime with compose up"

# A complete current-revision owned runtime may use the cheaper start path.
printf '%s\n' complete >"$test_root/runtime-mode"
start_count_before="$(grep -c '^ARG=start$' "$docker_log" || :)"
vx_compose_start alice web
[[ "$(grep -c '^ARG=start$' "$docker_log" || :)" -eq $((start_count_before + 1)) ]] \
    || fail "complete current runtime did not use compose start"

# Every container selected by the exact Compose project label is inspected.
# A foreign Vortex ownership label must stop before a Compose mutation.
printf '%s\n' foreign >"$test_root/runtime-mode"
mutation_count_before="$(
    grep -Ec '^ARG=(up|start|stop|restart|down)$|^ARG=--force-recreate$' \
        "$docker_log" || :
)"
if vx_compose_start alice web 2>"$test_root/foreign.error"; then
    fail "foreign-labelled project container was accepted"
fi
mutation_count_after="$(
    grep -Ec '^ARG=(up|start|stop|restart|down)$|^ARG=--force-recreate$' \
        "$docker_log" || :
)"
[[ "$mutation_count_before" -eq "$mutation_count_after" ]] \
    || fail "foreign container labels reached a Compose mutation"
grep -Fq 'ownership mismatch' "$test_root/foreign.error" \
    || fail "foreign container labels returned the wrong diagnostic"

# Missing revision identity is incomplete, not success: start reconverges it.
printf '%s\n' incomplete >"$test_root/runtime-mode"
up_count_before="$(grep -c '^ARG=up$' "$docker_log" || :)"
vx_compose_start alice web
[[ "$(grep -c '^ARG=up$' "$docker_log" || :)" -eq $((up_count_before + 1)) ]] \
    || fail "incomplete runtime identity did not converge with compose up"
printf '%s\n' complete >"$test_root/runtime-mode"

# Compose returning zero is not success unless exact post-candidate runtime
# identity exists. An incomplete post-state is contained and made explicit for
# the outer transaction/recovery path.
: >"$test_root/preserve-runtime-mode"
printf '%s\n' incomplete >"$test_root/runtime-mode"
stop_count_before="$(grep -c '^ARG=stop$' "$docker_log" || :)"
if vx_compose_restart alice web 2>/dev/null; then
    fail "incomplete post-convergence identity was accepted"
fi
[[ "$(vx_compose_meta_get \
        "$(vx_compose_project_root alice web)/project.conf" STATE)" \
        == restore-required
    && "$(grep -c '^ARG=stop$' "$docker_log" || :)" \
        -eq $((stop_count_before + 1)) ]] \
    || fail "failed post-convergence identity was not safely contained"
rm -f -- "$test_root/preserve-runtime-mode"
vx_compose_deploy alice web
[[ "$(vx_compose_meta_get \
        "$(vx_compose_project_root alice web)/project.conf" STATE)" == running ]] \
    || fail "prior authority could not recover after post-identity failure"

# Candidate overrides must not redefine the pre-mutation identity of the
# currently active runtime. Image updates and service removals therefore reach
# candidate convergence, where their own exact post-state is then enforced.
candidate_update="$test_root/candidate-update"
mkdir -p "$candidate_update"
printf '%s\n' \
    '{"services":{"web":{"image":"example.test/web:v2"}}}' \
    >"$candidate_update/canonical.json"
printf '%s\n' \
    '{"web":{"REFERENCE":"example.test/web:v2","IMAGE_ID":"sha256:candidate","REPO_DIGESTS":["example.test/web@sha256:candidate"],"OS":"linux","ARCHITECTURE":"amd64"}}' \
    >"$candidate_update/images.json"
: >"$candidate_update/variables.env"
restart_count_before="$(grep -c '^ARG=restart$' "$docker_log" || :)"
if VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$candidate_update/canonical.json" \
    VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$candidate_update/images.json" \
    VX_COMPOSE_INVOKE_REVISION_OVERRIDE=2 \
    VX_COMPOSE_INVOKE_ENV_OVERRIDE="$candidate_update/variables.env" \
    vx_compose_restart alice web 2>/dev/null; then
    fail "synthetic candidate image update unexpectedly converged"
fi
[[ "$(grep -c '^ARG=restart$' "$docker_log" || :)" \
    -eq $((restart_count_before + 1)) ]] \
    || fail "candidate image update was falsely rejected by active preflight"
vx_compose_deploy alice web

candidate_remove="$test_root/candidate-remove"
mkdir -p "$candidate_remove"
printf '{"services":{}}\n' >"$candidate_remove/canonical.json"
printf '{}\n' >"$candidate_remove/images.json"
: >"$candidate_remove/variables.env"
restart_count_before="$(grep -c '^ARG=restart$' "$docker_log" || :)"
if VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE="$candidate_remove/canonical.json" \
    VX_COMPOSE_INVOKE_IMAGES_OVERRIDE="$candidate_remove/images.json" \
    VX_COMPOSE_INVOKE_REVISION_OVERRIDE=2 \
    VX_COMPOSE_INVOKE_ENV_OVERRIDE="$candidate_remove/variables.env" \
    vx_compose_restart alice web 2>/dev/null; then
    fail "synthetic candidate service removal unexpectedly converged"
fi
[[ "$(grep -c '^ARG=restart$' "$docker_log" || :)" \
    -eq $((restart_count_before + 1)) ]] \
    || fail "candidate service removal was falsely rejected by active preflight"
vx_compose_deploy alice web

vx_compose_restart alice web
vx_compose_recreate alice web web

docker_calls_before="$(grep -c '^END$' "$docker_log")"
if vx_compose_recreate alice web 'web;touch-pwned' 2>/dev/null; then
    fail "hostile service name was accepted"
fi
docker_calls_after="$(grep -c '^END$' "$docker_log")"
[[ "$docker_calls_before" -eq "$docker_calls_after" ]] \
    || fail "hostile service name reached Docker"

grep -Fq 'ARG=--project-name' "$docker_log" || fail "project-name option is missing"
grep -Fq 'ARG=vx-alice-web' "$docker_log" || fail "stable runtime name is missing"
grep -Fq 'ARG=--project-directory' "$docker_log" || fail "project directory option is missing"
grep -Fq 'ARG=--file' "$docker_log" || fail "explicit Compose file option is missing"
grep -Fq "ARG=$(vx_compose_project_root alice web)/runtime/.invoke." \
    "$docker_log" \
    || fail "runtime did not invoke a protected identity-bound definition"
grep -Fq 'ARG=--env-file' "$docker_log" || fail "controlled env file option is missing"
grep -Fq 'ARG=--wait' "$docker_log" || fail "deploy does not wait for health"
grep -Fq 'ARG=--force-recreate' "$docker_log" || fail "recreate flag is missing"
grep -Fq 'IDENTITY_OK' "$docker_log" \
    || fail "runtime definition was not pinned to revision image identity"
if grep -Fq 'ENV_LEAK=must-not-reach-docker' "$docker_log"; then
    fail "caller environment leaked into Docker invocation"
fi
if grep -Eqi 'system prune|volume prune|--volumes' "$docker_log"; then
    fail "lifecycle used a forbidden global/data-destructive option"
fi

# Missing bind data must block start/create paths, while emergency stop/down
# remains available to contain an already-running workload.
vx_compose_managed_binds_verify() { return 1; }
if vx_compose_invoke alice web up -d 2>/dev/null; then
    fail "start-like mutation ignored failed bind revalidation"
fi
vx_compose_invoke alice web stop --timeout 30 \
    || fail "emergency stop incorrectly depended on bind availability"
unset -f vx_compose_managed_binds_verify
# shellcheck source=func/vx/compose/volumes.sh
source "$repo_root/func/vx/compose/volumes.sh"

# Raw Compose stderr is never exposed or persisted. The caller receives only a
# bounded diagnostic redacted against managed secrets.
project_root="$(vx_compose_project_root alice web)"
install -d -m 0700 "$project_root/runtime/secret-redaction"
printf '%s\n' lifecycle-secret-canary \
    >"$project_root/runtime/secret-redaction/current"
chmod 0600 "$project_root/runtime/secret-redaction/current"
: >"$test_root/fail-compose"
if vx_compose_recreate alice web web \
    >"$test_root/failure.stdout" 2>"$test_root/failure.stderr"; then
    fail "synthetic Compose stderr failure reported success"
fi
rm -f -- "$test_root/fail-compose"
rm -rf -- "$project_root/runtime/secret-redaction"
grep -Fq '[REDACTED]' "$test_root/failure.stderr" \
    || fail "caller did not receive a redacted Compose diagnostic"
if grep -Fq lifecycle-secret-canary \
    "$test_root/failure.stdout" "$test_root/failure.stderr" \
    "$project_root/audit.log" "$project_root/runtime/last-operation.json"; then
    fail "raw Compose stderr canary leaked through lifecycle evidence"
fi

# Active control is executable authority only while its recorded digest and
# finalized revision manifest remain exact. Either mismatch must stop before
# Docker receives a mutation.
cp -p -- "$project_root/runtime/canonical.json" \
    "$test_root/canonical.before-tamper"
printf '\n' >>"$project_root/runtime/canonical.json"
docker_calls_before="$(grep -c '^END$' "$docker_log")"
if vx_compose_restart alice web 2>/dev/null; then
    fail "tampered active canonical authority was accepted"
fi
docker_calls_after="$(grep -c '^END$' "$docker_log")"
[[ "$docker_calls_before" -eq "$docker_calls_after" ]] \
    || fail "active canonical tamper reached Docker"
mv -- "$test_root/canonical.before-tamper" \
    "$project_root/runtime/canonical.json"
touch "$project_root/revisions/000001/unmanifested"
docker_calls_before="$(grep -c '^END$' "$docker_log")"
if vx_compose_restart alice web 2>/dev/null; then
    fail "mutated finalized revision was accepted"
fi
docker_calls_after="$(grep -c '^END$' "$docker_log")"
[[ "$docker_calls_before" -eq "$docker_calls_after" ]] \
    || fail "revision manifest mismatch reached Docker"
rm -f -- "$project_root/revisions/000001/unmanifested"

# Lifecycle lock acquisition is fail-closed and unwinds locks acquired earlier
# in the global ordering before Docker is called.
ports_lock_definition="$(declare -f vx_compose_ports_lock_acquire)"
vx_compose_ports_lock_acquire() { return 1; }
docker_calls_before="$(grep -c '^END$' "$docker_log")"
if vx_compose_restart alice web 2>/dev/null; then
    fail "lifecycle ignored failed global port-lock acquisition"
fi
unset -f vx_compose_ports_lock_acquire
eval "$ports_lock_definition"
docker_calls_after="$(grep -c '^END$' "$docker_log")"
[[ "$docker_calls_before" -eq "$docker_calls_after"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}" ]] \
    || fail "lifecycle port-lock failure mutated runtime or leaked locks"

quota_lock_definition="$(declare -f vx_compose_owner_quota_lock_acquire)"
vx_compose_owner_quota_lock_acquire() { return 1; }
docker_calls_before="$(grep -c '^END$' "$docker_log")"
if vx_compose_restart alice web 2>/dev/null; then
    fail "lifecycle ignored failed owner-quota lock acquisition"
fi
unset -f vx_compose_owner_quota_lock_acquire
eval "$quota_lock_definition"
docker_calls_after="$(grep -c '^END$' "$docker_log")"
[[ "$docker_calls_before" -eq "$docker_calls_after"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "${VX_COMPOSE_PORTS_LOCK_FD:-}"
    && -z "${VX_COMPOSE_QUOTA_LOCK_FD:-}" ]] \
    || fail "lifecycle quota-lock failure mutated runtime or leaked locks"

# A terminal evidence write failure is an operation failure. A stopped prior
# runtime is not falsely published as running, and a running prior runtime is
# re-converged before its prior state is restored.
audit_definition="$(declare -f vx_compose_audit)"
eval "${audit_definition/vx_compose_audit ()/vx_compose_audit_original ()}"
vx_compose_audit() {
    if [[ "$2" == stop && "$3" == succeeded ]]; then
        return 1
    fi
    vx_compose_audit_original "$@"
}
up_count_before="$(grep -c '^ARG=up$' "$docker_log" || :)"
if vx_compose_stop alice web 2>/dev/null; then
    fail "terminal audit failure was reported as lifecycle success"
fi
[[ "$(vx_compose_meta_get "$project_root/project.conf" STATE)" == running
    && "$(grep -c '^ARG=up$' "$docker_log" || :)" \
        -eq $((up_count_before + 1)) ]] \
    || fail "terminal audit failure left runtime/control state incoherent"
unset -f vx_compose_audit vx_compose_audit_original
eval "$audit_definition"

[[ "$(vx_compose_meta_get "$(vx_compose_project_root alice web)/project.conf" STATE)" == running ]] \
    || fail "lifecycle state was not updated"
if vx_compose_start bob web 2>/dev/null; then
    fail "cross-owner lifecycle operation succeeded"
fi

vx_compose_list_json alice | jq -e '."vx-alice-web".OWNER == "alice"' >/dev/null \
    || fail "owner-scoped list output is wrong"
inspect_json="$(vx_compose_inspect_json alice web)"
jq -e '
    .PROJECT == "web"
    and .SERVICE_SUMMARY.web.IMAGE == "example.test/web:v1"
    and .SERVICE_SUMMARY.web.PORTS == []
    and .IMAGE_IDENTITIES.web.IMAGE_ID == "sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"
    and .REVISIONS == [1]
' <<<"$inspect_json" >/dev/null \
    || fail "inspect output omitted the safe service/revision summary"

# Bundle-managed canonical runtime definitions use immutable IDs, while
# refresh must inspect the accepted tag reference and reject a moved tag.
project_root="$(vx_compose_project_root alice web)"
revision_root="$project_root/revisions/000001"
image_id="sha256:fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"
for canonical_path in \
    "$project_root/runtime/canonical.json" "$revision_root/canonical.json"; do
    jq --arg id "$image_id" \
        --arg source "$project_root/runtime/workload-secrets/current/credential" '
        .services.web.image=$id
        | .services.web.secrets=[{source:"credential",target:"/run/secrets/credential"}]
        | .secrets={credential:{file:$source}}
    ' "$canonical_path" \
        >"$test_root/canonical.updated"
    install -m 0640 "$test_root/canonical.updated" "$canonical_path"
done
canonical_sha="$(sha256sum "$project_root/runtime/canonical.json" | awk '{print $1}')"
sed "s/^CANONICAL_SHA256=.*/CANONICAL_SHA256='$canonical_sha'/" \
    "$project_root/project.conf" >"$test_root/project.updated"
install -m 0640 "$test_root/project.updated" "$project_root/project.conf"
mkdir -p "$project_root/secrets"
chmod 0700 "$project_root/secrets"
printf 'lifecycle-secret\n' >"$project_root/secrets/credential"
chmod 0600 "$project_root/secrets/credential"
printf '%s\n' \
    '{"secrets":[{"name":"credential","target":"/run/secrets/credential"}]}' \
    >"$project_root/workload.json"
chmod 0600 "$project_root/workload.json"
install -m 0600 "$project_root/workload.json" "$revision_root/workload.json"
rm -f -- "$revision_root/manifest.sha256"
vx_compose_revision_manifest_write "$revision_root"
vx_compose_current_workload_image_approval_require() { return 0; }
printf absent >"$test_root/runtime-mode"
touch "$test_root/secret-runtime"
tag_lookups_before="$(grep -c '^ARG=example.test/web:v1$' "$docker_log" || :)"
vx_compose_deploy alice web \
    || fail 'immutable canonical deploy did not resolve its accepted tag authority'
runtime_secret="$project_root/runtime/workload-secrets/current/credential"
[[ "$(<"$runtime_secret")" == lifecycle-secret \
    && "$(stat -c '%a' "$project_root/secrets/credential")" == 600 \
    && "$(stat -c '%a' "$runtime_secret")" == 444 ]] \
    || fail 'deploy did not materialize its protected runtime secret copy'
vx_compose_drift_observe_json alice web | jq -e '
    .MATCH == true
    and .DESIRED[0].MOUNTS[0].READ_ONLY == true
    and .OBSERVED[0].MOUNTS[0].READ_ONLY == true
' >/dev/null || fail 'runtime secret mount produced false drift'
[[ ! -e "$revision_root/runtime" ]] \
    && ! grep -R -Fq 'lifecycle-secret' "$revision_root" \
    || fail 'immutable revision retained a disposable runtime secret copy'
[[ "$(grep -c '^ARG=example.test/web:v1$' "$docker_log" || :)" \
    -gt "$tag_lookups_before" ]] \
    || fail 'bundle refresh inspected the canonical digest instead of accepted tag'
printf 'rotated-lifecycle-secret\n' >"$project_root/secrets/credential"
vx_compose_restart alice web \
    || fail 'restart did not converge after authoritative secret rotation'
[[ "$(<"$runtime_secret")" == rotated-lifecycle-secret ]] \
    || fail 'restart did not refresh the runtime secret copy'
printf '%s\n' 'sha256:cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd' \
    >"$test_root/image-id"
if vx_compose_restart alice web 2>/dev/null; then
    fail 'moved accepted image tag passed workload lifecycle refresh'
fi
printf '%s\n' "$image_id" >"$test_root/image-id"

# Transitioning to a generic project removes workload-only paths and clears
# the disposable runtime secret authority before the next start.
for canonical_path in \
    "$project_root/runtime/canonical.json" "$revision_root/canonical.json"; do
    jq '.services.web.image="example.test/web:v1"
        | del(.services.web.secrets,.secrets)' "$canonical_path" \
        >"$test_root/canonical.generic"
    install -m 0640 "$test_root/canonical.generic" "$canonical_path"
done
rm -f -- "$project_root/workload.json" "$revision_root/workload.json" \
    "$revision_root/manifest.sha256" "$test_root/secret-runtime"
vx_compose_revision_manifest_write "$revision_root"
canonical_sha="$(sha256sum "$project_root/runtime/canonical.json" | awk '{print $1}')"
sed "s/^CANONICAL_SHA256=.*/CANONICAL_SHA256='$canonical_sha'/" \
    "$project_root/project.conf" >"$test_root/project.generic"
install -m 0640 "$test_root/project.generic" "$project_root/project.conf"
vx_compose_start alice web \
    || fail 'workload-to-generic lifecycle transition failed'
[[ ! -e "$project_root/runtime/workload-secrets" ]] \
    || fail 'generic lifecycle retained stale workload runtime secrets'

# A failed tombstone deletion must fail the command and restore a discoverable
# normal control root while leaving owner data/runtime scope untouched. The
# project lock remains held across the whole remove, including final cleanup.
remove_barrier="$test_root/remove.fifo"
mkfifo "$remove_barrier"
rm -f -- "$test_root/remove.ready" "$test_root/remove-competitor.entered"
rm() {
    if [[ "$*" == *"/.removing-web-"* ]]; then
        printf 'ready\n' >"$test_root/remove.ready"
        IFS= read -r _ <"$remove_barrier"
        return 1
    fi
    command rm "$@"
}
vx_compose_remove alice web &
remove_pid=$!
for _ in {1..200}; do
    [[ -s "$test_root/remove.ready" ]] && break
    sleep 0.01
done
[[ -s "$test_root/remove.ready" ]] \
    || fail "remove did not reach the final cleanup barrier"
(
    vx_compose_lock_acquire alice web
    printf 'entered\n' >"$test_root/remove-competitor.entered"
    vx_compose_lock_release
) &
remove_competitor_pid=$!
sleep 0.1
[[ ! -e "$test_root/remove-competitor.entered" ]] \
    || fail "project lock was released before remove cleanup completed"
printf 'release\n' >"$remove_barrier"
if wait "$remove_pid"; then
    fail "tombstone deletion failure was reported as success"
fi
wait "$remove_competitor_pid"
unset -f rm
project_root="$(vx_compose_project_root alice web)"
[[ -d "$project_root"
    && "$(vx_compose_meta_get "$project_root/project.conf" STATE)" \
        == cleanup-required
    && -d "$HOMEDIR/alice/docker/web"
    && -z "${VX_COMPOSE_LOCK_FD:-}"
    && -z "$(find "$(vx_compose_projects_root alice)" -maxdepth 1 \
        -name '.removing-web-*' -print -quit)" ]] \
    || fail "failed tombstone deletion did not restore retryable normal state"
[[ -s "$test_root/remove-competitor.entered" ]] \
    || fail "project lock was not released after failed remove cleanup"
jq -e 'select(.ACTION == "remove-cleanup" and .RESULT == "failed")
    | .ACTOR == "root" and .OWNER == "alice"
    and (.DETAILS | contains("normal root restored"))' \
    "$project_root/audit.log" >/dev/null \
    || fail "tombstone deletion recovery audit is missing"

vx_compose_remove alice web
[[ ! -e "$(vx_compose_project_root alice web)" ]] \
    || fail "removed project metadata still exists"
[[ -d "$HOMEDIR/alice/docker/web" ]] \
    || fail "remove did not retain the project data root"

echo "Compose lifecycle tests passed."
