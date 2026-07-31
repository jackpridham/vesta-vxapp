#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_COMPOSE_IMAGE_STAGING_ROOT="$test_root/staging"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice" "$VX_COMPOSE_IMAGE_STAGING_ROOT/alice"
printf "DOCKER_PROJECTS='0'\n" >"$VESTA/data/users/alice/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_docker="$test_root/fake-docker"
inspect_json='{"Id":"sha256:1234567890abcdef","RepoTags":["example.test/app:1"],"RepoDigests":["aaa.invalid/unrelated@sha256:0000000000000000000000000000000000000000000000000000000000000000","example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Architecture":"amd64","Os":"linux","Config":{"Labels":{"org.opencontainers.image.source":"https://example.test/source","org.opencontainers.image.revision":"abc123","org.opencontainers.image.version":"secret token must-not-copy","org.opencontainers.image.vendor":"Vortex","org.opencontainers.image.created":"2026-07-31T00:00:00Z","secret.label":"must-not-copy"}}}'
current_manifest_json='[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"Platform":{"os":"linux","architecture":"amd64"}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"Platform":{"os":"linux","architecture":"arm64"}}]'
candidate_manifest_json='[{"Descriptor":{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"Platform":{"os":"linux","architecture":"amd64"}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"Platform":{"os":"linux","architecture":"arm64"}}]'
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s\n" CALL >>"$(dirname -- "$0")/docker.log"'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/docker.log"'
    printf '%s\n' 'case " $* " in'
    printf '%s\n' '  *" image inspect "*)'
: <<'VX_BROKEN_GENERATOR'
    printf '%s\n' '    printf "%s\n" '"'"'{"Id":"sha256:1234567890abcdef","RepoTags":["example.test/app:1"],"RepoDigests":["example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Architecture":"amd64","Os":"linux","Config":{"Labels":{"org.opencontainers.image.source":"https://example.test/source","org.opencontainers.image.revision":"abc123","org.opencontainers.image.version":"1","org.opencontainers.image.vendor":"Vortex","org.opencontainers.image.created":"2026-07-31T00:00:00Z","secret.label":"must-not-copy"}}}'"'"'"
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" manifest inspect "*)'
    printf '%s\n' '    printf "%s\n" '"'"'{"Descriptor":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'"'"
VX_BROKEN_GENERATOR
    printf '    printf "%%s\\n" %q\n' "$inspect_json"
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" manifest inspect "*)'
    printf '%s\n' '    if [[ "${!#}" == *@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || -e "$(dirname -- "$0")/manifest-same" ]]; then'
    printf '      printf "%%s\\n" %q\n' "$current_manifest_json"
    printf '%s\n' '    else'
    printf '      printf "%%s\\n" %q\n' "$candidate_manifest_json"
    printf '%s\n' '    fi'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" image load "*) printf "%s\n" "Loaded image: example.test/app:1" ;;'
    printf '%s\n' 'esac'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

vx_compose_image_pull alice example.test/app:1 >"$test_root/pull.json"
jq -e '
    .OWNER == "alice"
    and .REFERENCE == "example.test/app:1"
    and .IMAGE_ID == "sha256:1234567890abcdef"
    and (.IMMUTABLE_REFERENCES | length == 2)
    and .OCI_LABELS.source == "https://example.test/source"
    and .OCI_LABELS.version == ""
    and (.OCI_LABELS | has("secret.label") | not)
    and .OS == "linux"
    and .ARCHITECTURE == "amd64"
' "$test_root/pull.json" >/dev/null || fail "public pull identity was not recorded"
if grep -Fq 'must-not-copy' "$test_root/pull.json"; then
    fail "credential-like content in an allowed OCI label leaked"
fi
[[ ! -e "$(vx_compose_image_metadata_root bob 2>/dev/null || true)" ]] \
    || fail "image metadata crossed owners"

if vx_compose_image_pull alice 'https://name:must-not-leak@example.test/app:1' \
    2>"$test_root/ref.error"; then
    fail "credential-bearing image reference was accepted"
fi
grep -Fq 'invalid Docker image reference' "$test_root/ref.error" \
    || fail "hostile image reference returned the wrong diagnostic"
if grep -Fq 'must-not-leak' "$test_root/ref.error"; then
    fail "hostile image reference leaked"
fi

archive="$VX_COMPOSE_IMAGE_STAGING_ROOT/alice/app.tar"
checksum="$VX_COMPOSE_IMAGE_STAGING_ROOT/alice/app.tar.sha256"
printf 'synthetic image archive\n' >"$archive"
(
    cd "$(dirname -- "$archive")"
    sha256sum "$(basename -- "$archive")" >"$(basename -- "$checksum")"
)
calls_before="$(grep -c '^CALL$' "$test_root/docker.log")"
vx_compose_image_load alice "$archive" "$checksum" >"$test_root/load.json"
jq -e '.IMAGE_ID == "sha256:1234567890abcdef"' "$test_root/load.json" >/dev/null \
    || fail "post-load image identity was not inspected"
[[ ! -e "$archive" && ! -e "$checksum" ]] \
    || fail "successful archive load did not clean staging files"

bad_archive="$VX_COMPOSE_IMAGE_STAGING_ROOT/alice/bad.tar"
bad_checksum="$VX_COMPOSE_IMAGE_STAGING_ROOT/alice/bad.tar.sha256"
printf 'bad archive\n' >"$bad_archive"
printf '%064d  bad.tar\n' 0 >"$bad_checksum"
if vx_compose_image_load alice "$bad_archive" "$bad_checksum" 2>/dev/null; then
    fail "checksum mismatch was accepted"
fi
calls_after="$(grep -c '^CALL$' "$test_root/docker.log")"
(( calls_after == calls_before + 2 )) \
    || fail "checksum failure reached Docker"

# Resolving image evidence for a pending candidate writes only the nominated
# protected output and never mutates an already-finalized revision.
project_root="$(vx_compose_project_root alice app)"
mkdir -p "$project_root/runtime" "$project_root/revisions/000001"
printf "OWNER='alice'\nPROJECT='app'\nPROFILE='standard'\nREVISION='1'\n" \
    >"$project_root/project.conf"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"
printf '{"services":{"web":{"image":"example.test/app:1"}}}\n' \
    >"$project_root/runtime/canonical.json"
printf 'frozen\n' >"$project_root/revisions/000001/images.json"
vx_compose_resolve_images_to_file \
    alice "$project_root/runtime/canonical.json" standard \
    "$test_root/pending-images.json"
jq -e '.web.IMAGE_ID == "sha256:1234567890abcdef"' \
    "$test_root/pending-images.json" >/dev/null \
    || fail "pending candidate image evidence is incomplete"
[[ "$(cat "$project_root/revisions/000001/images.json")" == frozen ]] \
    || fail "candidate image resolution mutated a finalized revision"
jq -e '
    .web.IMMUTABLE_REFERENCE == "example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .web.REGISTRY_DIGEST == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .web.TRUST.DECISION == "disabled"
' "$test_root/pending-images.json" >/dev/null \
    || fail "immutable registry, OCI, or disabled trust evidence is incomplete"

update_log_start="$(wc -l <"$test_root/docker.log")"
touch "$test_root/manifest-same"
vx_compose_image_update_candidate alice example.test/app:1 \
    >"$test_root/update-same.json"
rm -f "$test_root/manifest-same"
jq -e '
    .CURRENT_REGISTRY_DIGEST == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .CURRENT_DIGEST == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .CANDIDATE_DIGEST == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .UPDATE_AVAILABLE == false
    and .MUTATED == false
' "$test_root/update-same.json" >/dev/null \
    || fail "unchanged multi-architecture tag reported a false update"
vx_compose_image_update_candidate alice example.test/app:1 \
    >"$test_root/update.json"
jq -e '
    .CURRENT_REGISTRY_DIGEST == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .CURRENT_DIGEST == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .CANDIDATE_DIGEST == "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    and .UPDATE_AVAILABLE == true
    and .MUTATED == false
' "$test_root/update.json" >/dev/null \
    || fail "non-mutating image update candidate is incomplete"
[[ "$(grep -c 'ARG=image' "$test_root/docker.log")" -ge 1 ]] \
    || fail "image inspection was not exercised"
grep -Fq 'ARG=manifest' "$test_root/docker.log" \
    || fail "update candidate did not use a manifest-only lookup"
if tail -n "+$((update_log_start + 1))" "$test_root/docker.log" \
    | grep -Eq 'ARG=(pull|tag|rm)'; then
    fail "update candidate mutated local image state"
fi

echo "Compose image source tests passed."
