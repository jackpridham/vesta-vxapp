#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
record="NAME='site' CTN_NAME='vx-alice-site' OWNER='alice' IMAGE='nginx:alpine' COMMAND='' ENV='' MOUNTS='' HOST_PORT='18080' CONTAINER_PORT='80' DOMAIN='' ROUTE_PATH='' AUTO_START='yes' RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='none'"
vx_compose_migration_render alice "$record" "$test_root/compose.yaml"
grep -Fq '127.0.0.1:18080:80' "$test_root/compose.yaml"
grep -Fq 'cap_drop:' "$test_root/compose.yaml"
grep -Fq 'no-new-privileges:true' "$test_root/compose.yaml"

bad="${record/ENV=\'\'/ENV=\'PASSWORD=canary\'}"
if vx_compose_migration_render alice "$bad" "$test_root/bad.yaml" 2>/dev/null; then
    echo 'FAIL: secret-like legacy environment was accepted' >&2
    exit 1
fi

echo "Compose migration tests passed."
