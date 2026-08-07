#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
unshare -Urnm bash "$repo_root/test/compose/fixtures/shell-broker-namespace.sh" \
    "$repo_root" "$fixture"

echo 'Compose shell access concurrency tests passed.'
