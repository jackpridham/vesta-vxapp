#!/usr/bin/env bash
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
for phrase in 'registry-info PROJECT' 'registry-publisher-change' 'immutable preview' 'No SCP, rsync' 'Automated restore apply'; do rg -q "$phrase" "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" "$root/docs/container-orchestration.md" "$root/.docs/contracts/harbor-provider.md" || { echo "FAIL: missing doc behavior: $phrase" >&2; exit 1; }; done
! rg -qi 'github\.com/[^ /]+/[^ /]+|gitlab\.com/[^ /]+/[^ /]+' "$root/docs/container-orchestration.md" "$root/DOCKER_ORCHESTRATION_DEPLOYMENT.md" || { echo 'FAIL: private repository-like name in docs' >&2; exit 1; }
printf 'PASS: Harbor documentation contract\n'
