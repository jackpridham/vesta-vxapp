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

rrd_vesta="$test_root/rrd-vesta"
mkdir -p "$rrd_vesta/func/vx/compose" "$rrd_vesta/conf"
cat >"$rrd_vesta/func/main.sh" <<'EOF'
E_RRD=8
vx_docker_rrd_period_graph_window() { return 0; }
vx_docker_ensure_rrd_dir() { return 0; }
vx_docker_list_all_records() { return 0; }
EOF
touch "$rrd_vesta/func/docker.sh" "$rrd_vesta/conf/vesta.conf"
cat >"$rrd_vesta/func/vx/compose/main.sh" <<'EOF'
vx_compose_preview_gc() {
    echo preview-gc >>"$VX_MONITOR_TEST_LOG"
    return 1
}
vx_compose_backup_policies_run_due() {
    echo backup-policies >>"$VX_MONITOR_TEST_LOG"
    return 1
}
vx_compose_monitor_all() {
    echo monitor-all >>"$VX_MONITOR_TEST_LOG"
}
EOF

export VX_MONITOR_TEST_LOG="$test_root/daily-actions"
VESTA="$rrd_vesta" \
HOMEDIR="$test_root/rrd-home" \
BIN="$rrd_vesta/bin" \
    "$repo_root/bin/v-update-sys-rrd-docker" daily
diff -u \
    <(printf '%s\n' preview-gc backup-policies monitor-all) \
    "$VX_MONITOR_TEST_LOG"

echo "Compose monitor-all tests passed."
