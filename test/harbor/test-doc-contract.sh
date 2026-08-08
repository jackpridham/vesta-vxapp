#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
guide="$root/.docs/user-guides/vesta-managed-harbor.md"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

line_of() {
    local phrase="$1" line
    line="$(rg -n -m1 -F -- "$phrase" "$guide" | cut -d: -f1)" || :
    [[ "$line" =~ ^[1-9][0-9]*$ ]] || fail "missing structural anchor: $phrase"
    printf '%s\n' "$line"
}

assert_before() {
    local earlier="$1" later="$2" earlier_line later_line
    earlier_line="$(line_of "$earlier")"
    later_line="$(line_of "$later")"
    (( earlier_line < later_line )) \
        || fail "expected '$earlier' before '$later'"
}

[[ -s "$guide" ]] || fail 'canonical Harbor tenant guide missing'

for phrase in \
    'registry-info PROJECT' 'registry-publisher-change' \
    'immutable preview' 'No SCP, rsync' 'Automated restore apply'
do
    rg -q "$phrase" "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" \
        "$root/docs/container-orchestration.md" \
        "$root/.docs/contracts/harbor-provider.md" \
        || fail "missing doc behavior: $phrase"
done

for phrase in \
    'BLOCKED — PRODUCT' 'production is deferred' \
    'no public host TCP listener' '/v2/' '/service/token' \
    'DOCKER_REGISTRY_MB' 'U_DOCKER_REGISTRY_MB' \
    'Runtime pull identity' 'Publisher identity' 'Vesta administrator' \
    'Tenant maintainer' 'Application repository' \
    'registry-info APP_PROJECT' \
    'registry-publisher-change < publisher-secret' \
    'registry-publisher-disable' '--password-stdin' \
    'v-docker image-pull' 'v-docker rollback-preview' \
    '26b3764595a024b5b830a955b164f0ad95a25a2b'
do
    rg -Fq -- "$phrase" "$guide" \
        || fail "missing tenant guide behavior: $phrase"
done

for generic_name in slave-vxapp asterisk-vxapp; do
    rg -Fq -- "$generic_name" "$guide" \
        || fail "required generic application example missing: $generic_name"
done
for placeholder in APP_OWNER APP_PROJECT IMAGE_NAME RELEASE_TAG; do
    rg -Fq -- "$placeholder='$placeholder'" "$guide" \
        || fail "required command placeholder missing: $placeholder"
done

# The required development host and acknowledgement must guard every command.
assert_before "VESTA_HOST='dev.jackpridham.com'" \
    '[[ "$deployment_acknowledgement" == '\''DEVELOPMENT ONLY - PRODUCTION DEFERRED'\'' ]]'
assert_before '[[ "$deployment_acknowledgement" == '\''DEVELOPMENT ONLY - PRODUCTION DEFERRED'\'' ]]' \
    'SSH_TARGET="${APP_OWNER}@${VESTA_HOST}"'
assert_before 'SSH_TARGET="${APP_OWNER}@${VESTA_HOST}"' \
    'ssh -- "$SSH_TARGET" v-docker quota json'
[[ "$(rg -F -c -- 'dev.jackpridham.com' "$guide")" -ge 2 ]] \
    || fail 'required development hostname is not assigned and checked'

# Credential-helper selection and executable validation must precede both
# publisher rotation and login. Inline base64 auth must be absent before and
# after login, and the password may enter Docker only on stdin.
assert_before '(.credHelpers[$registry] // .credsStore // empty)' \
    'command -v -- "$helper_binary"'
assert_before 'command -v -- "$helper_binary"' \
    'ssh -- "$SSH_TARGET" v-docker registry-publisher-change'
assert_before 'ssh -- "$SSH_TARGET" v-docker registry-publisher-change' \
    'docker login "$REGISTRY"'
assert_before 'docker login "$REGISTRY"' \
    '--password-stdin <"$publisher_secret_file"'
password_stdin_line="$(line_of '--password-stdin <"$publisher_secret_file"')"
cleanup_line="$(rg -n -F -- 'rm -f -- "$publisher_secret_file"' "$guide" \
    | tail -n 1 | cut -d: -f1)"
(( password_stdin_line < cleanup_line )) \
    || fail 'publisher secret file is not removed after login'
mapfile -t inline_auth_lines < <(
    rg -n -F -- '((.auths[$registry].auth? // "") == "")' "$guide" \
        | cut -d: -f1
)
[[ "${#inline_auth_lines[@]}" -eq 2 ]] \
    || fail 'inline Docker auth must be checked before and after login'
rotation_line="$(line_of 'ssh -- "$SSH_TARGET" v-docker registry-publisher-change')"
login_line="$(line_of 'docker login "$REGISTRY"')"
(( inline_auth_lines[0] < rotation_line && inline_auth_lines[1] > login_line )) \
    || fail 'inline Docker auth checks do not bracket credential use'
rg -Fq 'reversible base64 `auth` value' "$guide" \
    || fail 'Docker base64 credential risk is not documented'
rg -Fq 'does not offer a temporary isolated' "$guide" \
    || fail 'unsafe isolated Docker config fallback is not rejected'
! rg -q -- '--password([ =]|$)' "$guide" \
    || fail 'unsafe registry password argument in tenant guide'

# The local Compose preflight must prove every image is immutable and the
# requested image occurs exactly once before preview/pull.
assert_before '[[ "$compose_image" =~ @sha256:[a-f0-9]{64}$ ]]' \
    '((image_occurrences += 1))'
assert_before '((image_occurrences += 1))' \
    '[[ "$image_occurrences" -eq 1 ]]'
assert_before '[[ "$image_occurrences" -eq 1 ]]' \
    'v-docker preview "$APP_PROJECT" change'
assert_before 'v-docker preview "$APP_PROJECT" change' \
    'ssh -- "$SSH_TARGET" v-docker image-pull'
rg -Fq 'call `v-docker image-pull` once' "$guide" \
    && rg -Fq 'per image with the same preview tuple before apply' "$guide" \
    || fail 'multi-image pull contract is missing'

# The exact v-docker show schema must fail closed before probe extraction or
# branch selection. WORKLOAD may be null; an object must contain a valid,
# unique probe-name array. Optional []? extraction is forbidden here.
schema_start_line="$(line_of '# Validate the exact v-docker show WORKLOAD contract before extraction.')"
[[ "$(sed -n "$((schema_start_line + 1))p" "$guide")" == "jq -e '" ]] \
    || fail 'WORKLOAD schema guard is not an enforcing jq expression'
schema_end_line="$(awk -v start="$schema_start_line" \
    'NR > start && /<<<"\$after_json" >\/dev\/null/ {print NR; exit}' \
    "$guide")"
[[ "$schema_end_line" =~ ^[1-9][0-9]*$ ]] \
    || fail 'WORKLOAD schema guard has no fail-closed completion'
for schema_anchor in \
    'has("WORKLOAD")' '.WORKLOAD == null' \
    '(.WORKLOAD | type) == "object"' \
    '.WORKLOAD | has("PROBES")' \
    '(.WORKLOAD.PROBES | type) == "array"' \
    '.WORKLOAD.PROBES[];' \
    'test("^[a-z0-9][a-z0-9-]{0,62}$")' \
    '.WORKLOAD.PROBES | unique | length'
do
    schema_anchor_line="$(line_of "$schema_anchor")"
    (( schema_start_line < schema_anchor_line \
        && schema_anchor_line < schema_end_line )) \
        || fail "WORKLOAD schema anchor is outside guard: $schema_anchor"
done
probe_extract_line="$(line_of 'if .WORKLOAD == null then empty else .WORKLOAD.PROBES[] end')"
probe_if_line="$(line_of 'if ((${#probe_names[@]} > 0)); then')"
(( schema_end_line < probe_extract_line && probe_extract_line < probe_if_line )) \
    || fail 'WORKLOAD schema is not validated before extraction and branching'
! rg -Fq '.WORKLOAD.PROBES[]?' "$guide" \
    || fail 'optional probe extraction can hide malformed WORKLOAD schema'

# Both readiness paths are executable branches and converge on common health,
# revision, drift, and rollback-preview evidence.
probe_command_line="$(line_of 'v-docker probe "$APP_PROJECT" "$probe_name" json')"
probe_else_line="$(awk -v start="$probe_if_line" \
    'NR > start && /^else$/ {print NR; exit}' "$guide")"
app_placeholder_line="$(line_of "APP_ACCEPTANCE_COMMAND='APP_ACCEPTANCE_COMMAND'")"
app_command_line="$(line_of '  "$app_acceptance_path"')"
probe_fi_line="$(awk -v start="$probe_else_line" \
    'NR > start && /^fi$/ {print NR; exit}' "$guide")"
[[ "$probe_else_line" =~ ^[1-9][0-9]*$ \
    && "$probe_fi_line" =~ ^[1-9][0-9]*$ ]] \
    || fail 'probe/no-probe branch is incomplete'
(( probe_if_line < probe_command_line \
    && probe_command_line < probe_else_line \
    && probe_else_line < app_placeholder_line \
    && app_placeholder_line < app_command_line \
    && app_command_line < probe_fi_line )) \
    || fail 'probe/no-probe branch ordering is invalid'
health_line="$(line_of '.STATUS == "healthy"')"
revision_line="$(line_of 'after_revision="$(jq -er')"
drift_line="$(line_of '.MATCH == true')"
rollback_check_line="$(line_of 'rollback_check_json="$(')"
(( health_line < probe_if_line && revision_line < probe_if_line \
    && drift_line < probe_if_line && rollback_check_line > probe_fi_line )) \
    || fail 'common health/revision/drift/rollback checks do not cover both branches'
rg -Fq 'without `eval`' "$guide" \
    || fail 'app-owned acceptance command safety is not documented'

for source in \
    "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" \
    "$root/docs/container-orchestration.md" "$root/.docs/README.md"
do
    rg -q 'vesta-managed-harbor\.md' "$source" \
        || fail "Harbor tenant guide is not linked from ${source#"$root/"}"
    rg -q 'harbor-provider\.md' "$source" \
        || fail "Harbor provider contract is not linked from ${source#"$root/"}"
done

# Permit only the explicitly required development host and generic app names;
# reject repository URLs, network addresses, synthetic registry hosts, and
# common literal credential forms.
mapfile -t documented_hosts < <(
    rg -o '[A-Za-z0-9.-]+\.jackpridham\.com' "$guide" | sort -u
)
[[ "${#documented_hosts[@]}" -eq 1 \
    && "${documented_hosts[0]}" == dev.jackpridham.com ]] \
    || fail 'unexpected jackpridham.com host in tenant guide'
! rg -qi 'https?://|ssh://|git@|github\.com|gitlab\.com|bitbucket\.org' "$guide" \
    || fail 'repository URL or address in tenant guide'
! rg -qi 'github\.com/[^ /]+/[^ /]+|gitlab\.com/[^ /]+/[^ /]+' \
    "$root/docs/container-orchestration.md" \
    "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" "$guide" \
    || fail 'private repository-like name in Harbor documentation'
! rg -q '([0-9]{1,3}\.){3}[0-9]{1,3}' "$guide" \
    || fail 'literal network address in tenant guide'
! rg -qi 'registry\.example|vesta\.example|ghcr\.io' "$guide" \
    || fail 'non-canonical registry example in tenant guide'
! rg -q '(PASSWORD|TOKEN|PUBLISHER_SECRET)=' "$guide" \
    || fail 'literal credential assignment in tenant guide'
! rg -qi 'Authorization:[[:space:]]*(Basic|Bearer)|BEGIN PRIVATE KEY|robot\$' \
    "$guide" || fail 'real credential-like value in tenant guide'

printf 'PASS: Harbor documentation contract\n'
