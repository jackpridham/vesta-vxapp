#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ "${VX_SHELL_ACCESS_CONTAINER_INNER:-}" != yes ]]; then
    [[ "$EUID" == 0 ]] || { echo 'SKIP: root is required to launch the disposable container'; exit 0; }
    command -v docker >/dev/null 2>&1 || { echo 'SKIP: Docker disposable backend is unavailable'; exit 0; }
    image=${VX_SHELL_ACCESS_ROOT_IMAGE:-}
    [[ -n "$image" ]] || {
        echo 'SKIP: VX_SHELL_ACCESS_ROOT_IMAGE is unset; a disposable image containing bash, sudo, visudo, useradd, getent, jq, and coreutils is required'
        exit 0
    }
    docker image inspect "$image" >/dev/null 2>&1 || { echo "SKIP: disposable image is unavailable: $image"; exit 0; }
    exec docker run --rm --network none --hostname vx-shell-disposable \
        --mount "type=bind,src=$repo_root,dst=/source,readonly" \
        -e VX_SHELL_ACCESS_CONTAINER_INNER=yes \
        --entrypoint /bin/bash "$image" /source/test/compose/test-shell-access-root-integration.sh
fi

[[ "$EUID" == 0 && -f /.dockerenv && "$(hostname)" == vx-shell-disposable ]] \
    || fail 'inner harness is not in the disposable container'
for tool in bash sudo visudo useradd userdel getent jq install; do
    command -v "$tool" >/dev/null 2>&1 || fail "disposable image lacks $tool"
done

cleanup() {
    userdel -r vx-shell-alice >/dev/null 2>&1 || :
    userdel -r vx-shell-bob >/dev/null 2>&1 || :
    rm -rf -- /usr/local/vesta /usr/local/bin/v-docker /etc/sudoers.d/vesta-compose-users /tmp/vx-shell-root-test
}
trap cleanup EXIT
mkdir -p /usr/local
cp -a /source /usr/local/vesta
chown -R root:root /usr/local/vesta
chmod go-w /usr/local/vesta /usr/local/vesta/bin /usr/local/vesta/func /usr/local/vesta/install
useradd -m -s /bin/bash vx-shell-alice
useradd -m -s /bin/bash vx-shell-bob
mkdir -p /tmp/vx-shell-root-test /usr/local/vesta/data/users/{vx-shell-alice,vx-shell-bob}/docker-projects/{app,admin}/runtime
chmod 0700 /tmp/vx-shell-root-test
docker_log=/tmp/vx-shell-root-test/docker.log
: >"$docker_log"

for user in vx-shell-alice vx-shell-bob; do
    cat >"/usr/local/vesta/data/users/$user/user.conf" <<EOF
SUSPENDED='no'
SHELL='bash'
DOCKER_PROJECTS='9'
EOF
    cat >"/usr/local/vesta/data/users/$user/docker-projects/app/project.conf" <<EOF
OWNER='$user'
PROJECT='app'
PROFILE='standard'
EOF
    cat >"/usr/local/vesta/data/users/$user/docker-projects/admin/project.conf" <<EOF
OWNER='$user'
PROJECT='admin'
PROFILE='admin-approved'
EOF
    for project in app admin; do
        : >"/usr/local/vesta/data/users/$user/docker-projects/$project/compose.yaml"
        : >"/usr/local/vesta/data/users/$user/docker-projects/$project/policy.conf"
        printf '{}\n' >"/usr/local/vesta/data/users/$user/docker-projects/$project/runtime/canonical.json"
    done
done
chown -R root:root /usr/local/vesta/data
find /usr/local/vesta/data -type d -exec chmod 0700 {} +
find /usr/local/vesta/data -type f -exec chmod 0600 {} +

cat >/usr/local/vesta/bin/v-list-docker-projects <<'EOF'
#!/usr/bin/env bash
printf 'projects %s\n' "$*" >>/tmp/vx-shell-root-test/docker.log
printf '[]\n'
EOF
cat >/usr/local/vesta/bin/v-list-docker-project-health <<'EOF'
#!/usr/bin/env bash
printf 'health %s\n' "$*" >>/tmp/vx-shell-root-test/docker.log
printf '{}\n'
EOF
cat >/usr/local/vesta/bin/v-run-docker-project-action <<'EOF'
#!/usr/bin/env bash
printf 'action %s\n' "$*" >>/tmp/vx-shell-root-test/docker.log
EOF
chmod 0755 /usr/local/vesta/bin/v-list-docker-projects /usr/local/vesta/bin/v-list-docker-project-health /usr/local/vesta/bin/v-run-docker-project-action
/usr/local/vesta/bin/v-install-docker-shell-access
visudo -cf /etc/sudoers.d/vesta-compose-users >/dev/null

as_alice() { sudo -n -u vx-shell-alice -- "$@"; }
deny_clean() {
    : >"$docker_log"
    if as_alice "$@" >/dev/null 2>&1; then fail "unexpected authorization: $*"; fi
    [[ ! -s "$docker_log" ]] || fail "denial reached fake Docker: $*"
}
as_alice /usr/local/bin/v-docker projects json >/dev/null
as_alice /usr/local/bin/v-docker health app json >/dev/null
as_alice /usr/local/bin/v-docker start app >/dev/null
deny_clean /usr/local/bin/v-docker health admin json
deny_clean /usr/local/bin/v-docker health ../vx-shell-bob/app json
deny_clean sudo -n /usr/bin/docker ps
deny_clean sudo -n /bin/bash -c id
deny_clean sudo -n VESTA=/tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
deny_clean sudo -n BASH_ENV=/tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
deny_clean sudo -n LD_PRELOAD=/tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
deny_clean sudo -n DOCKER_HOST=unix:///tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
deny_clean sudo -n COMPOSE_FILE=/tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
deny_clean sudo -n VX_COMPOSE_DOCKER_BIN=/tmp/evil /usr/local/vesta/bin/v-run-user-docker-command projects json
[[ ! -r /var/run/docker.sock && ! -w /var/run/docker.sock ]] || fail 'tenant can access docker.sock'

sed -i "s/DOCKER_PROJECTS='9'/DOCKER_PROJECTS='0'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
deny_clean /usr/local/bin/v-docker projects json
sed -i "s/DOCKER_PROJECTS='0'/DOCKER_PROJECTS='9'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
sed -i "s/SHELL='bash'/SHELL='nologin'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
deny_clean /usr/local/bin/v-docker projects json
sed -i "s/SHELL='nologin'/SHELL='bash'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
sed -i "s/SUSPENDED='no'/SUSPENDED='yes'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
deny_clean /usr/local/bin/v-docker projects json
sed -i "s/SUSPENDED='yes'/SUSPENDED='no'/" /usr/local/vesta/data/users/vx-shell-alice/user.conf
/usr/local/vesta/bin/v-sync-docker-shell-access vx-shell-alice
as_alice /usr/local/bin/v-docker projects json >/dev/null

sudo -l -U vx-shell-alice | grep -Fq '/usr/local/vesta/bin/v-run-user-docker-command *' \
    || fail 'sudo list omits exact broker'
echo 'Disposable root shell-access integration passed.'
