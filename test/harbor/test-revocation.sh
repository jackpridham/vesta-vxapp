#!/usr/bin/env bash
set -Eeuo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$repo/bin/v-suspend-user" "$repo/bin/v-unsuspend-user" "$repo/bin/v-delete-user"
line_pub="$(grep -n 'publisher_revoke_locked' "$repo/func/vx/harbor/owners.sh"|tail -1|cut -d: -f1)"; line_run="$(grep -n 'runtime_revoke' "$repo/func/vx/harbor/owners.sh"|tail -1|cut -d: -f1)"; (( line_pub < line_run ))
! grep -q 'docker\|nginx\|firewall\|route' "$repo/func/vx/harbor/publisher.sh"
grep -q 'vx_harbor_owner_revoke' "$repo/bin/v-suspend-user"; grep -q 'vx_harbor_owner_revoke' "$repo/bin/v-delete-user"; grep -q 'vx_harbor_owner_reconcile' "$repo/bin/v-unsuspend-user"
printf 'PASS: retained-artifact credential revocation\n'
