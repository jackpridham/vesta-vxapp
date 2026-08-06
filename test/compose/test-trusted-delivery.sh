#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_DOCKER_TRUST_ADAPTER_ROOT="$test_root/adapters"
export VX_DOCKER_TRUST_TIMEOUT_SECONDS=1
export VX_DOCKER_POLICY_VALIDATOR_VERSION=2
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice" \
    "$VX_DOCKER_TRUST_ADAPTER_ROOT"
printf "DOCKER_PROJECTS='0'\n" >"$VESTA/data/users/alice/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

make_adapter() {
    local name="$1"
    cat >"$VX_DOCKER_TRUST_ADAPTER_ROOT/$name" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" -eq 3 && "$1" =~ ^sha256:[a-f0-9]{64}$ && -d "$2" ]] || exit 2
if env | grep -Eq '^(TRUST_|DOCKER_|REGISTRY_|VESTA=|HOMEDIR=)'; then
    echo 'trust-secret-must-not-leak' >&2
    exit 3
fi
expected_root="$(dirname -- "$(dirname -- "$2")")"
[[ "$PWD" == "$expected_root"
    && "$(readlink /proc/self/fd/0)" == /dev/null
    && ! -e /proc/self/fd/9 ]] || {
    echo 'trust-secret-must-not-leak' >&2
    exit 3
}
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$2/adapter.log"
state="$(cat "$2/adapter-state" 2>/dev/null || printf pass)"
if [[ "$state" == timeout ]]; then
    sleep 2
fi
if [[ "$state" == oversize ]]; then
    head -c 32768 /dev/zero | tr '\0' x
    exit 0
fi
if [[ "$state" == error ]]; then
    echo 'trust-secret-must-not-leak' >&2
    exit 3
fi
jq -n -c --arg adapter "$(basename -- "$0")" --arg state "$state" \
    '{SCHEMA:1,ADAPTER:$adapter,STATE:$state,DETAIL:"bounded result"}'
EOF
    chmod 0755 "$VX_DOCKER_TRUST_ADAPTER_ROOT/$name"
}

make_adapter signature
make_adapter vulnerability
export TRUST_SECRET_CANARY='trust-secret-must-not-leak'
printf 'inherited-fd-canary\n' >"$test_root/inherited-fd"
exec 9<"$test_root/inherited-fd"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

digest='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
reference="example.test/app@$digest"
image_id='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
labels='{"source":"https://example.test/source","revision":"abc","version":"1","vendor":"Vortex","created":"2026-07-31T00:00:00Z"}'

export VX_DOCKER_TRUST_MODE_STANDARD=disabled
disabled="$(vx_compose_verify_image_trust standard '' "$image_id" "$labels")"
jq -e '.MODE == "disabled" and .DECISION == "disabled"
    and .SIGNATURE.STATE == "not-run"' <<<"$disabled" >/dev/null \
    || fail "explicit disabled mode did not preserve approved local images"
[[ ! -e "$(vx_compose_trust_root)" ]] \
    || fail "disabled trust mode invoked an adapter"
export VX_DOCKER_TRUST_MODE_STANDARD=enforce
pass="$(vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels")"
jq -e '.MODE == "enforce" and .DECISION == "pass"
    and .SIGNATURE.STATE == "pass"
    and .VULNERABILITY.STATE == "pass"
    and .PROFILE_VERSION == 2 and .POLICY_VERSION == 2' \
    <<<"$pass" >/dev/null || fail "enforced trust pass was not policy bound"
evidence="$(vx_compose_trust_evidence_dir "$digest")"
adapter_log="$evidence/adapter.log"
[[ "$(wc -l <"$adapter_log")" -eq 2 ]] \
    || fail "isolated trust adapters did not receive the bounded interface"
[[ "$evidence" == "$VESTA/data/vx/compose/image-trust/evidence/"*
    && "$evidence" != "$VESTA/data/users/"*
    && "$(stat -c '%a' "$evidence/image.json")" == 600 ]] \
    || fail "image evidence was not protected outside tenant paths"
jq -e '.OCI_LABELS | keys
    == ["created","revision","source","vendor","version"]' \
    "$evidence/image.json" >/dev/null \
    || fail "OCI evidence exceeded the bounded label allowlist"
cp "$evidence/image.json" "$test_root/image.json.valid"
jq '.IMAGE_ID = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
    "$test_root/image.json.valid" >"$evidence/image.json"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>"$test_root/rebind.err"; then
    fail "stale digest evidence accepted a mismatched daemon image identity"
fi
mv "$test_root/image.json.valid" "$evidence/image.json"

attachment="$test_root/sbom.spdx.json"
printf '{"spdxVersion":"SPDX-2.3","canary":"document-not-public"}\n' >"$attachment"
chmod 0600 "$attachment"
public_attachment="$(
    vx_compose_trust_attachment_add \
        "$digest" sbom "$attachment" buildkit-0.13 verified
)"
jq -e 'keys == ["CREATED","DIGEST","GENERATOR","TYPE","VERIFICATION_STATE"]
    and .TYPE == "sbom" and .VERIFICATION_STATE == "verified"' \
    <<<"$public_attachment" >/dev/null \
    || fail "attachment metadata was not bounded"
grep -Fq 'document-not-public' "$evidence/sbom.document" \
    || fail "protected SBOM document was not retained"
if grep -Fq 'document-not-public' "$evidence/sbom.json"; then
    fail "SBOM document content leaked into metadata"
fi

printf '%s\n' offline >"$evidence/adapter-state"
export VX_DOCKER_TRUST_MODE_STANDARD=audit
audit="$(vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels")"
jq -e '.MODE == "audit" and .DECISION == "fail"
    and .SIGNATURE.STATE == "offline"
    and .VULNERABILITY.STATE == "offline"' <<<"$audit" >/dev/null \
    || fail "audit mode did not retain explicit offline state"

export VX_DOCKER_TRUST_MODE_STANDARD=enforce
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >"$test_root/enforce.out" 2>"$test_root/enforce.err"; then
    fail "enforce mode accepted offline adapters"
fi
grep -Fq 'Docker image trust verification failed' "$test_root/enforce.err" \
    || fail "enforcement returned the wrong redacted diagnostic"

printf '%s\n' error >"$evidence/adapter-state"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >"$test_root/error.out" 2>"$test_root/error.err"; then
    fail "enforce mode accepted failed adapters"
fi
if grep -R -Fq "$TRUST_SECRET_CANARY" \
    "$test_root/error.out" "$test_root/error.err" \
    "$(vx_compose_trust_root)/decisions"; then
    fail "adapter stderr canary leaked"
fi
jq -e '.SIGNATURE.STATE == "error"
    and .VULNERABILITY.STATE == "error"' \
    "$(vx_compose_trust_root)/decisions/${digest#sha256:}.json" >/dev/null \
    || fail "adapter failure was not normalized"

printf '%s\n' timeout >"$evidence/adapter-state"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>"$test_root/timeout.err"; then
    fail "enforce mode accepted timed-out adapters"
fi
jq -e '.SIGNATURE.STATE == "timeout"
    and .VULNERABILITY.STATE == "timeout"' \
    "$(vx_compose_trust_root)/decisions/${digest#sha256:}.json" >/dev/null \
    || fail "adapter timeout was not normalized"

printf '%s\n' oversize >"$evidence/adapter-state"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>"$test_root/oversize.err"; then
    fail "enforce mode accepted oversized adapter output"
fi
jq -e '.SIGNATURE.STATE == "error"
    and .VULNERABILITY.STATE == "error"' \
    "$(vx_compose_trust_root)/decisions/${digest#sha256:}.json" >/dev/null \
    || fail "oversized adapter output was not bounded and normalized"

rm -f "$VX_DOCKER_TRUST_ADAPTER_ROOT/signature"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>"$test_root/unavailable.err"; then
    fail "enforce mode accepted an unavailable adapter"
fi
jq -e '.SIGNATURE.STATE == "unavailable"' \
    "$(vx_compose_trust_root)/decisions/${digest#sha256:}.json" >/dev/null \
    || fail "unavailable adapter state was not retained"

make_adapter signature
printf '%s\n' fail >"$evidence/adapter-state"
exception_root="$(vx_compose_trust_root)/exceptions"
mkdir -p "$exception_root"
expires="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
jq -n -S --arg digest "$digest" --arg expires "$expires" '{
    SCHEMA:1,AUTHORITY:"root",DIGEST:$digest,PROFILE:"standard",
    PROFILE_VERSION:2,POLICY_VERSION:2,EXPIRES:$expires,
    REASON:"bounded release exception"
}' >"$exception_root/${digest#sha256:}.json"
chmod 0600 "$exception_root/${digest#sha256:}.json"
excepted="$(
    vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels"
)"
jq -e '.DECISION == "exception" and .EXCEPTION == true' \
    <<<"$excepted" >/dev/null \
    || fail "valid root exception did not bind the failed digest"

sed -i 's/"PROFILE_VERSION": 2/"PROFILE_VERSION": 99/' \
    "$exception_root/${digest#sha256:}.json"
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>&1; then
    fail "mismatched profile-version exception was accepted"
fi

if VX_DOCKER_TRUST_MODE_STANDARD=enforce \
    vx_compose_verify_image_trust standard '' "$image_id" "$labels" \
    >/dev/null 2>"$test_root/local.err"; then
    fail "enforced registry policy silently downgraded to local image"
fi
grep -Fq 'registry digest is required' "$test_root/local.err" \
    || fail "local-image enforcement rejection was not explicit"

export VX_DOCKER_TRUST_MODE_STANDARD=unexpected
if vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >/dev/null 2>"$test_root/mode.err"; then
    fail "invalid trust mode silently downgraded"
fi
grep -Fq 'trust mode is invalid' "$test_root/mode.err" \
    || fail "invalid trust mode returned the wrong diagnostic"

export VX_DOCKER_TRUST_MODE_STANDARD=enforce
export VX_DOCKER_TRUST_MODE_ADMIN_APPROVED=enforce
printf '%s\n' pass >"$evidence/adapter-state"
vx_compose_verify_image_trust standard "$reference" "$image_id" "$labels" \
    >"$test_root/race-standard.json" &
race_standard_pid=$!
vx_compose_verify_image_trust admin-approved \
    "$reference" "$image_id" "$labels" >"$test_root/race-admin.json" &
race_admin_pid=$!
wait "$race_standard_pid"
wait "$race_admin_pid"
jq -e '.PROFILE == "standard" and .MODE == "enforce"
    and .DECISION == "pass"' "$test_root/race-standard.json" >/dev/null \
    || fail "concurrent standard verification returned a crossed decision"
jq -e '.PROFILE == "admin-approved" and .MODE == "enforce"
    and .DECISION == "pass"' "$test_root/race-admin.json" >/dev/null \
    || fail "concurrent admin verification returned a crossed decision"

exec 9<&-
echo "Compose trusted delivery tests passed."
