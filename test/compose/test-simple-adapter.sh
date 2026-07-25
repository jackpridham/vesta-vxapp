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

# Globals intentionally model vx_docker_load_spec output consumed by the
# compatibility helper.
# shellcheck disable=SC2034
declare -g \
    NAME=site \
    IMAGE=nginx:alpine \
    COMMAND='' \
    ENV='NODE_ENV=production' \
    MOUNTS='' \
    CONTAINER_PORT=8080 \
    RESTART_POLICY=unless-stopped \
    HEALTHCHECK_TYPE=none \
    HEALTHCHECK_TARGET='' \
    HEALTHCHECK_INTERVAL=60
vx_compose_simple_render_loaded alice 18080 "$test_root/compose.yaml"
grep -Fq '127.0.0.1:18080:8080' "$test_root/compose.yaml"
grep -Fq 'NODE_ENV=production' "$test_root/compose.yaml"
grep -Fq 'cap_drop: [ALL]' "$test_root/compose.yaml"
mkdir "$test_root/candidate"
vx_compose_simple_metadata_write_candidate \
    alice 18080 "$test_root/candidate"
jq -e '
    .OWNER == "alice"
    and .NAME == "site"
    and .IMAGE == "nginx:alpine"
    and .ENV == "NODE_ENV=production"
    and .HOST_PORT == "18080"
    and .CONTAINER_PORT == "8080"
' "$test_root/candidate/simple.json" >/dev/null \
    || {
        echo 'FAIL: safe simple-form metadata was not rendered' >&2
        exit 1
    }
[[ "$(stat -c '%a' "$test_root/candidate/simple.json")" == 600 ]] \
    || {
        echo 'FAIL: simple-form metadata mode is not protected' >&2
        exit 1
    }

project_root="$VESTA/data/users/alice/docker-projects/site"
mkdir -p "$project_root/runtime"
cp "$test_root/candidate/simple.json" "$project_root/simple.json"
chmod 0600 "$project_root/simple.json"
cat >"$project_root/project.conf" <<'EOF'
OWNER='alice'
PROJECT='site'
COMPOSE_PROJECT='vx-alice-site'
PROFILE='standard'
STATE='running'
REVISION='1'
CREATED='2026-07-25T00:00:00Z'
UPDATED='2026-07-25T00:01:00Z'
EOF
cat >"$project_root/policy.conf" <<'EOF'
SERVICES='1'
EOF
cp "$test_root/compose.yaml" "$project_root/compose.yaml"
cat >"$project_root/runtime/canonical.json" <<'EOF'
{"services":{"site":{"image":"nginx:alpine"}}}
EOF
cat >"$project_root/routes.conf" <<'EOF'
{"site.example.test":{"SCHEME":"http","HOST_PORT":18080}}
EOF
jq '.DOMAIN = "site.example.test"' \
    "$project_root/simple.json" >"$project_root/.simple.json.new"
mv "$project_root/.simple.json.new" "$project_root/simple.json"
chmod 0600 "$project_root/simple.json"
vx_compose_runtime_containers_json() {
    printf '%s\n' \
        '[{"Name":"/vx-alice-site-site-1","State":{"Status":"running"}}]'
}
vx_compose_simple_load_legacy_record alice site
[[ "$NAME" == site
    && "$CTN_NAME" == vx-alice-site-site-1
    && "$OWNER" == alice
    && "$PROXY_MODE" == proxy
    && "$PROXY_TARGET" == http://127.0.0.1:18080
    && "$STATUS" == running ]] \
    || {
        echo 'FAIL: simple Compose metadata was not loaded as a legacy record' >&2
        exit 1
    }

for command_name in add change start stop restart delete; do
    command_path="$repo_root/bin/v-${command_name}-docker-container"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
for command_name in \
    list-docker-container \
    list-docker-container-inspect \
    list-docker-container-health \
    list-docker-container-alerts \
    list-docker-container-stats \
    list-docker-container-logs
do
    command_path="$repo_root/bin/v-${command_name}"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || {
            echo "FAIL: $command_name does not load the Compose adapter" >&2
            exit 1
        }
done
if grep -En 'vx_docker_create_runtime|docker (run|create)' \
    "$repo_root/bin/v-add-docker-container"; then
    echo 'FAIL: simple add still creates a direct container' >&2
    exit 1
fi
grep -Fq 'advanced Compose projects cannot use the simple editor' \
    "$repo_root/bin/v-change-docker-container" \
    || {
        echo 'FAIL: simple change adapter does not enforce provenance' >&2
        exit 1
    }
[[ "$(grep -Fc 'vx_compose_routes_apply' \
    "$repo_root/func/vx/compose/simple.sh")" -ge 2 ]] \
    || {
        echo 'FAIL: simple add/change do not apply their persisted routes' >&2
        exit 1
    }

echo "Compose simple-adapter tests passed."
