#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

index_output="$(php "$repo_root/test/test_compose_ingress_modal.php" \
    index tenant-a tenant-a)"
grep -Fq 'name="docker_ingress_consumers"' <<<"$index_output" \
    || fail 'project action modal does not expose native ingress consumers'

owner_output="$(php "$repo_root/test/test_compose_ingress_modal.php" \
    router tenant-a tenant-a)"
grep -Fq '&quot;COUNT&quot;:1' <<<"$owner_output" \
    || fail 'ordinary owner modal did not receive count-only ingress output'
grep -Fq '__INGRESS_STATE__{"call":["tenant-a","app","tenant-a"]}' \
    <<<"$owner_output" \
    || fail 'ordinary owner modal did not bind its authenticated actor'
if grep -Fq app.example.test <<<"$owner_output"; then
    fail 'ordinary owner modal received full ingress consumer metadata'
fi

admin_output="$(php "$repo_root/test/test_compose_ingress_modal.php" \
    router admin tenant-a)"
grep -Fq 'app.example.test' <<<"$admin_output" \
    || fail 'administrator modal did not receive full redacted ingress output'
grep -Fq 'X-Protected-Name' <<<"$admin_output" \
    || fail 'administrator modal did not receive header-name metadata'
grep -Fq '__INGRESS_STATE__{"call":["tenant-a","app","admin"]}' \
    <<<"$admin_output" \
    || fail 'administrator modal did not bind its authenticated actor'

denied_output="$(php "$repo_root/test/test_compose_ingress_modal.php" \
    router tenant-b tenant-a)"
grep -Fq 'You do not have access to this Compose project.' <<<"$denied_output" \
    || fail 'cross-owner modal request did not fail closed'
grep -Fq '__INGRESS_STATE__{"call":null}' <<<"$denied_output" \
    || fail 'cross-owner modal request reached ingress listing'

echo 'Compose ingress modal tests passed.'
