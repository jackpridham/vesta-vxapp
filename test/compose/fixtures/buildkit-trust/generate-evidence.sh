#!/usr/bin/env bash
set -Eeuo pipefail

fixture_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output="${1:?usage: generate-evidence.sh OUTPUT.oci.tar}"

[[ "$output" == *.oci.tar && ! -e "$output" ]] || {
    echo 'output must be a new .oci.tar path' >&2
    exit 2
}
docker buildx build \
    --network=none \
    --sbom=true \
    --provenance=mode=max \
    --output "type=oci,dest=$output" \
    "$fixture_root"
sha256sum "$output" >"$output.sha256"
