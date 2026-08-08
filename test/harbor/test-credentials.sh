#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$repo/func/vx/harbor/credentials.sh"
grep -q 'auths' "$repo/func/vx/harbor/credentials.sh"
grep -q 'robot_get' "$repo/func/vx/harbor/credentials.sh"
grep -q 'robot_delete.*old_id' "$repo/func/vx/harbor/credentials.sh"
! grep -q -- '--password ' "$repo/func/vx/harbor/credentials.sh"
printf 'PASS: runtime credential rotation boundary\n'
