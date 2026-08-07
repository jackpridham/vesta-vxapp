#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/func/vx/compose/shell-access.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

if (( EUID == 0 )); then
    original_umask="$(umask)"
    umask 0022
    expected_umask="$(umask)"
    assert_umask_unchanged() {
        [[ "$(umask)" == "$expected_umask" ]] || fail "$1 changed caller umask"
    }
    for size in 1 1048576; do
        snapshot_root= snapshot_file=
        vx_compose_shell_snapshot_stdin compose 1048576 snapshot_root snapshot_file \
            < <(head -c "$size" /dev/zero) || fail "snapshot rejected $size bytes"
        assert_umask_unchanged 'compose success'
        file="$snapshot_file"
        [[ "$file" =~ ^/tmp/vx-compose-web[.][a-f0-9]{32}/compose[.]yaml$ ]] \
            || fail 'compose snapshot path shape wrong'
        [[ "$snapshot_root" == "${file%/*}" ]] || fail 'compose snapshot root output wrong'
        [[ "$(stat -c '%s' "$file")" == "$size" ]] || fail 'snapshot size changed'
        [[ "$(stat -c '%u:%g:%a:%F' "${file%/*}")" == '0:0:700:directory' ]] || fail 'snapshot parent mode wrong'
        [[ "$(stat -c '%u:%g:%a:%F' "$file")" == '0:0:600:regular file' ]] || fail 'snapshot file mode wrong'
        rm -rf -- "${file%/*}"
    done
    for kind in secret registry; do
        snapshot_root= snapshot_file=
        vx_compose_shell_snapshot_stdin "$kind" 65536 snapshot_root snapshot_file \
            < <(printf 'protected-input') || fail "$kind snapshot rejected valid input"
        assert_umask_unchanged "$kind success"
        file="$snapshot_file"
        protected_path_re="^/var/tmp/vesta-compose-shell[.][A-Za-z0-9]{8}/${kind}[.]input$"
        [[ "$file" =~ $protected_path_re ]] \
            || fail "$kind snapshot path shape wrong"
        [[ "$snapshot_root" == "${file%/*}" ]] || fail "$kind snapshot root output wrong"
        [[ "$(stat -c '%s' "$file")" == 15 ]] || fail "$kind snapshot size changed"
        [[ "$(stat -c '%u:%g:%a:%F' "${file%/*}")" == '0:0:700:directory' ]] \
            || fail "$kind snapshot parent mode wrong"
        [[ "$(stat -c '%u:%g:%a:%F' "$file")" == '0:0:600:regular file' ]] \
            || fail "$kind snapshot file mode wrong"
        rm -rf -- "${file%/*}"
    done
    ! vx_compose_shell_snapshot_stdin compose 1048576 snapshot_root snapshot_file </dev/null \
        || fail 'empty compose accepted'
    assert_umask_unchanged 'empty compose rejection'
    ! vx_compose_shell_snapshot_stdin compose 1048576 snapshot_root snapshot_file \
        < <(head -c 1048577 /dev/zero) || fail 'oversize compose accepted'
    assert_umask_unchanged 'oversize compose rejection'
    for kind in secret registry; do
        ! vx_compose_shell_snapshot_stdin "$kind" 65536 snapshot_root snapshot_file </dev/null \
            || fail "empty $kind accepted"
        assert_umask_unchanged "empty $kind rejection"
        ! vx_compose_shell_snapshot_stdin "$kind" 65536 snapshot_root snapshot_file \
            < <(head -c 65537 /dev/zero) \
            || fail "oversize $kind accepted"
        assert_umask_unchanged "oversize $kind rejection"
    done
    ! vx_compose_shell_snapshot_stdin compose 1048576 'bad-name' snapshot_file </dev/null \
        || fail 'invalid snapshot output variable accepted'
    assert_umask_unchanged 'invalid-output rejection'
    ! vx_compose_shell_snapshot_stdin compose 1048576 snapshot_root snapshot_root </dev/null \
        || fail 'duplicate snapshot output variable accepted'
    assert_umask_unchanged 'duplicate-output rejection'
    umask "$original_umask"
fi
grep -Fq 'snapshot compose 1048576' "$repo_root/bin/v-run-user-docker-command" || fail 'compose bound missing'
grep -Fq 'snapshot secret 65536' "$repo_root/bin/v-run-user-docker-command" || fail 'secret bound missing'
grep -Fq 'snapshot registry 65536' "$repo_root/bin/v-run-user-docker-command" || fail 'registry bound missing'
! rg -n 'bash -c|sh -c|eval ' "$repo_root/bin/v-run-user-docker-command" >/dev/null || fail 'dynamic dispatch present'

echo 'Compose shell input tests passed.'
