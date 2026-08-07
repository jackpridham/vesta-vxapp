#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/install/common/sudo/vesta-compose-users"
mirror="$repo_root/example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users"
installer="$repo_root/bin/v-install-docker-shell-access"
fail() { echo "FAIL: $*" >&2; exit 1; }

cmp -s "$policy" "$mirror" || fail 'canonical and synthetic sudo policies differ'
[[ "$(wc -l <"$policy")" == 5 ]] || fail 'sudo policy has an unexpected rule count'
grep -Fxq 'Defaults:%vesta-compose-users env_reset' "$policy" || fail 'env_reset is missing'
grep -Fxq 'Defaults:%vesta-compose-users !setenv' "$policy" || fail '!setenv is missing'
grep -Fxq 'Defaults:%vesta-compose-users secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$policy" || fail 'secure_path is not exact'
grep -Fxq '%vesta-compose-users ALL=(root) NOPASSWD:NOSETENV: /usr/local/vesta/bin/v-run-user-docker-command *' "$policy" || fail 'broker grant is not exact'
grep -Fq 'env_delete += "VESTA BASH_ENV ENV CDPATH GLOBIGNORE BASHOPTS SHELLOPTS PYTHONPATH PYTHONHOME LD_PRELOAD LD_LIBRARY_PATH DOCKER_HOST DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME"' "$policy" || fail 'dangerous environment deletion is incomplete'
if grep -Eqi 'log_input|(^|[^O])SETENV:|/bin/(ba)?sh|/usr/bin/(docker|env|python|perl|ruby|cp|vi|vim)|docker\.sock|%docker|/usr/local/vesta/bin/v-docker' "$policy"; then
    fail 'sudo policy grants a forbidden surface'
fi
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$policy" >/dev/null || fail 'visudo rejected canonical policy'
else
    echo 'SKIP: visudo parser unavailable'
fi

grep -Fq '/usr/sbin/groupadd --system "$group"' "$installer" || fail 'system group creation is not exact'
! grep -Eq 'groupadd[^#\n]* (-g|--gid)' "$installer" || fail 'installer fixes a GID'
grep -Fq '/usr/sbin/visudo -cf "$temp"' "$installer" || fail 'staged policy is not validated'
grep -Fq '/usr/bin/mv -fT -- "$temp" "$target_policy"' "$installer" || fail 'policy is not atomically renamed'
grep -Fq '/usr/bin/install -m 0440 -o root -g root' "$installer" || fail 'staged policy ownership/mode is not exact'
grep -Fq 'v-sync-docker-shell-access-all' "$installer" || fail 'normal install does not reconcile users'

for file in install/vst-install-debian.sh install/vst-install-ubuntu.sh install/vst-install-rhel.sh install/vst-install-amazon.sh src/deb/vesta/postinst src/rpm/specs/vesta.spec bin/v-install-docker-service; do
    grep -Fq 'v-install-docker-shell-access' "$repo_root/$file" || fail "$file omits shell-access installation"
done

echo 'Compose shell-access installation tests passed.'
