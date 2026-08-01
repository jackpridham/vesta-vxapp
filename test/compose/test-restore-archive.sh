#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

declare -F vx_compose_restore_archive_validate >/dev/null \
    || fail "restore archive validator is missing"
grep -Fq 'runtime/routes.pending.json' \
    "$repo_root/func/vx/compose/restore.sh" \
    || fail 'restore does not clear stale pending route state'

authority_source="$test_root/user-restore-authority"
mkdir -p "$authority_source"
ln -s "$authority_source" "$test_root/user-restore-authority-link"
if vx_compose_restore_user_data_roots_prepare \
    alice "$test_root/user-restore-authority-link" 2>/dev/null; then
    fail 'restore data-root preparation accepted a linked archive root'
fi
ln -s /etc/passwd "$authority_source/linked.tar.gz"
if vx_compose_restore_user_data_roots_prepare \
    alice "$authority_source" 2>/dev/null; then
    fail 'restore data-root preparation accepted a linked project archive'
fi

expect_invalid_archive() {
    local name="$1"
    local archive="$2"

    if vx_compose_restore_archive_validate \
        alice app "$archive" "$test_root/$name-output" 2>/dev/null; then
        fail "$name archive was accepted"
    fi
    [[ ! -e "$test_root/$name-output" ]] \
        || fail "$name archive left extracted state"
}

mkdir -p "$test_root/source/control"
printf '{}\n' >"$test_root/source/manifest.json"
printf 'bad\n' >"$test_root/source/control/compose.yaml"
tar -czf "$test_root/unexpected.tar.gz" -C "$test_root/source" .
expect_invalid_archive unexpected "$test_root/unexpected.tar.gz"

tar -czf "$test_root/traversal.tar.gz" \
    --transform='s#^#../../#' -C "$test_root/source" control/compose.yaml
expect_invalid_archive traversal "$test_root/traversal.tar.gz"

tar -czf "$test_root/absolute.tar.gz" \
    --transform='s#^#/etc/#' -C "$test_root/source" control/compose.yaml
expect_invalid_archive absolute "$test_root/absolute.tar.gz"

ln -s /etc/passwd "$test_root/source/control/link"
tar -czf "$test_root/symlink.tar.gz" -C "$test_root/source" control/link
expect_invalid_archive symlink "$test_root/symlink.tar.gz"

mkfifo "$test_root/source/control/pipe"
tar -czf "$test_root/fifo.tar.gz" -C "$test_root/source" control/pipe
expect_invalid_archive fifo "$test_root/fifo.tar.gz"

valid="$test_root/valid"
mkdir -p "$valid/control" "$valid/binds" "$valid/volumes"
printf 'services: {}\n' >"$valid/control/compose.yaml"
jq -n '{
    SCHEMA: 1,
    OWNER: "alice",
    PROJECT: "app",
    REVISION: 1,
    STATE: "stopped",
    VOLUMES: [],
    SECRETS: []
}' >"$valid/manifest.json"
(
    cd "$valid"
    find . -type f ! -path './manifest.sha256' -print0 \
        | sort -z \
        | xargs -0 sha256sum >manifest.sha256
)
printf 'corrupted\n' >>"$valid/control/compose.yaml"
tar -czf "$test_root/checksum.tar.gz" -C "$valid" .
expect_invalid_archive checksum "$test_root/checksum.tar.gz"

large="$test_root/large"
mkdir -p "$large/control"
head -c 4096 /dev/zero >"$large/control/compose.yaml"
tar -czf "$test_root/expanded.tar.gz" -C "$large" control/compose.yaml
old_expanded_limit="$VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES"
VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES=1024
expect_invalid_archive expanded "$test_root/expanded.tar.gz"
VX_COMPOSE_BACKUP_MAX_EXPANDED_BYTES="$old_expanded_limit"

echo "Compose restore archive rejection tests passed."
