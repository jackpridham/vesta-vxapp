#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_COMPOSE_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
mkdir -p "$VESTA/data/users/alice/docker-projects/app/runtime" \
    "$VESTA/data/users/alice/docker-projects/app/revisions/000001" \
    "$VESTA/data/users/alice/docker-projects/app/secrets" \
    "$VESTA/data/users/alice/docker-projects/.locks" \
    "$VESTA/data/users/alice" "$VESTA/data" "$HOMEDIR/alice"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

root="$VESTA/data/users/alice/docker-projects/app"
revision_root="$root/revisions/000001"
printf '%s\n' \
    "OWNER='alice'" "PROJECT='app'" "PROFILE='admin-approved'" \
    "REVISION='1'" >"$root/project.conf"
printf '%s\n' \
    "POLICY_SCHEMA='1'" "PROFILE_VERSION='3'" "VALIDATOR_VERSION='2'" \
    >"$root/policy.conf"
printf '%s\n' 'synthetic-probe-secret' >"$root/secrets/credential"
chmod 0600 "$root/secrets/credential"
printf '%s\n' '{"compatibility":{"orchestrator_api":1,"policy_schema":1,"validator_max":2,"validator_min":1},"health_timeout_seconds":30,"image":{"architecture":"amd64","id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","os":"linux","reference":"local/example:release-1"},"ports":[],"probes":{"ready":{"argv":["/usr/local/bin/example-health","--json"],"max_output_bytes":512,"service":"service","timeout_seconds":1}},"profile":{"name":"admin-approved","version":3},"resources":{"cpus":"1.000","memory_mib":128,"pids":64},"schema":1,"secrets":[],"services":[{"image":"local/example:release-1","name":"service"}],"volumes":[],"workload":{"id":"example","release":"release-1"}}' \
    >"$revision_root/workload.json"
chmod 0600 "$revision_root/workload.json"
(
    cd "$revision_root"
    sha256sum workload.json >manifest.sha256
)
chmod 0640 "$revision_root/manifest.sha256"

fake_docker="$test_root/fake-docker"
mode_file="$test_root/docker-mode"
inspect_count="$test_root/inspect-count"
argv_log="$test_root/argv.log"
printf pass >"$mode_file"
printf 0 >"$inspect_count"
touch "$argv_log"
chmod 0600 "$mode_file" "$inspect_count" "$argv_log"
cat >"$fake_docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
base="$(dirname -- "$0")"
mode="$(<"$base/docker-mode")"
if [[ " $* " == *" ps -aq "* ]]; then
    printf '%s\n' aaaaaaaaaaaa
    exit 0
fi
if [[ " $* " == *" inspect "* ]]; then
    count="$(<"$base/inspect-count")"
    printf '%s\n' "$((count + 1))" >"$base/inspect-count"
    revision=1
    started_at='2026-08-06T00:00:00Z'
    if [[ "$mode" == identity && "$count" -ge 1 ]]; then
        revision=2
    fi
    [[ "$mode" != restart ]] || started_at='2026-08-06T00:01:00Z'
    jq -n \
        --arg revision "$revision" \
        --arg started_at "$started_at" \
        --arg image 'sha256:1111111111111111111111111111111111111111111111111111111111111111' '[{
            Id:"aaaaaaaaaaaa", Image:$image,
            Config:{Labels:{
                "com.docker.compose.project":"vx-alice-app",
                "com.docker.compose.service":"service",
                "vx.managed":"yes", "vx.user":"alice", "vx.project":"app",
                "vx.revision":$revision, "vx.image-id":$image
            }},
            State:{Status:"running",StartedAt:$started_at}
        }]'
    exit 0
fi
if [[ " $* " == *" exec "* ]]; then
    shift
    container=$1
    shift
    : >"$base/argv.log"
    for argument in "$@"; do
        printf 'ARG=%s\n' "$argument" >>"$base/argv.log"
    done
    case "$mode" in
        pass|identity)
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}'
            ;;
        fail)
            printf '%s\n' \
                '{"schema":1,"state":"fail","summary":"not ready","observations":{"check":"pending"}}'
            ;;
        secret)
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"synthetic-probe-secret","observations":{"check":"ok"}}'
            ;;
        duplicate)
            printf '%s\n' \
                '{"schema":1,"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}'
            ;;
        credential)
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"authorization ready","observations":{"check":"ok"}}'
            ;;
        nonzero)
            printf '%s\n' 'synthetic-probe-secret from stderr' >&2
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}'
            exit 7
            ;;
        slow)
            sleep 2
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"late","observations":{"check":"ok"}}'
            ;;
        hang)
            sleep 5
            ;;
        restart)
            printf '%s\n' \
                '{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}'
            ;;
    esac
    exit 0
fi
exit 64
EOF
chmod 0755 "$fake_docker"

fake_engine="$test_root/fake-probe-engine"
cat >"$fake_engine" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
base="$(dirname -- "$0")"
if [[ "$1" == inspect ]]; then
    printf '%s\n' '{"EXEC_ID":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","RUNNING":true,"EXIT_CODE":null,"PID":42}' >"$3"
    chmod 0600 "$3"
    exit 0
fi
request=$1 stdout=$2 stderr=$3 result=$4
mode="$(<"$base/docker-mode")"
jq -r '.argv[]|"ARG="+.' "$request" >"$base/argv.log"
exit_code=0 running=false transport=false declared=false truncated=false
case "$mode" in
  pass|identity|restart) printf '%s\n' '{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}' >"$stdout" ;;
  fail) printf '%s\n' '{"schema":1,"state":"fail","summary":"not ready","observations":{"check":"pending"}}' >"$stdout" ;;
  secret) printf '%s\n' '{"schema":1,"state":"pass","summary":"synthetic-probe-secret","observations":{"check":"ok"}}' >"$stdout" ;;
  duplicate) printf '%s\n' '{"schema":1,"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}' >"$stdout" ;;
  credential) printf '%s\n' '{"schema":1,"state":"pass","summary":"authorization ready","observations":{"check":"ok"}}' >"$stdout" ;;
  nonzero) printf '%s\n' 'synthetic-probe-secret from stderr' >"$stderr"; printf '%s\n' '{"schema":1,"state":"pass","summary":"ready","observations":{"check":"ok"}}' >"$stdout"; exit_code=7 ;;
  slow) printf '%s\n' '{"schema":1,"state":"pass","summary":"late","observations":{"check":"ok"}}' >"$stdout"; declared=true ;;
  hang) transport=true; running=true ;;
esac
jq -nS --argjson exit "$exit_code" --argjson running "$running" \
  --argjson transport "$transport" --argjson declared "$declared" \
  --argjson truncated "$truncated" '{EXEC_ID:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  RUNNING:$running,PID:42,EXIT_CODE:$exit,TRANSPORT_TIMEOUT:$transport,
  DECLARED_TIMEOUT:$declared,TRUNCATED:$truncated}' >"$result"
chmod 0600 "$result"
EOF
chmod 0755 "$fake_engine"
export VX_COMPOSE_PROBE_ENGINE_HELPER="$fake_engine"

source "$repo_root/func/vx/compose/common.sh"
source "$repo_root/func/vx/compose/audit.sh"
source "$repo_root/func/vx/compose/probes.sh"

vx_compose_project_root() {
    printf '%s/data/users/%s/docker-projects/%s\n' "$VESTA" "$1" "$2"
}
vx_compose_projects_root() {
    printf '%s/data/users/%s/docker-projects\n' "$VESTA" "$1"
}
vx_compose_meta_get() {
    local key="$2"
    sed -n "s/^${key}='\\(.*\\)'$/\\1/p" "$1" | head -n 1
}
vx_compose_probe_lock_authorize() { return 0; }
vx_compose_lock_release() { return 0; }
vx_compose_active_revision_verify() { return 0; }
vx_compose_profile_require_authorized() { return 0; }
vx_compose_image_approval_require() { return 0; }
vx_compose_runtime_identity_preflight() { printf '%s\n' complete; }
vx_compose_audit() { return 0; }
vx_compose_docker_bin() { printf '%s\n' "$fake_docker"; }

run_probe() {
    vx_compose_probe_run admin alice app ready
}

payload="$(run_probe)" || fail 'passing probe was rejected'
jq -e '
    .SCHEMA == 1 and .OWNER == "alice" and .PROJECT == "app"
    and .PROBE == "ready" and .SERVICE == "service"
    and .REVISION == 1 and .STATE == "pass" and .EXIT_CODE == 0
    and .SUMMARY == "ready" and .OBSERVATIONS.check == "ok"
    and (.WORKLOAD_SHA256 | test("^[a-f0-9]{64}$"))
' <<<"$payload" >/dev/null || fail 'passing result schema is wrong'
cmp -s <(printf '%s\n' "$payload") "$root/runtime/last-probe.json" \
    || fail 'safe controller result was not persisted exactly'
[[ "$(stat -c '%a' "$root/runtime/last-probe.json")" == 600 ]] \
    || fail 'persisted safe controller result is not mode 0600'
grep -Fxq 'ARG=/usr/local/bin/example-health' "$argv_log" \
    || fail 'manifest executable was not passed directly'
grep -Fxq 'ARG=--json' "$argv_log" \
    || fail 'manifest argument was not passed directly'

printf fail >"$mode_file"
payload="$(run_probe)" || fail 'application failure result was unavailable'
jq -e '.STATE == "fail" and .SUMMARY == "not ready"
    and .OBSERVATIONS.check == "pending"' <<<"$payload" >/dev/null \
    || fail 'application failure was not retained safely'

printf secret >"$mode_file"
payload="$(run_probe)" || fail 'secret disclosure did not produce a result'
jq -e '.STATE == "invalid-output" and .OBSERVATIONS == {}' \
    <<<"$payload" >/dev/null || fail 'managed secret disclosure was accepted'
grep -Fq 'synthetic-probe-secret' <<<"$payload" \
    && fail 'managed secret appeared in controller output'

printf duplicate >"$mode_file"
payload="$(run_probe)" || fail 'duplicate-key output did not produce a result'
jq -e '.STATE == "invalid-output"' <<<"$payload" >/dev/null \
    || fail 'duplicate JSON keys were accepted'

printf credential >"$mode_file"
payload="$(run_probe)" || fail 'credential-like output did not produce a result'
jq -e '.STATE == "invalid-output"' <<<"$payload" >/dev/null \
    || fail 'credential-like output was accepted'

printf nonzero >"$mode_file"
payload="$(run_probe)" || fail 'process failure did not produce a result'
jq -e '.STATE == "unavailable" and .EXIT_CODE == 7
    and .OBSERVATIONS == {}' <<<"$payload" >/dev/null \
    || fail 'process failure was represented as an application pass'
grep -Fq 'synthetic-probe-secret' <<<"$payload" \
    && fail 'raw probe stderr appeared in controller output'

printf slow >"$mode_file"
payload="$(run_probe)" || fail 'late probe did not produce a result'
jq -e '.STATE == "timeout" and .OBSERVATIONS == {}' \
    <<<"$payload" >/dev/null || fail 'declared timeout was not enforced'

printf hang >"$mode_file"
payload="$(run_probe)" || fail 'transport deadline did not produce a result'
jq -e '.STATE == "unavailable" and .EXIT_CODE == null' \
    <<<"$payload" >/dev/null || fail 'transport deadline was not unavailable'
[[ "$(stat -c '%a' "$root/runtime/probes/unavailable.json")" == 600 ]] \
    || fail 'probe-unavailable latch is not protected'
if run_probe >"$test_root/latched-output" 2>"$test_root/latched-error"; then
    fail 'latched project launched another probe'
fi
[[ ! -s "$test_root/latched-output" ]] \
    || fail 'latched probe returned workload output'
printf restart >"$mode_file"
payload="$(run_probe)" || fail 'container restart did not clear probe latch'
jq -e '.STATE == "pass"' <<<"$payload" >/dev/null \
    || fail 'probe did not recover after container restart'
[[ ! -e "$root/runtime/probes/unavailable.json" ]] \
    || fail 'stale probe-unavailable latch was retained after restart'

printf identity >"$mode_file"
printf 0 >"$inspect_count"
payload="$(run_probe)" || fail 'identity race did not produce a result'
jq -e '.STATE == "unavailable" and .EXIT_CODE == null
    and .OBSERVATIONS == {}' <<<"$payload" >/dev/null \
    || fail 'runtime identity drift was not rejected'

find "$root/runtime/probes" -maxdepth 1 -type d -name '.capture.*' \
    | grep -q . && fail 'protected capture directory was retained'

printf '%s\n' 'PASS: immutable project probe controller'
