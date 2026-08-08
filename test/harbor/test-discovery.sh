#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$repo/bin/v-list-user-harbor-registry" "$repo/bin/v-run-user-docker-command"
grep -q 'registry-info)' "$repo/bin/v-run-user-docker-command"
! grep -q 'RUNTIME_ROBOT_ID\|PROJECT_ID\|QUOTA_ID' "$repo/bin/v-list-user-harbor-registry"
grep -q 'require_standard' "$repo/bin/v-run-user-docker-command"
printf 'PASS: redacted registry discovery\n'
