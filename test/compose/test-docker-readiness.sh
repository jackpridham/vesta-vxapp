#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

real_jq="$(command -v jq)"
fake_bin="$test_root/bin"
state_dir="$test_root/state"
fake_vesta="$test_root/vesta"
apt_root="$test_root/etc/apt"
systemd_root="$test_root/etc/systemd/system"
installer_under_test="$test_root/v-install-docker-service"
test_uid="$(id -u)"
test_gid="$(id -g)"
mkdir -p "$fake_bin" "$state_dir" "$fake_vesta/func" "$fake_vesta/conf" \
    "$fake_vesta/bin" "$fake_vesta/install/common/systemd/docker.service.d" \
    "$systemd_root"
cat >"$fake_vesta/bin/v-prepare-docker-compose-data-roots" <<'EOF'
#!/usr/bin/env bash
printf 'prepare %s\n' "$*" >>"$VX_TEST_STATE/lifecycle.log"
[[ "$*" == migrate ]]
EOF
chmod 0755 "$fake_vesta/bin/v-prepare-docker-compose-data-roots"
sed \
    -e "s#systemd_root=/etc/systemd/system#systemd_root=$systemd_root#" \
    -e "s/install -o 0 -g 0/install -o $test_uid -g $test_gid/" \
    "$repo_root/bin/v-install-docker-compose-mount-guard" \
    >"$fake_vesta/bin/v-install-docker-compose-mount-guard"
chmod 0755 "$fake_vesta/bin/v-install-docker-compose-mount-guard"
cp "$repo_root/install/common/systemd/vesta-compose-data-roots.service" \
    "$fake_vesta/install/common/systemd/"
cp "$repo_root/install/common/systemd/docker.service.d/vesta-compose-data-roots.conf" \
    "$fake_vesta/install/common/systemd/docker.service.d/"

sed \
    -e "s#/etc/apt/keyrings#$apt_root/keyrings#g" \
    -e "s#/etc/apt/sources.list.d#$apt_root/sources.list.d#g" \
    -e "s/install -o 0 -g 0/install -o $test_uid -g $test_gid/" \
    -e "s/0:0:755/$test_uid:$test_gid:755/g" \
    -e "s/0:0:644/$test_uid:$test_gid:644/g" \
    "$repo_root/bin/v-install-docker-service" >"$installer_under_test"
chmod 0755 "$installer_under_test"

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1-} ${2-}" in
    '--version ') [[ -f "$VX_TEST_STATE/docker" ]] ;;
    'compose version') [[ -f "$VX_TEST_STATE/compose" ]] ;;
    'info ') [[ -f "$VX_TEST_STATE/daemon" ]] ;;
    *) exit 1 ;;
esac
EOF

cat >"$fake_bin/jq" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = '--version' && -f "$VX_TEST_STATE/jq" ]]
EOF

cat >"$fake_bin/age" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = '--version' && -f "$VX_TEST_STATE/age" ]]
EOF

cat >"$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = '--version' && -f "$VX_TEST_STATE/python3" ]]
EOF

cat >"$fake_bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = 'show' ]] || exit 1
case "${2-}" in
    docker-compose-plugin)
        [[ -f "$VX_TEST_STATE/docker-repo" ]]
        ;;
    docker.io|docker-compose|jq|age|python3)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat >"$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VX_TEST_STATE/apt.log"
[[ "${1-}" = 'update' ]] && exit 0
[[ "${1-}" = 'install' ]] || exit 1
for package in "$@"; do
    case "$package" in
        docker.io)
            touch "$VX_TEST_STATE/docker"
            ;;
        docker-compose|docker-compose-plugin)
            if [[ "$package" = 'docker-compose-plugin' ]]; then
                touch "$VX_TEST_STATE/compose"
            else
                touch "$VX_TEST_STATE/legacy-compose"
            fi
            ;;
        jq)
            touch "$VX_TEST_STATE/jq"
            ;;
        age)
            if [[ "${VX_TEST_WITHHOLD_AGE:-no}" != 'yes' ]]; then
                touch "$VX_TEST_STATE/age"
            fi
            ;;
        python3)
            if [[ "${VX_TEST_WITHHOLD_PYTHON3:-no}" != 'yes' ]]; then
                touch "$VX_TEST_STATE/python3"
            fi
            ;;
    esac
done
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" = *'https://download.docker.com/linux/debian/gpg'* ]] || exit 1
output=
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -o && "$#" -ge 2 ]]; then
        output="$2"
        break
    fi
    shift
done
[[ -n "$output" ]] || exit 1
printf '%s\n' 'fake Docker signing key' >"$output"
touch "$VX_TEST_STATE/docker-repo"
EOF

cat >"$fake_bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = '--print-architecture' ]] || exit 1
echo amd64
EOF

cat >"$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
/usr/bin/install "$@"
EOF

cat >"$fake_bin/lsb_release" <<'EOF'
#!/usr/bin/env bash
[[ "${1-}" = '-sc' ]] || exit 1
echo bookworm
EOF

cat >"$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
/usr/bin/chmod "$@"
EOF

cat >"$fake_bin/tee" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF

cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VX_TEST_STATE/systemctl.log"
printf 'systemctl %s\n' "$*" >>"$VX_TEST_STATE/lifecycle.log"
if [[ "$*" == 'is-active --quiet vesta-compose-data-roots.service' ]]; then
    [[ -f "$VX_TEST_STATE/guard-active" ]]
    exit
fi
if [[ "$*" == 'start vesta-compose-data-roots.service'
    && "${VX_TEST_FAIL_MOUNT_GUARD:-no}" == yes ]]; then
    exit 1
fi
[[ "$*" == 'start vesta-compose-data-roots.service' ]] \
    && touch "$VX_TEST_STATE/guard-active"
[[ "$*" == 'enable --now docker' ]] && touch "$VX_TEST_STATE/daemon"
exit 0
EOF

chmod +x "$fake_bin"/*
touch "$fake_vesta/func/docker.sh" "$fake_vesta/conf/vesta.conf"
cat >"$fake_vesta/func/main.sh" <<'EOF'
E_INVALID=3
check_result() {
    return "$1"
}
EOF

export VX_TEST_STATE="$state_dir"
export PATH="$fake_bin:$PATH"
export VESTA="$fake_vesta"

mkdir -p "$apt_root/keyrings" "$apt_root/sources.list.d"
unsafe_key_target="$test_root/unsafe-key-target"
printf '%s\n' 'key target must remain unchanged' >"$unsafe_key_target"
printf '%s\n' 'unsafe existing source' >"$apt_root/sources.list.d/docker.list"
chmod 0666 "$unsafe_key_target" "$apt_root/sources.list.d/docker.list"
ln -s "$unsafe_key_target" "$apt_root/keyrings/docker.asc"

touch "$state_dir/docker" "$state_dir/daemon"
"$installer_under_test" >/dev/null

cmp "$repo_root/install/common/systemd/vesta-compose-data-roots.service" \
    "$systemd_root/vesta-compose-data-roots.service"
cmp "$repo_root/install/common/systemd/docker.service.d/vesta-compose-data-roots.conf" \
    "$systemd_root/docker.service.d/vesta-compose-data-roots.conf"
grep -Fq 'Before=docker.service containerd.service' \
    "$systemd_root/vesta-compose-data-roots.service"
grep -Fq 'Requires=vesta-compose-data-roots.service' \
    "$systemd_root/docker.service.d/vesta-compose-data-roots.conf"
grep -Fq 'After=vesta-compose-data-roots.service' \
    "$systemd_root/docker.service.d/vesta-compose-data-roots.conf"
grep -Fq 'daemon-reload' "$state_dir/systemctl.log"
grep -Fq 'enable vesta-compose-data-roots.service' \
    "$state_dir/systemctl.log"
grep -Fq 'start vesta-compose-data-roots.service' \
    "$state_dir/systemctl.log"
[[ "$(sed -n '1p' "$state_dir/lifecycle.log")" == 'prepare migrate' ]] \
    || { echo "mount migration did not precede systemd activation" >&2; exit 1; }
start_count="$(
    grep -Fc 'start vesta-compose-data-roots.service' \
        "$state_dir/systemctl.log"
)"
prepare_count="$(grep -Fc 'prepare migrate' "$state_dir/lifecycle.log")"
VESTA="$fake_vesta" \
    "$fake_vesta/bin/v-install-docker-compose-mount-guard" defer >/dev/null
[[ "$(
    grep -Fc 'start vesta-compose-data-roots.service' \
        "$state_dir/systemctl.log"
)" == "$start_count" ]] \
    || { echo "deferred mount-guard installation activated the unit" >&2; exit 1; }
[[ "$(grep -Fc 'prepare migrate' "$state_dir/lifecycle.log")" \
    == "$prepare_count" ]] \
    || { echo "deferred mount-guard installation migrated data" >&2; exit 1; }
VESTA="$fake_vesta" \
    "$fake_vesta/bin/v-install-docker-compose-mount-guard" >/dev/null
[[ "$(grep -Fc 'start vesta-compose-data-roots.service' \
    "$state_dir/systemctl.log")" == "$start_count" ]] \
    || { echo "active mount guard was stopped during upgrade" >&2; exit 1; }
rm -f "$state_dir/guard-active"
if VX_TEST_FAIL_MOUNT_GUARD=yes "$installer_under_test" \
    >"$test_root/guard-failure.out" 2>&1; then
    echo "installer continued after mount-guard preparation failed" >&2
    exit 1
fi
grep -Fq 'unable to establish protected Compose data-root mounts' \
    "$test_root/guard-failure.out"

for tool_state in docker daemon compose jq age python3; do
    [[ -f "$state_dir/$tool_state" ]] \
        || { echo "installer did not establish $tool_state readiness" >&2; exit 1; }
done
grep -Fq 'docker-compose' "$state_dir/apt.log"
grep -Fq 'docker-compose-plugin' "$state_dir/apt.log"
[[ -f "$state_dir/legacy-compose" && -f "$state_dir/docker-repo" ]]
grep -Fq 'jq' "$state_dir/apt.log"
grep -Fq 'age' "$state_dir/apt.log"
grep -Fq 'python3' "$state_dir/apt.log"
[[ -f "$apt_root/keyrings/docker.asc"
    && ! -L "$apt_root/keyrings/docker.asc"
    && "$(stat -c '%a' "$apt_root/keyrings/docker.asc")" == 644 ]] \
    || { echo "installer did not atomically repair the Docker apt key" >&2; exit 1; }
[[ -f "$apt_root/sources.list.d/docker.list"
    && ! -L "$apt_root/sources.list.d/docker.list"
    && "$(stat -c '%a' "$apt_root/sources.list.d/docker.list")" == 644 ]] \
    || { echo "installer did not atomically repair the Docker apt source" >&2; exit 1; }
grep -Fqx 'key target must remain unchanged' "$unsafe_key_target"
grep -Fq 'signed-by='"$apt_root/keyrings/docker.asc" \
    "$apt_root/sources.list.d/docker.list"
if find "$apt_root" -type f \
    \( -name '.docker.asc.*' -o -name '.docker.list.*' \) \
    -print -quit | grep -q .; then
    echo "installer retained an apt repository temporary file" >&2
    exit 1
fi
if rg -n 'api\.github\.com|releases/latest|wget|docker-compose-linux' \
    "$repo_root/bin/v-install-docker-service"; then
    echo "installer still references a downloaded tool binary" >&2
    exit 1
fi

readiness_json="$("$repo_root/bin/v-check-docker-engine" json)"
for key in \
    DOCKER_AVAILABLE \
    DOCKER_DAEMON_AVAILABLE \
    DOCKER_COMPOSE_AVAILABLE \
    JQ_AVAILABLE \
    AGE_AVAILABLE \
    PYTHON3_AVAILABLE \
    DOCKER_ORCHESTRATION_READY
do
    [[ "$(printf '%s' "$readiness_json" | "$real_jq" -r --arg key "$key" '.[$key]')" = 'yes' ]] \
        || { echo "readiness key $key did not report yes" >&2; exit 1; }
done
[[ "$("$repo_root/bin/v-check-docker-engine" plain)" = 'yes' ]] \
    || { echo "legacy plain readiness output changed" >&2; exit 1; }

rm -f "$state_dir/daemon"
"$installer_under_test" >/dev/null
[[ -f "$state_dir/daemon" ]]
grep -Fq 'enable --now docker' "$state_dir/systemctl.log"

rm -f "$state_dir/age"
not_ready_json="$("$repo_root/bin/v-check-docker-engine" json)"
[[ "$(printf '%s' "$not_ready_json" | "$real_jq" -r '.DOCKER_AVAILABLE')" = 'yes' ]]
[[ "$(printf '%s' "$not_ready_json" | "$real_jq" -r '.DOCKER_ORCHESTRATION_READY')" = 'no' ]]

if VX_TEST_WITHHOLD_AGE=yes "$installer_under_test" >/dev/null 2>&1; then
    echo "installer succeeded without a working age command" >&2
    exit 1
fi

touch "$state_dir/age"
rm -f "$state_dir/python3"
if VX_TEST_WITHHOLD_PYTHON3=yes \
    "$installer_under_test" >/dev/null 2>&1; then
    echo "installer succeeded without a working python3 command" >&2
    exit 1
fi

[[ -x "$repo_root/bin/v-install-docker-service" ]] \
    || { echo "installer is not executable" >&2; exit 1; }

echo "Docker orchestration readiness tests passed."
