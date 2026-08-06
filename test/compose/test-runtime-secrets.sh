#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'chmod -R u+w "$test_root" 2>/dev/null || :; rm -rf -- "$test_root"' EXIT
chmod 0700 "$test_root"
project="$test_root/project"
mkdir -m 0750 "$project" "$project/runtime"
mkdir -m 0700 "$project/secrets"
printf 'first-value\n' >"$project/secrets/credential"
chmod 0600 "$project/secrets/credential"
printf '%s\n' '{"secrets":[{"name":"credential","target":"/run/secrets/credential"}]}' \
    >"$test_root/workload.json"
chmod 0600 "$test_root/workload.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
helper="$repo_root/func/vx/compose/runtime-secrets.py"
/usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
    || fail 'initial runtime secret materialization failed'
runtime_parent="$project/runtime/workload-secrets"
runtime_secret="$runtime_parent/current/credential"
[[ "$(stat -c '%a' "$project/secrets/credential")" == 600
    && "$(stat -c '%a' "$runtime_parent")" == 700
    && "$(stat -c '%a' "$runtime_parent/current")" == 700
    && "$(stat -c '%a' "$runtime_secret")" == 444
    && "$(<"$runtime_secret")" == first-value ]] \
    || fail 'runtime and authoritative secret modes/bytes are incorrect'
[[ "$(stat -c '%u:%g' "$runtime_secret")" \
    == "$(id -u):$(id -g)" ]] || fail 'runtime secret ownership is incorrect'

printf 'rotated-value\n' >"$project/secrets/credential"
/usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
    || fail 'rotated runtime secret materialization failed'
[[ "$(<"$runtime_secret")" == rotated-value \
    && "$(stat -c '%a' "$project/secrets/credential")" == 600 ]] \
    || fail 'rotation did not refresh the runtime-only copy'

if (( EUID != 0 )); then
    printf 'failed-value\n' >"$project/secrets/credential"
    if VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL=before-activate \
        /usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
        >/dev/null 2>&1; then
        fail 'injected materialization failure succeeded'
    fi
    [[ "$(<"$runtime_secret")" == rotated-value \
        && -z "$(find "$runtime_parent" -mindepth 1 -maxdepth 1 \
            -name '.next.*' -print -quit)" ]] \
        || fail 'failed materialization changed authority or leaked staging'
    printf 'rotated-value\n' >"$project/secrets/credential"
fi

mv "$project/secrets/credential" "$project/secrets/credential.real"
ln -s credential.real "$project/secrets/credential"
if /usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
    >/dev/null 2>&1; then
    fail 'symlinked authoritative secret was accepted'
fi
[[ "$(<"$runtime_secret")" == rotated-value ]] \
    || fail 'symlink rejection changed the active runtime copy'
[[ -z "$(find "$runtime_parent" -mindepth 1 -maxdepth 1 \
    -name '.next.*' -print -quit)" ]] \
    || fail 'symlink rejection leaked runtime staging'

rm "$project/secrets/credential"
mv "$project/secrets/credential.real" "$project/secrets/credential"
if (( EUID != 0 )); then
    VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL=pause-before-activate \
        /usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
        >/dev/null 2>&1 &
    helper_pid=$!
    for _ in {1..100}; do
        [[ -e "$runtime_parent/.runtime-secrets-test-ready" ]] && break
        sleep 0.01
    done
    [[ -e "$runtime_parent/.runtime-secrets-test-ready" ]] \
        || fail 'runtime secret race did not reach descriptor snapshot'
    mv "$project/secrets" "$project/secrets-held"
    mkdir -m 0700 "$project/secrets"
    printf 'replacement\n' >"$project/secrets/credential"
    chmod 0600 "$project/secrets/credential"
    if wait "$helper_pid"; then
        fail 'replaced authoritative secret directory was accepted'
    fi
    [[ "$(<"$runtime_secret")" == rotated-value \
        && -z "$(find "$runtime_parent" -mindepth 1 -maxdepth 1 \
            -name '.next.*' -print -quit)" ]] \
        || fail 'secret directory race changed active runtime authority'
fi

echo 'Compose runtime secret tests passed.'
