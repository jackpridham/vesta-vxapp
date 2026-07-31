#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users" "$HOMEDIR"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

make_project() {
    local owner="$1" project="$2" root
    root="$VESTA/data/users/$owner/docker-projects/$project"
    mkdir -p "$root/runtime" "$root/revisions" "$root/secrets" \
        "$HOMEDIR/$owner/docker/$project/binds"
    printf "OWNER='%s'\nPROJECT='%s'\nREVISION='1'\nSTATE='stopped'\nPROFILE='standard'\nCANONICAL_SHA256='abc'\n" \
        "$owner" "$project" >"$root/project.conf"
    printf "POLICY_SCHEMA='1'\nPROFILE_VERSION='1'\nVALIDATOR_VERSION='2'\n" \
        >"$root/policy.conf"
    printf 'services: {}\n' >"$root/compose.yaml"
    printf '{"services":{},"volumes":{}}\n' >"$root/runtime/canonical.json"
    printf '{}\n' >"$root/images.json"
    printf '{}\n' >"$root/secrets.json"
    printf '{}\n' >"$root/secret-integrity.json"
    printf 'backup-secret-canary\n' >"$root/secrets/canary"
    chmod 0600 "$root/secrets/"* "$root/"*.json
}

make_project alice app
make_project alice future
make_project alice disabled
make_project bob app

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

for function_name in \
    vx_compose_backup_policy_add \
    vx_compose_backup_policy_list_json \
    vx_compose_backup_policy_run \
    vx_compose_backup_policies_run_due \
    vx_compose_backup_policy_retention \
    vx_compose_backup_restore_drill \
    vx_compose_backup_alert_set \
    vx_compose_backup_alerts_evaluate_policy; do
    declare -F "$function_name" >/dev/null \
        || fail "main.sh did not publish $function_name"
done

# Policy validation, persistence, owner/project binding, mode, and attribution.
_VX_COMPOSE_AUDIT_ACTOR='admin'
vx_compose_backup_policy_add \
    alice app yes daily@02:30 7 4 yes fixture-copy 7200 86400
unset _VX_COMPOSE_AUDIT_ACTOR
policy_path="$VESTA/data/users/alice/docker-projects/app/backup-policy.conf"
[[ -f "$policy_path" && ! -L "$policy_path" ]] \
    || fail "backup policy was not persisted beneath the exact project root"
[[ "$(stat -c '%a' "$policy_path")" == 600 ]] \
    || fail "backup policy mode is not 0600"
[[ ! -e "$VESTA/data/users/bob/docker-projects/app/backup-policy.conf" ]] \
    || fail "backup policy crossed its owner boundary"
jq -e '
    .OWNER == "alice"
    and .PROJECT == "app"
    and .ENABLED == "yes"
    and .SCHEDULE == "daily@02:30"
    and .RETAIN_DAILY == 7
    and .RETAIN_WEEKLY == 4
    and .ENCRYPTION_REQUIRED == "yes"
    and .REPLICATION_ADAPTER == "fixture-copy"
    and .FRESHNESS_SECONDS == 7200
    and .RESTORE_TEST_INTERVAL_SECONDS == 86400
    and (.NEXT_RUN | test("Z$"))
' <<<"$(vx_compose_backup_policy_list_json alice app)" >/dev/null \
    || fail "backup policy listing omitted validated authority"
vx_compose_backup_policy_file_validate "$policy_path" \
    || fail "persisted backup policy did not pass its restore validator"
malicious_policy="$test_root/malicious-backup-policy.conf"
cp "$policy_path" "$malicious_policy"
sed -i "s#^REPLICATION_ADAPTER=.*#REPLICATION_ADAPTER='../escape'#" \
    "$malicious_policy"
if vx_compose_backup_policy_file_validate "$malicious_policy" 2>/dev/null; then
    fail "malicious archived backup policy metadata was accepted"
fi
archived_policy="$test_root/archived-backup-policy.conf"
cp "$policy_path" "$archived_policy"
vx_compose_backup_policy_state_update \
    "$archived_policy" LAST_SUCCESS '2026-01-01T00:00:00Z'
vx_compose_backup_policy_state_update \
    "$archived_policy" REPLICATION_STATE succeeded
vx_compose_backup_policy_restore_reset alice app "$archived_policy"
reset_policy="$(vx_compose_backup_policy_list_json alice app)"
jq -e '
    .ENABLED == "yes"
    and .SCHEDULE == "daily@02:30"
    and .REPLICATION_ADAPTER == "fixture-copy"
    and .LAST_SUCCESS == ""
    and .LAST_ARCHIVE == ""
    and .REPLICATION_STATE == ""
    and .RESTORE_TEST_STATE == ""
    and (.NEXT_RUN | test("Z$"))
' <<<"$reset_policy" >/dev/null \
    || fail "restore did not reset archived operational policy state safely"
control_copy="$test_root/control-copy"
vx_compose_backup_copy_control \
    "$VESTA/data/users/alice/docker-projects/app" "$control_copy"
cmp -s "$policy_path" "$control_copy/backup-policy.conf" \
    || fail "backup did not preserve policy evidence exactly"
jq -e '
    select(
        .ACTOR == "admin"
        and .OWNER == "alice"
        and .PROJECT == "app"
        and .ACTION == "backup-policy"
        and .RESULT == "succeeded"
    )
' "$VESTA/data/users/alice/docker-projects/app/audit.log" >/dev/null \
    || fail "backup policy audit attribution is missing"

valid_policy=(alice future yes weekly@mon@03:45 8 5 no none 3600 172800)
vx_compose_backup_policy_add "${valid_policy[@]}"
cp "$VESTA/data/users/alice/docker-projects/future/backup-policy.conf" \
    "$test_root/policy-before"
invalid_policies=(
    "maybe daily@02:30 7 4 no none 3600 86400"
    "yes hourly@02:30 7 4 no none 3600 86400"
    "yes daily@24:00 7 4 no none 3600 86400"
    "yes weekly@funday@02:30 7 4 no none 3600 86400"
    "yes daily@02:30 6 4 no none 3600 86400"
    "yes daily@02:30 7 3 no none 3600 86400"
    "yes daily@02:30 7 4 maybe none 3600 86400"
    "yes daily@02:30 7 4 no ../adapter 3600 86400"
    "yes daily@02:30 7 4 no local-fixture 3600 86400"
    "yes daily@02:30 7 4 no none 3599 86400"
    "yes daily@02:30 7 4 no none 3600 86399"
)
for invalid in "${invalid_policies[@]}"; do
    # Intentional splitting supplies the eight policy fields in this fixture.
    # shellcheck disable=SC2086
    if vx_compose_backup_policy_add alice future $invalid 2>/dev/null; then
        fail "invalid backup policy was accepted: $invalid"
    fi
    cmp -s "$test_root/policy-before" \
        "$VESTA/data/users/alice/docker-projects/future/backup-policy.conf" \
        || fail "rejected policy changed persisted authority"
done

# Retention is calendar-aware, retains the last known-good archive, and does
# not traverse or remove similarly named files outside the project root.
backup_root="$(vx_compose_backup_root alice app)"
mkdir -p "$backup_root"
for offset in $(seq 0 2 34); do
    archive="$backup_root/app-retention-$offset.tar.gz"
    printf '%s\n' "$offset" >"$archive"
    touch -d "2026-07-31 - $offset days" "$archive"
done
last_good='app-retention-34.tar.gz'
outside="$test_root/app-outside.tar.gz"
printf 'outside\n' >"$outside"
ln -s "$outside" "$backup_root/app-linked.tar.gz"
vx_compose_backup_policy_retention alice app 7 4 "$last_good"
[[ -f "$backup_root/$last_good" ]] \
    || fail "retention removed the last known-good backup"
[[ "$(cat "$outside")" == outside && -L "$backup_root/app-linked.tar.gz" ]] \
    || fail "retention traversed outside the exact backup root"
remaining_days="$(
    find "$backup_root" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
        | while read -r epoch path; do date -u -d "@${epoch%.*}" +%F; done \
        | sort -u | wc -l
)"
remaining_weeks="$(
    find "$backup_root" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' \
        | while read -r epoch path; do date -u -d "@${epoch%.*}" +%G-W%V; done \
        | sort -u | wc -l
)"
[[ "$remaining_days" -ge 7 && "$remaining_weeks" -ge 4 ]] \
    || fail "calendar retention did not preserve seven daily/four weekly points"

# Restore drill is validation-only, cleans its staging directory, and never
# invokes the mutation path.
printf 'fixture\n' >"$test_root/drill.tar.gz"
: >"$test_root/restore-validation.log"
vx_compose_restore_archive_validate() {
    local owner="$1" project="$2" archive="$3" destination="$4"
    printf '%s %s %s\n' "$owner" "$project" "$(basename -- "$archive")" \
        >>"$test_root/restore-validation.log"
    mkdir -p "$destination"
    printf 'validated\n' >"$destination/result"
}
vx_compose_restore_project() {
    fail "restore drill invoked the mutating restore path"
}
vx_compose_backup_restore_drill alice app "$test_root/drill.tar.gz"
[[ "$(cat "$test_root/restore-validation.log")" == \
    'alice app drill.tar.gz' ]] \
    || fail "restore drill did not validate the exact owner/project archive"
if find "$VESTA/data/users/alice/docker-projects/app/runtime" -maxdepth 1 \
    -name '.restore-drill.*' -print -quit | grep -q .; then
    fail "restore drill left validation state behind"
fi

# The shipped fixture adapter cannot report success without an explicit,
# protected target. Once configured, it copies and verifies descriptor input.
replication="$(
    vx_compose_backup_replicate \
        alice app local-fixture "$test_root/drill.tar.gz"
)"
jq -e '.STATE == "not-configured"' <<<"$replication" >/dev/null \
    || fail "unconfigured fixture replication was reported as success"
mkdir -p "$VESTA/conf" "$test_root/replicated"
chmod 0700 "$test_root/replicated"
mkdir -p "$VESTA/func/vx/compose/replication-adapters"
cp "$repo_root/func/vx/compose/replication-adapters/local-fixture" \
    "$VESTA/func/vx/compose/replication-adapters/local-fixture"
chmod 0755 "$VESTA/func/vx/compose/replication-adapters/local-fixture"
printf "TARGET_ROOT='%s'\n" "$test_root/replicated" \
    >"$VESTA/conf/vx-compose-replication-local-fixture.conf"
chmod 0600 "$VESTA/conf/vx-compose-replication-local-fixture.conf"
replication="$(
    vx_compose_backup_replicate \
        alice app local-fixture "$test_root/drill.tar.gz"
)"
jq -e '.STATE == "succeeded"' <<<"$replication" >/dev/null \
    || fail "configured fixture replication did not succeed"
replicated_file="$(find "$test_root/replicated/alice/app" -type f -name '*.age')"
cmp -s "$test_root/drill.tar.gz" "$replicated_file" \
    || fail "fixture adapter did not persist and verify descriptor input"

# A managed run updates durable state, invokes protected replication, performs
# the due restore drill, retention, and emits an attributed audit event.
fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'output=' \
    'input=' \
    'while (($#)); do' \
    '  case "$1" in' \
    '    --output) output=$2; shift 2 ;;' \
    '    --recipient) shift 2 ;;' \
    '    --encrypt) shift ;;' \
    '    *) input=$1; shift ;;' \
    '  esac' \
    'done' \
    'printf "age-encrypted\\n" >"$output"' \
    'base64 "$input" >>"$output"' >"$fake_bin/age"
chmod 0755 "$fake_bin/age"
prior_path="$PATH"
PATH="$fake_bin:$PATH"
VX_DOCKER_AGE_RECIPIENT='age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
export VX_DOCKER_AGE_RECIPIENT
vx_compose_backup_policy_add \
    alice app yes daily@02:30 7 4 yes fixture-copy 3600 86400
vx_compose_backup_allocate_path() {
    local root
    root="$(vx_compose_backup_root "$1" "$2")"
    mkdir -p "$root"
    printf '%s/%s-managed-run.tar.gz\n' "$root" "$2"
}
vx_compose_backup_project() {
    printf 'managed archive\n' >"$3"
}
vx_compose_backup_replicate() {
    [[ "$1" == alice && "$2" == app && "$3" == fixture-copy && -f "$4" ]] \
        || return 1
    if [[ "${EXPECT_CIPHERTEXT:-no}" == yes ]]; then
        cp -- "$4" "$test_root/adapter-input"
        ! grep -Fq 'managed archive' "$4" \
            || fail "replication adapter received the plaintext archive"
    fi
    printf '{"STATE":"succeeded","REFERENCE":"redacted-fixture"}\n'
}
vx_compose_backup_restore_drill() {
    [[ "$1" == alice && "$2" == app && -f "$3" ]] || return 1
    printf '%s\n' "$(basename -- "$3")" >"$test_root/run-drill.log"
}
vx_compose_backup_policy_run alice app
run_policy="$(vx_compose_backup_policy_list_json alice app)"
jq -e '
    .LAST_ATTEMPT != ""
    and .LAST_SUCCESS != ""
    and .LAST_ARCHIVE == "app-managed-run.tar.gz"
    and .LAST_ERROR == ""
    and .REPLICATION_STATE == "succeeded"
    and .LAST_REPLICATED != ""
    and .RESTORE_TEST_STATE == "succeeded"
    and .LAST_RESTORE_TEST != ""
    and (.NEXT_RUN | test("Z$"))
' <<<"$run_policy" >/dev/null \
    || fail "managed run did not persist complete lifecycle state"
[[ "$(cat "$test_root/run-drill.log")" == app-managed-run.tar.gz ]] \
    || fail "managed run skipped its due validation-only restore drill"
jq -e '
    select(
        .ACTION == "backup-policy-run"
        and .RESULT == "succeeded"
        and (.DETAILS | contains("replication=succeeded"))
    )
' "$VESTA/data/users/alice/docker-projects/app/audit.log" >/dev/null \
    || fail "managed run audit evidence is missing"

# Encryption-required replication receives a disposable whole-archive
# ciphertext, never the managed plaintext archive or a key on argv.
EXPECT_CIPHERTEXT=yes
export EXPECT_CIPHERTEXT
vx_compose_backup_policy_add \
    alice app yes daily@02:30 7 4 yes fixture-copy 3600 86400
vx_compose_backup_policy_run alice app
grep -Fq 'age-encrypted' "$test_root/adapter-input" \
    || fail "replication adapter input was not whole-archive ciphertext"
if grep -Fq 'managed archive' "$test_root/adapter-input"; then
    fail "replication ciphertext exposed plaintext archive content"
fi
if find "$VESTA/data/users/alice/docker-projects/app/runtime" -maxdepth 1 \
    -name '.backup-replication.*' -print -quit | grep -q .; then
    fail "encrypted replication left a temporary payload"
fi

# A duplicate run is rejected while the first owns the run lock. Killing the
# first process releases both flock descriptors and leaves NEXT_RUN due, so
# the scheduler can recover the interrupted attempt.
original_backup_project="$(declare -f vx_compose_backup_project)"
vx_compose_backup_policy_add \
    alice app yes daily@02:30 7 4 yes fixture-copy 3600 86400
vx_compose_backup_policy_state_update "$policy_path" \
    NEXT_RUN '2000-01-01T00:00:00Z'
barrier="$test_root/blocked-run.fifo"
mkfifo "$barrier"
exec {barrier_fd}<>"$barrier"
vx_compose_backup_project() {
    : >"$test_root/blocked-run.ready"
    IFS= read -r _ <&"$barrier_fd"
}
vx_compose_backup_policy_run alice app >/dev/null 2>&1 &
blocked_pid=$!
for _ in $(seq 1 100); do
    [[ -f "$test_root/blocked-run.ready" ]] && break
    sleep 0.01
done
[[ -f "$test_root/blocked-run.ready" ]] \
    || fail "concurrency fixture did not enter backup"
if vx_compose_backup_policy_run alice app >/dev/null 2>&1; then
    fail "duplicate concurrent backup policy run was not excluded"
fi
kill "$blocked_pid"
wait "$blocked_pid" 2>/dev/null || :
exec {barrier_fd}>&-
[[ "$(vx_compose_meta_get "$policy_path" NEXT_RUN)" \
    == '2000-01-01T00:00:00Z' ]] \
    || fail "interrupted run consumed the next scheduler attempt"
eval "$original_backup_project"
vx_compose_backup_policy_run alice app \
    || fail "policy lock did not recover after interruption"
PATH="$prior_path"
unset VX_DOCKER_AGE_RECIPIENT EXPECT_CIPHERTEXT

# Scheduler enumerates only enabled, due policy files and passes structured
# owner/project arguments rather than executing stored shell strings.
vx_compose_backup_policy_add \
    alice future yes daily@04:00 7 4 no none 3600 86400
vx_compose_backup_policy_add \
    alice disabled no daily@04:00 7 4 no none 3600 86400
vx_compose_backup_policy_state_update \
    "$VESTA/data/users/alice/docker-projects/app/backup-policy.conf" \
    NEXT_RUN '2000-01-01T00:00:00Z'
vx_compose_backup_policy_state_update \
    "$VESTA/data/users/alice/docker-projects/future/backup-policy.conf" \
    NEXT_RUN '2999-01-01T00:00:00Z'
vx_compose_backup_policy_state_update \
    "$VESTA/data/users/alice/docker-projects/disabled/backup-policy.conf" \
    NEXT_RUN '2000-01-01T00:00:00Z'
: >"$test_root/scheduler-runs.log"
vx_compose_backup_policy_run() {
    printf '%s/%s\n' "$1" "$2" >>"$test_root/scheduler-runs.log"
    [[ "${BLOCK_SCHEDULER:-no}" != yes ]] \
        || IFS= read -r _ <&"$scheduler_barrier_fd"
}
mkfifo "$test_root/scheduler.fifo"
exec {scheduler_barrier_fd}<>"$test_root/scheduler.fifo"
BLOCK_SCHEDULER=yes
export BLOCK_SCHEDULER
vx_compose_backup_policies_run_due &
scheduler_pid=$!
for _ in $(seq 1 100); do
    [[ -s "$test_root/scheduler-runs.log" ]] && break
    sleep 0.01
done
[[ "$(cat "$test_root/scheduler-runs.log")" == alice/app ]] \
    || fail "scheduler concurrency fixture did not enter the due project"
vx_compose_backup_policies_run_due
[[ "$(wc -l <"$test_root/scheduler-runs.log")" -eq 1 ]] \
    || fail "host scheduler lock allowed a duplicate enumeration"
kill "$scheduler_pid"
wait "$scheduler_pid" 2>/dev/null || :
exec {scheduler_barrier_fd}>&-
unset BLOCK_SCHEDULER
: >"$test_root/scheduler-runs.log"
vx_compose_backup_policies_run_due
[[ "$(cat "$test_root/scheduler-runs.log")" == alice/app ]] \
    || fail "scheduler did not restart with exactly the enabled due project"

# Typed backup alerts are stable, redacted, idempotent, and close on recovery.
printf 'typed-alert-secret-canary\n' \
    >"$VESTA/data/users/alice/docker-projects/app/secrets/typed"
for type in \
    missed-run backup-failure freshness-breach encryption-unavailable \
    replication-lag replication-failure restore-test-failure; do
    vx_compose_backup_alert_set alice app "$type" \
        "synthetic $type typed-alert-secret-canary"
done
vx_compose_backup_alert_set alice app backup-failure \
    'duplicate typed-alert-secret-canary'
alerts="$(vx_compose_alerts_list_json alice app)"
jq -e '
    [.ALERTS[] | select(.STATUS == "open") | .TYPE] | sort
    == [
        "backup-failure",
        "encryption-unavailable",
        "freshness-breach",
        "missed-run",
        "replication-failure",
        "replication-lag",
        "restore-test-failure"
    ]
' <<<"$alerts" >/dev/null \
    || fail "typed backup alerts are missing or duplicated"
if rg -F 'typed-alert-secret-canary' \
    "$VESTA/data/users/alice/docker-projects/app/alerts.json"; then
    fail "typed backup alert state leaked a managed secret"
fi

# A healthy, fresh, replicated and recently restore-tested policy closes
# policy-derived alerts without blocking evaluation.
now="$(vx_compose_now)"
for update in \
    "LAST_SUCCESS $now" \
    "NEXT_RUN 2999-01-01T00:00:00Z" \
    "REPLICATION_STATE succeeded" \
    "LAST_REPLICATED $now" \
    "LAST_RESTORE_TEST $now" \
    "RESTORE_TEST_STATE succeeded" \
    "LAST_ERROR ''"; do
    # Values here contain no whitespace except the field separator.
    field="${update%% *}"
    value="${update#* }"
    [[ "$value" != "''" ]] || value=''
    vx_compose_backup_policy_state_update "$policy_path" "$field" "$value"
done
vx_compose_backup_alerts_evaluate_policy alice app
jq -e '
    all(
        .ALERTS[]
        | select(
            .TYPE == "missed-run"
            or .TYPE == "freshness-breach"
            or .TYPE == "replication-lag"
            or .TYPE == "replication-failure"
            or .TYPE == "restore-test-failure"
        );
        .STATUS == "closed"
    )
' <<<"$(vx_compose_alerts_list_json alice app)" >/dev/null \
    || fail "policy alert recovery did not close derived alerts"

if rg -F 'backup-secret-canary' "$VESTA/data/users" \
    --glob 'backup-policy.conf' --glob 'audit.log' --glob 'alerts.json'; then
    fail "backup lifecycle surfaces leaked a managed secret"
fi

echo "Compose backup policy tests passed."
