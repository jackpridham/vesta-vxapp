#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

if grep -REn 'cat .*secrets/|docker-registry/config.json|PASSWORD=|TOKEN=' \
    "$repo_root/bin"/v-*-docker-* "$repo_root/func/vx/compose"; then
    echo "FAIL: secret-bearing storage is exposed by a read surface" >&2
    exit 1
fi
if grep -En 'docker-projects/.*/secrets|docker-registry/config.json' \
    "$repo_root/bin/v-backup-user"; then
    echo "FAIL: unencrypted user backup includes Compose secret/auth values" >&2
    exit 1
fi
for dependency in docker-compose jq age python3; do
    grep -Fq "$dependency" "$repo_root/install/vst-install-debian.sh" \
        || {
            echo "FAIL: Debian installer omits $dependency" >&2
            exit 1
        }
done

echo "Compose redaction surface tests passed."
