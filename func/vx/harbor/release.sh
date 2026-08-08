#!/usr/bin/env bash

vx_harbor_release_manifest() {
    printf '%s/install/harbor/release-manifest.json\n' "$VESTA"
}

vx_harbor_release_manifest_validate() {
    local manifest="$1" machine policy
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    machine="${VX_HARBOR_ARCHITECTURE:-$(/usr/bin/uname -m)}"
    [[ "$machine" == x86_64 || "$machine" == amd64 ]] || return 1
    /usr/bin/jq -e '
      type == "object" and keys == ["architecture","archive","cosign","images","schema","version"]
      and .schema == 1 and .version == "v2.15.0" and .architecture == "amd64"
      and (.archive | keys == ["bundle_sha256","bundle_url","sha256","url"])
      and (.archive.url == "https://github.com/goharbor/harbor/releases/download/v2.15.0/harbor-online-installer-v2.15.0.tgz")
      and (.archive.bundle_url == (.archive.url + ".sigstore.json"))
      and ([.archive.sha256,.archive.bundle_sha256] | all(test("^[0-9a-f]{64}$")))
      and (.cosign | keys == ["identity","issuer"])
      and .cosign.identity == "https://github.com/goharbor/harbor/.github/workflows/publish_release.yml@refs/tags/v2.15.0"
      and .cosign.issuer == "https://token.actions.githubusercontent.com"
      and (.images | length == 10)
      and (.images | to_entries | all(
        (.key | test("^goharbor/[a-z0-9-]+$")) and
        (.value | test("^sha256:[0-9a-f]{64}$"))))
    ' "$manifest" >/dev/null 2>&1 || return 1
    policy="$VESTA/install/harbor/cosign-policy.json"
    [[ -f "$policy" && ! -L "$policy" ]] || return 1
    /usr/bin/jq -e --slurpfile manifest "$manifest" '
      type == "object"
      and keys == ["certificateIdentity","certificateOidcIssuer","offlineBundleRequired","schema"]
      and .schema == 1 and .offlineBundleRequired == true
      and .certificateIdentity == $manifest[0].cosign.identity
      and .certificateOidcIssuer == $manifest[0].cosign.issuer
    ' "$policy" >/dev/null 2>&1
}

_vx_harbor_release_download() {
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' \
        --tlsv1.2 --connect-timeout 10 --max-time 300 --output "$2" -- "$1"
}

_vx_harbor_release_sha256() {
    local expected="$1" path="$2"
    [[ "$(/usr/bin/sha256sum -- "$path" | /usr/bin/awk '{print $1}')" == "$expected" ]]
}

_vx_harbor_release_archive_validate() {
    /usr/bin/python3 - "$1" <<'PY'
import pathlib, sys, tarfile
p = pathlib.Path(sys.argv[1])
with tarfile.open(p, "r:gz") as archive:
    members = archive.getmembers()
    if not members or len(members) > 128:
        raise SystemExit(1)
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts or not path.parts
                or path.parts[0] != "harbor" or member.issym()
                or member.islnk() or member.isdev()):
            raise SystemExit(1)
PY
}

vx_harbor_release_verify_archive() {
    local manifest="$1" archive="$2" bundle="$3" identity issuer
    vx_harbor_release_manifest_validate "$manifest" || return 1
    _vx_harbor_release_sha256 "$(/usr/bin/jq -r '.archive.sha256' "$manifest")" "$archive" || return 1
    _vx_harbor_release_sha256 "$(/usr/bin/jq -r '.archive.bundle_sha256' "$manifest")" "$bundle" || return 1
    identity="$(/usr/bin/jq -r '.cosign.identity' "$manifest")" || return 1
    issuer="$(/usr/bin/jq -r '.cosign.issuer' "$manifest")" || return 1
    "${VX_HARBOR_COSIGN:-/usr/bin/cosign}" verify-blob --offline \
        --bundle "$bundle" --certificate-identity "$identity" \
        --certificate-oidc-issuer "$issuer" "$archive" >/dev/null 2>&1 || return 1
    _vx_harbor_release_archive_validate "$archive"
}

vx_harbor_release_images_validate() {
    local manifest="$1" compose="$2"
    vx_harbor_release_manifest_validate "$manifest" || return 1
    [[ -f "$compose" && ! -L "$compose" ]] || return 1
    /usr/bin/python3 - "$manifest" "$compose" <<'PY'
import json, re, sys
manifest=json.load(open(sys.argv[1], encoding="utf-8"))
text=open(sys.argv[2], encoding="utf-8").read()
images=re.findall(r"^[ ]*image:[ ]*([^\t\r\n #]+)[ ]*$", text, re.M)
expected={name+"@"+digest for name,digest in manifest["images"].items()}
if set(images) != expected or len(images) != len(expected):
    raise SystemExit(1)
if re.search(r"(^|\s)(network_mode:[ ]*host|privileged:[ ]*true)(\s|$)", text, re.M|re.I):
    raise SystemExit(1)
if re.search(r"(^|[ /])(?:var/run/docker\.sock|run/docker\.sock)(?:[: /]|$)", text):
    raise SystemExit(1)
if re.search(r"^[ ]*ports:[ ]*$|^[ ]*-[ ]*[\"']?[0-9.]*:[0-9]+", text, re.M):
    raise SystemExit(1)
PY
}

vx_harbor_release_stage() {
    local destination="$1" manifest archive bundle evidence source
    manifest="$(vx_harbor_release_manifest)" || return 1
    vx_harbor_release_manifest_validate "$manifest" || return 1
    [[ -d "$destination" && ! -L "$destination" ]] || return 1
    archive="$destination/release.tgz"; bundle="$destination/release.sigstore.json"
    _vx_harbor_release_download "$(/usr/bin/jq -r '.archive.url' "$manifest")" "$archive" || return 1
    _vx_harbor_release_download "$(/usr/bin/jq -r '.archive.bundle_url' "$manifest")" "$bundle" || return 1
    vx_harbor_release_verify_archive "$manifest" "$archive" "$bundle" || return 1
    /usr/bin/mkdir -p "$destination/extracted" || return 1
    /usr/bin/tar -xzf "$archive" -C "$destination/extracted" --no-same-owner --no-same-permissions || return 1
    evidence="$destination/evidence.json"; source="$destination/.evidence-source.json"
    /usr/bin/jq -n --arg version v2.15.0 \
      --arg manifest_sha256 "$(/usr/bin/sha256sum "$manifest" | /usr/bin/awk '{print $1}')" \
      --arg archive_sha256 "$(/usr/bin/jq -r '.archive.sha256' "$manifest")" \
      '{SCHEMA:1,VERSION:$version,MANIFEST_SHA256:$manifest_sha256,ARCHIVE_SHA256:$archive_sha256,SIGNATURE_VERIFIED:true}' >"$source" || return 1
    /usr/bin/mv -fT "$source" "$evidence" && /usr/bin/chmod 0600 "$evidence"
}
