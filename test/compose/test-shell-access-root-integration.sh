#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ "$EUID" == 0 ]] || { echo 'SKIP: root-only disposable integration'; exit 0; }

# Never exercise account, group, or sudoers mutation in the developer host
# namespace. A disposable container harness must opt in explicitly.
[[ "${VX_SHELL_ACCESS_DISPOSABLE_ROOT:-}" == yes && -f /.dockerenv ]] || {
    echo 'SKIP: root is not inside an explicitly approved disposable container'
    exit 0
}

bash "$repo_root/test/compose/test-shell-access.sh"
bash "$repo_root/test/compose/test-shell-input.sh"
bash "$repo_root/test/compose/test-malicious-input.sh"
bash "$repo_root/test/compose/test-policy.sh"
echo 'Disposable root shell-access regression boundary passed.'
