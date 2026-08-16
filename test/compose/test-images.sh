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

digest_a='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
digest_c='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
immutable_reference="example.test/app@$digest_a"
fake_docker="$test_root/fake-docker"
inspect_json='{"Id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","Size":30,"RepoTags":["example.test/app:1"],"RepoDigests":["aaa.invalid/unrelated@sha256:0000000000000000000000000000000000000000000000000000000000000000","example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Architecture":"amd64","Os":"linux","Config":{"Labels":{"org.opencontainers.image.source":"https://example.test/source?auth=must-not-copy","org.opencontainers.image.revision":"abc123","org.opencontainers.image.version":"secret token must-not-copy","org.opencontainers.image.vendor":"Vortex","org.opencontainers.image.created":"2026-07-31T00:00:00Z","secret.label":"must-not-copy"}}}'
port_inspect_json='{"Id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","Size":30,"RepoTags":[],"RepoDigests":["registry.example:5000/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Architecture":"amd64","Os":"linux","Config":{"Labels":{}}}'
single_manifest_json='{"Digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Descriptor":{"platform":{"os":"linux","architecture":"amd64"}},"SchemaV2Manifest":{"schemaVersion":2,"config":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":10},"layers":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":20}]}}'
child_manifest_json='{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":{"os":"linux","architecture":"amd64"}},"SchemaV2Manifest":{"schemaVersion":2,"config":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":11},"layers":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":21}]}}'
index_manifest_json='[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":{"os":"linux","architecture":"amd64"}}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","platform":{"os":"linux","architecture":"arm64"}}}]'
too_many_layers_json="$(jq -cn '
  {Descriptor:{digest:"sha256:" + ("a" * 64)},
   Platform:{os:"linux",architecture:"amd64"},
   SchemaV2Manifest:{
     config:{digest:"sha256:" + ("1" * 64),size:1},
     layers:[range(0;129) | {digest:"sha256:" + ("2" * 64),size:1}]
   }}')"
current_manifest_json='[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","platform":{"os":"linux","architecture":"amd64"}}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","platform":{"os":"linux","architecture":"arm64"}}}]'
candidate_manifest_json='[{"Descriptor":{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","platform":{"os":"linux","architecture":"amd64"}}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","platform":{"os":"linux","architecture":"arm64"}}}]'
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
    printf '%s\n' '    printf "%s\n" '"'"'{"Id":"sha256:1111111111111111111111111111111111111111111111111111111111111111","RepoTags":["example.test/app:1"],"RepoDigests":["example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],"Architecture":"amd64","Os":"linux","Config":{"Labels":{"org.opencontainers.image.source":"https://example.test/source","org.opencontainers.image.revision":"abc123","org.opencontainers.image.version":"1","org.opencontainers.image.vendor":"Vortex","org.opencontainers.image.created":"2026-07-31T00:00:00Z","secret.label":"must-not-copy"}}}'"'"'"
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" manifest inspect "*)'
    printf '%s\n' '    printf "%s\n" '"'"'{"Descriptor":{"digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'"'"
VX_BROKEN_GENERATOR
    printf '%s\n' '    if [[ " $* " == *" registry.example:5000/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "* ]]; then'
    printf '      printf "%%s\\n" %q\n' "$port_inspect_json"
    printf '%s\n' '    elif [[ -e "$(dirname -- "$0")/oversized-local" ]]; then'
    printf '      printf "%%s\\n" %q\n' "$(jq -c '.Size=5368709121' <<<"$inspect_json")"
    printf '%s\n' '    else'
    printf '      printf "%%s\\n" %q\n' "$inspect_json"
    printf '%s\n' '    fi'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" manifest inspect "*)'
    printf '%s\n' '    mode="$(cat "$(dirname -- "$0")/manifest-mode" 2>/dev/null || printf update)"'
    printf '%s\n' '    case "$mode" in'
    printf '      single) printf "%%s\\n" %q ;;\n' "$single_manifest_json"
    printf '%s\n' '      index)'
    printf '%s\n' '        if [[ "${!#}" == *@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc ]]; then'
    printf '          printf "%%s\\n" %q\n' "$child_manifest_json"
    printf '%s\n' '        else'
    printf '          printf "%%s\\n" %q\n' "$index_manifest_json"
    printf '%s\n' '        fi ;;'
    printf '      missing) printf "%%s\\n" %q ;;\n' '[{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"Platform":{"os":"linux","architecture":"arm64"}}]'
    printf '      ambiguous) printf "%%s\\n" %q ;;\n' '[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"Platform":{"os":"linux","architecture":"amd64"}},{"Descriptor":{"digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"Platform":{"os":"linux","architecture":"amd64"}}]'
    printf '      wrong-platform) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"arm64"},"SchemaV2Manifest":{"config":{"size":10},"layers":[{"size":20}]}}'
    printf '      zero) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"amd64"},"SchemaV2Manifest":{"config":{"size":0},"layers":[]}}'
    printf '      malformed) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"amd64"},"SchemaV2Manifest":{"config":{"size":"10"},"layers":[{"size":20}]}}'
    printf '      oversized) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"amd64"},"SchemaV2Manifest":{"config":{"size":5368709120},"layers":[{"size":1}]}}'
    printf '      too-many-layers) printf "%%s\\n" %q ;;\n' "$too_many_layers_json"
    printf '      foreign-url) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"amd64"},"SchemaV2Manifest":{"config":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":10},"layers":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":20,"urls":["https://foreign.invalid/layer"]}]}}'
    printf '      foreign-media) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"Platform":{"os":"linux","architecture":"amd64"},"SchemaV2Manifest":{"config":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":10},"layers":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":20,"mediaType":"application/vnd.docker.image.rootfs.foreign.diff.tar.gzip"}]}}'
    printf '      foreign-index) printf "%%s\\n" %q ;;\n' '[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","urls":["https://foreign.invalid/manifest"]},"Platform":{"os":"linux","architecture":"amd64"}}]'
    printf '      foreign-outer) printf "%%s\\n" %q ;;\n' '{"Descriptor":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","platform":{"os":"linux","architecture":"amd64"},"urls":["https://foreign.invalid/manifest"],"mediaType":"application/vnd.docker.distribution.manifest.v2+foreign"},"SchemaV2Manifest":{"config":{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":10},"layers":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","size":20}]}}'
    printf '      foreign-other-index) printf "%%s\\n" %q ;;\n' '[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"Platform":{"os":"linux","architecture":"amd64"}},{"Descriptor":{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","urls":["https://foreign.invalid/manifest"]},"Platform":{"os":"linux","architecture":"arm64"}}]'
    printf '      malformed-other-index) printf "%%s\\n" %q ;;\n' '[{"Descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},"Platform":{"os":"linux","architecture":"amd64"}},{"Descriptor":{"digest":"not-a-digest"},"Platform":{"os":"linux","architecture":"arm64"}}]'
    printf '%s\n' '      timeout) sleep 2; printf "%s\n" "{}" ;;'
    printf '%s\n' '      output-limit) head -c 1048577 /dev/zero | tr "\\000" x ;;'
    printf '%s\n' '      *)'
    printf '%s\n' '    if [[ "${!#}" == *@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || -e "$(dirname -- "$0")/manifest-same" ]]; then'
    printf '      printf "%%s\\n" %q\n' "$current_manifest_json"
    printf '%s\n' '    else'
    printf '      printf "%%s\\n" %q\n' "$candidate_manifest_json"
    printf '%s\n' '    fi'
    printf '%s\n' '        ;;'
    printf '%s\n' '    esac'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *" image pull "*) [[ ! -e "$(dirname -- "$0")/pull-timeout" ]] || sleep 2 ;;'
    printf '%s\n' '  *" image load "*) printf "%s\n" "Loaded image: example.test/app:1" ;;'
    printf '%s\n' 'esac'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

vx_compose_preview_expected_uid() { id -u; }
vx_compose_preview_expected_gid() { id -g; }
audit_lock_seen=no
activation_lock_seen=no
audit_original="$(declare -f vx_compose_image_pull_audit)"
activation_original="$(declare -f vx_compose_image_registry_pull_activate)"
eval "${audit_original/vx_compose_image_pull_audit ()/vx_compose_image_pull_audit_original ()}"
eval "${activation_original/vx_compose_image_registry_pull_activate ()/vx_compose_image_registry_pull_activate_original ()}"
vx_compose_image_pull_audit() {
    if [[ "$4" == succeeded \
        && -n "${VX_COMPOSE_REGISTRY_LOCK_FD:-}" ]]; then
        audit_lock_seen=yes
    fi
    vx_compose_image_pull_audit_original "$@"
}
vx_compose_image_registry_pull_activate() {
    [[ -z "${VX_COMPOSE_REGISTRY_LOCK_FD:-}" ]] \
        || activation_lock_seen=yes
    vx_compose_image_registry_pull_activate_original "$@"
}
preview_id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
preview_root="$VESTA/data/tmp/compose-previews/$preview_id"
source_sha=''
candidate_sha=''
write_pull_preview() {
    local canonical="$1" created expires policy_sha
    install -d -m 0700 "$(dirname -- "$preview_root")" "$preview_root"
    printf 'services:\n  web:\n    image: %s\n' "$immutable_reference" \
        >"$preview_root/source.compose.yaml"
    cp "$preview_root/source.compose.yaml" "$preview_root/compose.yaml"
    printf '%s\n' "$canonical" >"$preview_root/canonical.json"
    printf "POLICY_SCHEMA='1'\n" >"$preview_root/policy.conf"
    source_sha="$(sha256sum "$preview_root/source.compose.yaml" | awk '{print $1}')"
    candidate_sha="$(sha256sum "$preview_root/canonical.json" | awk '{print $1}')"
    policy_sha="$(sha256sum "$preview_root/policy.conf" | awk '{print $1}')"
    printf '%s  canonical.json\n' "$candidate_sha" \
        >"$preview_root/canonical.sha256"
    created="$(date +%s)"
    expires=$((created + 900))
    {
        printf "ACTOR='alice'\nOWNER='alice'\nPROJECT='app'\n"
        printf "PROFILE='standard'\nMODE='add'\n"
        printf "SOURCE_SHA256='%s'\n" "$source_sha"
        printf "CANDIDATE_SHA256='%s'\n" "$candidate_sha"
        printf "POLICY_SHA256='%s'\n" "$policy_sha"
        printf "EXPECTED_CURRENT_REVISION='0'\n"
        printf "CREATED_EPOCH='%s'\nEXPIRES_EPOCH='%s'\n" "$created" "$expires"
    } >"$preview_root/preview.conf"
    (
        cd "$preview_root"
        sha256sum source.compose.yaml compose.yaml canonical.json \
            canonical.sha256 policy.conf >manifest.sha256
    )
    chmod 0600 "$preview_root"/*
}
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"

vx_compose_image_reference_is_immutable "$immutable_reference" \
    || fail 'exact immutable repository digest was rejected'
for invalid_reference in \
    example.test/app:latest \
    'https://example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'user:password@example.test/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'registry.example:0/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'registry.example:65536/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'registry.example:5000@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'registry.example:bad/team/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'registry.example/team:5000/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'example.test/app@sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; do
    ! vx_compose_image_reference_is_immutable "$invalid_reference" \
        || fail "invalid immutable reference was accepted: $invalid_reference"
done

printf 'single\n' >"$test_root/manifest-mode"
: >"$test_root/docker.log"
vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" \
    >"$test_root/immutable-pull.json"
[[ "$audit_lock_seen:$activation_lock_seen" == yes:yes ]] \
    || fail 'registry lock was not held through terminal audit and activation'
jq -e --arg reference "$immutable_reference" '
    .SCHEMA == 1 and .RESULT == "succeeded"
    and .OWNER == "alice"
    and .REFERENCE == $reference
    and .PLATFORM_MANIFEST_DIGEST == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .MANIFEST_SIZE_BYTES == 30
    and .LOCAL_SIZE_BYTES == 30
    and .OS == "linux"
    and .ARCHITECTURE == "amd64"
' "$test_root/immutable-pull.json" >/dev/null \
    || fail 'immutable pull metadata is incomplete'
immutable_key="$(printf '%s' "$immutable_reference" | sha256sum | awk '{print $1}')"
immutable_metadata="$(vx_compose_image_metadata_root alice)/$immutable_key.json"
vx_compose_image_registry_pull_is_recorded alice "$immutable_reference" \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    linux amd64 || fail 'registry-pull provenance did not validate'
cp "$immutable_metadata" "$test_root/active-pull-authority.json"
jq '.PROVENANCE.STATE = "pending"' "$immutable_metadata" \
    >"$test_root/pending-pull-authority.json"
install -m 0600 "$test_root/pending-pull-authority.json" "$immutable_metadata"
if vx_compose_image_registry_pull_is_recorded alice "$immutable_reference" \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    linux amd64; then
    fail 'pending pull evidence became deployment authority'
fi
install -m 0600 "$test_root/active-pull-authority.json" "$immutable_metadata"
[[ "$(stat -c '%a:%h' "$immutable_metadata")" == 600:1 \
    && "$(stat -c '%s' "$immutable_metadata")" -le 1048576 ]] \
    || fail 'registry-pull provenance file security is incorrect'
jq -e -s '
    [ .[] | select(.ACTION == "image-pull") | .RESULT ]
    | index("started") != null and index("succeeded") != null
' "$VESTA/data/users/alice/docker-audit.log" >/dev/null \
    || fail 'tenant image pull audit lacks started/succeeded evidence'

primary_immutable_reference="$immutable_reference"
immutable_reference="registry.example:5000/team/app@$digest_a"
vx_compose_image_reference_is_immutable "$immutable_reference" \
    || fail 'private registry reference with an explicit port was rejected'
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"
vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" \
    >"$test_root/port-pull.json"
port_key="$(printf '%s' "$immutable_reference" | sha256sum | awk '{print $1}')"
vx_compose_image_registry_pull_is_recorded alice "$immutable_reference" \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    linux amd64 || fail 'explicit-port registry pull provenance did not validate'
[[ -f "$(vx_compose_image_metadata_root alice)/$port_key.json" ]] \
    || fail 'explicit-port registry pull authority was not recorded'
immutable_reference="$primary_immutable_reference"
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"

: >"$test_root/docker.log"
if vx_compose_image_pull_for_preview bob alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'cross-owner image pull was accepted'
fi
[[ ! -s "$test_root/docker.log" ]] \
    || fail 'cross-owner image pull reached Docker'

sed -i "s/PROFILE='standard'/PROFILE='admin-approved'/" \
    "$preview_root/preview.conf"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'privileged-profile image pull was accepted'
fi
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"
sed -i "s/^EXPIRES_EPOCH=.*/EXPIRES_EPOCH='1'/" \
    "$preview_root/preview.conf"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'expired-preview image pull was accepted'
fi
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"

authority_before="$(sha256sum "$immutable_metadata" | awk '{print $1}')"
audit_definition="$(declare -f vx_compose_image_pull_audit)"
vx_compose_image_pull_audit() { [[ "$4" != succeeded ]]; }
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'failed terminal success audit was ignored'
fi
eval "$audit_definition"
[[ "$(sha256sum "$immutable_metadata" | awk '{print $1}')" \
    == "$authority_before" ]] \
    || fail 'audit failure did not restore prior pull authority'
activation_definition="$(declare -f vx_compose_image_registry_pull_activate)"
vx_compose_image_registry_pull_activate() { return 1; }
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'failed pull-authority activation was ignored'
fi
eval "$activation_definition"
[[ "$(sha256sum "$immutable_metadata" | awk '{print $1}')" \
    == "$authority_before" ]] \
    || fail 'activation failure did not restore prior pull authority'
jq -e -s '
    [ .[] | select(.ACTION == "image-pull") | .RESULT ][-2:]
    == ["succeeded", "failed"]
' "$VESTA/data/users/alice/docker-audit.log" >/dev/null \
    || fail 'activation failure did not record a terminal failed event'
manifest_line="$(grep -n '^ARG=manifest$' "$test_root/docker.log" | head -1 | cut -d: -f1)"
pull_line="$(grep -n '^ARG=pull$' "$test_root/docker.log" | head -1 | cut -d: -f1)"
[[ -n "$manifest_line" && -n "$pull_line" && "$manifest_line" -lt "$pull_line" ]] \
    || fail 'manifest admission did not precede image pull'

printf 'index\n' >"$test_root/manifest-mode"
vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" \
    >"$test_root/index-pull.json"
jq -e '
    .PLATFORM_MANIFEST_DIGEST == "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    and .MANIFEST_SIZE_BYTES == 32
' "$test_root/index-pull.json" >/dev/null \
    || fail 'index manifest did not select exactly one approved child'

for mode in missing ambiguous wrong-platform zero malformed oversized \
    too-many-layers foreign-url foreign-media foreign-index foreign-outer \
    foreign-other-index malformed-other-index output-limit; do
    printf '%s\n' "$mode" >"$test_root/manifest-mode"
    : >"$test_root/docker.log"
    if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
        "$candidate_sha" 0 "$immutable_reference" \
        >"$test_root/$mode.out" 2>"$test_root/$mode.error"; then
        fail "$mode manifest was accepted"
    fi
    ! grep -Fxq 'ARG=pull' "$test_root/docker.log" \
        || fail "$mode manifest reached Docker image pull"
done
printf 'timeout\n' >"$test_root/manifest-mode"
VX_COMPOSE_IMAGE_MANIFEST_TIMEOUT_SECONDS=1
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'manifest timeout was accepted'
fi
VX_COMPOSE_IMAGE_MANIFEST_TIMEOUT_SECONDS=30

printf 'single\n' >"$test_root/manifest-mode"
touch "$test_root/pull-timeout"
VX_COMPOSE_IMAGE_PULL_TIMEOUT_SECONDS=1
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'image pull timeout was accepted'
fi
VX_COMPOSE_IMAGE_PULL_TIMEOUT_SECONDS=300
rm -f "$test_root/pull-timeout"

touch "$test_root/oversized-local"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'oversized post-pull local image was accepted'
fi
rm -f "$test_root/oversized-local"
: >"$test_root/docker.log"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 example.test/app:latest \
    2>"$test_root/tag-pull.error"; then
    fail 'tenant immutable pull accepted a tag'
fi
[[ ! -s "$test_root/docker.log" ]] \
    || fail 'invalid tenant image reference reached Docker'

write_pull_preview \
    "{\"services\":{\"one\":{\"image\":\"$immutable_reference\"},\"two\":{\"image\":\"$immutable_reference\"}}}"
: >"$test_root/docker.log"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 0 "$immutable_reference" 2>/dev/null; then
    fail 'preview with duplicate image occurrence was accepted'
fi
[[ ! -s "$test_root/docker.log" ]] \
    || fail 'duplicate preview image reached Docker'
write_pull_preview \
    "{\"services\":{\"web\":{\"image\":\"$immutable_reference\"}}}"
if vx_compose_image_pull_for_preview alice alice app "$preview_id" "$source_sha" \
    "$candidate_sha" 1 "$immutable_reference" 2>/dev/null; then
    fail 'preview pull accepted a stale revision argument'
fi

printf 'update\n' >"$test_root/manifest-mode"

printf 'single\n' >"$test_root/manifest-mode"
[[ "$(vx_compose_image_manifest_platform_digest \
        alice "$immutable_reference")" == "$digest_a" ]] \
    || fail 'uppercase Docker single-manifest Digest was not recognized'
printf 'update\n' >"$test_root/manifest-mode"

vx_compose_image_pull alice example.test/app:1 >"$test_root/pull.json"
jq -e '
    .OWNER == "alice"
    and .REFERENCE == "example.test/app:1"
    and .IMAGE_ID == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    and (.IMMUTABLE_REFERENCES | length == 2)
    and .DELIVERY == "administrator-pull"
    and .OCI_LABELS.source == ""
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
jq -e '.IMAGE_ID == "sha256:1111111111111111111111111111111111111111111111111111111111111111"' "$test_root/load.json" >/dev/null \
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
printf '{"services":{"web":{"image":"%s"}}}\n' "$immutable_reference" \
    >"$project_root/runtime/canonical.json"
printf 'frozen\n' >"$project_root/revisions/000001/images.json"
vx_compose_resolve_images_to_file \
    alice "$project_root/runtime/canonical.json" standard \
    "$test_root/pending-images.json"
jq -e '.web.IMAGE_ID == "sha256:1111111111111111111111111111111111111111111111111111111111111111"' \
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

bad_port_reference="registry.example:65536/team/app@$digest_a"
jq --arg reference "$bad_port_reference" --arg digest "$digest_a" '
    .web.REFERENCE = $reference
    | .web.IMMUTABLE_REFERENCE = $reference
    | .web.REGISTRY_DIGEST = $digest
    | .web.REPO_DIGESTS = [$reference]
' "$test_root/pending-images.json" >"$test_root/bad-port-current.json"
chmod 0640 "$test_root/bad-port-current.json"
if vx_compose_image_evidence_current_validate \
    "$test_root/bad-port-current.json"; then
    fail 'current image evidence accepted an out-of-range registry port'
fi
jq -n --arg reference "$bad_port_reference" '{
    web:{ARCHITECTURE:"amd64",
         IMAGE_ID:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
         OS:"linux",REFERENCE:$reference,REPO_DIGESTS:[$reference]}
}' >"$test_root/bad-port-legacy.json"
chmod 0640 "$test_root/bad-port-legacy.json"
if vx_compose_image_evidence_legacy_validate \
    "$test_root/bad-port-legacy.json"; then
    fail 'legacy image evidence accepted an out-of-range registry port'
fi

immutable_key="$(printf '%s' "$immutable_reference" | sha256sum | awk '{print $1}')"
immutable_metadata="$(vx_compose_image_metadata_root alice)/$immutable_key.json"
cp "$immutable_metadata" "$test_root/immutable-metadata.json"
rm -f "$immutable_metadata"
if vx_compose_resolve_images_to_file alice \
    "$project_root/runtime/canonical.json" standard \
    "$test_root/unrecorded-images.json" 2>/dev/null; then
    fail 'standard resolver accepted an unrecorded immutable digest'
fi
install -m 0600 "$test_root/immutable-metadata.json" "$immutable_metadata"

printf '{"services":{"web":{"image":"example.test/app:1"}}}\n' \
    >"$test_root/tag-canonical.json"
if vx_compose_resolve_images_to_file alice "$test_root/tag-canonical.json" \
    standard "$test_root/tag-unapproved.json" 2>/dev/null; then
    fail 'Docker-29-style tag RepoDigest bypassed local image approval'
fi
expires="$(date -u -d '+1 hour' +'%Y-%m-%dT%H:%M:%SZ')"
vx_compose_image_approval_add admin alice example.test/app:1 \
    sha256:1111111111111111111111111111111111111111111111111111111111111111 \
    linux amd64 standard 2 "$expires" >/dev/null
vx_compose_resolve_images_to_file alice "$test_root/tag-canonical.json" \
    standard "$test_root/tag-approved.json" \
    || fail 'standard resolver rejected a current administrator approval'

printf '{"services":{"web":{"image":"example.test/legacy:1"}}}\n' \
    >"$test_root/legacy-canonical.json"
if vx_compose_resolve_images_to_file alice "$test_root/legacy-canonical.json" \
    restricted-compatibility "$test_root/legacy-images.json" 2>/dev/null; then
    fail 'fresh non-standard candidate used broad RepoDigests compatibility'
fi

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
