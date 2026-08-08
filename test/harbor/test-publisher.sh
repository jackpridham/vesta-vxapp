#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$repo/func/vx/harbor/publisher.sh"
grep -q 'push-pull' "$repo/func/vx/harbor/publisher.sh"
grep -q 'PUBLISHER_ENABLED=true' "$repo/func/vx/harbor/publisher.sh"
! grep -q 'printf.*secret' "$repo/func/vx/harbor/publisher.sh"
printf 'PASS: separate publisher lifecycle\n'
