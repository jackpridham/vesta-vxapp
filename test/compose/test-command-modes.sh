#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

while IFS= read -r command_path; do
    full_path="$repo_root/$command_path"
    [[ -f "$full_path" ]] \
        || fail "Vesta command is not a regular file: $command_path"
    [[ -x "$full_path" ]] \
        || fail "Vesta command is not executable: $command_path"

    git_mode="$(
        git -C "$repo_root" ls-files -s -- "$command_path" \
            | awk '{print $1}'
    )"
    [[ "$git_mode" == 100755 ]] \
        || fail "Vesta command Git mode is not 100755: $command_path"

    IFS= read -r first_line <"$full_path" || true
    [[ "$first_line" == '#!'* ]] \
        || fail "Vesta command shebang is not at byte zero: $command_path"
done < <(git -C "$repo_root" ls-files 'bin/v-*' | sort)

printf '%s\n' 'Vesta command mode tests passed.'
