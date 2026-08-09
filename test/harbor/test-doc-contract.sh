#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
provider="$root/.docs/contracts/harbor-provider.md"
shell_access="$root/.docs/contracts/compose-shell-access.md"
spec="$root/.docs/specs/2026-08-08-vesta-managed-harbor-registry.md"
validation="$root/.docs/validation/2026-08-08-vesta-managed-harbor-development.md"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1" phrase="$2"
    rg -Fqi -- "$phrase" "$file" \
        || fail "${file#"$root/"} omits: $phrase"
}

line_of() {
    local file="$1" phrase="$2" line
    line="$(rg -n -m1 -F -- "$phrase" "$file" | cut -d: -f1)" || :
    [[ "$line" =~ ^[1-9][0-9]*$ ]] \
        || fail "${file#"$root/"} omits structural anchor: $phrase"
    printf '%s\n' "$line"
}

assert_before() {
    local file="$1" earlier="$2" later="$3" earlier_line later_line
    earlier_line="$(line_of "$file" "$earlier")"
    later_line="$(line_of "$file" "$later")"
    (( earlier_line < later_line )) \
        || fail "expected '$earlier' before '$later' in ${file#"$root/"}"
}

for file in "$provider" "$shell_access" "$spec" "$validation"; do
    [[ -s "$file" ]] || fail "missing Milestone 1 document: ${file#"$root/"}"
done

# Harbor v2.15.0 source parity: RobotCreate.secret is ignored, CreateSec is
# authoritative, RobotCreated.secret is one-time output, read/list redact it,
# delegated child permissions must be a subset, and robot RBAC omits update.
for phrase in \
    'e2b5ce92728f86c4b02f6a9a667741c1e5b62678' \
    'RobotCreate.secret' \
    'RobotCreated.secret' \
    'always generates a valid secret' \
    'secret-redacted' \
    'every child permission is a subset' \
    'robot:update' \
    'Update and refresh therefore return `403`'
do
    assert_contains "$provider" "$phrase"
done

for source_path in \
    'src/controller/robot/controller.go' \
    'src/server/v2.0/handler/robot.go' \
    'src/server/v2.0/handler/model/robot.go' \
    'src/common/rbac/const.go'
do
    assert_contains "$validation" "$source_path"
done

# The corrected routine lifecycle is generated-secret create/verify/switch/
# delete. Runtime is pull-only, publisher is pull+push, lost create responses
# leave a marked candidate, and revocation is delete followed by not-found.
for phrase in \
    'create, verify, switch Vesta authority, and delete the prior child' \
    'Runtime children are project-level and pull-only' \
    'project-level and pull-plus-push' \
    'Harbor-generated one-time create secrets' \
    'Every create request carries a unique non-secret candidate marker' \
    'read validates `404`' \
    'artifacts are retained' \
    'metadata, exactly `{"public":"false"}`'
do
    assert_contains "$provider" "$phrase"
done

for phrase in \
    'system scope `/`' \
    'wildcard project scope' \
    'read/list/pull/push' \
    'robot create/read/list/delete' \
    'Routine Vesta lifecycle shall use create, verify, switch, and' \
    'delete only, never robot update/refresh' \
    'marked unrecoverable candidate' \
    'delete the old generation and validate its absence'
do
    assert_contains "$spec" "$phrase"
done

# Owner command and plaintext authority are fixed at this milestone. Publisher
# plaintext is never durable; runtime plaintext-equivalent remains Vesta-owned.
for file in "$provider" "$spec"; do
    assert_contains "$file" 'registry-publisher-rotate < age-recipient'
    assert_contains "$file" 'ASCII-armored age ciphertext'
done
assert_contains "$shell_access" 'registry-publisher-rotate'
assert_contains "$shell_access" '< age-recipient'
assert_contains "$shell_access" 'ASCII-armored age ciphertext'
assert_contains "$provider" 'Publisher plaintext is never durable on Vesta'
assert_contains "$provider" 'runtime pull plaintext-equivalent remains Vesta-owned'
assert_contains "$shell_access" 'failed rotation leaves stdout empty'
assert_contains "$spec" 'Publisher plaintext shall never be written to a regular file'

# Superseded behavior is absent only from the Milestone 1 active authorities.
# Tenant guides and deployment runbooks are intentionally deferred to
# Milestone 4, while the validation record intentionally preserves the failed
# historical publisher-change evidence.
if rg -n -i \
    'registry-publisher-change|caller-generated publisher secret|developer generates secret' \
    "$provider" "$shell_access" "$spec"
then
    fail 'Milestone 1 authority retains the superseded publisher-secret contract'
fi

# Preserve the original failed development evidence, append the source-backed
# resolution after it, and keep live acceptance explicitly incomplete.
for phrase in \
    'BLOCKED — PRODUCT' \
    'requested creation secret equals returned secret: false' \
    'integration robot refresh of child secret:       403' \
    'v-docker registry-publisher-change' \
    '## Acceptance not claimed' \
    '## Source-validated resolution — 2026-08-09' \
    'The failed development evidence above is preserved as observed' \
    'development acceptance remains incomplete' \
    'This is design and local fixture evidence only' \
    'No corrected' \
    'successor was staged' \
    'all production deployment remain deferred'
do
    assert_contains "$validation" "$phrase"
done
assert_before "$validation" '## Install transaction and product blocker' \
    '## Source-validated resolution — 2026-08-09'
assert_before "$validation" '## Acceptance not claimed' \
    '## Source-validated resolution — 2026-08-09'

printf 'PASS: Harbor Milestone 1 documentation contract\n'
