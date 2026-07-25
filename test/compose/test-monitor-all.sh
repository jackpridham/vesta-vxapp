#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice/docker-projects/app" \
    "$VESTA/data/users/bob/docker-projects/site" \
    "$VESTA/data/users/bob/docker-projects/.locks"
touch \
    "$VESTA/data/users/alice/docker-projects/app/project.conf" \
    "$VESTA/data/users/bob/docker-projects/site/project.conf"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

vx_compose_monitor_project() {
    printf '%s/%s\n' "$1" "$2" >>"$test_root/monitored"
}

vx_compose_monitor_all
diff -u <(printf '%s\n' alice/app bob/site) "$test_root/monitored"

echo "Compose monitor-all tests passed."
