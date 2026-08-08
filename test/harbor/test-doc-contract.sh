#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
guide="$root/.docs/user-guides/vesta-managed-harbor.md"
[[ -s "$guide" ]] || { echo 'FAIL: canonical Harbor tenant guide missing' >&2; exit 1; }
for phrase in \
    'registry-info PROJECT' 'registry-publisher-change' \
    'immutable preview' 'No SCP, rsync' 'Automated restore apply'
do
    rg -q "$phrase" "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" \
        "$root/docs/container-orchestration.md" \
        "$root/.docs/contracts/harbor-provider.md" \
        || { echo "FAIL: missing doc behavior: $phrase" >&2; exit 1; }
done
for phrase in \
    'BLOCKED — PRODUCT' 'production is deferred' \
    'no public host TCP listener' '/v2/' '/service/token' \
    'DOCKER_REGISTRY_MB' 'U_DOCKER_REGISTRY_MB' \
    'Runtime pull identity' 'Publisher identity' 'Vesta administrator' \
    'Tenant maintainer' 'Application repository' \
    'registry-info APP_PROJECT' \
    'registry-publisher-change < publisher-secret' \
    'registry-publisher-disable' 'docker login "$REGISTRY"' \
    '--password-stdin' 'v-docker image-pull' 'v-docker rollback-preview' \
    '26b3764595a024b5b830a955b164f0ad95a25a2b'
do
    rg -Fq -- "$phrase" "$guide" \
        || { echo "FAIL: missing tenant guide behavior: $phrase" >&2; exit 1; }
done
for source in "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" "$root/docs/container-orchestration.md" "$root/.docs/README.md"; do
    rg -q 'vesta-managed-harbor\.md' "$source" || { echo "FAIL: Harbor tenant guide is not linked from ${source#"$root/"}" >&2; exit 1; }
    rg -q 'harbor-provider\.md' "$source" || { echo "FAIL: Harbor provider contract is not linked from ${source#"$root/"}" >&2; exit 1; }
done
! rg -qi 'github\.com/[^ /]+/[^ /]+|gitlab\.com/[^ /]+/[^ /]+' "$root/docs/container-orchestration.md" "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" "$guide" || { echo 'FAIL: private repository-like name in docs' >&2; exit 1; }
! rg -qi 'registry\.example|vesta\.example|ghcr\.io' "$guide" \
    || { echo 'FAIL: non-canonical registry example in tenant guide' >&2; exit 1; }
! rg -q -- '--password([ =]|$)' "$guide" || { echo 'FAIL: unsafe registry password argument in tenant guide' >&2; exit 1; }
printf 'PASS: Harbor documentation contract\n'
