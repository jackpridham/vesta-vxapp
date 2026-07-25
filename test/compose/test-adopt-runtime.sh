#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export VX_COMPOSE_DOCKER_BIN="$test_root/fake-docker"
mkdir -p "$VESTA/data/users/alice"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then' \
    '  printf "aaaaaaaaaaaa\n"' \
    'else' \
    '  printf '\''[{"Config":{"Labels":{"com.docker.compose.project":"vx-alice-imported","com.docker.compose.service":"web"}}}]'\''' \
    'fi' >"$VX_COMPOSE_DOCKER_BIN"
chmod 0755 "$VX_COMPOSE_DOCKER_BIN"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
if vx_compose_adopt_runtime_json alice imported 2>/dev/null; then
    echo 'FAIL: ambiguous existing Compose ownership was accepted' >&2
    exit 1
fi

echo "Compose adoption runtime tests passed."
