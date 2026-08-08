#!/usr/bin/env bash

VX_COMPOSE_IMAGE_MAX_BYTES="${VX_COMPOSE_IMAGE_MAX_BYTES:-${VX_DOCKER_IMAGE_MAX_BYTES:-5368709120}}"
VX_COMPOSE_ALLOWED_ARCHITECTURE="${VX_COMPOSE_ALLOWED_ARCHITECTURE:-${VX_DOCKER_ALLOWED_ARCHITECTURE:-amd64}}"
VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION='2'
VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES='1048576'
VX_COMPOSE_IMAGE_MANIFEST_MAX_BYTES='1048576'
VX_COMPOSE_IMAGE_MAX_LAYERS='128'
VX_COMPOSE_IMAGE_MANIFEST_TIMEOUT_SECONDS='30'
VX_COMPOSE_IMAGE_PULL_TIMEOUT_SECONDS='300'
[[ "$VX_COMPOSE_IMAGE_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] \
    || VX_COMPOSE_IMAGE_MAX_BYTES='5368709120'
[[ "$VX_COMPOSE_ALLOWED_ARCHITECTURE" =~ ^(amd64|arm64)$ ]] \
    || VX_COMPOSE_ALLOWED_ARCHITECTURE='amd64'

vx_compose_image_immutable_repository_is_valid() {
    local repository="$1" first path host port segment

    [[ -n "$repository" && ${#repository} -le 182
        && "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]*$
        && "$repository" != */ && "$repository" != *//*
        && "$repository" != *..* ]] || return 1
    path="$repository"
    if [[ "$repository" == *:* ]]; then
        [[ "$repository" == */* ]] || return 1
        first="${repository%%/*}"
        [[ "$first" == *:* && "$first" != *:*:* ]] || return 1
        host="${first%:*}"
        port="${first##*:}"
        [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$
            && "$port" =~ ^[0-9]{1,5}$
            && $((10#$port)) -ge 1 && $((10#$port)) -le 65535 ]] || return 1
        path="${repository#*/}"
    fi
    while IFS= read -r segment; do
        [[ "$segment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
            || return 1
    done < <(tr / '\n' <<<"$path")
}

vx_compose_image_reference_is_valid() {
    local reference="$1" repository digest

    [[ "$reference" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$
        && "$reference" != *://*
        && "$reference" != *..*
        && "$reference" != *@*@*
        && ! "$reference" =~ ^[^/]*:[^/]*@ ]] || return 1
    if [[ "$reference" == *@* ]]; then
        repository="${reference%@*}"
        digest="${reference##*@}"
        vx_compose_image_immutable_repository_is_valid "$repository" \
            && [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]]
    fi
}

vx_compose_image_reference_is_immutable() {
    local reference="$1"

    vx_compose_image_reference_is_valid "$reference" \
        && [[ "$reference" == *@sha256:* ]]
}

vx_compose_image_repository_for_reference() {
    local reference="$1" repository leaf prefix

    vx_compose_image_reference_is_valid "$reference" || return 1
    repository="${reference%@*}"
    leaf="${repository##*/}"
    if [[ "$leaf" == *:* ]]; then
        leaf="${leaf%%:*}"
        if [[ "$repository" == */* ]]; then
            prefix="${repository%/*}"
            repository="$prefix/$leaf"
        else
            repository="$leaf"
        fi
    fi
    printf '%s\n' "$repository"
}

vx_compose_image_immutable_reference() {
    local inspection="$1" reference="$2" repository

    repository="$(vx_compose_image_repository_for_reference "$reference")" \
        || return 1
    jq -er --arg repository "$repository" '
        [(.RepoDigests // [])[]
         | select(type == "string" and length <= 255)
         | select(startswith($repository + "@sha256:"))
         | select((split("@") | length) == 2)
         | select(split("@")[1] | test("^sha256:[a-f0-9]{64}$"))]
        | unique | sort
        | if length <= 1 then first // ""
          else error("ambiguous repository digest identity") end
    ' <<<"$inspection"
}

vx_compose_image_oci_labels() {
    jq -c '
        def sensitive:
            test(
                "(?i)(^|[^a-z0-9])(password|passwd|secret|token|credential|auth|authorization|authentication|auth[._ -]?(header|key|token|secret|credential)|bearer|private[._ -]?key|access[._ -]?(key|token|secret|credential)|client[._ -]?(key|token|secret|credential)|api[._ -]?key)([^a-z0-9]|$)"
            )
            or test("(?i)[a-z][a-z0-9+.-]*://[^/@[:space:]]+@");
        def bounded:
            if type == "string"
               and length <= 512
               and (test("[[:cntrl:]]") | not)
               and (sensitive | not)
            then .
            else ""
            end;
        {
            source: (.Config.Labels["org.opencontainers.image.source"] // ""),
            revision: (.Config.Labels["org.opencontainers.image.revision"] // ""),
            version: (.Config.Labels["org.opencontainers.image.version"] // ""),
            vendor: (.Config.Labels["org.opencontainers.image.vendor"] // ""),
            created: (.Config.Labels["org.opencontainers.image.created"] // "")
        } | with_entries(.value |= bounded)
    ' <<<"$1"
}

vx_compose_image_oci_labels_are_safe() {
    jq -e '
        def sensitive:
            test(
                "(?i)(^|[^a-z0-9])(password|passwd|secret|token|credential|auth|authorization|authentication|auth[._ -]?(header|key|token|secret|credential)|bearer|private[._ -]?key|access[._ -]?(key|token|secret|credential)|client[._ -]?(key|token|secret|credential)|api[._ -]?key)([^a-z0-9]|$)"
            )
            or test("(?i)[a-z][a-z0-9+.-]*://[^/@[:space:]]+@");
        type == "object"
        and (keys - ["source","revision","version","vendor","created"]
             | length == 0)
        and all(.[];
            type == "string"
            and length <= 512
            and (test("[[:cntrl:]]") | not)
            and (sensitive | not)
        )
    ' <<<"$1" >/dev/null
}

vx_compose_image_manifest_platform_digest() {
    local owner="$1" reference="$2" manifest

    manifest="$(vx_compose_owner_docker \
        "$owner" manifest inspect --verbose "$reference")" \
        || return 1
    jq -r --arg architecture "$VX_COMPOSE_ALLOWED_ARCHITECTURE" '
        def platform:
            (.Platform // .platform // .Descriptor.platform
             // .Descriptor.Platform // {});
        if type == "array" then
            [.[] | select((platform.os // "") == "linux"
                          and (platform.architecture // "") == $architecture)
                 | .Descriptor.digest]
            | unique
            | if length == 1 then .[0] else "" end
        elif (.Descriptor.digest? | type) == "string" then .Descriptor.digest
        elif (.Digest? | type) == "string" then .Digest
        elif (.digest? | type) == "string" then .digest
        else "" end
    ' <<<"$manifest"
}

vx_compose_image_metadata_root() {
    printf '%s/data/users/%s/docker-images\n' "$VESTA" "$1"
}

vx_compose_image_owner_docker_bounded() {
    local owner="$1" timeout_seconds="$2"
    local root docker_bin
    shift 2

    [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
    vx_compose_registry_prepare "$owner" || return 1
    root="$(vx_compose_registry_root "$owner")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" \
        env -i PATH="$VX_COMPOSE_SAFE_PATH" HOME="$root/home" \
        DOCKER_CONFIG="$root" "$docker_bin" "$@"
}

vx_compose_tenant_image_pull_lock_acquire() {
    local root lock expected_uid expected_gid

    root="$VESTA/data/vx/compose"
    lock="$root/.tenant-image-pull.lock"
    expected_uid="$(vx_compose_authority_uid)" || return 1
    expected_gid="$(vx_compose_authority_gid)" || return 1
    [[ ! -e "$root" || (-d "$root" && ! -L "$root") ]] || return 1
    install -d -m 0700 "$root" || return 1
    [[ "$(stat -c '%u:%g:%a:%F' "$root" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:700:directory" ]] || return 1
    if [[ ! -e "$lock" ]]; then
        ( umask 077; set -C; : >"$lock" ) 2>/dev/null || [[ -e "$lock" ]]
    fi
    [[ -f "$lock" && ! -L "$lock"
        && "$(stat -c '%u:%g:%a' "$lock" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:600" ]] || return 1
    exec {VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD}>"$lock" || return 1
    flock -x "$VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD" || {
        exec {VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD}>&-
        unset VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD
        return 1
    }
}

vx_compose_tenant_image_pull_lock_release() {
    [[ -n "${VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD:-}" ]] || return 0
    flock -u "$VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD" || true
    exec {VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD}>&-
    unset VX_COMPOSE_TENANT_IMAGE_PULL_LOCK_FD
}

vx_compose_image_manifest_parse() {
    local manifest_file="$1" expected_digest="$2" allow_index="$3"

    python3 - "$manifest_file" "$expected_digest" \
        "$VX_COMPOSE_ALLOWED_ARCHITECTURE" "$VX_COMPOSE_IMAGE_MAX_BYTES" \
        "$allow_index" "$VX_COMPOSE_IMAGE_MAX_LAYERS" <<'PY'
import json
import re
import sys

path, expected, architecture, maximum, allow_index, maximum_layers = sys.argv[1:]
digest_re = re.compile(r"^sha256:[a-f0-9]{64}$")
maximum = int(maximum)
maximum_layers = int(maximum_layers)

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate manifest key")
        result[key] = value
    return result

def reject_constant(_value):
    raise ValueError("non-standard manifest number")

with open(path, "rb") as source:
    document = json.load(
        source,
        object_pairs_hook=unique_object,
        parse_constant=reject_constant,
    )

def platform(entry):
    value = entry.get("Platform", entry.get("platform"))
    if value is None:
        descriptor = entry.get("Descriptor", {})
        if not isinstance(descriptor, dict):
            return None, None
        value = descriptor.get("platform", descriptor.get("Platform", {}))
    if not isinstance(value, dict):
        return None, None
    return value.get("os"), value.get("architecture")

def descriptor_digest(entry):
    descriptor = entry.get("Descriptor", {})
    return descriptor.get(
        "digest", entry.get("Digest", entry.get("digest", ""))
    )

def descriptor_has_foreign_source(entry):
    descriptor = entry.get("Descriptor", {})
    urls = descriptor.get("urls", entry.get("urls"))
    if urls not in (None, []):
        return True
    media_type = descriptor.get(
        "mediaType", entry.get("mediaType", entry.get("MediaType", ""))
    )
    if not isinstance(media_type, str):
        return True
    lowered = media_type.lower()
    return "foreign" in lowered or "nondistributable" in lowered

entries = None
if isinstance(document, list):
    entries = document
elif isinstance(document, dict) and isinstance(document.get("manifests"), list):
    entries = document["manifests"]

if entries is not None:
    if allow_index != "yes":
        raise ValueError("nested manifest index")
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("manifest index descriptor is invalid")
        entry_digest = descriptor_digest(entry)
        if (not isinstance(entry_digest, str)
                or not digest_re.fullmatch(entry_digest)):
            raise ValueError("manifest index descriptor digest is invalid")
        if descriptor_has_foreign_source(entry):
            raise ValueError("foreign index descriptors are not accepted")
    candidates = [
        entry for entry in entries
        if platform(entry) == ("linux", architecture)
    ]
    if len(candidates) != 1:
        raise ValueError("manifest platform selection is ambiguous")
    digest = descriptor_digest(candidates[0])
    print(json.dumps({"KIND": "child", "DIGEST": digest}, sort_keys=True))
    raise SystemExit(0)

if not isinstance(document, dict):
    raise ValueError("manifest is not an object")
if descriptor_has_foreign_source(document):
    raise ValueError("foreign manifest descriptors are not accepted")
if platform(document) != ("linux", architecture):
    raise ValueError("manifest platform is not approved")
digest = descriptor_digest(document)
if not isinstance(digest, str) or digest != expected or not digest_re.fullmatch(digest):
    raise ValueError("manifest digest does not match the requested identity")
body = document.get("SchemaV2Manifest", document.get("OCIManifest", document))
if not isinstance(body, dict):
    raise ValueError("manifest body is invalid")
config = body.get("config")
layers = body.get("layers")
if not isinstance(config, dict) or not isinstance(layers, list):
    raise ValueError("manifest config or layers are missing")
if len(layers) > maximum_layers:
    raise ValueError("manifest has too many layers")
descriptors = [config] + layers
for descriptor in descriptors:
    descriptor_digest_value = (
        descriptor.get("digest") if isinstance(descriptor, dict) else None
    )
    if (not isinstance(descriptor_digest_value, str)
            or not digest_re.fullmatch(descriptor_digest_value)):
        raise ValueError("manifest descriptor digest is invalid")
    urls = descriptor.get("urls")
    if urls not in (None, []):
        raise ValueError("foreign layer URLs are not accepted")
    media_type = descriptor.get("mediaType", "")
    if not isinstance(media_type, str):
        raise ValueError("manifest media type is invalid")
    if "foreign" in media_type.lower() or "nondistributable" in media_type.lower():
        raise ValueError("foreign layers are not accepted")
sizes = [config.get("size")] + [
    layer.get("size") if isinstance(layer, dict) else None for layer in layers
]
if any(isinstance(size, bool) or not isinstance(size, int) or size < 0 for size in sizes):
    raise ValueError("manifest size is malformed")
total = 0
for size in sizes:
    if size > maximum - total:
        raise ValueError("manifest exceeds the image size limit")
    total += size
if total <= 0:
    raise ValueError("manifest image size must be positive")
print(json.dumps({
    "ARCHITECTURE": architecture,
    "KIND": "manifest",
    "MANIFEST_SIZE_BYTES": total,
    "OS": "linux",
    "PLATFORM_MANIFEST_DIGEST": digest,
}, sort_keys=True))
PY
}

vx_compose_image_manifest_inspect_bounded() {
    local owner="$1" reference="$2" manifest_file root size limit

    root="$(vx_compose_registry_root "$owner")"
    limit="$VX_COMPOSE_IMAGE_MANIFEST_MAX_BYTES"
    manifest_file="$(mktemp "$root/.manifest.XXXXXX")" || return 1
    chmod 0600 "$manifest_file" || {
        rm -f -- "$manifest_file"
        return 1
    }
    if ! (set -o pipefail; \
        vx_compose_image_owner_docker_bounded "$owner" \
            "$VX_COMPOSE_IMAGE_MANIFEST_TIMEOUT_SECONDS" \
            manifest inspect --verbose "$reference" 2>/dev/null \
            | head -c "$((limit + 1))" >"$manifest_file"); then
        rm -f -- "$manifest_file"
        return 1
    fi
    size="$(stat -c '%s' "$manifest_file" 2>/dev/null)" || {
        rm -f -- "$manifest_file"
        return 1
    }
    [[ "$size" -gt 0 && "$size" -le "$limit" ]] || {
        rm -f -- "$manifest_file"
        return 1
    }
    printf '%s\n' "$manifest_file"
}

vx_compose_image_manifest_admission() {
    local owner="$1" reference="$2" requested_digest repository
    local manifest_file selection kind child_digest child_reference

    vx_compose_image_reference_is_immutable "$reference" || return 1
    requested_digest="${reference##*@}"
    manifest_file="$(vx_compose_image_manifest_inspect_bounded \
        "$owner" "$reference")" || return 1
    selection="$(vx_compose_image_manifest_parse \
        "$manifest_file" "$requested_digest" yes 2>/dev/null)" || {
        rm -f -- "$manifest_file"
        return 1
    }
    rm -f -- "$manifest_file"
    kind="$(jq -er '.KIND' <<<"$selection")" || return 1
    if [[ "$kind" == manifest ]]; then
        printf '%s\n' "$selection"
        return
    fi
    [[ "$kind" == child ]] || return 1
    child_digest="$(jq -er '.DIGEST' <<<"$selection")" || return 1
    repository="${reference%@*}"
    child_reference="$repository@$child_digest"
    manifest_file="$(vx_compose_image_manifest_inspect_bounded \
        "$owner" "$child_reference")" || return 1
    selection="$(vx_compose_image_manifest_parse \
        "$manifest_file" "$child_digest" no 2>/dev/null)" || {
        rm -f -- "$manifest_file"
        return 1
    }
    rm -f -- "$manifest_file"
    [[ "$(jq -er '.KIND' <<<"$selection")" == manifest ]] || return 1
    printf '%s\n' "$selection"
}

vx_compose_image_inspect() {
    local owner="$1"
    local reference="$2"
    local raw normalized

    raw="$(set -o pipefail; \
        vx_compose_image_owner_docker_bounded "$owner" \
            "$VX_COMPOSE_IMAGE_MANIFEST_TIMEOUT_SECONDS" \
            image inspect "$reference" 2>/dev/null \
            | head -c "$((VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES + 1))")" \
        || {
            vx_compose_error 'Docker image inspection failed'
            return 1
        }
    [[ "${#raw}" -le "$VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES" ]] || {
        vx_compose_error 'Docker image inspection exceeded the output limit'
        return 1
    }
    normalized="$(jq -c 'if type == "array" then .[0] else . end' <<<"$raw")" \
        || {
            vx_compose_error 'Docker image inspection returned invalid JSON'
            return 1
        }
    jq -e \
        --arg architecture "$VX_COMPOSE_ALLOWED_ARCHITECTURE" \
        '.Id | type == "string" and length > 0' <<<"$normalized" >/dev/null \
        || {
            vx_compose_error 'Docker image identity is incomplete'
            return 1
        }
    jq -e \
        --arg architecture "$VX_COMPOSE_ALLOWED_ARCHITECTURE" \
        '.Os == "linux" and .Architecture == $architecture' \
        <<<"$normalized" >/dev/null \
        || {
            vx_compose_error 'Docker image platform is not approved'
            return 1
        }
    printf '%s\n' "$normalized"
}

vx_compose_image_record() {
    local owner="$1"
    local reference="$2"
    local inspection="$3"
    local delivery="${4:-recorded}" platform_digest="${5:-}"
    local manifest_size="${6:-0}" provenance="${7-}" local_size="${8:-0}"
    local root key metadata temp_file labels expected_uid expected_gid

    root="$(vx_compose_image_metadata_root "$owner")"
    [[ -n "$provenance" ]] || provenance='{}'
    [[ "$delivery" =~ ^(recorded|administrator-pull|local-load|registry-pull)$ \
        && "$manifest_size" =~ ^[0-9]+$ \
        && "$local_size" =~ ^[0-9]+$ ]] || return 1
    [[ ! -e "$root" || (-d "$root" && ! -L "$root") ]] || return 1
    install -d -m 0700 "$root" || return 1
    expected_uid="$(vx_compose_authority_uid)" || return 1
    expected_gid="$(vx_compose_authority_gid)" || return 1
    [[ "$(stat -c '%u:%g:%a:%F' "$root" 2>/dev/null)" \
        == "$expected_uid:$expected_gid:700:directory" ]] || return 1
    key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    metadata="$root/$key.json"
    temp_file="$(mktemp "$root/.image.XXXXXX")"
    labels="$(vx_compose_image_oci_labels "$inspection")" || {
        rm -f -- "$temp_file"
        return 1
    }
    if ! jq -n -S \
        --arg owner "$owner" \
        --arg reference "$reference" \
        --arg inspected "$(vx_compose_now)" \
        --arg delivery "$delivery" \
        --arg platform_digest "$platform_digest" \
        --argjson manifest_size "$manifest_size" \
        --argjson local_size "$local_size" \
        --argjson provenance "$provenance" \
        --argjson image "$inspection" \
        --argjson labels "$labels" \
        'def immutable_reference_valid:
            type == "string" and length <= 255
            and test("^(?:[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}/)?[A-Za-z0-9][A-Za-z0-9._-]{0,127}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,127})*@sha256:[a-f0-9]{64}$")
            and ((split("@")[0] | split("/")[0]) as $first
                | if ($first | contains(":")) then
                    ($first | split(":")[1] | tonumber) as $port
                    | $port >= 1 and $port <= 65535
                  else true end);
        {
            OWNER: $owner,
            REFERENCE: $reference,
            DELIVERY: $delivery,
            IMAGE_ID: $image.Id,
            REPO_TAGS: (($image.RepoTags // [])
                | map(select(type == "string" and length <= 255))
                | unique | sort | .[0:128]),
            REPO_DIGESTS: (($image.RepoDigests // [])
                | map(select(type == "string" and length <= 255))
                | unique | sort | .[0:128]),
            IMMUTABLE_REFERENCES: (
                ($image.RepoDigests // [])
                | map(select(immutable_reference_valid))
                | unique | sort
            ),
            OCI_LABELS: $labels,
            OS: $image.Os,
            ARCHITECTURE: $image.Architecture,
            PLATFORM_MANIFEST_DIGEST: $platform_digest,
            MANIFEST_SIZE_BYTES: $manifest_size,
            LOCAL_SIZE_BYTES: $local_size,
            PROVENANCE: $provenance,
            INSPECTED: $inspected
        }' >"$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    vx_compose_control_file_protect "$temp_file" 600 || {
        rm -f -- "$temp_file"
        return 1
    }
    vx_compose_fsync_path "$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }
    mv -f -- "$temp_file" "$metadata" \
        && vx_compose_fsync_path "$metadata" \
        && vx_compose_fsync_path "$root" || return 1
    cat "$metadata"
}

vx_compose_image_audit() {
    local owner="$1"
    local action="$2"
    local reference="$3"
    local reference_sha

    reference_sha="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    vx_compose_owner_audit \
        "$owner" "image-$action" succeeded \
        "reference_sha256=$reference_sha"
}

vx_compose_image_pull() {
    local owner="$1"
    local reference="$2"
    local inspection metadata

    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_reference_is_valid "$reference" \
        || {
            vx_compose_error 'invalid Docker image reference'
            return 1
        }
    vx_compose_registry_lock_acquire "$owner" || return 1
    vx_compose_owner_docker "$owner" image pull "$reference" >/dev/null \
        || {
            vx_compose_registry_lock_release
            vx_compose_error 'Docker image pull failed'
            return 1
        }
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || {
        vx_compose_registry_lock_release
        return 1
    }
    jq -e '(.RepoDigests // []) | length > 0' <<<"$inspection" >/dev/null \
        || {
            vx_compose_registry_lock_release
            vx_compose_error 'pulled Docker image has no repository digest'
            return 1
        }
    metadata="$(vx_compose_image_record \
        "$owner" "$reference" "$inspection" administrator-pull)" \
        || {
            vx_compose_registry_lock_release
            return 1
        }
    vx_compose_image_audit "$owner" pull "$reference" || {
        vx_compose_registry_lock_release
        return 1
    }
    vx_compose_registry_lock_release
    printf '%s\n' "$metadata"
}

vx_compose_image_pull_immutable() {
    local owner="$1" reference="$2" provenance="$3"
    local admission inspection metadata platform_digest manifest_size
    local image_id local_size complete_provenance response
    local registry_lock_owned=no

    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_reference_is_immutable "$reference" || {
        vx_compose_error 'tenant image pull requires an immutable repository digest'
        return 1
    }
    jq -e \
        --arg owner "$owner" \
        --arg reference "$reference" '
        type == "object"
        and keys == ["CANDIDATE_SHA256","EXPECTED_CURRENT_REVISION","OWNER",
                     "PREVIEW_ID","PROJECT","REFERENCE","SOURCE_SHA256","TYPE"]
        and .TYPE == "registry-pull"
        and .OWNER == $owner
        and .REFERENCE == $reference
        and (.PROJECT | type == "string"
            and test("^[a-z0-9][a-z0-9-]{0,62}$"))
        and (.PREVIEW_ID | type == "string" and test("^[a-f0-9]{32}$"))
        and (.SOURCE_SHA256 | type == "string" and test("^[a-f0-9]{64}$"))
        and (.CANDIDATE_SHA256 | type == "string" and test("^[a-f0-9]{64}$"))
        and (.EXPECTED_CURRENT_REVISION | type == "number"
            and floor == . and . >= 0)
    ' <<<"$provenance" >/dev/null || return 1
    if [[ -z "${VX_COMPOSE_REGISTRY_LOCK_FD:-}" ]]; then
        vx_compose_registry_lock_acquire "$owner" || return 1
        registry_lock_owned=yes
    fi
    admission="$(vx_compose_image_manifest_admission \
        "$owner" "$reference")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        vx_compose_error 'Docker image manifest admission failed'
        return 1
    }
    if ! vx_compose_image_owner_docker_bounded "$owner" \
        "$VX_COMPOSE_IMAGE_PULL_TIMEOUT_SECONDS" \
        image pull "$reference" >/dev/null 2>/dev/null; then
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        vx_compose_error 'Docker image pull failed'
        return 1
    fi
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        return 1
    }
    image_id="$(jq -er '.Id | select(test("^sha256:[a-f0-9]{64}$"))' \
        <<<"$inspection")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        vx_compose_error 'pulled Docker image ID is invalid'
        return 1
    }
    local_size="$(jq -er --argjson maximum "$VX_COMPOSE_IMAGE_MAX_BYTES" '
        .Size | select(type == "number" and floor == . and . > 0 and . <= $maximum)
    ' <<<"$inspection")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        vx_compose_error 'pulled Docker image local size is invalid'
        return 1
    }
    jq -e --arg reference "$reference" \
        '(.RepoDigests // []) | index($reference) != null' \
        <<<"$inspection" >/dev/null || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        vx_compose_error 'pulled Docker image digest does not match the request'
        return 1
    }
    platform_digest="$(jq -er '.PLATFORM_MANIFEST_DIGEST' \
        <<<"$admission")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        return 1
    }
    manifest_size="$(jq -er '.MANIFEST_SIZE_BYTES' <<<"$admission")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        return 1
    }
    complete_provenance="$(jq -c \
        --arg image_id "$image_id" \
        --arg architecture "$VX_COMPOSE_ALLOWED_ARCHITECTURE" \
        --arg platform_digest "$platform_digest" \
        --argjson manifest_size "$manifest_size" \
        --argjson local_size "$local_size" \
        --arg recorded "$(vx_compose_now)" \
        '. + {
            IMAGE_ID:$image_id,
            OS:"linux",
            ARCHITECTURE:$architecture,
            STATE:"pending",
            PLATFORM_MANIFEST_DIGEST:$platform_digest,
            MANIFEST_SIZE_BYTES:$manifest_size,
            LOCAL_SIZE_BYTES:$local_size,
            RECORDED:$recorded
        }' <<<"$provenance")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        return 1
    }
    response="$(jq -n -cS \
        --arg owner "$owner" --arg reference "$reference" \
        --arg image_id "$image_id" --arg platform_digest "$platform_digest" \
        --arg architecture "$VX_COMPOSE_ALLOWED_ARCHITECTURE" \
        --argjson manifest_size "$manifest_size" \
        --argjson local_size "$local_size" \
        '{SCHEMA:1,RESULT:"succeeded",OWNER:$owner,REFERENCE:$reference,
          IMAGE_ID:$image_id,OS:"linux",ARCHITECTURE:$architecture,
          PLATFORM_MANIFEST_DIGEST:$platform_digest,
          MANIFEST_SIZE_BYTES:$manifest_size,LOCAL_SIZE_BYTES:$local_size}')" \
        || {
            [[ "$registry_lock_owned" != yes ]] \
                || vx_compose_registry_lock_release
            return 1
        }
    metadata="$(vx_compose_image_record "$owner" "$reference" \
        "$inspection" registry-pull "$platform_digest" "$manifest_size" \
        "$complete_provenance" "$local_size")" || {
        [[ "$registry_lock_owned" != yes ]] \
            || vx_compose_registry_lock_release
        return 1
    }
    [[ "$registry_lock_owned" != yes ]] || vx_compose_registry_lock_release
    printf '%s\n' "$response"
}

vx_compose_image_pull_audit() {
    local owner="$1" project="$2" reference="$3" result="$4"
    local reference_sha

    [[ "$result" == started || "$result" == succeeded || "$result" == failed ]] \
        || return 1
    reference_sha="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    vx_compose_owner_audit "$owner" image-pull "$result" \
        "project=$project reference_sha256=$reference_sha"
}

vx_compose_image_registry_pull_activate() {
    local owner="$1" reference="$2" root key metadata temp_file

    root="$(vx_compose_image_metadata_root "$owner")"
    key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    metadata="$root/$key.json"
    vx_compose_control_file_is_secure "$metadata" 600 \
        && [[ "$(stat -c '%h' "$metadata" 2>/dev/null)" == 1 \
            && "$(stat -c '%s' "$metadata" 2>/dev/null)" -le \
                "$VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES" ]] || return 1
    jq -e --arg owner "$owner" --arg reference "$reference" '
        .DELIVERY == "registry-pull"
        and .OWNER == $owner
        and .REFERENCE == $reference
        and .PROVENANCE.OWNER == $owner
        and .PROVENANCE.REFERENCE == $reference
        and .PROVENANCE.STATE == "pending"
    ' "$metadata" >/dev/null || return 1
    temp_file="$(mktemp "$root/.activate.XXXXXX")" || return 1
    jq -S '.PROVENANCE.STATE = "active"' "$metadata" >"$temp_file" \
        && vx_compose_control_file_protect "$temp_file" 600 \
        && vx_compose_fsync_path "$temp_file" \
        && mv -f -- "$temp_file" "$metadata" \
        && vx_compose_fsync_path "$metadata" \
        && vx_compose_fsync_path "$root" || {
            rm -f -- "$temp_file"
            return 1
        }
}

vx_compose_image_pull_for_preview() {
    local actor="$1" owner="$2" project="$3" preview_id="$4" source_sha="$5"
    local candidate_sha="$6" expected_revision="$7" reference="$8"
    local verified metadata mode root current count provenance result status=1
    local image_root image_key authority backup had_authority=no

    [[ "$actor" == "$owner" ]] || return 1
    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    vx_compose_image_reference_is_immutable "$reference" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    verified="$(vx_compose_preview_verify "$actor" "$owner" "$project" \
        "$preview_id" "$source_sha" "$candidate_sha" \
        "$expected_revision")" || {
        vx_compose_lock_release
        vx_compose_error 'immutable image pull preview evidence is invalid'
        return 1
    }
    metadata="$verified/preview.conf"
    mode="$(vx_compose_meta_get "$metadata" MODE)" || mode=
    root="$(vx_compose_project_root "$owner" "$project")"
    if [[ "$mode" == add ]]; then
        [[ "$expected_revision" == 0 && ! -e "$root" && ! -L "$root" ]] \
            || mode=
    elif [[ "$mode" == change ]] \
        && vx_compose_require_project "$owner" "$project"; then
        current="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
            || current=
        [[ "$current" == "$expected_revision"
            && "$(vx_compose_meta_get "$root/project.conf" PROFILE)" \
                == standard ]] || mode=
    else
        mode=
    fi
    [[ -n "$mode" ]] || {
        vx_compose_lock_release
        vx_compose_error 'immutable image pull preview revision is stale'
        return 1
    }
    count="$(jq -er --arg reference "$reference" '
        [.services[]?.image | select(. == $reference)] | length
    ' "$verified/canonical.json")" || {
        vx_compose_lock_release
        return 1
    }
    [[ "$count" == 1 ]] || {
        vx_compose_lock_release
        vx_compose_error \
            'immutable image must occur exactly once in the protected preview'
        return 1
    }
    provenance="$(jq -n -c \
        --arg owner "$owner" --arg project "$project" \
        --arg preview_id "$preview_id" --arg source_sha "$source_sha" \
        --arg candidate_sha "$candidate_sha" \
        --argjson revision "$expected_revision" \
        --arg reference "$reference" '{
            TYPE:"registry-pull",OWNER:$owner,PROJECT:$project,
            PREVIEW_ID:$preview_id,SOURCE_SHA256:$source_sha,
            CANDIDATE_SHA256:$candidate_sha,
            EXPECTED_CURRENT_REVISION:$revision,REFERENCE:$reference
        }')" || {
        vx_compose_lock_release
        return 1
    }
    if ! vx_compose_tenant_image_pull_lock_acquire; then
        vx_compose_lock_release
        return 1
    fi
    if ! vx_compose_registry_lock_acquire "$owner"; then
        vx_compose_tenant_image_pull_lock_release
        vx_compose_lock_release
        return 1
    fi
    image_root="$(vx_compose_image_metadata_root "$owner")"
    [[ ! -e "$image_root" || (-d "$image_root" && ! -L "$image_root") ]] \
        && install -d -m 0700 "$image_root" \
        && [[ "$(stat -c '%u:%g:%a:%F' "$image_root" 2>/dev/null)" \
            == "$(vx_compose_authority_uid):$(vx_compose_authority_gid):700:directory" ]] \
        || {
            vx_compose_registry_lock_release
            vx_compose_tenant_image_pull_lock_release
            vx_compose_lock_release
            return 1
        }
    image_key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    authority="$image_root/$image_key.json"
    backup="$(mktemp "$image_root/.pull-authority.XXXXXX")" || {
        vx_compose_registry_lock_release
        vx_compose_tenant_image_pull_lock_release
        vx_compose_lock_release
        return 1
    }
    if [[ -e "$authority" ]]; then
        vx_compose_control_file_is_secure "$authority" 600 \
            && [[ "$(stat -c '%h' "$authority" 2>/dev/null)" == 1 \
                && "$(stat -c '%s' "$authority" 2>/dev/null)" =~ ^[0-9]+$ \
                && "$(stat -c '%s' "$authority")" \
                    -le "$VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES" ]] \
            && cp -- "$authority" "$backup" \
            && vx_compose_control_file_protect "$backup" 600 \
            || {
                rm -f -- "$backup"
                vx_compose_registry_lock_release
                vx_compose_tenant_image_pull_lock_release
                vx_compose_lock_release
                return 1
            }
        had_authority=yes
    fi
    if ! vx_compose_image_pull_audit "$owner" "$project" "$reference" started; then
        rm -f -- "$backup"
        vx_compose_registry_lock_release
        vx_compose_tenant_image_pull_lock_release
        vx_compose_lock_release
        return 1
    fi
    if result="$(vx_compose_image_pull_immutable \
        "$owner" "$reference" "$provenance")"; then
        if vx_compose_image_pull_audit \
            "$owner" "$project" "$reference" succeeded \
            && vx_compose_image_registry_pull_activate \
                "$owner" "$reference"; then
            status=0
        elif [[ "$had_authority" == yes ]]; then
            if mv -f -- "$backup" "$authority" \
                && vx_compose_fsync_path "$authority" \
                && vx_compose_fsync_path "$image_root"; then
                :
            else
                rm -f -- "$authority"
                vx_compose_fsync_path "$image_root" || :
            fi
        else
            rm -f -- "$authority"
            vx_compose_fsync_path "$image_root" || :
        fi
    else
        if [[ "$had_authority" == yes ]]; then
            if mv -f -- "$backup" "$authority" \
                && vx_compose_fsync_path "$authority" \
                && vx_compose_fsync_path "$image_root"; then
                :
            else
                rm -f -- "$authority"
                vx_compose_fsync_path "$image_root" || :
            fi
        else
            rm -f -- "$authority"
            vx_compose_fsync_path "$image_root" || :
        fi
    fi
    (( status == 0 )) \
        || vx_compose_image_pull_audit \
            "$owner" "$project" "$reference" failed || :
    rm -f -- "$backup"
    vx_compose_registry_lock_release
    vx_compose_tenant_image_pull_lock_release
    vx_compose_lock_release
    (( status == 0 )) || return 1
    printf '%s\n' "$result"
}

vx_compose_image_archive_validate() {
    local owner="$1"
    local archive="$2"
    local checksum="$3"
    local staging_root owner_root resolved_parent checksum_name expected_name

    staging_root="${VX_COMPOSE_IMAGE_STAGING_ROOT:-/var/lib/vesta/docker-images}"
    owner_root="$staging_root/$owner"
    [[ -d "$owner_root" && ! -L "$owner_root" ]] \
        || {
            vx_compose_error 'image staging directory is unavailable'
            return 1
        }
    if [[ "$EUID" -eq 0 && "$(stat -c '%u' "$owner_root")" -ne 0 ]]; then
        vx_compose_error 'image staging directory is not root-controlled'
        return 1
    fi
    [[ -f "$archive" && ! -L "$archive" && -f "$checksum" && ! -L "$checksum" ]] \
        || {
            vx_compose_error 'image archive and checksum must be regular files'
            return 1
        }
    resolved_parent="$(realpath -e -- "$(dirname -- "$archive")")" || return 1
    [[ "$resolved_parent" == "$(realpath -e -- "$owner_root")"
        && "$(dirname -- "$checksum")" == "$(dirname -- "$archive")" ]] \
        || {
            vx_compose_error 'image archive is outside owner staging'
            return 1
        }
    [[ "$(basename -- "$archive")" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}[.]tar([.]gz)?$ ]] \
        || {
            vx_compose_error 'invalid image archive filename'
            return 1
        }
    [[ "$(stat -c '%s' "$archive")" -le "$VX_COMPOSE_IMAGE_MAX_BYTES" ]] \
        || {
            vx_compose_error 'image archive exceeds the size limit'
            return 1
        }
    [[ "$(stat -c '%s' "$checksum")" -le 256
        && "$(basename -- "$checksum")" == "$(basename -- "$archive").sha256" ]] \
        || {
            vx_compose_error 'invalid image checksum filename or size'
            return 1
        }
    checksum_name="$(awk 'NF == 2 { print $2 }' "$checksum")"
    expected_name="$(basename -- "$archive")"
    [[ "$(wc -l <"$checksum")" -eq 1
        && "$checksum_name" == "$expected_name"
        && "$(awk 'NF == 2 { print $1 }' "$checksum")" =~ ^[a-f0-9]{64}$ ]] \
        || {
            vx_compose_error 'invalid image checksum manifest'
            return 1
        }
    (
        cd "$(dirname -- "$archive")"
        sha256sum -c --status "$(basename -- "$checksum")"
    ) || {
        vx_compose_error 'image archive checksum mismatch'
        return 1
    }
}

vx_compose_image_load() {
    local owner="$1"
    local archive="$2"
    local checksum="$3"
    local validation_function="${4:-}"
    local load_output reference inspection metadata

    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_archive_validate "$owner" "$archive" "$checksum" || return 1
    vx_compose_registry_lock_acquire "$owner" || return 1
    load_output="$(vx_compose_owner_docker "$owner" image load --input "$archive")" \
        || {
            vx_compose_registry_lock_release
            vx_compose_error 'Docker image load failed'
            return 1
        }
    reference="$(awk -F ': ' '/^Loaded image: / { print $2 }' <<<"$load_output")"
    if [[ "$(wc -l <<<"$reference")" -ne 1 ]] \
        || ! vx_compose_image_reference_is_valid "$reference"; then
        vx_compose_error 'loaded image reference is ambiguous or invalid'
        vx_compose_registry_lock_release
        return 1
    fi
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || {
        vx_compose_registry_lock_release
        return 1
    }
    if [[ -n "$validation_function" ]]; then
        if ! declare -F "$validation_function" >/dev/null \
            || ! "$validation_function" "$inspection"; then
            vx_compose_registry_lock_release
            vx_compose_error 'loaded image failed workload identity approval'
            return 1
        fi
    fi
    metadata="$(vx_compose_image_record \
        "$owner" "$reference" "$inspection" local-load)" \
        || {
            vx_compose_registry_lock_release
            return 1
        }
    vx_compose_image_audit "$owner" load "$reference" || {
        vx_compose_registry_lock_release
        return 1
    }
    vx_compose_registry_lock_release
    rm -f -- "$archive" "$checksum"
    printf '%s\n' "$metadata"
}

vx_compose_image_identity_is_recorded() {
    local owner="$1"
    local reference="$2"
    local image_id="$3"
    local key metadata root expected_uid expected_gid

    key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    root="$(vx_compose_image_metadata_root "$owner")"
    metadata="$root/$key.json"
    expected_uid="$(vx_compose_authority_uid)" || return 1
    expected_gid="$(vx_compose_authority_gid)" || return 1
    [[ -d "$root" && ! -L "$root"
        && "$(stat -c '%u:%g:%a' "$root" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:700"
        && -f "$metadata" && ! -L "$metadata"
        && "$(stat -c '%u:%g:%a' "$metadata" 2>/dev/null)" \
            == "$expected_uid:$expected_gid:600" ]] || return 1
    jq -e --arg owner "$owner" --arg reference "$reference" \
        --arg image_id "$image_id" '
        .OWNER == $owner and .REFERENCE == $reference and .IMAGE_ID == $image_id
    ' \
        "$metadata" >/dev/null
}

vx_compose_image_registry_pull_is_recorded() {
    local owner="$1" reference="$2" image_id="$3" image_os="$4"
    local architecture="$5" key metadata

    vx_compose_image_reference_is_immutable "$reference" || return 1
    key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    metadata="$(vx_compose_image_metadata_root "$owner")/$key.json"
    vx_compose_image_identity_is_recorded \
        "$owner" "$reference" "$image_id" || return 1
    [[ "$(stat -c '%h' "$metadata" 2>/dev/null)" == 1 \
        && "$(stat -c '%s' "$metadata" 2>/dev/null)" =~ ^[0-9]+$ \
        && "$(stat -c '%s' "$metadata")" -le "$VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES" ]] \
        || return 1
    jq -e \
        --arg owner "$owner" --arg reference "$reference" \
        --arg image_id "$image_id" --arg image_os "$image_os" \
        --arg architecture "$architecture" \
        --argjson maximum "$VX_COMPOSE_IMAGE_MAX_BYTES" '
        keys == ["ARCHITECTURE","DELIVERY","IMAGE_ID","IMMUTABLE_REFERENCES",
                 "INSPECTED","LOCAL_SIZE_BYTES","MANIFEST_SIZE_BYTES",
                 "OCI_LABELS","OS","OWNER","PLATFORM_MANIFEST_DIGEST",
                 "PROVENANCE","REFERENCE","REPO_DIGESTS","REPO_TAGS"]
        and .DELIVERY == "registry-pull"
        and .OWNER == $owner
        and .REFERENCE == $reference
        and .IMAGE_ID == $image_id
        and .OS == $image_os
        and .ARCHITECTURE == $architecture
        and (.IMMUTABLE_REFERENCES | index($reference) != null)
        and (.PLATFORM_MANIFEST_DIGEST
            | type == "string" and test("^sha256:[a-f0-9]{64}$"))
        and (.MANIFEST_SIZE_BYTES | type == "number" and floor == .
            and . > 0 and . <= $maximum)
        and (.LOCAL_SIZE_BYTES | type == "number" and floor == .
            and . > 0 and . <= $maximum)
        and (.REPO_TAGS | type == "array" and length <= 128
            and all(.[]; type == "string" and length <= 255))
        and (.REPO_DIGESTS | type == "array" and length <= 128
            and all(.[]; type == "string" and length <= 255))
        and (.PROVENANCE | type == "object")
        and (.PROVENANCE | keys
            == ["ARCHITECTURE","CANDIDATE_SHA256","EXPECTED_CURRENT_REVISION",
                "IMAGE_ID","LOCAL_SIZE_BYTES","MANIFEST_SIZE_BYTES","OS",
                "OWNER","PLATFORM_MANIFEST_DIGEST","PREVIEW_ID","PROJECT",
                "RECORDED","REFERENCE","SOURCE_SHA256","STATE","TYPE"])
        and .PROVENANCE.TYPE == "registry-pull"
        and .PROVENANCE.OWNER == $owner
        and .PROVENANCE.REFERENCE == $reference
        and .PROVENANCE.IMAGE_ID == $image_id
        and .PROVENANCE.OS == $image_os
        and .PROVENANCE.ARCHITECTURE == $architecture
        and .PROVENANCE.STATE == "active"
        and .PROVENANCE.PLATFORM_MANIFEST_DIGEST == .PLATFORM_MANIFEST_DIGEST
        and .PROVENANCE.MANIFEST_SIZE_BYTES == .MANIFEST_SIZE_BYTES
        and .PROVENANCE.LOCAL_SIZE_BYTES == .LOCAL_SIZE_BYTES
        and (.PROVENANCE.PROJECT | type == "string"
            and test("^[a-z0-9][a-z0-9-]{0,62}$"))
        and (.PROVENANCE.PREVIEW_ID | type == "string"
            and test("^[a-f0-9]{32}$"))
        and (.PROVENANCE.SOURCE_SHA256 | type == "string"
            and test("^[a-f0-9]{64}$"))
        and (.PROVENANCE.CANDIDATE_SHA256 | type == "string"
            and test("^[a-f0-9]{64}$"))
        and (.PROVENANCE.EXPECTED_CURRENT_REVISION | type == "number"
            and floor == . and . >= 0)
        and (.PROVENANCE.RECORDED | type == "string"
            and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$metadata" >/dev/null
}

vx_compose_json_has_unique_object_keys() {
    local evidence="$1"

    [[ -f "$evidence" && ! -L "$evidence"
        && "$(stat -c '%s' "$evidence" 2>/dev/null)" =~ ^[0-9]+$
        && "$(stat -c '%s' "$evidence")" \
            -le "$VX_COMPOSE_IMAGE_EVIDENCE_MAX_BYTES" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$evidence" <<'PY' >/dev/null 2>&1
import json
import sys

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result

def reject_constant(_value):
    raise ValueError("non-standard JSON constant")

with open(sys.argv[1], "rb") as source:
    raw = source.read(1048577)
if len(raw) > 1048576:
    raise ValueError("JSON document exceeds limit")
json.loads(
    raw.decode("utf-8"),
    object_pairs_hook=unique_object,
    parse_constant=reject_constant,
)
PY
}

vx_compose_image_evidence_file_is_secure() {
    local path="$1" mode="${2:-640}"

    vx_compose_control_file_is_secure "$path" "$mode"
}

vx_compose_image_evidence_directory_is_secure() {
    local path="$1" mode="$2" expected

    expected="$(vx_compose_authority_uid):$(vx_compose_authority_gid):$mode:directory" \
        || return 1
    [[ ! -L "$path"
        && "$(stat -c '%u:%g:%a:%F' "$path" 2>/dev/null)" == "$expected" ]]
}

vx_compose_revision_manifest_binds_images() {
    local revision_root="$1" recorded actual count

    vx_compose_revision_manifest_verify "$revision_root" || return 1
    count="$(awk '$2 == "images.json" { count++ } END { print count + 0 }' \
        "$revision_root/manifest.sha256")" || return 1
    [[ "$count" == 1 ]] || return 1
    recorded="$(awk '$2 == "images.json" { print $1 }' \
        "$revision_root/manifest.sha256")" || return 1
    actual="$(sha256sum "$revision_root/images.json" | awk '{print $1}')" \
        || return 1
    [[ "$recorded" == "$actual" ]]
}

vx_compose_image_evidence_legacy_validate() {
    local evidence="$1"

    [[ -f "$evidence" && ! -L "$evidence" ]] || return 1
    vx_compose_json_has_unique_object_keys "$evidence" || return 1
    jq -e '
        def immutable_reference_valid:
            type == "string" and length <= 255
            and test("^(?:[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}/)?[A-Za-z0-9][A-Za-z0-9._-]{0,127}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,127})*@sha256:[a-f0-9]{64}$")
            and ((split("@")[0] | split("/")[0]) as $first
                | if ($first | contains(":")) then
                    ($first | split(":")[1] | tonumber) as $port
                    | $port >= 1 and $port <= 65535
                  else true end);
        type == "object" and length > 0
        and all(to_entries[];
            (.key | type == "string" and length > 0 and length <= 128
                    and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"))
            and (.value | type == "object")
            and (.value | keys
                == ["ARCHITECTURE","IMAGE_ID","OS","REFERENCE","REPO_DIGESTS"])
            and (.value.REFERENCE | type == "string" and length > 0
                    and length <= 255 and test("^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$")
                    and (contains("://") | not) and (contains("..") | not))
            and (.value.IMAGE_ID
                | type == "string" and test("^sha256:[a-f0-9]{64}$"))
            and (.value.REPO_DIGESTS | type == "array"
                and length == (unique | length)
                and all(.[]; immutable_reference_valid))
            and if (.value.REFERENCE | contains("@")) then
                .value.REFERENCE as $reference
                | ($reference | immutable_reference_valid)
                and ([.value.REPO_DIGESTS[]
                    | select(. == $reference)] | length) == 1
            else true end
            and (.value.OS == "linux")
            and (.value.ARCHITECTURE | IN("amd64","arm64"))
        )
    ' "$evidence" >/dev/null 2>&1
}

vx_compose_image_evidence_current_validate() {
    local evidence="$1"

    [[ -f "$evidence" && ! -L "$evidence" ]] || return 1
    vx_compose_json_has_unique_object_keys "$evidence" || return 1
    jq -e --argjson schema "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" '
        def sensitive:
            test(
                "(?i)(^|[^a-z0-9])(password|passwd|secret|token|credential|auth|authorization|authentication|auth[._ -]?(header|key|token|secret|credential)|bearer|private[._ -]?key|access[._ -]?(key|token|secret|credential)|client[._ -]?(key|token|secret|credential)|api[._ -]?key)([^a-z0-9]|$)"
            )
            or test("(?i)[a-z][a-z0-9+.-]*://[^/@[:space:]]+@");
        def bounded($maximum):
            type == "string" and length <= $maximum
            and (test("[[:cntrl:]]") | not) and (sensitive | not);
        def adapter($name):
            type == "object"
            and keys == ["ADAPTER","DETAIL","STATE"]
            and .ADAPTER == $name
            and (.STATE | IN("pass","fail","offline","unavailable","timeout","error"))
            and (.DETAIL | bounded(256));
        def trust:
            type == "object"
            and if .MODE == "disabled" then
                keys == ["DECISION","EXCEPTION","MODE","POLICY_VERSION",
                         "PROFILE","PROFILE_VERSION","SIGNATURE","VULNERABILITY"]
                and .DECISION == "disabled" and .EXCEPTION == false
                and (.PROFILE | type == "string" and length > 0 and length <= 64)
                and (.PROFILE_VERSION | type == "number" and floor == . and . > 0)
                and (.POLICY_VERSION | type == "number" and floor == . and . >= 0)
                and .SIGNATURE == {"STATE":"not-run"}
                and .VULNERABILITY == {"STATE":"not-run"}
            elif (.MODE | IN("audit","enforce")) then
                keys == ["CREATED","DECISION","EXCEPTION","MODE","POLICY_VERSION",
                         "PROFILE","PROFILE_VERSION","SCHEMA","SIGNATURE",
                         "VULNERABILITY","VULNERABILITY_THRESHOLD"]
                and .SCHEMA == 1
                and (.DECISION | IN("pass","fail","exception"))
                and (.EXCEPTION | type == "boolean")
                and ((.DECISION == "exception") == .EXCEPTION)
                and (.PROFILE | type == "string" and length > 0 and length <= 64)
                and (.PROFILE_VERSION | type == "number" and floor == . and . > 0)
                and (.POLICY_VERSION | type == "number" and floor == . and . >= 0)
                and (.VULNERABILITY_THRESHOLD | IN("low","medium","high","critical"))
                and (.CREATED | type == "string"
                    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
                and (.SIGNATURE | adapter("signature"))
                and (.VULNERABILITY | adapter("vulnerability"))
                and if .DECISION == "pass" then
                    .EXCEPTION == false
                    and .SIGNATURE.STATE == "pass"
                    and .VULNERABILITY.STATE == "pass"
                elif .DECISION == "exception" then
                    .EXCEPTION == true
                    and (.SIGNATURE.STATE != "pass"
                        or .VULNERABILITY.STATE != "pass")
                else
                    .MODE == "audit" and .EXCEPTION == false
                    and (.SIGNATURE.STATE != "pass"
                        or .VULNERABILITY.STATE != "pass")
                end
            else false end;
        def labels:
            type == "object"
            and keys == ["created","revision","source","vendor","version"]
            and all(.[]; bounded(512));
        def repository($reference):
            ($reference | split("@")[0] | split("/")) as $parts
            | ($parts[-1]
                | if contains(":") then split(":")[0] else . end) as $leaf
            | if ($parts | length) > 1
              then (($parts[0:-1] + [$leaf]) | join("/"))
              else $leaf end;
        def immutable_reference_valid:
            type == "string" and length <= 255
            and test("^(?:[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}/)?[A-Za-z0-9][A-Za-z0-9._-]{0,127}(?:/[A-Za-z0-9][A-Za-z0-9._-]{0,127})*@sha256:[a-f0-9]{64}$")
            and ((split("@")[0] | split("/")[0]) as $first
                | if ($first | contains(":")) then
                    ($first | split(":")[1] | tonumber) as $port
                    | $port >= 1 and $port <= 65535
                  else true end);
        type == "object" and length > 0
        and all(to_entries[];
            (.key | type == "string" and length > 0 and length <= 128
                    and test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"))
            and (.value | type == "object")
            and (.value | keys == ["ARCHITECTURE","IMAGE_ID",
                    "IMMUTABLE_REFERENCE","OCI_LABELS","OS","REFERENCE",
                    "REGISTRY_DIGEST","REPO_DIGESTS","SCHEMA","TRUST"])
            and .value.SCHEMA == $schema
            and (.value.REFERENCE | type == "string" and length > 0
                    and length <= 255 and test("^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,254}$")
                    and (contains("://") | not) and (contains("..") | not))
            and (.value.IMAGE_ID
                | type == "string" and test("^sha256:[a-f0-9]{64}$"))
            and (.value.REPO_DIGESTS | type == "array"
                and . == (unique | sort)
                and all(.[]; immutable_reference_valid))
            and (.value.IMMUTABLE_REFERENCE | type == "string"
                and (. == "" or immutable_reference_valid))
            and (.value.REGISTRY_DIGEST | type == "string"
                and (. == "" or test("^sha256:[a-f0-9]{64}$")))
            and if (.value.REFERENCE | contains("@")) then
                .value.REFERENCE as $reference
                | ($reference | immutable_reference_valid)
                and $reference == .value.IMMUTABLE_REFERENCE
                and .value.REGISTRY_DIGEST
                    == ($reference | split("@")[1])
            else true end
            and if .value.IMMUTABLE_REFERENCE == "" then
                .value.REGISTRY_DIGEST == ""
            else
                .value.IMMUTABLE_REFERENCE as $immutable
                | .value.REFERENCE as $reference
                | ($immutable | startswith(repository($reference) + "@"))
                and .value.REGISTRY_DIGEST == ($immutable | split("@")[1])
                and (.value.REPO_DIGESTS | index($immutable)) != null
            end
            and (.value.OCI_LABELS | labels)
            and (.value.TRUST | trust)
            and (.value.OS == "linux")
            and (.value.ARCHITECTURE | IN("amd64","arm64"))
        )
    ' "$evidence" >/dev/null 2>&1
}

vx_compose_image_evidence_kind() {
    local evidence="$1"

    if vx_compose_image_evidence_current_validate "$evidence"; then
        printf '%s\n' "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION"
    elif vx_compose_image_evidence_legacy_validate "$evidence"; then
        printf '%s\n' legacy-production-five-field
    else
        return 1
    fi
}

vx_compose_image_evidence_legacy_projection() {
    jq -cS 'with_entries(.value = {
        REFERENCE:.value.REFERENCE,
        IMAGE_ID:.value.IMAGE_ID,
        REPO_DIGESTS:(.value.REPO_DIGESTS | unique | sort),
        OS:.value.OS,
        ARCHITECTURE:.value.ARCHITECTURE
    })' "$1"
}

vx_compose_image_evidence_current_projection() {
    jq -cS 'with_entries(.value = {
        REFERENCE:.value.REFERENCE,
        IMMUTABLE_REFERENCE:.value.IMMUTABLE_REFERENCE,
        REGISTRY_DIGEST:.value.REGISTRY_DIGEST,
        IMAGE_ID:.value.IMAGE_ID,
        REPO_DIGESTS:.value.REPO_DIGESTS,
        OS:.value.OS,
        ARCHITECTURE:.value.ARCHITECTURE,
        TRUST:{
            MODE:.value.TRUST.MODE,
            DECISION:.value.TRUST.DECISION,
            PROFILE:.value.TRUST.PROFILE,
            PROFILE_VERSION:.value.TRUST.PROFILE_VERSION,
            POLICY_VERSION:.value.TRUST.POLICY_VERSION,
            VULNERABILITY_THRESHOLD:(.value.TRUST.VULNERABILITY_THRESHOLD // ""),
            SIGNATURE:{
                ADAPTER:(.value.TRUST.SIGNATURE.ADAPTER // ""),
                STATE:.value.TRUST.SIGNATURE.STATE
            },
            VULNERABILITY:{
                ADAPTER:(.value.TRUST.VULNERABILITY.ADAPTER // ""),
                STATE:.value.TRUST.VULNERABILITY.STATE
            },
            EXCEPTION:.value.TRUST.EXCEPTION
        }
    })' "$1"
}

vx_compose_image_evidence_matches_current() {
    local accepted="$1" current="$2" accepted_kind current_kind
    local accepted_projection current_projection

    accepted_kind="$(vx_compose_image_evidence_kind "$accepted")" || return 1
    current_kind="$(vx_compose_image_evidence_kind "$current")" || return 1
    if [[ "$accepted_kind" == legacy-production-five-field ]]; then
        accepted_projection="$(
            vx_compose_image_evidence_legacy_projection "$accepted"
        )" || return 1
        current_projection="$(
            vx_compose_image_evidence_legacy_projection "$current"
        )" || return 1
    else
        [[ "$current_kind" == "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" ]] \
            || return 1
        accepted_projection="$(
            vx_compose_image_evidence_current_projection "$accepted"
        )" || return 1
        current_projection="$(
            vx_compose_image_evidence_current_projection "$current"
        )" || return 1
    fi
    [[ "$accepted_projection" == "$current_projection" ]]
}

vx_compose_image_evidence_migration_root() {
    printf '%s/image-evidence-migration\n' "$1"
}

vx_compose_image_evidence_legacy_sources_json() {
    local root="$1" revision_root revision name sha manifest_sha kind
    local manifest_binds entries='[]'

    vx_compose_image_evidence_directory_is_secure "$root" 750 || return 1
    vx_compose_image_evidence_directory_is_secure "$root/revisions" 750 \
        || return 1
    for revision_root in "$root"/revisions/[0-9][0-9][0-9][0-9][0-9][0-9]; do
        [[ -d "$revision_root" ]] || continue
        vx_compose_image_evidence_directory_is_secure "$revision_root" 750 \
            || return 1
        [[ ! -e "$revision_root/images.json" ]] && continue
        vx_compose_image_evidence_file_is_secure \
            "$revision_root/images.json" 640 || return 1
        kind="$(vx_compose_image_evidence_kind \
            "$revision_root/images.json")" || return 1
        [[ "$kind" == legacy-production-five-field ]] || continue
        vx_compose_image_evidence_file_is_secure \
            "$revision_root/manifest.sha256" 640 || return 1
        vx_compose_revision_manifest_verify "$revision_root" || return 1
        name="$(basename -- "$revision_root")"
        revision="$((10#$name))"
        sha="$(sha256sum "$revision_root/images.json" | awk '{print $1}')" \
            || return 1
        manifest_sha="$(sha256sum \
            "$revision_root/manifest.sha256" | awk '{print $1}')" || return 1
        if vx_compose_revision_manifest_binds_images "$revision_root"; then
            manifest_binds=true
        else
            manifest_binds=false
        fi
        entries="$(jq -c \
            --argjson revision "$revision" --arg name "$name" \
            --arg sha "$sha" --arg manifest_sha "$manifest_sha" \
            --argjson manifest_binds "$manifest_binds" \
            --slurpfile evidence "$revision_root/images.json" \
            '. + [{REVISION:$revision,NAME:$name,IMAGES_SHA256:$sha,
                    MANIFEST_SHA256:$manifest_sha,
                    MANIFEST_BINDS_IMAGES:$manifest_binds,
                    EVIDENCE:$evidence[0]}]' <<<"$entries")" \
            || return 1
    done
    jq -ce 'select(length > 0) | sort_by(.REVISION)' <<<"$entries"
}

vx_compose_image_evidence_migration_authority_verify() {
    local owner="$1" project="$2" root="$3" revision="${4:-}"
    local candidate="${5:-}" authority evidence manifest expected stored
    local accepted_temp

    authority="$(vx_compose_image_evidence_migration_root "$root")"
    evidence="$authority/evidence.json"
    manifest="$authority/manifest.sha256"
    vx_compose_image_evidence_directory_is_secure "$root" 750 \
        && vx_compose_image_evidence_directory_is_secure "$authority" 500 \
        && vx_compose_image_evidence_file_is_secure "$evidence" 400 \
        && vx_compose_image_evidence_file_is_secure "$manifest" 400 \
        || return 1
    vx_compose_json_has_unique_object_keys "$evidence" || return 1
    [[ "$(wc -l <"$manifest")" == 1
        && "$(awk '{print $2}' "$manifest")" == evidence.json ]] || return 1
    (
        cd "$authority" || exit 1
        sha256sum --strict -c manifest.sha256 >/dev/null
    ) || return 1
    jq -e --arg owner "$owner" --arg project "$project" '
        type == "object"
        and keys == ["ENTRIES","OWNER","PROJECT","SCHEMA"]
        and .SCHEMA == 1 and .OWNER == $owner and .PROJECT == $project
        and (.ENTRIES | type == "array" and length > 0
            and . == (sort_by(.REVISION))
            and ([.[].REVISION] | length == (unique | length))
            and all(.[];
                type == "object"
                and keys == ["EVIDENCE","IMAGES_SHA256",
                    "MANIFEST_BINDS_IMAGES","MANIFEST_SHA256","NAME","REVISION"]
                and (.REVISION | type == "number" and floor == . and . > 0)
                and (.NAME | test("^[0-9]{6}$"))
                and (.REVISION == (.NAME | tonumber))
                and (.IMAGES_SHA256 | test("^[a-f0-9]{64}$"))
                and (.MANIFEST_SHA256 | test("^[a-f0-9]{64}$"))
                and (.MANIFEST_BINDS_IMAGES | type == "boolean")))
    ' "$evidence" >/dev/null || return 1
    expected="$(
        vx_compose_image_evidence_legacy_sources_json "$root"
    )" || return 1
    stored="$(jq -cS '.ENTRIES' "$evidence")" || return 1
    [[ "$stored" == "$(jq -cS . <<<"$expected")" ]] \
        || return 1
    if [[ -n "$revision" || -n "$candidate" ]]; then
        [[ "$revision" =~ ^[1-9][0-9]*$ && -n "$candidate" ]] || return 1
        accepted_temp="$(mktemp "$root/.legacy-evidence.XXXXXX")" || return 1
        if ! jq -S --argjson revision "$revision" '
                [.ENTRIES[] | select(.REVISION == $revision)]
                | if length == 1 then .[0].EVIDENCE else error("missing") end
            ' "$evidence" >"$accepted_temp" \
            || ! vx_compose_image_evidence_legacy_validate "$accepted_temp" \
            || ! vx_compose_image_evidence_matches_current \
                "$accepted_temp" "$candidate"; then
            rm -f -- "$accepted_temp"
            return 1
        fi
        rm -f -- "$accepted_temp"
    fi
}

vx_compose_image_evidence_migration_authority_create() {
    local owner="$1" project="$2" root="$3" current="$4" fresh="$5"
    local authority temp_root evidence manifest entries active_revision
    local active_name active_file current_sha active_sha

    [[ "$(vx_compose_meta_get "$root/project.conf" OWNER)" == "$owner"
        && "$(vx_compose_meta_get "$root/project.conf" PROJECT)" == "$project"
        ]] || return 1
    vx_compose_image_evidence_directory_is_secure "$root" 750 \
        && vx_compose_image_evidence_file_is_secure "$current" 640 \
        && vx_compose_image_evidence_legacy_validate "$current" \
        && vx_compose_image_evidence_matches_current "$current" "$fresh" \
        || return 1
    entries="$(vx_compose_image_evidence_legacy_sources_json "$root")" \
        || return 1
    active_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || return 1
    [[ "$active_revision" =~ ^[1-9][0-9]*$ ]] || return 1
    printf -v active_name '%06d' "$active_revision"
    active_file="$root/revisions/$active_name/images.json"
    vx_compose_image_evidence_file_is_secure "$active_file" 640 || return 1
    current_sha="$(sha256sum "$current" | awk '{print $1}')" || return 1
    active_sha="$(jq -r --argjson revision "$active_revision" '
        [.[] | select(.REVISION == $revision)]
        | if length == 1 then .[0].IMAGES_SHA256 else "" end
    ' <<<"$entries")" || return 1
    [[ "$active_sha" == "$current_sha" ]] \
        && cmp -s "$active_file" "$current" || return 1

    authority="$(vx_compose_image_evidence_migration_root "$root")"
    if [[ -e "$authority" ]]; then
        vx_compose_image_evidence_migration_authority_verify \
            "$owner" "$project" "$root" "$active_revision" "$fresh"
        return
    fi
    temp_root="$(mktemp -d "$root/.image-evidence-migration.XXXXXX")" \
        || return 1
    evidence="$temp_root/evidence.json"
    manifest="$temp_root/manifest.sha256"
    if ! jq -n -S --arg owner "$owner" --arg project "$project" \
        --argjson entries "$entries" '{
            SCHEMA:1,OWNER:$owner,PROJECT:$project,ENTRIES:$entries
        }' >"$evidence" \
        || ! (cd "$temp_root" && sha256sum evidence.json >manifest.sha256) \
        || ! vx_compose_control_file_protect "$evidence" 400 \
        || ! vx_compose_control_file_protect "$manifest" 400 \
        || ! vx_compose_control_file_protect "$temp_root" 500 \
        || ! vx_compose_fsync_path "$evidence" \
        || ! vx_compose_fsync_path "$manifest" \
        || ! vx_compose_fsync_path "$temp_root"; then
        chmod 0700 "$temp_root" 2>/dev/null || :
        rm -rf -- "$temp_root"
        return 1
    fi
    if ! mv -T -- "$temp_root" "$authority" \
        || ! vx_compose_fsync_path "$root" \
        || ! vx_compose_image_evidence_migration_authority_verify \
            "$owner" "$project" "$root" "$active_revision" "$fresh"; then
        [[ ! -d "$temp_root" ]] || {
            chmod 0700 "$temp_root" 2>/dev/null || :
            rm -rf -- "$temp_root"
        }
        return 1
    fi
}

vx_compose_image_evidence_migration_authority_ensure() {
    local owner="$1" project="$2" root="$3" current="$4" fresh="$5"
    local authority revision

    authority="$(vx_compose_image_evidence_migration_root "$root")"
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || return 1
    if [[ -e "$authority" ]]; then
        vx_compose_image_evidence_migration_authority_verify \
            "$owner" "$project" "$root" "$revision" "$fresh"
    else
        vx_compose_image_evidence_migration_authority_create \
            "$owner" "$project" "$root" "$current" "$fresh"
    fi
}

vx_compose_image_accepted_entry_matches() {
    local evidence="$1" service="$2" reference="$3" inspection="$4"
    local immutable_reference="$5" kind

    vx_compose_image_evidence_file_is_secure "$evidence" 640 || return 1
    kind="$(vx_compose_image_evidence_kind "$evidence")" || return 1
    if [[ "$kind" == legacy-production-five-field ]]; then
        jq -e --arg service "$service" --arg reference "$reference" \
            --argjson image "$inspection" '
            .[$service] as $accepted
            | ($accepted | type == "object")
            and $accepted.REFERENCE == $reference
            and $accepted.IMAGE_ID == $image.Id
            and $accepted.OS == $image.Os
            and $accepted.ARCHITECTURE == $image.Architecture
            and ($accepted.REPO_DIGESTS | unique | sort)
                == (($image.RepoDigests // []) | unique | sort)
        ' "$evidence" >/dev/null
    else
        jq -e --arg service "$service" --arg reference "$reference" \
            --arg immutable "$immutable_reference" --argjson image "$inspection" '
            .[$service] as $accepted
            | ($accepted | type == "object")
            and $accepted.REFERENCE == $reference
            and $accepted.IMMUTABLE_REFERENCE == $immutable
            and $accepted.IMAGE_ID == $image.Id
            and $accepted.OS == $image.Os
            and $accepted.ARCHITECTURE == $image.Architecture
            and ($accepted.REPO_DIGESTS | unique | sort)
                == (($image.RepoDigests // []) | unique | sort)
        ' "$evidence" >/dev/null
    fi
}

vx_compose_resolve_images_to_file() {
    local owner="$1"
    local canonical="$2"
    local profile="$3"
    local output_file="$4"
    local accepted_evidence="${5-}"
    local service reference inspection image_id image_os architecture digests
    local resolved='{}' temp_file immutable_reference digest labels trust
    local admitted profile_version

    [[ -f "$canonical" && ! -L "$canonical"
        && ! -e "$output_file" ]] || return 1
    vx_compose_registry_lock_acquire "$owner" || return 1
    while IFS=$'\t' read -r service reference; do
        inspection="$(vx_compose_image_inspect "$owner" "$reference")" || {
            vx_compose_registry_lock_release
            return 1
        }
        image_id="$(jq -r '.Id' <<<"$inspection")"
        image_os="$(jq -r '.Os' <<<"$inspection")"
        architecture="$(jq -r '.Architecture' <<<"$inspection")"
        digests="$(jq -r '(.RepoDigests // []) | length' <<<"$inspection")"
        immutable_reference="$(
            vx_compose_image_immutable_reference "$inspection" "$reference"
        )" || {
            vx_compose_registry_lock_release
            return 1
        }
        digest="${immutable_reference##*@}"
        labels="$(vx_compose_image_oci_labels "$inspection")" || {
            vx_compose_registry_lock_release
            return 1
        }
        admitted=no
        if vx_compose_image_reference_is_immutable "$reference" \
            && [[ "$immutable_reference" == "$reference" ]] \
            && vx_compose_image_registry_pull_is_recorded \
                "$owner" "$reference" "$image_id" \
                "$image_os" "$architecture"; then
            admitted=yes
        else
            profile_version="$(vx_compose_profile_version "$profile")" \
                || profile_version=
            if [[ -n "$profile_version" ]] \
                && vx_compose_image_approval_require \
                    "$owner" "$reference" "$image_id" "$image_os" \
                    "$architecture" "$profile" "$profile_version" \
                    >/dev/null 2>&1; then
                admitted=yes
            elif [[ -n "$accepted_evidence" ]] \
                && vx_compose_image_accepted_entry_matches \
                    "$accepted_evidence" "$service" "$reference" \
                    "$inspection" "$immutable_reference"; then
                admitted=yes
            fi
        fi
        if [[ "$admitted" != yes ]]; then
            vx_compose_registry_lock_release
            vx_compose_error \
                'Docker image lacks registry-pull provenance, local approval, or exact accepted-revision authority'
            return 1
        fi
        trust="$(vx_compose_verify_image_trust \
            "$profile" "$immutable_reference" "$image_id" "$labels")" || {
                vx_compose_registry_lock_release
                return 1
            }
        resolved="$(jq -c \
            --argjson schema "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" \
            --arg service "$service" \
            --arg reference "$reference" \
            --arg immutable_reference "$immutable_reference" \
            --arg digest "$digest" \
            --argjson image "$inspection" \
            --argjson labels "$labels" \
            --argjson trust "$trust" \
            '.[$service] = {
                SCHEMA: $schema,
                REFERENCE: $reference,
                IMMUTABLE_REFERENCE: $immutable_reference,
                REGISTRY_DIGEST: $digest,
                IMAGE_ID: $image.Id,
                REPO_DIGESTS: (($image.RepoDigests // []) | unique | sort),
                OCI_LABELS: $labels,
                TRUST: $trust,
                OS: $image.Os,
                ARCHITECTURE: $image.Architecture
            }' <<<"$resolved")" || {
                vx_compose_registry_lock_release
                return 1
            }
    done < <(jq -r '.services | to_entries[] | [.key, .value.image] | @tsv' \
        "$canonical")
    vx_compose_registry_lock_release
    temp_file="$(mktemp "$(dirname -- "$output_file")/.images.XXXXXX")" \
        || return 1
    jq -S . <<<"$resolved" >"$temp_file" || {
        rm -f -- "$temp_file"
        return 1
    }
    if ! vx_compose_control_file_protect "$temp_file" 640 \
        || ! vx_compose_image_evidence_current_validate "$temp_file" \
        || ! vx_compose_fsync_path "$temp_file"; then
        rm -f -- "$temp_file"
        vx_compose_error 'resolved Docker image evidence is malformed'
        return 1
    fi
    if ! mv -- "$temp_file" "$output_file" \
        || ! vx_compose_fsync_path "$output_file" \
        || ! vx_compose_fsync_path "$(dirname -- "$output_file")"; then
        rm -f -- "$temp_file" "$output_file"
        vx_compose_fsync_path "$(dirname -- "$output_file")" || :
        return 1
    fi
}

vx_compose_image_evidence_restore_previous() {
    local root="$1" backup="$2" had_current="$3"

    if [[ "$had_current" == yes ]]; then
        vx_compose_control_file_protect "$backup" 640 \
            && vx_compose_fsync_path "$backup" \
            && mv -f -- "$backup" "$root/images.json" \
            && vx_compose_fsync_path "$root/images.json" \
            && vx_compose_fsync_path "$root"
    else
        rm -f -- "$root/images.json" \
            && vx_compose_fsync_path "$root"
    fi
}

vx_compose_project_resolve_images() {
    local owner="$1"
    local project="$2"
    local root canonical resolution_canonical metadata revision revision_name temp_file profile
    local revision_file revision_kind current_kind upgrade=no service_count
    local install_required=yes revision_sha='' current_sha='' expected_sha
    local backup_file='' had_current=no failure_detail='' accepted_evidence=''

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    vx_compose_image_evidence_directory_is_secure "$root" 750 \
        && vx_compose_image_evidence_directory_is_secure \
            "$root/revisions" 750 || {
        vx_compose_error 'Compose image evidence control directory is insecure'
        return 1
    }
    canonical="$root/runtime/canonical.json"
    metadata="$root/project.conf"
    profile="$(vx_compose_meta_get "$metadata" PROFILE)" || return 1
    revision="$(vx_compose_meta_get "$metadata" REVISION)" || return 1
    printf -v revision_name '%06d' "$revision"
    revision_file="$root/revisions/$revision_name/images.json"
    resolution_canonical="$canonical"
    if [[ -e "$revision_file" ]]; then
        vx_compose_image_evidence_file_is_secure "$revision_file" 640 \
            || return 1
        revision_kind="$(vx_compose_image_evidence_kind "$revision_file")" \
            || return 1
        accepted_evidence="$revision_file"
    fi
    if [[ -f "$root/workload.json" && ! -L "$root/workload.json"
        && -e "$revision_file" ]]; then
        if [[ "$revision_kind" == "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" ]]; then
            resolution_canonical="$(mktemp "$root/.canonical.lookup.XXXXXX")" \
                || return 1
            if ! jq -eS --slurpfile accepted "$revision_file" '
                select(($accepted[0] | keys) == (.services | keys))
                | select(all(.services | to_entries[]; . as $service
                    | .value.image == $accepted[0][$service.key].IMAGE_ID))
                | .services |= with_entries(
                    .value.image = $accepted[0][.key].REFERENCE)
            ' "$canonical" >"$resolution_canonical"; then
                rm -f -- "$resolution_canonical"
                vx_compose_error 'accepted workload image authority does not match canonical services'
                return 1
            fi
            chmod 0600 "$resolution_canonical"
        fi
    fi
    temp_file="$(mktemp "$root/.images.pending.XXXXXX")"
    rm -f -- "$temp_file"
    if ! vx_compose_resolve_images_to_file \
        "$owner" "$resolution_canonical" "$profile" "$temp_file" \
        "$accepted_evidence"; then
        [[ "$resolution_canonical" == "$canonical" ]] \
            || rm -f -- "$resolution_canonical"
        return 1
    fi
    [[ "$resolution_canonical" == "$canonical" ]] \
        || rm -f -- "$resolution_canonical"

    if [[ -e "$revision_file" ]]; then
        vx_compose_image_evidence_directory_is_secure \
            "$root/revisions/$revision_name" 750 \
            && vx_compose_image_evidence_file_is_secure \
                "$revision_file" 640 || {
            rm -f -- "$temp_file"
            vx_compose_error 'accepted Docker image evidence is unavailable'
            return 1
        }
        revision_kind="$(vx_compose_image_evidence_kind "$revision_file")" \
            || {
                rm -f -- "$temp_file"
                vx_compose_error 'accepted Docker image evidence schema is malformed or unsupported'
                return 1
            }
        revision_sha="$(sha256sum "$revision_file" | awk '{print $1}')" \
            || return 1
        vx_compose_image_evidence_file_is_secure \
            "$root/revisions/$revision_name/manifest.sha256" 640 || {
                rm -f -- "$temp_file"
                vx_compose_error 'accepted Docker image manifest is insecure'
                return 1
            }
        if ! vx_compose_revision_manifest_binds_images \
            "$root/revisions/$revision_name"; then
            if [[ "$revision_kind" != legacy-production-five-field
                || ! -f "$root/images.json" ]] \
                || ! vx_compose_image_evidence_migration_authority_ensure \
                    "$owner" "$project" "$root" \
                    "$root/images.json" "$temp_file"; then
                rm -f -- "$temp_file"
                vx_compose_error 'immutable Docker image migration authority is unavailable'
                return 1
            fi
        fi
        if ! vx_compose_image_evidence_matches_current \
            "$revision_file" "$temp_file"; then
            rm -f -- "$temp_file"
            vx_compose_error 'Docker image identity drifted from the accepted revision'
            return 1
        fi
    else
        revision_kind=
        if [[ -e "$(vx_compose_image_evidence_migration_root "$root")" ]]; then
            rm -f -- "$temp_file"
            vx_compose_error 'active revision Docker image evidence is required by migration authority'
            return 1
        fi
    fi
    if [[ -e "$root/images.json" ]]; then
        had_current=yes
        vx_compose_image_evidence_file_is_secure "$root/images.json" 640 || {
            rm -f -- "$temp_file"
            vx_compose_error 'current Docker image evidence is unavailable'
            return 1
        }
        current_kind="$(vx_compose_image_evidence_kind "$root/images.json")" \
            || {
                rm -f -- "$temp_file"
                vx_compose_error 'current Docker image evidence schema is malformed or unsupported'
                return 1
            }
        current_sha="$(sha256sum "$root/images.json" | awk '{print $1}')" \
            || return 1
        if ! vx_compose_image_evidence_matches_current \
            "$root/images.json" "$temp_file"; then
            rm -f -- "$temp_file"
            vx_compose_error 'current Docker image identity drifted from accepted authority'
            return 1
        fi
        if [[ "$current_kind" == legacy-production-five-field ]]; then
            upgrade=yes
        else
            install_required=no
        fi
    elif [[ "$revision_kind" == legacy-production-five-field ]]; then
        upgrade=yes
    fi
    if [[ "$upgrade" == yes && -z "$revision_kind" ]]; then
        rm -f -- "$temp_file"
        vx_compose_error 'active revision Docker image evidence is required for migration'
        return 1
    fi
    if [[ "$revision_kind" == legacy-production-five-field
        && -f "$root/images.json" ]] \
        && ! vx_compose_image_evidence_matches_current \
            "$revision_file" "$root/images.json"; then
        rm -f -- "$temp_file"
        vx_compose_error 'current Docker image identity drifted from accepted revision'
        return 1
    fi
    if [[ "$had_current" == yes ]]; then
        backup_file="$(mktemp "$root/.images.previous.XXXXXX")" || {
            rm -f -- "$temp_file"
            return 1
        }
        if ! install -m 0640 "$root/images.json" "$backup_file" \
            || ! vx_compose_control_file_protect "$backup_file" 640 \
            || ! vx_compose_fsync_path "$backup_file"; then
            rm -f -- "$temp_file" "$backup_file"
            return 1
        fi
    fi
    if [[ -n "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_REPLACE_CURRENT_WITH:-}" ]]; then
        install -m 0640 \
            "$VX_COMPOSE_TEST_IMAGE_EVIDENCE_REPLACE_CURRENT_WITH" \
            "$root/images.json" || :
    fi
    if [[ "$revision_kind" == legacy-production-five-field ]] \
        && ! vx_compose_revision_manifest_binds_images \
            "$root/revisions/$revision_name" \
        && ! vx_compose_image_evidence_migration_authority_verify \
            "$owner" "$project" "$root" "$revision" "$temp_file"; then
        rm -f -- "$temp_file" "$backup_file"
        vx_compose_error 'Docker image migration authority changed during resolution'
        return 1
    fi
    if [[ -n "$revision_sha" ]] \
        && { ! vx_compose_image_evidence_file_is_secure "$revision_file" 640 \
            || [[ "$(sha256sum "$revision_file" | awk '{print $1}')" \
                != "$revision_sha" ]]; }; then
        rm -f -- "$temp_file" "$backup_file"
        vx_compose_error 'accepted Docker image evidence changed during resolution'
        return 1
    fi
    if [[ "$had_current" == yes ]] \
        && { ! vx_compose_image_evidence_file_is_secure \
                "$root/images.json" 640 \
            || [[ "$(sha256sum "$root/images.json" | awk '{print $1}')" \
                != "$current_sha" ]]; }; then
        rm -f -- "$temp_file"
        vx_compose_image_evidence_restore_previous \
            "$root" "$backup_file" "$had_current" || return 1
        vx_compose_error 'current Docker image evidence changed during resolution'
        return 1
    fi
    if [[ "$install_required" == yes
        && "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_INSTALL_FAIL:-no}" == yes ]]; then
        rm -f -- "$temp_file" "$backup_file"
        vx_compose_error 'Docker image evidence install was interrupted'
        return 1
    fi
    if [[ "$install_required" == yes ]]; then
        expected_sha="$(sha256sum "$temp_file" | awk '{print $1}')" || {
            rm -f -- "$temp_file"
            return 1
        }
        if [[ "$had_current" == yes ]]; then
            [[ -f "$backup_file" ]] || return 1
        fi
        if ! vx_compose_control_file_protect "$temp_file" 640 \
            || ! vx_compose_fsync_path "$temp_file" \
            || ! mv -f -- "$temp_file" "$root/images.json"; then
            rm -f -- "$temp_file" "$backup_file"
            return 1
        fi
        if [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_AFTER_RENAME:-no}" \
                == yes ]]; then
            failure_detail=after-rename
        elif ! vx_compose_image_evidence_file_is_secure \
                "$root/images.json" 640 \
            || [[ "$(sha256sum "$root/images.json" | awk '{print $1}')" \
                != "$expected_sha" ]] \
            || ! vx_compose_image_evidence_current_validate \
                "$root/images.json"; then
            failure_detail=post-install-validation
        elif [[ "$revision_kind" == legacy-production-five-field ]] \
            && ! vx_compose_revision_manifest_binds_images \
                "$root/revisions/$revision_name" \
            && ! vx_compose_image_evidence_migration_authority_verify \
                "$owner" "$project" "$root" "$revision" \
                "$root/images.json"; then
            failure_detail=post-install-authority
        elif ! vx_compose_fsync_path "$root/images.json" \
            || [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_AFTER_FSYNC:-no}" \
                == yes ]]; then
            failure_detail=durability
        elif ! vx_compose_fsync_path "$root" \
            || [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_FINAL_DIR_FSYNC:-no}" \
                == yes ]]; then
            failure_detail=final-directory-fsync
        fi
        if [[ -n "$failure_detail" ]]; then
            vx_compose_image_evidence_restore_previous \
                "$root" "$backup_file" "$had_current" || return 1
            vx_compose_audit "$root" resolve-images failed \
                "stage=$failure_detail" >/dev/null 2>&1 || :
            vx_compose_error 'Docker image evidence installation failed safely'
            return 1
        fi
    else
        rm -f -- "$temp_file"
    fi
    if [[ "$upgrade" == yes ]]; then
        if [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_SERVICE_COUNT:-no}" \
                == yes ]] \
            || ! service_count="$(jq 'length' "$root/images.json")"; then
            failure_detail='service-count'
        fi
    fi
    if [[ -z "$failure_detail" ]] \
        && { [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_RESOLVE_AUDIT:-no}" \
                == yes ]] \
            || ! vx_compose_audit "$root" resolve-images succeeded \
                "$([[ "$upgrade" == yes ]] \
                    && printf 'schema_transition=legacy-production-five-field-to-%s services=%s' \
                        "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" \
                        "$service_count")"; }; then
        failure_detail=resolve-audit
    fi
    if [[ -n "$failure_detail" && "$install_required" == yes ]]; then
        vx_compose_image_evidence_restore_previous \
            "$root" "$backup_file" "$had_current" || return 1
        vx_compose_audit "$root" resolve-images failed \
            "stage=$failure_detail" >/dev/null 2>&1 || :
        vx_compose_error 'Docker image evidence audit failed safely'
        return 1
    elif [[ -n "$failure_detail" ]]; then
        rm -f -- "$backup_file" || :
        return 1
    fi
    if [[ -n "$backup_file" ]]; then
        if [[ "${VX_COMPOSE_TEST_IMAGE_EVIDENCE_FAIL_BACKUP_CLEANUP:-no}" \
                == yes ]] \
            || ! rm -f -- "$backup_file" \
            || ! vx_compose_fsync_path "$root"; then
            vx_compose_audit "$root" image-evidence-cleanup failed \
                'rollback_snapshot_cleanup=pending' >/dev/null 2>&1 || :
        fi
    fi
    return 0
}

vx_compose_image_update_candidate() {
    local owner="$1" reference="$2"
    local key metadata repository current_registry_digest current_reference
    local current_digest candidate_digest

    vx_compose_require_owner "$owner" || return 1
    vx_compose_image_reference_is_valid "$reference" || {
        vx_compose_error 'invalid Docker image reference'
        return 1
    }
    key="$(printf '%s' "$reference" | sha256sum | awk '{print $1}')"
    metadata="$(vx_compose_image_metadata_root "$owner")/$key.json"
    [[ -f "$metadata" && ! -L "$metadata" ]] || {
        vx_compose_error 'recorded Docker image identity is unavailable'
        return 1
    }
    repository="$(vx_compose_image_repository_for_reference "$reference")" \
        || return 1
    current_registry_digest="$(jq -r --arg repository "$repository" '
        [.IMMUTABLE_REFERENCES[]?
         | select(startswith($repository + "@"))
         | split("@")[1]]
        | unique | sort | first // ""
    ' "$metadata")"
    vx_compose_trust_digest_is_valid "$current_registry_digest" || {
        vx_compose_error 'recorded Docker image registry digest is unavailable'
        return 1
    }
    current_reference="$repository@$current_registry_digest"
    current_digest="$(vx_compose_image_manifest_platform_digest \
        "$owner" "$current_reference")" || {
            vx_compose_error 'recorded Docker image manifest lookup failed'
            return 1
        }
    candidate_digest="$(vx_compose_image_manifest_platform_digest \
        "$owner" "$reference")" || {
            vx_compose_error 'Docker image update lookup failed'
            return 1
        }
    vx_compose_trust_digest_is_valid "$current_digest" || {
        vx_compose_error 'recorded Docker image platform digest is unavailable'
        return 1
    }
    vx_compose_trust_digest_is_valid "$candidate_digest" || {
        vx_compose_error 'Docker image update lookup returned no immutable digest'
        return 1
    }
    jq -n -S --arg reference "$reference" \
        --arg current_registry_digest "$current_registry_digest" \
        --arg current "$current_digest" --arg candidate "$candidate_digest" '{
        REFERENCE:$reference,
        CURRENT_REGISTRY_DIGEST:$current_registry_digest,
        CURRENT_DIGEST:$current,
        CANDIDATE_DIGEST:$candidate,
        UPDATE_AVAILABLE:($current != $candidate),
        MUTATED:false,
        NEXT_ACTION:"stage immutable preview/apply"
    }'
}
