#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="$repo_root/install/common/sudo/vesta-compose-users"
mirror="$repo_root/example-of-linux-root-folder/etc/sudoers.d/vesta-compose-users"
installer="$repo_root/bin/v-install-docker-shell-access"
fail() { echo "FAIL: $*" >&2; exit 1; }
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

cmp -s "$policy" "$mirror" || fail 'canonical and synthetic sudo policies differ'
[[ "$(wc -l <"$policy")" == 5 ]] || fail 'sudo policy has an unexpected rule count'
grep -Fxq 'Defaults:%vesta-compose-users env_reset' "$policy" || fail 'env_reset is missing'
grep -Fxq 'Defaults:%vesta-compose-users !setenv' "$policy" || fail '!setenv is missing'
grep -Fxq 'Defaults:%vesta-compose-users secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$policy" || fail 'secure_path is not exact'
grep -Fxq '%vesta-compose-users ALL=(root) NOPASSWD:NOSETENV: /usr/local/vesta/bin/v-run-user-docker-command *' "$policy" || fail 'broker grant is not exact'
grep -Fq 'env_keep -= "VESTA BASH_ENV ENV CDPATH GLOBIGNORE BASHOPTS SHELLOPTS PYTHONPATH PYTHONHOME LD_PRELOAD LD_LIBRARY_PATH DOCKER_HOST DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME", env_delete += "VESTA BASH_ENV ENV CDPATH GLOBIGNORE BASHOPTS SHELLOPTS PYTHONPATH PYTHONHOME LD_PRELOAD LD_LIBRARY_PATH DOCKER_HOST DOCKER_CONFIG COMPOSE_FILE COMPOSE_PROJECT_NAME"' "$policy" || fail 'dangerous environment removal is incomplete'
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
grep -Fq '/usr/bin/mv -fT -- "$client_stage" "$client_link"' "$installer" || fail 'client link is not atomically renamed'
grep -Fq 'v-sync-docker-shell-access-all' "$installer" || fail 'normal install does not reconcile users'
grep -Fq '[[ -x /usr/bin/getfacl ]]' "$installer" || fail 'installer does not require ACL inspection'
grep -Fq 'Depends: acl,' "$repo_root/src/deb/vesta/control" || fail 'Debian package omits ACL dependency'
for release in 10 11 12 13; do
    release_block="$(sed -n "/if \[ \"\$release\" -eq $release \]/,/^elif \|^fi$/p" "$repo_root/install/vst-install-debian.sh")"
    grep -Eq '(^|[[:space:]])acl([[:space:]]|$)' <<<"$release_block" \
        || fail "Debian $release installer omits ACL package"
done

for file in install/vst-install-debian.sh install/vst-install-ubuntu.sh install/vst-install-rhel.sh install/vst-install-amazon.sh src/deb/vesta/postinst src/rpm/specs/vesta.spec bin/v-install-docker-service; do
    grep -Fq 'v-install-docker-shell-access' "$repo_root/$file" || fail "$file omits shell-access installation"
done

# Execute installer mutation/failure paths in an unprivileged user+mount
# namespace. UID 0 exists only inside the namespace; host /etc and /usr remain
# read-only and the exact mutable targets are temporary bind mounts.
if command -v bwrap >/dev/null 2>&1 \
    && bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / /usr/bin/true 2>/dev/null; then
    ns="$test_root/ns"
    mkdir -p "$ns/usr-local/vesta/bin" "$ns/usr-local/vesta/install/common/sudo" "$ns/usr-local/bin" "$ns/sudoers" "$ns/tools"
    cp "$repo_root/bin/v-install-docker-shell-access" "$ns/usr-local/vesta/bin/"
    sed -i 's/\[\[ "$owner" == 0 &&/[[ ( "$owner" == 0 || "$owner" == 65534 ) \&\&/' \
        "$ns/usr-local/vesta/bin/v-install-docker-shell-access"
    cp "$repo_root/bin/v-run-user-docker-command" "$repo_root/bin/v-docker" "$ns/usr-local/vesta/bin/"
    cp "$policy" "$ns/usr-local/vesta/install/common/sudo/vesta-compose-users"
    chmod 0755 "$ns/usr-local/vesta/bin/"*; chmod 0644 "$ns/usr-local/vesta/install/common/sudo/vesta-compose-users"
    printf 'root:x:0:\n' >"$ns/group"
    cat >"$ns/tools/getent" <<'EOF'
#!/usr/bin/env bash
[[ ! -e /mnt/getent.fail ]] || exit 3
awk -F: -v name="$2" '$1 == name { print; found=1 } END { exit !found }' /etc/group
EOF
    cat >"$ns/tools/groupadd" <<'EOF'
#!/usr/bin/env bash
printf 'groupadd %s\n' "$*" >>/mnt/actions
printf 'vesta-compose-users:x:991:\n' >>/etc/group
EOF
    cat >"$ns/tools/visudo" <<'EOF'
#!/usr/bin/env bash
printf 'visudo %s\n' "$*" >>/mnt/actions
[[ ! -e /mnt/visudo.fail ]] && grep -Fq 'v-run-user-docker-command *' "$2"
EOF
    cp /usr/bin/mv "$ns/real-mv"
    cat >"$ns/tools/mv" <<'EOF'
#!/usr/bin/env bash
destination="${@: -1}"
if [[ -e /mnt/client-mv.fail && "$destination" == /usr/local/bin/v-docker ]]; then
    exit 1
fi
exec /mnt/real-mv "$@"
EOF
    cat >"$ns/usr-local/vesta/bin/v-sync-docker-shell-access-all" <<'EOF'
#!/usr/bin/env bash
printf 'sync\n' >>/mnt/actions
[[ ! -e /mnt/sync.fail ]]
EOF
    chmod 0755 "$ns/tools/"* "$ns/usr-local/vesta/bin/v-sync-docker-shell-access-all"
    cat >"$ns/runner" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
installer=/usr/local/vesta/bin/v-install-docker-shell-access
policy=/etc/sudoers.d/vesta-compose-users
: >/mnt/actions
"$installer" defer
grep -Fq 'groupadd --system vesta-compose-users' /mnt/actions
! grep -Fq sync /mnt/actions
[[ "$(stat -c '%u:%g:%a' "$policy")" == 0:0:440 ]]
first=$(sha256sum "$policy")
"$installer" defer
[[ "$(sha256sum "$policy")" == "$first" ]]
"$installer"
grep -Fq sync /mnt/actions
chmod 0640 "$policy"
printf '# preserved prior policy\n' >>"$policy"
chmod 0440 "$policy"
cp "$policy" /mnt/previous
prior_link=$(readlink /usr/local/bin/v-docker)
touch /mnt/client-mv.fail
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous "$policy"
[[ "$(readlink /usr/local/bin/v-docker)" == "$prior_link" ]]
rm /mnt/client-mv.fail
touch /mnt/sync.fail
! "$installer" >/dev/null 2>&1
cmp /mnt/previous "$policy"
[[ "$(readlink /usr/local/bin/v-docker)" == "$prior_link" ]]
rm /mnt/sync.fail
rm /usr/local/bin/v-docker
touch /mnt/sync.fail
! "$installer" >/dev/null 2>&1
cmp /mnt/previous "$policy"
[[ ! -e /usr/local/bin/v-docker && ! -L /usr/local/bin/v-docker ]]
rm /mnt/sync.fail
"$installer" defer
rm /mnt/previous
cp "$policy" /mnt/previous
chmod 0666 /usr/local/vesta/install/common/sudo/vesta-compose-users
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous "$policy"
chmod 0644 /usr/local/vesta/install/common/sudo/vesta-compose-users
mv /usr/local/vesta/install/common/sudo/vesta-compose-users /mnt/source
ln -s /mnt/source /usr/local/vesta/install/common/sudo/vesta-compose-users
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous "$policy"
rm /usr/local/vesta/install/common/sudo/vesta-compose-users
mv /mnt/source /usr/local/vesta/install/common/sudo/vesta-compose-users
chmod 0644 /usr/local/vesta/install/common/sudo/vesta-compose-users
chmod 0666 "$policy"
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous "$policy"
chmod 0440 "$policy"
touch /mnt/visudo.fail
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous "$policy"
rm /mnt/visudo.fail
ln -s /mnt/previous /mnt/linked-target
rm "$policy"; ln -s /mnt/linked-target "$policy"
! "$installer" defer >/dev/null 2>&1
cmp /mnt/previous /mnt/linked-target
EOF
    chmod 0755 "$ns/runner"
    bwrap --unshare-user --uid 0 --gid 0 --unshare-pid --unshare-net --die-with-parent \
        --ro-bind / / --dev /dev --tmpfs /tmp \
        --bind "$ns/usr-local" /usr/local \
        --bind "$ns/sudoers" /etc/sudoers.d \
        --bind "$ns/group" /etc/group \
        --bind "$ns/tools/getent" /usr/bin/getent \
        --bind "$ns/tools/groupadd" /usr/sbin/groupadd \
        --bind "$ns/tools/visudo" /usr/sbin/visudo \
        --bind "$ns/tools/mv" /usr/bin/mv \
        --bind "$ns" /mnt /mnt/runner
else
    echo 'SKIP: bubblewrap user namespace unavailable for executable installer failure paths'
fi

# Execute the one-user reconciler against fake fixed tools. Lookup errors must
# never reach either mutation tool.
fake_vesta="$test_root/vesta"
fake_bin="$test_root/tools"
mkdir -p "$fake_vesta/func/vx/compose" "$fake_vesta/bin" "$fake_bin"
cat >"$fake_vesta/func/vx/compose/main.sh" <<'EOF'
vx_compose_shell_access_lock_acquire() { :; }
vx_compose_shell_access_lock_release() { :; }
vx_compose_shell_should_be_group_member() {
    [[ "$1" == alice && "$(cat "$VX_TEST_ELIGIBLE")" == yes ]]
}
vx_compose_shell_group_state() {
    local groups
    groups="$("$VX_TEST_ID" -nG "$1")" || return 2
    [[ " $groups " == *' vesta-compose-users '* ]] && return 0
    return 1
}
EOF
cat >"$fake_bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$VX_TEST_GETENT_ERROR" ]] || exit 3
printf 'vesta-compose-users:x:991:%s\n' "$(cat "$VX_TEST_MEMBERSHIP")"
EOF
cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ ! -e "$VX_TEST_ID_ERROR" ]] || exit 4
user=${@: -1}
members=$(cat "$VX_TEST_MEMBERSHIP")
if [[ ",$members," == *",$user,"* ]]; then printf 'users vesta-compose-users\n'; else printf 'users\n'; fi
EOF
cat >"$fake_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod %s\n' "$*" >>"$VX_TEST_MUTATIONS"
user=${@: -1}; current=$(cat "$VX_TEST_MEMBERSHIP")
[[ -z "$current" ]] && printf '%s\n' "$user" >"$VX_TEST_MEMBERSHIP" || printf '%s,%s\n' "$current" "$user" >"$VX_TEST_MEMBERSHIP"
EOF
cat >"$fake_bin/gpasswd" <<'EOF'
#!/usr/bin/env bash
printf 'gpasswd %s\n' "$*" >>"$VX_TEST_MUTATIONS"
user=$2
awk -v user="$user" -v RS=, -v ORS=, '$0 != user { print }' "$VX_TEST_MEMBERSHIP" | sed 's/,$//' >"$VX_TEST_MEMBERSHIP.new"
mv "$VX_TEST_MEMBERSHIP.new" "$VX_TEST_MEMBERSHIP"
EOF
chmod 0755 "$fake_bin"/*
sed \
    -e 's/\[\[ "$EUID" == 0 \]\]/true/' \
    -e "s#/usr/bin/getent#$fake_bin/getent#g" \
    -e "s#/usr/sbin/usermod#$fake_bin/usermod#g" \
    -e "s#/usr/bin/gpasswd#$fake_bin/gpasswd#g" \
    "$repo_root/bin/v-sync-docker-shell-access" >"$fake_vesta/bin/v-sync-docker-shell-access"
chmod 0755 "$fake_vesta/bin/v-sync-docker-shell-access"
export VX_TEST_ID="$fake_bin/id" VX_TEST_ID_ERROR="$test_root/id.error"
export VX_TEST_GETENT_ERROR="$test_root/getent.error" VX_TEST_MUTATIONS="$test_root/mutations"
export VX_TEST_MEMBERSHIP="$test_root/membership" VX_TEST_ELIGIBLE="$test_root/eligible"
printf 'yes\n' >"$VX_TEST_ELIGIBLE"; : >"$VX_TEST_MEMBERSHIP"
VESTA="$fake_vesta" "$fake_vesta/bin/v-sync-docker-shell-access" alice
grep -Fq 'usermod -a -G vesta-compose-users -- alice' "$VX_TEST_MUTATIONS" || fail 'eligible user was not added exactly once'
: >"$VX_TEST_MUTATIONS"; touch "$VX_TEST_ID_ERROR"
if VESTA="$fake_vesta" "$fake_vesta/bin/v-sync-docker-shell-access" alice >/dev/null 2>&1; then fail 'id failure was accepted'; fi
[[ ! -s "$VX_TEST_MUTATIONS" ]] || fail 'id failure reached a mutation tool'
rm -f "$VX_TEST_ID_ERROR"; touch "$VX_TEST_GETENT_ERROR"
if VESTA="$fake_vesta" "$fake_vesta/bin/v-sync-docker-shell-access" alice >/dev/null 2>&1; then fail 'getent failure was accepted'; fi
[[ ! -s "$VX_TEST_MUTATIONS" ]] || fail 'getent failure reached a mutation tool'
rm -f "$VX_TEST_GETENT_ERROR"
mkdir -p "$fake_vesta/data/users/alice"
printf "SUSPENDED='no'\n" >"$fake_vesta/data/users/alice/user.conf"
test_uid=$(id -u); test_gid=$(id -g)
sed \
    -e 's/\[\[ "$EUID" == 0 \]\]/true/' \
    -e "s#/usr/bin/getent#$fake_bin/getent#g" \
    -e "s#/usr/bin/gpasswd#$fake_bin/gpasswd#g" \
    -e "s#/usr/bin/install -d -m 0700 -o root -g root#/usr/bin/install -d -m 0700#g" \
    -e "s/0:0:700:directory/$test_uid:$test_gid:700:directory/g" \
    -e "s/0:0:600/$test_uid:$test_gid:600/g" \
    "$repo_root/bin/v-sync-docker-shell-access-all" >"$fake_vesta/bin/v-sync-docker-shell-access-all"
chmod 0755 "$fake_vesta/bin/v-sync-docker-shell-access-all"
printf 'alice,Manual.User,stale-user,bad!name\n' >"$VX_TEST_MEMBERSHIP"
: >"$VX_TEST_MUTATIONS"
if VESTA="$fake_vesta" VX_COMPOSE_RECONCILE_LOCK_ROOT="$test_root/locks" \
    "$fake_vesta/bin/v-sync-docker-shell-access-all" >"$test_root/full.out"; then
    fail 'malformed manual member was silently accepted'
fi
grep -Fq 'gpasswd -d Manual.User -- vesta-compose-users' "$VX_TEST_MUTATIONS" \
    || fail 'uppercase/dot manual member was not revoked'
grep -Fq 'gpasswd -d stale-user -- vesta-compose-users' "$VX_TEST_MUTATIONS" || fail 'hyphenated stale member was not revoked'
[[ "$(cat "$VX_TEST_MEMBERSHIP")" == *bad!name* ]] || fail 'malformed member was mutated unsafely'
printf 'alice\n' >"$VX_TEST_MEMBERSHIP"; : >"$VX_TEST_MUTATIONS"
VESTA="$fake_vesta" VX_COMPOSE_RECONCILE_LOCK_ROOT="$test_root/locks" \
    "$fake_vesta/bin/v-sync-docker-shell-access-all" >"$test_root/full-idempotent.out"
[[ ! -s "$VX_TEST_MUTATIONS" ]] || fail 'idempotent full sync performed a mutation'
grep -Eq '^added=0 removed=0 unchanged=1 failed=0$' "$test_root/full-idempotent.out" || fail 'idempotent counts are incorrect'
touch "$VX_TEST_GETENT_ERROR"; : >"$VX_TEST_MUTATIONS"
if VESTA="$fake_vesta" VX_COMPOSE_RECONCILE_LOCK_ROOT="$test_root/locks" \
    "$fake_vesta/bin/v-sync-docker-shell-access-all" >/dev/null 2>&1; then
    fail 'full reconciliation suppressed getent failure'
fi
[[ ! -s "$VX_TEST_MUTATIONS" ]] || fail 'full getent failure reached a mutation tool'

echo 'Compose shell-access installation tests passed.'
