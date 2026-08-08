#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$repo/func/vx/harbor/owners.sh" "$repo/func/vx/harbor/quota.sh"
grep -q 'vx_harbor_package_transition_recover' "$repo/func/vx/harbor/owners.sh"
grep -q 'provider_lock_acquire shared' "$repo/func/vx/harbor/owners.sh"
! grep -q 'project_lock' "$repo/func/vx/harbor/owners.sh"
source "$repo/func/vx/harbor/owners.sh"
[[ "$(vx_harbor_owner_namespace alice)" == vx-alice ]]
[[ "$(vx_harbor_owner_namespace alice_test)" == vx-u-* ]]
printf 'PASS: owner mapping and reconcile boundary\n'
