#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p \
    "$VESTA/data/users/alice" \
    "$HOMEDIR/alice/docker/app/binds/config" \
    "$test_root/outside"
printf "DOCKER_VOLUMES='2'\n" >"$VESTA/data/users/alice/user.conf"
ln -s "$test_root/outside" "$HOMEDIR/alice/docker/app/binds/escape"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

model="$test_root/model.json"
jq -n --arg bind "$HOMEDIR/alice/docker/app/binds/config" '{
    volumes: {
        state: {
            name: "vx_alice_app_state",
            labels: {
                "vx.managed": "yes",
                "vx.user": "alice",
                "vx.project": "app",
                "vx.volume": "state"
            }
        }
    },
    services: {
        app: {
            volumes: [
                {type: "volume", source: "state", target: "/srv/state"},
                {type: "bind", source: $bind, target: "/srv/config", read_only: true}
            ]
        }
    }
}' >"$model"
vx_compose_policy_check_storage "$model" alice app \
    || fail "managed bind and named volume were rejected"

expect_storage_rejection() {
    local name="$1"
    local fixture="$test_root/$name.json"
    shift

    jq "$@" "$model" >"$fixture"
    if vx_compose_policy_check_storage "$fixture" alice app 2>/dev/null; then
        fail "$name storage input was accepted"
    fi
}

expect_storage_rejection anonymous \
    '.services.app.volumes[0] |= del(.source)'
expect_storage_rejection wrong_name \
    '.volumes.state.name = "other"'
expect_storage_rejection wrong_labels \
    '.volumes.state.labels["vx.user"] = "bob"'
expect_storage_rejection host_bind \
    '.services.app.volumes[1].source = "/etc"'
# shellcheck disable=SC2016
expect_storage_rejection symlink_escape \
    --arg path "$HOMEDIR/alice/docker/app/binds/escape" \
    '.services.app.volumes[1].source = $path'
expect_storage_rejection unsafe_target \
    '.services.app.volumes[1].target = "/etc/passwd"'

[[ "$(vx_compose_volume_runtime_name alice app state)" == vx_alice_app_state ]] \
    || fail "stable volume name is wrong"

project_root="$(vx_compose_project_root alice app)"
mkdir -p "$project_root/runtime"
cp "$model" "$project_root/runtime/canonical.json"
printf 'services: {}\n' >"$project_root/compose.yaml"
printf "OWNER='alice'\nPROJECT='app'\n" >"$project_root/project.conf"
printf "POLICY_SCHEMA='1'\n" >"$project_root/policy.conf"

fake_docker="$test_root/fake-docker"
docker_log="$test_root/docker.log"
# The single-quoted lines intentionally write a separate test executable.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'root="$(dirname -- "$0")"' \
    'printf "ARG=%s\n" "$@" >>"$root/docker.log"' \
    'if [[ " $* " == *" volume inspect "* ]]; then' \
    '  cat "$root/volume.json"' \
    'elif [[ " $* " == *" run "* ]]; then' \
    '  for argument in "$@"; do' \
    '    case "$argument" in type=bind,src=*,dst=/backup)' \
    '      output_root="${argument#type=bind,src=}"' \
    '      output_root="${output_root%,dst=/backup}"' \
    '      ;;' \
    '    esac' \
    '  done' \
    '  printf "volume-data\n" >"$output_root/state.tar.gz"' \
    'fi' >"$fake_docker"
chmod 0755 "$fake_docker"
cat >"$test_root/volume.json" <<'EOF'
[{
  "Name": "vx_alice_app_state",
  "Labels": {
    "com.docker.compose.project": "vx-alice-app",
    "vx.managed": "yes",
    "vx.user": "alice",
    "vx.project": "app",
    "vx.volume": "state"
  }
}]
EOF
export VX_COMPOSE_DOCKER_BIN="$fake_docker"
vx_compose_volume_inspect alice app state >/dev/null \
    || fail "managed volume inspection failed"
vx_compose_volume_export alice app state "$test_root/state.tar.gz"
[[ -s "$test_root/state.tar.gz" ]] || fail "managed volume export was not created"
grep -Fq 'ARG=--network' "$docker_log" || fail "volume helper network was not disabled"
grep -Fq 'ARG=none' "$docker_log" || fail "volume helper network mode is wrong"
grep -Fq 'ARG=--cap-drop' "$docker_log" || fail "volume helper capabilities were not dropped"
grep -Fq "ARG=$VX_COMPOSE_VOLUME_HELPER_IMAGE" "$docker_log" \
    || fail "pinned volume helper image was not used"
if grep -Eqi 'prune|/var/lib/docker|docker.sock' "$docker_log"; then
    fail "volume operation escaped its explicit managed target"
fi

echo "Compose volume policy tests passed."
