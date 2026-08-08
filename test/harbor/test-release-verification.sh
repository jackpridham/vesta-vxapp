#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
trap cleanup_vesta_root EXIT
new_vesta_root
install_harbor_helpers
mkdir -p "$VESTA/install/harbor"
cp "$HARBOR_REPO_ROOT/install/harbor/release-manifest.json" "$HARBOR_REPO_ROOT/install/harbor/cosign-policy.json" "$VESTA/install/harbor/"
source "$VESTA/func/vx/harbor/release.sh"

work="$HARBOR_TEST_ROOT/release"; mkdir -p "$work/payload/harbor"
printf 'fixture\n' >"$work/payload/harbor/install.sh"
tar -czf "$work/release.tgz" -C "$work/payload" harbor
printf '{"fixture":"offline bundle"}\n' >"$work/release.sigstore.json"
manifest="$work/manifest.json"
jq --arg archive "$(sha256sum "$work/release.tgz" | awk '{print $1}')" \
   --arg bundle "$(sha256sum "$work/release.sigstore.json" | awk '{print $1}')" \
   '.archive.sha256=$archive | .archive.bundle_sha256=$bundle' \
   "$VESTA/install/harbor/release-manifest.json" >"$manifest"
fake_cosign="$work/cosign"
printf '#!/bin/sh\ncase "$*" in *"--offline"*"--bundle"*"--certificate-identity"*"--certificate-oidc-issuer"*) exit 0;; *) exit 1;; esac\n' >"$fake_cosign"
chmod +x "$fake_cosign"; VX_HARBOR_COSIGN="$fake_cosign"
vx_harbor_release_verify_archive "$manifest" "$work/release.tgz" "$work/release.sigstore.json" || fail 'valid pinned release rejected'

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
printf x >>"$work/release.tgz"
! vx_harbor_release_verify_archive "$manifest" "$work/release.tgz" "$work/release.sigstore.json" || fail 'tampered archive accepted'
tar -czf "$work/release.tgz" -C "$work/payload" harbor
jq --arg archive "$(sha256sum "$work/release.tgz" | awk '{print $1}')" '.archive.sha256=$archive' "$manifest" >"$work/link-manifest.json"
ln -s /etc/passwd "$work/payload/harbor/link"
tar -czf "$work/link.tgz" -C "$work/payload" harbor
jq --arg archive "$(sha256sum "$work/link.tgz" | awk '{print $1}')" '.archive.sha256=$archive' "$manifest" >"$work/link-manifest.json"
! vx_harbor_release_verify_archive "$work/link-manifest.json" "$work/link.tgz" "$work/release.sigstore.json" || fail 'archive link accepted'

compose="$work/compose.yaml"; {
  printf 'services:\n'
  jq -r '.images|to_entries[]|"  x\(.key|gsub("[^a-z0-9]";"")):\n    image: \(.key)@\(.value)"' "$manifest"
} >"$compose"
vx_harbor_release_images_validate "$manifest" "$compose" || fail 'pinned compose rejected'
sed -i 's/@sha256:/\:v2.15.0 # @sha256:/' "$compose"
! vx_harbor_release_images_validate "$manifest" "$compose" || fail 'tampered generated compose accepted'
printf 'PASS: Harbor release verification\n'
