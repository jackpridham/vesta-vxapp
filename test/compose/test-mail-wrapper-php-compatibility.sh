#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
php_bin=/usr/bin/php
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

compile_output="$("$php_bin" -d error_reporting=-1 -d display_errors=1 \
    -l "$repo_root/web/inc/main.php" 2>&1)" \
    || fail 'main.php did not compile'
grep -Eq 'Deprecated:|Using \$\{' <<<"$compile_output" \
    && fail 'main.php emits deprecated interpolation warnings'

cli_output="$("$php_bin" -d error_reporting=-1 -d display_errors=1 \
    -r '
        session_set_save_handler(new class implements SessionHandlerInterface {
            public function open(string $path, string $name): bool { return true; }
            public function close(): bool { return true; }
            public function read(string $id): string|false { return ""; }
            public function write(string $id, string $data): bool { return true; }
            public function destroy(string $id): bool { return true; }
            public function gc(int $max_lifetime): int|false { return 0; }
        }, true);
        define("NO_AUTH_REQUIRED", true);
        $_SERVER["SCRIPT_FILENAME"] = $argv[1];
        require $argv[1];
    ' "$repo_root/web/inc/main.php" 2>&1)" \
    || fail 'main.php failed in the CLI notification context'
grep -Eq 'Warning:|Deprecated:|Notice:|Undefined array key' <<<"$cli_output" \
    && fail 'main.php emits diagnostics in the CLI notification context'

grep -Fq "isset(\$_SERVER['REMOTE_ADDR'])" "$repo_root/web/inc/main.php" \
    || fail 'normal HTTP remote-address session check is missing'

printf '%s\n' 'Mail-wrapper PHP compatibility tests passed.'
