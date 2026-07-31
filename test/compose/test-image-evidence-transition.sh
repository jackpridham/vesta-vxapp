#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$repo_root/test/compose/fixtures/image-evidence/production-five-field.json"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

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
    Architecture:"amd64",Os:"linux",
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
    Architecture:"amd64",Os:"linux",Config:{Labels:{}}
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
install -m 0640 "$fixture" "$revision_file"
install -m 0640 "$fixture" "$project_root/images.json"

# Local digest-less evidence remains available only through the existing
# recorded-image approval gate.
local_identity_key="$(printf '%s' 'vesta-worker:local' | sha256sum | awk '{print $1}')"
mkdir -p "$(vx_compose_image_metadata_root alice)"
jq -S '{IMAGE_ID:.worker.IMAGE_ID}' "$fixture" \
    >"$(vx_compose_image_metadata_root alice)/$local_identity_key.json"

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
jq -e 'select(.ACTION == "image-evidence-schema-upgrade"
              and .RESULT == "succeeded"
              and (.DETAILS | length <= 256))' \
    "$project_root/audit.log" >/dev/null \
    || fail "schema upgrade was not recorded in the bounded audit"

# A modern finalized manifest may retain legacy image bytes while current is
# schema 2; active authority verification compares their stable semantics.
install -m 0640 "$project_root/compose.yaml" \
    "$project_root/revisions/000001/compose.yaml"
install -m 0640 "$project_root/runtime/canonical.json" \
    "$project_root/revisions/000001/canonical.json"
install -m 0640 "$project_root/policy.conf" \
    "$project_root/revisions/000001/policy.conf"
(
    cd "$project_root/revisions/000001"
    sha256sum canonical.json compose.yaml images.json policy.conf \
        >manifest.sha256
)
vx_compose_active_revision_verify alice evidence \
    || fail "active revision rejected a verified legacy-to-current transition"

# Fresh candidate/new-revision evidence is always schema 2.
vx_compose_resolve_images_to_file alice \
    "$project_root/runtime/canonical.json" standard "$test_root/new-images.json"
jq -e 'length == 2 and all(.[]; .SCHEMA == 2)' \
    "$test_root/new-images.json" >/dev/null \
    || fail "new evidence did not use schema 2"

baseline="$test_root/baseline.json"
cp "$test_root/new-images.json" "$baseline"
cp "$baseline" "$revision_file"
cp "$baseline" "$project_root/images.json"

assert_rejected_without_mutation() {
    local description="$1"
    local current_before revision_before

    current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
    revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
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
assert_rejected_without_mutation "trust policy drift"
cp "$baseline" "$revision_file"

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
upgrade_events_before="$(jq -s '[.[] | select(.ACTION == "image-evidence-schema-upgrade")] | length' "$project_root/audit.log")"
vx_compose_project_resolve_images alice evidence
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "repeat resolution was not byte-idempotent"
[[ "$(jq -s '[.[] | select(.ACTION == "image-evidence-schema-upgrade")] | length' "$project_root/audit.log")" \
    == "$upgrade_events_before" ]] || fail "repeat resolution repeated the schema-upgrade audit"

# Unknown or unsupported schemas/fields are never interpreted as compatible.
jq '.api.UNKNOWN = true' "$baseline" >"$revision_file"
assert_rejected_without_mutation "unknown schema field"
jq '.api.SCHEMA = 99' "$baseline" >"$revision_file"
assert_rejected_without_mutation "unsupported schema"
jq '.api.REPO_DIGESTS = "not-an-array"' "$baseline" >"$revision_file"
assert_rejected_without_mutation "malformed schema"
cp "$baseline" "$revision_file"

# A controlled interruption before atomic install preserves both byte streams.
jq '.Config.Labels["org.opencontainers.image.revision"] = "fixture-c"' \
    "$registry_inspect" >"$test_root/changed.json"
mv "$test_root/changed.json" "$registry_inspect"
install -m 0640 "$fixture" "$revision_file"
install -m 0640 "$fixture" "$project_root/images.json"
current_before="$(sha256sum "$project_root/images.json" | awk '{print $1}')"
revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
if VX_COMPOSE_TEST_IMAGE_EVIDENCE_INSTALL_FAIL=yes \
    vx_compose_project_resolve_images alice evidence 2>/dev/null; then
    fail "pre-install failure injection was ignored"
fi
[[ "$(sha256sum "$project_root/images.json" | awk '{print $1}')" \
    == "$current_before" ]] || fail "pre-install interruption changed current evidence"
[[ "$(sha256sum "$revision_file" | awk '{print $1}')" \
    == "$revision_before" ]] || fail "pre-install interruption changed revision evidence"

# Rollback may restore the retained production-era bytes; re-resolution upgrades
# only current evidence and leaves the immutable legacy authority byte-exact.
install -m 0640 "$fixture" "$revision_file"
install -m 0640 "$fixture" "$project_root/images.json"
revision_before="$(sha256sum "$revision_file" | awk '{print $1}')"
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
