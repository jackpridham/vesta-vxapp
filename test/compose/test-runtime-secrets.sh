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
printf 'retired-value\n' >"$project/secrets/retired"
chmod 0600 "$project/secrets/credential"
chmod 0600 "$project/secrets/retired"
printf '%s\n' '{"secrets":[{"name":"credential","target":"/run/secrets/credential"},{"name":"retired","target":"/run/secrets/retired"}]}' \
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
[[ -f "$runtime_parent/current/retired" ]] \
    || fail 'declared second secret was not materialized'
[[ "$(stat -c '%u:%g' "$runtime_secret")" \
    == "$(id -u):$(id -g)" ]] || fail 'runtime secret ownership is incorrect'

printf 'rotated-value\n' >"$project/secrets/credential"
printf '%s\n' '{"secrets":[{"name":"credential","target":"/run/secrets/credential"}]}' \
    >"$test_root/workload.json"
/usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
    || fail 'rotated runtime secret materialization failed'
[[ "$(<"$runtime_secret")" == rotated-value \
    && ! -e "$runtime_parent/current/retired" \
    && -f "$project/secrets/retired" \
    && "$(stat -c '%a' "$project/secrets/credential")" == 600 ]] \
    || fail 'rotation did not refresh the runtime-only copy'
unchanged_inode="$(stat -c '%d:%i' "$runtime_secret")"
set +e
/usr/bin/python3 "$helper" "$project" "$test_root/workload.json"
unchanged_status=$?
set -e
[[ "$unchanged_status" -eq 20 \
    && "$(stat -c '%d:%i' "$runtime_secret")" == "$unchanged_inode" ]] \
    || fail 'unchanged runtime secret generation was replaced'

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

if (( EUID != 0 )); then
    printf 'fsync-value\n' >"$project/secrets/credential"
    if VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL=final-fsync \
        /usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
        >/dev/null 2>&1; then
        fail 'injected final fsync failure succeeded'
    fi
    [[ "$(<"$runtime_secret")" == rotated-value ]] \
        || fail 'pre-commit fsync failure activated the new set'
    printf 'cleanup-value\n' >"$project/secrets/credential"
    VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL=cleanup \
        /usr/bin/python3 "$helper" "$project" "$test_root/workload.json" \
        || fail 'post-commit cleanup failure was reported as activation failure'
    [[ "$(<"$runtime_secret")" == cleanup-value ]] \
        || fail 'post-commit cleanup did not leave the new complete set active'
    printf 'rotated-value\n' >"$project/secrets/credential"
    /usr/bin/python3 "$helper" "$project" "$test_root/workload.json"
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

touch "$runtime_parent/unknown"
if /usr/bin/python3 "$helper" clear "$project" >/dev/null 2>&1; then
    fail 'runtime secret clear accepted an unknown member'
fi
[[ "$(<"$runtime_secret")" == rotated-value ]] \
    || fail 'unknown-member clear failure changed the active runtime copy'
rm -f -- "$runtime_parent/unknown"

ln -s current "$runtime_parent/.next.invalid"
if /usr/bin/python3 "$helper" clear "$project" >/dev/null 2>&1; then
    fail 'runtime secret clear followed a symlinked generation'
fi
[[ -f "$runtime_secret" ]] \
    || fail 'symlinked-generation clear failure changed active authority'
rm -f -- "$runtime_parent/.next.invalid"

if (( EUID != 0 )); then
    if VX_COMPOSE_RUNTIME_SECRET_TEST_FAIL=clear-fsync \
        /usr/bin/python3 "$helper" clear "$project" >/dev/null 2>&1; then
        fail 'injected runtime secret clear fsync failure succeeded'
    fi
    [[ -f "$runtime_secret" ]] \
        || fail 'clear fsync failure changed active authority'
fi

/usr/bin/python3 "$helper" clear "$project" \
    || fail 'generic transition did not clear runtime workload secrets'
[[ ! -e "$runtime_parent" ]] \
    || fail 'generic transition retained stale runtime workload secrets'

echo 'Compose runtime secret tests passed.'
