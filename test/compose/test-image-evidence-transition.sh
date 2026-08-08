#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$repo_root/test/compose/fixtures/image-evidence/production-five-field.json"
test_root="$(mktemp -d)"
cleanup() {
    chmod -R u+w "$test_root" 2>/dev/null || :
    rm -rf -- "$test_root"
}
trap cleanup EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"
printf "DOCKER_PROJECTS='0'\n" >"$VESTA/data/users/alice/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

registry_inspect="$test_root/registry-inspect.json"
local_inspect="$test_root/local-inspect.json"
jq -n '{
    Id:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
    RepoTags:["registry.example.invalid/vesta/api:stable"],
    RepoDigests:["registry.example.invalid/vesta/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    Architecture:"amd64",Os:"linux",Size:30,
    Config:{Labels:{
        "org.opencontainers.image.source":"https://example.invalid/source",
        "org.opencontainers.image.revision":"fixture-a",
        "org.opencontainers.image.version":"1",
        "org.opencontainers.image.vendor":"Example",
        "org.opencontainers.image.created":"2026-08-01T00:00:00Z"
    }}
}' >"$registry_inspect"
jq -n '{
    Id:"sha256:2222222222222222222222222222222222222222222222222222222222222222",
    RepoTags:["vesta-worker:local"],RepoDigests:[],
    Architecture:"amd64",Os:"linux",Size:30,Config:{Labels:{}}
}' >"$local_inspect"

fake_docker="$test_root/fake-docker"
cat >"$fake_docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$(dirname -- "$0")"
case " $* " in
    *" image inspect "*)
        case "${!#}" in
            registry.example.invalid/vesta/api:stable)
                cat "$root/registry-inspect.json"
                ;;
            vesta-worker:local)
                cat "$root/local-inspect.json"
                ;;
            *)
                cat "$root/registry-inspect.json"
                ;;
        esac
        ;;
esac
EOF
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

project_root="$(vx_compose_project_root alice evidence)"
revision_file="$project_root/revisions/000001/images.json"
mkdir -p "$project_root/runtime" "$project_root/revisions/000001"
chmod 0750 "$project_root" "$project_root/runtime" \
    "$project_root/revisions" "$project_root/revisions/000001"
cat >"$project_root/project.conf" <<'EOF'
OWNER='alice'
PROJECT='evidence'
PROFILE='standard'
REVISION='1'
EOF
printf 'services: {}\n' >"$project_root/compose.yaml"
cat >"$project_root/policy.conf" <<'EOF'
POLICY_SCHEMA='1'
VALIDATOR_VERSION='2'
PROFILE_VERSION='1'
EOF
cat >"$project_root/runtime/canonical.json" <<'EOF'
{"services":{"worker":{"image":"vesta-worker:local"},"api":{"image":"registry.example.invalid/vesta/api:stable"}}}
EOF
printf "CANONICAL_SHA256='%s'\n" \
    "$(sha256sum "$project_root/runtime/canonical.json" | awk '{print $1}')" \
    >>"$project_root/project.conf"
for revision_name in 000001 000002 000003 000004; do
    revision_root="$project_root/revisions/$revision_name"
    install -d -m 0750 "$revision_root"
    install -m 0640 "$fixture" "$revision_root/images.json"
    install -m 0640 "$project_root/runtime/canonical.json" \
        "$revision_root/canonical.json"
    (
        cd "$revision_root"
        sha256sum canonical.json >manifest.sha256
        chmod 0640 manifest.sha256
    )
done
install -m 0640 "$fixture" "$project_root/images.json"

# Local digest-less evidence remains available only through the existing
# recorded-image approval gate.
local_identity_key="$(printf '%s' 'vesta-worker:local' | sha256sum | awk '{print $1}')"
mkdir -p "$(vx_compose_image_metadata_root alice)"
jq -S '{IMAGE_ID:.worker.IMAGE_ID}' "$fixture" \
    >"$(vx_compose_image_metadata_root alice)/$local_identity_key.json"

# A missing active revision image can never bootstrap from current-only bytes.
mv "$revision_file" "$test_root/active-revision-images.json"
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
if vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "current-only legacy evidence created migration authority"
fi
[[ ! -e "$project_root/image-evidence-migration"
    && "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
        == "$current_before" ]] \
    || fail "missing active revision changed current evidence"
install -m 0640 "$test_root/active-revision-images.json" "$revision_file"

# Retained revisions may bind distinct valid historical image identities.
jq '.worker.IMAGE_ID = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
    "$fixture" >"$test_root/revision-000004-images.json"
install -m 0640 "$test_root/revision-000004-images.json" \
    "$project_root/revisions/000004/images.json"

revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
vx_compose_project_resolve_images alice evidence
[[ "$(sha256sum "$revision_file" | awk '{print $1}')" == "$revision_before" ]] \
    || fail "legacy revision evidence was mutated"
jq -e '
    length == 2
    and all(.[]; .SCHEMA == 2)
    and .api.IMMUTABLE_REFERENCE == "registry.example.invalid/vesta/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .api.REGISTRY_DIGEST == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .worker.IMMUTABLE_REFERENCE == ""
    and .worker.REGISTRY_DIGEST == ""
    and .api.TRUST.DECISION == "disabled"
    and .worker.TRUST.DECISION == "disabled"
' "$project_root/images.json" >/dev/null \
    || fail "legacy evidence did not upgrade to schema 2"
jq -e 'select(.ACTION == "resolve-images"
              and .RESULT == "succeeded"
              and (.DETAILS | contains("schema_transition="))
              and (.DETAILS | length <= 256))' \
    "$project_root/audit.log" >/dev/null \
    || fail "schema upgrade was not recorded in the bounded audit"
authority="$project_root/image-evidence-migration"
[[ -d "$authority"
    && "$(stat -c '%a' "$authority")" == 500
    && "$(stat -c '%a' "$authority/evidence.json")" == 400
    && "$(stat -c '%a' "$authority/manifest.sha256")" == 400 ]] \
    || fail "legacy migration authority permissions are not immutable"
jq -e '
    .SCHEMA == 1 and .OWNER == "alice" and .PROJECT == "evidence"
    and [.ENTRIES[].NAME] == ["000001","000002","000003","000004"]
    and .ENTRIES[0].EVIDENCE.api.IMAGE_ID
        == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    and .ENTRIES[3].EVIDENCE.worker.IMAGE_ID
        == "sha256:9999999999999999999999999999999999999999999999999999999999999999"
' "$authority/evidence.json" >/dev/null \
    || fail "legacy migration authority did not bind all retained sources"
vx_compose_image_evidence_migration_authority_verify \
    alice evidence "$project_root" 1 "$revision_file" \
    || fail "active revision authority entry was not selectable"
vx_compose_image_evidence_migration_authority_verify \
    alice evidence "$project_root" 4 \
    "$project_root/revisions/000004/images.json" \
    || fail "historical revision authority entry was not selectable"

authority_manifest_copy="$test_root/migration-manifest.sha256"
cp "$authority/manifest.sha256" "$authority_manifest_copy"
chmod 0700 "$authority"
chmod 0600 "$authority/manifest.sha256"
printf 'tamper\n' >>"$authority/manifest.sha256"
chmod 0400 "$authority/manifest.sha256"
chmod 0500 "$authority"
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
if vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "tampered migration authority was accepted"
fi
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "authority tamper changed current evidence"
chmod 0700 "$authority"
install -m 0400 "$authority_manifest_copy" "$authority/manifest.sha256"
chmod 0500 "$authority"

install -m 0640 "$fixture" "$project_root/revisions/000004/images.json"
if vx_compose_image_evidence_migration_authority_verify \
    alice evidence "$project_root" 4 \
    "$project_root/revisions/000004/images.json"; then
    fail "tampered retained revision authority entry was accepted"
fi
install -m 0640 "$test_root/revision-000004-images.json" \
    "$project_root/revisions/000004/images.json"

# Selecting a distinct retained revision re-resolves against that revision's
# own authority entry rather than the active revision's historical identity.
cp "$project_root/images.json" "$test_root/revision-000001-current.json"
sed -i "s/^REVISION='1'/REVISION='4'/" "$project_root/project.conf"
install -m 0640 "$test_root/revision-000004-images.json" \
    "$project_root/images.json"
jq '.Id = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
    "$local_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$local_inspect"
jq -n -S '{IMAGE_ID:"sha256:9999999999999999999999999999999999999999999999999999999999999999"}' \
    >"$(vx_compose_image_metadata_root alice)/$local_identity_key.json"
vx_compose_project_resolve_images alice evidence
jq -e '.worker.IMAGE_ID
    == "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
    "$project_root/images.json" >/dev/null \
    || fail "distinct retained revision could not be re-resolved"
sed -i "s/^REVISION='4'/REVISION='1'/" "$project_root/project.conf"
jq '.Id = "sha256:2222222222222222222222222222222222222222222222222222222222222222"' \
    "$local_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$local_inspect"
jq -n -S '{IMAGE_ID:"sha256:2222222222222222222222222222222222222222222222222222222222222222"}' \
    >"$(vx_compose_image_metadata_root alice)/$local_identity_key.json"
install -m 0640 "$test_root/revision-000001-current.json" \
    "$project_root/images.json"

# Active authority verification accepts schema 2 current evidence only through
# the separately manifest-bound legacy migration authority.
install -m 0640 "$project_root/compose.yaml" \
    "$project_root/revisions/000001/compose.yaml"
install -m 0640 "$project_root/runtime/canonical.json" \
    "$project_root/revisions/000001/canonical.json"
install -m 0640 "$project_root/policy.conf" \
    "$project_root/revisions/000001/policy.conf"
vx_compose_active_revision_verify alice evidence \
    || fail "active revision rejected a verified legacy-to-current transition"

# Subsequent schema-2 drift checks use an ordinarily manifest-bound revision.
(
    cd "$project_root/revisions/000001"
    sha256sum canonical.json compose.yaml images.json policy.conf \
        >manifest.sha256
)

# Accepted-revision refresh emits schema 2 but cannot authorize a new
# add/change candidate; pass the exact protected active revision explicitly.
vx_compose_resolve_images_to_file alice \
    "$project_root/runtime/canonical.json" standard "$test_root/new-images.json" \
    "$revision_file"
jq -e 'length == 2 and all(.[]; .SCHEMA == 2)' \
    "$test_root/new-images.json" >/dev/null \
    || fail "new evidence did not use schema 2"

baseline="$test_root/baseline.json"
cp "$test_root/new-images.json" "$baseline"
cp "$baseline" "$revision_file"
cp "$baseline" "$project_root/images.json"

bind_active_revision() {
    (
        cd "$project_root/revisions/000001"
        sha256sum canonical.json compose.yaml images.json policy.conf \
            >manifest.sha256
        chmod 0640 manifest.sha256
    )
}

bind_legacy_canonical_only() {
    (
        cd "$project_root/revisions/000001"
        sha256sum canonical.json >manifest.sha256
        chmod 0640 manifest.sha256
    )
}

bind_active_revision

# Active verification enforces the complete protected path even when current
# and revision image bytes are equal.
vx_compose_active_revision_verify alice evidence \
    || fail "secure byte-equal active evidence was rejected"
chmod 0770 "$project_root/revisions"
if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
    fail "writable revisions directory passed active verification"
fi
chmod 0750 "$project_root/revisions"
chmod 0660 "$project_root/revisions/000001/manifest.sha256"
if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
    fail "writable active manifest passed active verification"
fi
chmod 0640 "$project_root/revisions/000001/manifest.sha256"
mv "$project_root/revisions/000001/manifest.sha256" \
    "$test_root/active-manifest.sha256"
ln -s "$test_root/active-manifest.sha256" \
    "$project_root/revisions/000001/manifest.sha256"
if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
    fail "linked active manifest passed active verification"
fi
rm -f -- "$project_root/revisions/000001/manifest.sha256"
install -m 0640 "$test_root/active-manifest.sha256" \
    "$project_root/revisions/000001/manifest.sha256"
if (( EUID == 0 )); then
    chown 65534:65534 "$revision_file"
    if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
        fail "wrong-owner active revision image passed verification"
    fi
    chown 0:0 "$revision_file"
fi

# Digest-bearing references are one unambiguous immutable identity, and raw
# duplicate JSON keys are rejected before jq can collapse them.
jq '.api.REFERENCE = "registry.example.invalid/vesta/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$baseline" >"$test_root/digest-contradiction.json"
if vx_compose_image_evidence_current_validate \
    "$test_root/digest-contradiction.json"; then
    fail "digest-bearing reference contradicted immutable identity"
fi
jq '.api.REFERENCE = "registry.example.invalid/vesta/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$baseline" >"$test_root/multiple-at.json"
if vx_compose_image_evidence_current_validate "$test_root/multiple-at.json"; then
    fail "multiple-at digest reference was accepted"
fi
jq '.api.REFERENCE = "registry.example.invalid/vesta/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
    "$fixture" >"$test_root/legacy-digest-contradiction.json"
if vx_compose_image_evidence_legacy_validate \
    "$test_root/legacy-digest-contradiction.json"; then
    fail "legacy digest-bearing reference contradiction was accepted"
fi
jq '.api.REPO_DIGESTS += [.api.REPO_DIGESTS[0]]' "$fixture" \
    >"$test_root/legacy-duplicate-digest.json"
if vx_compose_image_evidence_legacy_validate \
    "$test_root/legacy-duplicate-digest.json"; then
    fail "duplicate legacy repository digest was normalized"
fi
api_legacy="$(jq -c '.api' "$fixture")"
printf '{"api":%s,"api":%s}\n' "$api_legacy" "$api_legacy" \
    >"$test_root/duplicate-document-key.json"
if vx_compose_image_evidence_legacy_validate \
    "$test_root/duplicate-document-key.json"; then
    fail "duplicate document service key was accepted"
fi
sed '0,/"REFERENCE":/s//"REFERENCE":"vesta-worker:local","REFERENCE":/' \
    "$fixture" >"$test_root/duplicate-service-key.json"
if vx_compose_image_evidence_legacy_validate \
    "$test_root/duplicate-service-key.json"; then
    fail "duplicate service evidence key was accepted"
fi
sed '0,/"MODE":/s//"MODE":"audit","MODE":/' "$baseline" \
    >"$test_root/duplicate-trust-key.json"
if vx_compose_image_evidence_current_validate \
    "$test_root/duplicate-trust-key.json"; then
    fail "duplicate nested trust key was accepted"
fi
jq '.api.TRUST = {
        SCHEMA:1,MODE:"enforce",DECISION:"pass",PROFILE:"standard",
        PROFILE_VERSION:2,POLICY_VERSION:2,VULNERABILITY_THRESHOLD:"high",
        CREATED:"2026-08-01T00:00:00Z",
        SIGNATURE:{ADAPTER:"signature",STATE:"fail",DETAIL:"failed"},
        VULNERABILITY:{ADAPTER:"vulnerability",STATE:"pass",DETAIL:"passed"},
        EXCEPTION:false
    }' "$baseline" >"$test_root/incoherent-trust-pass.json"
if vx_compose_image_evidence_current_validate \
    "$test_root/incoherent-trust-pass.json"; then
    fail "passing trust decision with a failed adapter was accepted"
fi
jq '.api.TRUST = {
        SCHEMA:1,MODE:"enforce",DECISION:"exception",PROFILE:"standard",
        PROFILE_VERSION:2,POLICY_VERSION:2,VULNERABILITY_THRESHOLD:"high",
        CREATED:"2026-08-01T00:00:00Z",
        SIGNATURE:{ADAPTER:"signature",STATE:"pass",DETAIL:"passed"},
        VULNERABILITY:{ADAPTER:"vulnerability",STATE:"pass",DETAIL:"passed"},
        EXCEPTION:true
    }' "$baseline" >"$test_root/incoherent-trust-exception.json"
if vx_compose_image_evidence_current_validate \
    "$test_root/incoherent-trust-exception.json"; then
    fail "trust exception without a failed adapter was accepted"
fi

assert_rejected_without_mutation() {
    local description="$1"
    local current_before revision_before

    current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
    revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
    success_before="$(jq -s '[.[] | select(.ACTION == "resolve-images"
        and .RESULT == "succeeded")] | length' "$project_root/audit.log")"
    if vx_compose_project_resolve_images alice evidence \
        >"$test_root/rejected.out" 2>"$test_root/rejected.err"; then
        fail "$description was accepted"
    fi
    [[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
        == "$current_before" ]] || fail "$description mutated current evidence"
    [[ "$(sha256sum "$revision_file" | awk '{print $1}')" \
        == "$revision_before" ]] || fail "$description mutated revision evidence"
}

# A stable-identity tamper in current evidence is not repaired silently merely
# because fresh daemon evidence still matches the immutable revision.
jq '.api.IMAGE_ID = "sha256:4444444444444444444444444444444444444444444444444444444444444444"' \
    "$baseline" >"$project_root/images.json"
assert_rejected_without_mutation "tampered current identity"
cp "$baseline" "$project_root/images.json"

chmod 0660 "$project_root/images.json"
assert_rejected_without_mutation "writable current evidence"
chmod 0640 "$project_root/images.json"
chmod 0660 "$revision_file"
assert_rejected_without_mutation "writable revision evidence"
chmod 0640 "$revision_file"
chmod 0770 "$project_root/revisions/000001"
assert_rejected_without_mutation "writable revision directory"
chmod 0750 "$project_root/revisions/000001"

mv "$project_root/images.json" "$test_root/current-real.json"
ln -s "$test_root/current-real.json" "$project_root/images.json"
if vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "symlink current evidence was accepted"
fi
rm -f -- "$project_root/images.json"
install -m 0640 "$test_root/current-real.json" "$project_root/images.json"

if (( EUID == 0 )); then
    chown 65534:65534 "$project_root/images.json"
    assert_rejected_without_mutation "wrong-owner current evidence"
    chown 0:0 "$project_root/images.json"
fi

chmod 0770 "$project_root"
if vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "writable project control directory was accepted"
fi
chmod 0750 "$project_root"

chmod 0700 "$authority"
if vx_compose_image_evidence_migration_authority_verify \
    alice evidence "$project_root" 1 "$baseline"; then
    fail "writable migration authority directory was accepted"
fi
chmod 0500 "$authority"

jq '.api.IMAGE_ID = "sha256:8888888888888888888888888888888888888888888888888888888888888888"' \
    "$baseline" >"$test_root/race-replacement.json"
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
if VX_COMPOSE_TEST_IMAGE_EVIDENCE_REPLACE_CURRENT_WITH="$test_root/race-replacement.json" \
    vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "current evidence replacement race was accepted"
fi
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "replacement race did not restore prior bytes"

# Every stable platform/image/reference/service identity component fails closed.
jq '.Id = "sha256:3333333333333333333333333333333333333333333333333333333333333333"' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
assert_rejected_without_mutation "image ID drift"
jq '.Id = "sha256:1111111111111111111111111111111111111111111111111111111111111111"' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"

jq '.RepoDigests = ["registry.example.invalid/vesta/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
assert_rejected_without_mutation "repository digest drift"
jq '.RepoDigests = ["registry.example.invalid/vesta/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"

jq '.Architecture = "arm64"' "$registry_inspect" \
    >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
assert_rejected_without_mutation "architecture platform drift"
jq '.Architecture = "amd64"' "$registry_inspect" \
    >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"

jq '.Os = "windows"' "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
assert_rejected_without_mutation "OS platform drift"
jq '.Os = "linux"' "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"

cp "$project_root/runtime/canonical.json" "$test_root/canonical.baseline"
jq '.services.api.image = "registry.example.invalid/vesta/api:other"' \
    "$test_root/canonical.baseline" >"$project_root/runtime/canonical.json"
assert_rejected_without_mutation "reference drift"
cp "$test_root/canonical.baseline" "$project_root/runtime/canonical.json"

jq '.services.renamed = .services.api | del(.services.api)' \
    "$test_root/canonical.baseline" >"$project_root/runtime/canonical.json"
assert_rejected_without_mutation "service set drift"
cp "$test_root/canonical.baseline" "$project_root/runtime/canonical.json"

# Security-significant trust facts are identity, unlike label/detail timestamps.
jq '.api.TRUST.PROFILE_VERSION += 1' "$baseline" >"$revision_file"
bind_active_revision
assert_rejected_without_mutation "trust policy drift"
cp "$baseline" "$revision_file"
bind_active_revision

# OCI label-only changes are informational and may refresh current evidence.
revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
jq '.Config.Labels["org.opencontainers.image.revision"] = "fixture-b"
    | .Config.Labels["org.opencontainers.image.created"] = "2026-08-01T01:00:00Z"' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
vx_compose_project_resolve_images alice evidence
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$(sha256sum "$baseline" | awk '{print $1}')" ]] \
    || fail "informational OCI label drift replaced accepted current evidence"
[[ "$(sha256sum "$revision_file" | awk '{print $1}')" == "$revision_before" ]] \
    || fail "OCI label refresh mutated revision authority"

# Repeating the same refresh is byte-idempotent and does not repeat upgrade audit.
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
upgrade_events_before="$(jq -s '[.[] | select(.ACTION == "resolve-images"
    and (.DETAILS | contains("schema_transition=")))] | length' "$project_root/audit.log")"
vx_compose_project_resolve_images alice evidence
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "repeat resolution was not byte-idempotent"
[[ "$(jq -s '[.[] | select(.ACTION == "resolve-images"
    and (.DETAILS | contains("schema_transition=")))] | length' "$project_root/audit.log")" \
    == "$upgrade_events_before" ]] || fail "repeat resolution repeated the schema-upgrade audit"

# Unknown or unsupported schemas/fields are never interpreted as compatible.
jq '.api.UNKNOWN = true' "$baseline" >"$revision_file"
bind_active_revision
assert_rejected_without_mutation "unknown schema field"
jq '.api.SCHEMA = 99' "$baseline" >"$revision_file"
bind_active_revision
assert_rejected_without_mutation "unsupported schema"
jq '.api.REPO_DIGESTS = "not-an-array"' "$baseline" >"$revision_file"
bind_active_revision
assert_rejected_without_mutation "malformed schema"
cp "$baseline" "$revision_file"
bind_active_revision

# A controlled interruption before atomic install preserves both byte streams.
jq '.Config.Labels["org.opencontainers.image.revision"] = "fixture-c"' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
for failure_hook in \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_INSTALL_FAIL \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_AFTER_RENAME \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_AFTER_FSYNC \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_FINAL_DIR_FSYNC \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_SERVICE_COUNT \
    VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_RESOLVE_AUDIT; do
    install -m 0640 "$fixture" "$revision_file"
    install -m 0640 "$fixture" "$project_root/images.json"
    bind_legacy_canonical_only
    current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
    revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
    export "$failure_hook=yes"
    if vx_compose_project_resolve_images alice evidence 2>/dev/null; then
        fail "$failure_hook was ignored"
    fi
    unset "$failure_hook"
    [[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
        == "$current_before" ]] \
        || fail "$failure_hook changed prior current evidence"
    [[ "$(sha256sum "$revision_file" | awk '{print $1}')" \
        == "$revision_before" ]] \
        || fail "$failure_hook changed revision evidence"
    [[ "$(jq -s '[.[] | select(.ACTION == "resolve-images"
        and .RESULT == "succeeded")] | length' "$project_root/audit.log")" \
        == "$success_before" ]] \
        || fail "$failure_hook left a false terminal success audit"
    if compgen -G "$project_root/.images.previous.*" >/dev/null; then
        fail "$failure_hook left an ambiguous rollback snapshot"
    fi
done
jq -s -e '[.[] | select(.ACTION == "resolve-images"
                         and .RESULT == "failed")] | length >= 5' \
    "$project_root/audit.log" >/dev/null \
    || fail "post-install failures were not reconstructable from audit"

# Snapshot cleanup happens after the one truthful terminal success event. A
# protected leftover is auditable but cannot turn durable success into failure.
install -m 0640 "$fixture" "$revision_file"
install -m 0640 "$fixture" "$project_root/images.json"
bind_legacy_canonical_only
success_before="$(jq -s '[.[] | select(.ACTION == "resolve-images"
    and .RESULT == "succeeded")] | length' "$project_root/audit.log")"
VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_BACKUP_CLEANUP=yes \
    vx_compose_project_resolve_images alice evidence
jq -e 'all(.[]; .SCHEMA == 2)' "$project_root/images.json" >/dev/null \
    || fail "cleanup failure rolled back durable current evidence"
[[ "$(jq -s '[.[] | select(.ACTION == "resolve-images"
    and .RESULT == "succeeded")] | length' "$project_root/audit.log")" \
    == $((success_before + 1)) ]] \
    || fail "cleanup failure corrupted terminal audit truth"
jq -s -e '[.[] | select(.ACTION == "image-evidence-cleanup"
                         and .RESULT == "failed")] | length >= 1' \
    "$project_root/audit.log" >/dev/null \
    || fail "cleanup failure was not audited"
rm -f -- "$project_root"/.images.previous.*

# Rollback may restore the retained production-era bytes; re-resolution upgrades
# only current evidence and leaves the immutable legacy authority byte-exact.
install -m 0640 "$fixture" "$revision_file"
install -m 0640 "$fixture" "$project_root/images.json"
bind_legacy_canonical_only
revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"

mv "$authority" "$project_root/.migration-authority.saved"
if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
    fail "byte-equal unmanifested legacy evidence bypassed missing authority"
fi
mv "$project_root/.migration-authority.saved" "$authority"

cp "$authority/manifest.sha256" "$test_root/rollback-authority-manifest"
chmod 0700 "$authority"
chmod 0600 "$authority/manifest.sha256"
printf 'corrupt\n' >>"$authority/manifest.sha256"
chmod 0400 "$authority/manifest.sha256"
chmod 0500 "$authority"
if vx_compose_active_revision_verify alice evidence 2>/dev/null; then
    fail "byte-equal unmanifested legacy evidence bypassed corrupt authority"
fi
chmod 0700 "$authority"
install -m 0400 "$test_root/rollback-authority-manifest" \
    "$authority/manifest.sha256"
chmod 0500 "$authority"
vx_compose_active_revision_verify alice evidence \
    || fail "valid per-revision authority rejected byte-equal rollback evidence"

vx_compose_project_resolve_images alice evidence
jq -e 'all(.[]; .SCHEMA == 2)' "$project_root/images.json" >/dev/null \
    || fail "legacy rollback evidence could not be re-resolved"
[[ "$(sha256sum "$revision_file" | awk '{print $1}')" == "$revision_before" ]] \
    || fail "legacy rollback re-resolution mutated revision authority"

# Compatibility cannot bypass current enforce-mode digest requirements.
install -m 0640 "$fixture" "$project_root/images.json"
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
if VX_DOCKER_TRUST_MODE_STANDARD=enforce \
    vx_compose_project_resolve_images alice evidence \
        2>"$test_root/enforce.error"; then
    fail "legacy digest-less evidence bypassed enforce-mode trust"
fi
grep -Fq 'registry digest is required by Docker image trust policy' \
    "$test_root/enforce.error" \
    || fail "enforce-mode rejection did not reach the digest-less trust gate"
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "failed enforce-mode check mutated current evidence"

echo "Compose image evidence transition tests passed."
