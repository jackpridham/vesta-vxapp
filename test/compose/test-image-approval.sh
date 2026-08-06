#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" \
    "$HOMEDIR/alice" "$HOMEDIR/bob"
printf "DOCKER_PROJECTS='0'\nSUSPENDED='no'\n" \
    >"$VESTA/data/users/alice/user.conf"
printf "DOCKER_PROJECTS='0'\nSUSPENDED='no'\n" \
    >"$VESTA/data/users/bob/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

image_id='sha256:1111111111111111111111111111111111111111111111111111111111111111'
other_id='sha256:2222222222222222222222222222222222222222222222222222222222222222'
reference='example.test/local-app:1'
inspect_json="{\"Id\":\"$image_id\",\"RepoTags\":[\"$reference\"],\"RepoDigests\":[],\"Architecture\":\"amd64\",\"Os\":\"linux\",\"Config\":{\"Labels\":{}}}"
fake_docker="$test_root/fake-docker"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'printf "ARG=%%s\\n" "$*" >>%q\n' "$test_root/docker.log"
    printf 'if [[ -e %q ]]; then\n' "$test_root/replaced"
    printf '    printf "%%s\\n" %q\n' \
        "${inspect_json//$image_id/$other_id}"
    printf '%s\n' 'else'
    printf '    printf "%%s\\n" %q\n' "$inspect_json"
    printf '%s\n' 'fi'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
# The main loader integration is intentionally covered by the parent task.
# shellcheck source=func/vx/compose/image-approvals.sh
source "$repo_root/func/vx/compose/image-approvals.sh"

inspection="$(vx_compose_image_inspect alice "$reference")"
vx_compose_image_record alice "$reference" "$inspection" >/dev/null
expires="$(date -u -d '+1 hour' +'%Y-%m-%dT%H:%M:%SZ')"

if vx_compose_image_approval_add \
    alice alice "$reference" "$image_id" linux amd64 standard 2 "$expires" \
    2>/dev/null; then
    fail 'tenant actor approved a local image'
fi
approval="$(vx_compose_image_approval_add \
    admin alice "$reference" "$image_id" linux amd64 standard 2 "$expires")"
[[ "$(stat -c '%a' "$approval")" == 600 \
    && "$(stat -c '%a' "$(dirname -- "$approval")")" == 700 ]] \
    || fail 'approval storage modes are not protected'
jq -e \
    --arg image_id "$image_id" \
    --arg expires "$expires" '
        .SCHEMA == 1
        and .ACTOR == "admin"
        and .OWNER == "alice"
        and .REFERENCE == "example.test/local-app:1"
        and .IMAGE_ID == $image_id
        and .OS == "linux"
        and .ARCHITECTURE == "amd64"
        and .PROFILE == "standard"
        and .PROFILE_VERSION == 2
        and .POLICY_SCHEMA == 1
        and .VALIDATOR_VERSION == 2
        and .EXPIRES == $expires
    ' "$approval" >/dev/null || fail 'approval authority is incomplete'

approval_output="$(vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2)" \
    || fail 'valid local image approval was rejected'
[[ -z "$approval_output" ]] \
    || fail 'internal image approval check emitted output'

if vx_compose_image_approval_require \
    bob "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'approval crossed owners'
fi
if vx_compose_image_approval_require \
    alice example.test/other:1 "$image_id" linux amd64 standard 2 \
    2>/dev/null; then
    fail 'approval crossed references'
fi
if vx_compose_image_approval_require \
    alice "$reference" "$other_id" linux amd64 standard 2 2>/dev/null; then
    fail 'approval crossed image IDs'
fi
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux arm64 standard 2 2>/dev/null; then
    fail 'approval crossed architectures'
fi
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" windows amd64 standard 2 2>/dev/null; then
    fail 'approval crossed operating systems'
fi
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 admin-approved 3 \
    2>/dev/null; then
    fail 'approval crossed profiles'
fi
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 1 2>/dev/null; then
    fail 'approval crossed profile versions'
fi

saved_policy="$VX_COMPOSE_POLICY_SCHEMA_VERSION"
VX_COMPOSE_POLICY_SCHEMA_VERSION=9
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'approval survived a policy-schema change'
fi
VX_COMPOSE_POLICY_SCHEMA_VERSION="$saved_policy"
saved_validator="$VX_COMPOSE_POLICY_VALIDATOR_VERSION"
VX_COMPOSE_POLICY_VALIDATOR_VERSION=9
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'approval survived a validator-version change'
fi
VX_COMPOSE_POLICY_VALIDATOR_VERSION="$saved_validator"

cp -- "$approval" "$test_root/valid-approval.json"
jq '.EXPIRES = "2000-01-01T00:00:00Z"' "$approval" \
    >"$test_root/expired.json"
mv -f -- "$test_root/expired.json" "$approval"
chmod 0600 "$approval"
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'expired local image approval remained valid'
fi
mv -f -- "$test_root/valid-approval.json" "$approval"
chmod 0600 "$approval"

touch "$test_root/replaced"
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'replaced local image identity remained approved'
fi
rm -f -- "$test_root/replaced"

chmod 0644 "$approval"
if vx_compose_image_approval_require \
    alice "$reference" "$image_id" linux amd64 standard 2 2>/dev/null; then
    fail 'insecure local image approval record was accepted'
fi
chmod 0600 "$approval"

docker_calls_before="$(wc -l <"$test_root/docker.log")"
vx_compose_image_approval_delete admin alice "$image_id" standard 2
[[ ! -e "$approval" ]] || fail 'revocation retained approval authority'
docker_calls_after="$(wc -l <"$test_root/docker.log")"
[[ "$docker_calls_after" == "$docker_calls_before" ]] \
    || fail 'revocation mutated or inspected Docker image data'
grep -Fq "image_id=$image_id profile=standard profile_version=2" \
    "$VESTA/data/users/alice/docker-audit.log" \
    || fail 'safe approval identity was not audited'
if grep -Fq "$reference" "$VESTA/data/users/alice/docker-audit.log"; then
    fail 'mutable image reference leaked into approval audit'
fi

rg -Fq '# options: ACTOR USER IMAGE_REFERENCE IMAGE_ID OS ARCHITECTURE PROFILE PROFILE_VERSION EXPIRES' \
    "$repo_root/bin/v-approve-docker-image" \
    || fail 'approval CLI argument contract drifted'
rg -Fq '# options: ACTOR USER IMAGE_ID PROFILE PROFILE_VERSION' \
    "$repo_root/bin/v-delete-docker-image-approval" \
    || fail 'revocation CLI argument contract drifted'

echo 'Compose local image approval tests passed.'
