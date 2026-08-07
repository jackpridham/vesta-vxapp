#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/func/vx/compose/shell-access.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

if (( EUID == 0 )); then
    for size in 1 1048576; do
        file="$(head -c "$size" /dev/zero | vx_compose_shell_snapshot_stdin compose 1048576)" || fail "snapshot rejected $size bytes"
        [[ "$(stat -c '%s' "$file")" == "$size" ]] || fail 'snapshot size changed'
        [[ "$(stat -c '%u:%g:%a:%F' "${file%/*}")" == '0:0:700:directory' ]] || fail 'snapshot parent mode wrong'
        [[ "$(stat -c '%u:%g:%a:%F' "$file")" == '0:0:600:regular file' ]] || fail 'snapshot file mode wrong'
        rm -rf -- "${file%/*}"
    done
    ! : | vx_compose_shell_snapshot_stdin compose 1048576 >/dev/null || fail 'empty compose accepted'
    ! head -c 1048577 /dev/zero | vx_compose_shell_snapshot_stdin compose 1048576 >/dev/null || fail 'oversize compose accepted'
fi
grep -Fq 'snapshot compose 1048576' "$repo_root/bin/v-run-user-docker-command" || fail 'compose bound missing'
grep -Fq 'snapshot secret 65536' "$repo_root/bin/v-run-user-docker-command" || fail 'secret bound missing'
grep -Fq 'snapshot registry 65536' "$repo_root/bin/v-run-user-docker-command" || fail 'registry bound missing'
! rg -n 'bash -c|sh -c|eval ' "$repo_root/bin/v-run-user-docker-command" >/dev/null || fail 'dynamic dispatch present'

echo 'Compose shell input tests passed.'
