#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/data/users/alice" "$fixture/data/users/bob"
VESTA="$fixture"
HOMEDIR=/home
source "$repo_root/func/vx/compose/common.sh"
source "$repo_root/func/vx/compose/storage.sh"
source "$repo_root/func/vx/compose/package.sh"
source "$repo_root/func/vx/compose/shell-access.sh"

fail() { echo "FAIL: $1" >&2; exit 1; }
vx_compose_shell_effective_uid() { printf '0\n'; }
vx_compose_shell_passwd_by_uid() { printf '%s:x:%s:1101:Alice:/home/%s:/bin/%s\n' "$test_passwd_actor" "$test_passwd_uid" "$test_passwd_actor" "$test_passwd_shell"; }
vx_compose_shell_passwd_by_name() { printf '%s:x:1101:1101:Alice:/home/%s:/bin/%s\n' "$1" "$1" "$test_passwd_shell"; }
vx_compose_shell_actor_uid() { printf '1101\n'; }
vx_compose_shell_actor_gids() { printf '1101\n'; }
vx_compose_shell_groups() { printf '%s\n' "$test_groups"; }
vx_compose_authority_uid() { stat -c '%u' "$fixture"; }

write_conf() {
    local actor="$1" shell="$2" suspended="$3" limit="$4"
    printf "SUSPENDED='%s'\nSHELL='%s'\nDOCKER_PROJECTS='%s'\n" "$suspended" "$shell" "$limit" >"$fixture/data/users/$actor/user.conf"
    chmod 0600 "$fixture/data/users/$actor/user.conf"
}

expect_allow() {
    local actor="$1" uid="$2" shell="$3" suspended="$4" limit="$5"
    test_passwd_actor=$actor test_passwd_uid=$uid test_passwd_shell=$shell test_groups="users $VX_COMPOSE_SHELL_GROUP"
    export SUDO_USER="$actor" SUDO_UID="$uid" SUDO_GID=1101
    write_conf "$actor" "$shell" "$suspended" "$limit"
    [[ "$(vx_compose_shell_actor_resolve)" == "$actor" ]] || fail "actor resolve denied $actor"
    vx_compose_shell_require_eligible "$actor" || fail "eligibility denied $actor/$limit"
}

expect_deny() {
    local actor="$1" uid="$2" shell="$3" suspended="$4" limit="$5"
    test_passwd_actor=$actor test_passwd_uid=$uid test_passwd_shell=$shell test_groups="users $VX_COMPOSE_SHELL_GROUP"
    [[ "$actor" != bob ]] || test_passwd_actor=alice
    export SUDO_USER="$actor" SUDO_UID="$uid" SUDO_GID=1101
    [[ -d "$fixture/data/users/$actor" ]] && write_conf "$actor" "$shell" "$suspended" "$limit"
    if [[ "$actor" == admin || "$actor" == root || "$actor" == bob ]]; then
        ! vx_compose_shell_actor_resolve >/dev/null 2>&1 || fail "actor resolve allowed $actor"
    else
        ! vx_compose_shell_require_eligible "$actor" >/dev/null 2>&1 || fail "eligibility allowed $actor/$limit"
    fi
}

expect_allow alice 1101 bash no 2
expect_allow alice 1101 bash no unlimited
expect_deny alice 1101 bash no 0
expect_deny alice 1101 nologin no 2
expect_deny alice 1101 bash yes 2
expect_deny bob 1101 bash no 2
expect_deny admin 1000 bash no unlimited
expect_deny malformed 1101 bash no '$(touch /tmp/canary)'
[[ ! -e /tmp/canary ]] || fail 'command-substitution canary executed'

write_conf alice bash no 2
ln -sf user.conf "$fixture/data/users/alice/linked.conf"
mv "$fixture/data/users/alice/user.conf" "$fixture/data/users/alice/real.conf"
ln -s real.conf "$fixture/data/users/alice/user.conf"
! vx_compose_shell_require_eligible alice >/dev/null 2>&1 || fail 'linked user.conf accepted'
rm "$fixture/data/users/alice/user.conf"; mv "$fixture/data/users/alice/real.conf" "$fixture/data/users/alice/user.conf"
chmod 0666 "$fixture/data/users/alice/user.conf"
! vx_compose_shell_require_eligible alice >/dev/null 2>&1 || fail 'actor-writable user.conf accepted'

test_passwd_actor=bob test_passwd_uid=1101 test_passwd_shell=bash
export SUDO_USER=alice SUDO_UID=1101 SUDO_GID=1101
! vx_compose_shell_actor_resolve >/dev/null 2>&1 || fail 'forged SUDO_USER accepted'
unset SUDO_USER SUDO_UID SUDO_GID
! vx_compose_shell_actor_resolve >/dev/null 2>&1 || fail 'root without sudo caller accepted'
vx_compose_shell_effective_uid() { printf '1101\n'; }
! vx_compose_shell_actor_resolve >/dev/null 2>&1 || fail 'direct non-root invocation accepted'

grep -Fq 'exec /usr/bin/sudo -n -- /usr/local/vesta/bin/v-run-user-docker-command "$@"' "$repo_root/bin/v-docker" || fail 'thin client changed'
grep -Fq 'v-run-docker-project-action "$actor" "$actor" "$1" "$operation"' "$repo_root/bin/v-run-user-docker-command" || fail 'lifecycle mapping missing'
grep -Fq 'v-run-docker-project-probe "$actor" "$actor" "$1" "$2" "$format"' "$repo_root/bin/v-run-user-docker-command" || fail 'probe mapping missing'

echo 'Compose shell access tests passed.'
