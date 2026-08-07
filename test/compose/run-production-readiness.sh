#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

run_step() {
    echo "==> $1"
}

for command_name in \
    bash shellcheck docker jq age python3 perl php node npm git rg \
    mount mountpoint umount; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required release-gate command is unavailable: $command_name"
done
docker compose version >/dev/null 2>&1 \
    || fail "docker compose is unavailable"

mapfile -t compose_helpers < <(find func/vx/compose -type f -name '*.sh' -print | sort)
mapfile -t compose_adapters < <(
    {
        find bin -maxdepth 1 -type f -name 'v-*docker*' -print
        printf '%s\n' \
            bin/v-check-docker-engine \
            bin/v-install-docker-service \
            bin/v-update-sys-rrd-docker
    } | sort -u
)

run_step "Bash syntax"
for source_file in "${compose_helpers[@]}" "${compose_adapters[@]}"; do
    bash -n "$source_file"
done
perl -c func/vx/compose/managed-directory.pl >/dev/null

run_step "resource-efficient ShellCheck"
bash test/compose/run-production-shellcheck.sh

run_step "Compose shell suites"
while IFS= read -r test_file; do
    bash "$test_file"
done < <(find test/compose -maxdepth 1 -type f -name 'test-*.sh' -print | sort)

run_step "committed Compose fixture renders"
base_fixture="test/compose/fixtures/basic-http.compose.yaml"
while IFS= read -r fixture; do
    compose_files=(--file "$fixture")
    if [[ "$fixture" == test/compose/fixtures/malicious/* ]]; then
        compose_files=(--file "$base_fixture" --file "$fixture")
    fi
    render_error="$(mktemp)"
    if ! docker compose --project-name vx-release-gate \
        "${compose_files[@]}" config --format json \
        >/dev/null 2>"$render_error"; then
        if [[ "$fixture" != \
            test/compose/fixtures/malicious/compose-api-socket.yaml ]] \
            || ! grep -Fq 'use_api_socket' "$render_error"; then
            cat "$render_error" >&2
            rm -f -- "$render_error"
            fail "Compose fixture did not reach a fail-closed parser boundary"
        fi
    fi
    rm -f -- "$render_error"
done < <(
    git ls-files -- \
        'test/compose/fixtures/*.compose.yaml' \
        'test/compose/fixtures/malicious/*.yaml' | sort
)

run_step "PHP syntax and helper tests"
mapfile -t php_files < <(
    find web -type f -name '*.php' -print | sort
)
for php_file in "${php_files[@]}"; do
    php -l "$php_file" >/dev/null
done
php test/test_compose_php_helpers.php

run_step "JavaScript syntax and unit tests"
while IFS= read -r js_file; do
    node --check "$js_file"
done < <(
    {
        printf '%s\n' playwright.config.js
        find tests/playwright test/js -type f -name '*.js' -print
        find web -type f -name '*.js' -print
    } | sort -u
)
node test/js/test-playwright-env-file.js
node test/js/test-floating-div.js

run_step "documentation consistency"
bash test/test_compose_docs.sh

run_step "Playwright discovery"
npm run playwright:test -- --list

run_step "working-tree whitespace"
git diff --check

echo "Compose production-readiness release gate passed."
