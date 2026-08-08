#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root
install_harbor_helpers
mkdir -p "$VESTA/install/harbor"
cp "$HARBOR_REPO_ROOT/install/harbor/release-manifest.json" "$HARBOR_REPO_ROOT/install/harbor/cosign-policy.json" \
  "$HARBOR_REPO_ROOT/install/harbor/release-provenance.json" "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/release.sh"

work="$HARBOR_TEST_ROOT/release"; mkdir -p "$work/payload/harbor" "$work/inner"
python3 - "$VESTA/install/harbor/release-provenance.json" "$work/inner/manifest.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); rows=[]
for name in p['runtime_images']:
    rows.append({'RepoTags':[name+':v2.15.0'],'Config':'blobs/sha256/fixture','Layers':[]})
rows += [
 {'RepoTags':['goharbor/prepare:v2.15.0'],'Config':'blobs/sha256/029f75920a4b0b4a4f32f3ee5b30a99ae91d3bf30365c8f0bab98e74e6185abc','Layers':[]},
 {'RepoTags':['goharbor/trivy-adapter-photon:v2.15.0'],'Config':'blobs/sha256/fixture','Layers':[]}]
json.dump(rows,open(sys.argv[2],'w'))
PY
tar -czf "$work/payload/harbor/harbor.v2.15.0.tar.gz" -C "$work/inner" manifest.json
for file in prepare harbor.yml.tmpl install.sh common.sh LICENSE; do printf 'fixture\n' >"$work/payload/harbor/$file"; done
tar -czf "$work/release.tgz" -C "$work/payload" harbor
printf '{"fixture":"offline bundle"}\n' >"$work/release.sigstore.json"
manifest="$VESTA/install/harbor/release-manifest.json"
fake_cosign="$work/cosign"
printf '#!/bin/sh\ncase "$*" in *"--offline"*"--bundle"*"--certificate-identity"*"--certificate-oidc-issuer"*) exit 0;; *) exit 1;; esac\n' >"$fake_cosign"
chmod +x "$fake_cosign"; VX_HARBOR_COSIGN="$fake_cosign"
vx_harbor_release_offline_payload_validate "$work/release.tgz" || fail 'canonical offline payload rejected'
jq -e --slurpfile p "$VESTA/install/harbor/release-provenance.json" '.archive.sha256==$p[0].archive.sha256 and .archive.bundle_sha256==$p[0].bundle.sha256 and .images==$p[0].runtime_images' "$manifest" >/dev/null || fail 'committed pins differ from captured official provenance'

for mutation in version arch url identity tag digest; do
    case "$mutation" in
      version) filter='.version="v2.15.1"' ;; arch) filter='.architecture="arm64"' ;;
      url) filter='.archive.url="http://example.invalid/release.tgz"' ;;
      identity) filter='.cosign.identity="attacker"' ;;
      tag) filter='.images["goharbor/harbor-core"]="v2.15.0"' ;;
      digest) filter='.images["goharbor/harbor-core"]="sha256:deadbeef"' ;;
    esac
    jq "$filter" "$manifest" >"$work/bad.json"
    ! vx_harbor_release_manifest_validate "$work/bad.json" || fail "$mutation manifest accepted"
done
if ( export VX_HARBOR_ARCHITECTURE=arm64; vx_harbor_release_manifest_validate "$manifest" ); then fail 'unsupported host architecture accepted'; fi
cp "$work/release.tgz" "$work/tampered.tgz"; printf x >>"$work/tampered.tgz"
! _vx_harbor_release_sha256 "$(jq -r .archive.sha256 "$manifest")" "$work/tampered.tgz" || fail 'tampered archive accepted'
ln -s /etc/passwd "$work/payload/harbor/link"
tar -czf "$work/link.tgz" -C "$work/payload" harbor
! _vx_harbor_release_archive_validate "$work/link.tgz" || fail 'archive link accepted'

compose="$work/compose.yaml"; {
  printf 'services:\n'
  jq -r '.images|to_entries[]|"  x\(.key|gsub("[^a-z0-9]";"")):\n    image: \(.key)@\(.value)"' "$manifest"
} >"$compose"
vx_harbor_release_images_validate "$manifest" "$compose" || fail 'pinned compose rejected'
sed -i 's/@sha256:/\:v2.15.0 # @sha256:/' "$compose"
! vx_harbor_release_images_validate "$manifest" "$compose" || fail 'tampered generated compose accepted'
printf 'PASS: Harbor release verification\n'
