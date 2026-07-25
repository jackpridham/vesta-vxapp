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
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s\n" CALL >>"$(dirname -- "$0")/docker.log"'
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "ARG=%s\n" "$@" >>"$(dirname -- "$0")/docker.log"'
    printf '%s\n' 'case " $* " in'
    printf '%s\n' '  *" image inspect "*)'
    printf '%s\n' '    printf "%s\n" '"'"'{"Id":"sha256:1234567890abcdef","RepoTags":["example.test/app:1"],"RepoDigests":["example.test/app@sha256:abcdef"],"Architecture":"amd64","Os":"linux"}'"'"
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
    and .OS == "linux"
    and .ARCHITECTURE == "amd64"
' "$test_root/pull.json" >/dev/null || fail "public pull identity was not recorded"
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

echo "Compose image source tests passed."
