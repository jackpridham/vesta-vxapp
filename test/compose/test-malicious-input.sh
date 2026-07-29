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

cases=(
    privileged:PRIVILEGED
    docker-socket:'(MOUNT|PATH)'
    root-mount:MOUNT
    host-pid:HOST_PID
    host-ipc:HOST_IPC
    device:DEVICE
    capability:CAP_ADD
    host-network:HOST_NETWORK
    build:BUILD
    external-network:EXTERNAL_NETWORK
    ownership-label:OWNERSHIP_LABEL
    missing-limits:CPU_LIMIT
    command-injection:SENSITIVE_VALUE
)

for test_case in "${cases[@]}"; do
    name="${test_case%%:*}"
    code="${test_case#*:}"
    input_file="$test_root/$name.yaml"
    error_file="$test_root/$name.error"

    docker compose \
        --project-name "fixture-$name" \
        --file "$repo_root/test/compose/fixtures/basic-http.compose.yaml" \
        --file "$repo_root/test/compose/fixtures/malicious/$name.yaml" \
        config >"$input_file"
    if vx_compose_prepare_candidate \
        alice "$name" "$input_file" "$test_root/$name-output" \
        2>"$error_file"; then
        fail "$name reached accepted candidate state"
    fi
    grep -Eq "Compose policy rejection \\[$code\\]" "$error_file" \
        || fail "$name returned the wrong deny-first diagnostic"
    if grep -Fq 'must-not-leak' "$error_file"; then
        fail "$name leaked a hostile input value"
    fi
done

echo "Compose malicious-input tests passed."
