#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$1"
fixture="$2"
fail() { echo "FAIL: $1" >&2; exit 1; }

mount -t tmpfs tmpfs /usr/local
mount -t tmpfs tmpfs /run/lock
export VESTA=/usr/local/vesta HOMEDIR=/home
mkdir -p /usr/local/vesta/{bin,func/vx,data/users/alice/docker-projects/app/runtime,data/log}
cp -a "$repo_root/func/vx/compose" /usr/local/vesta/func/vx/
cp "$repo_root/bin/v-run-user-docker-command" /usr/local/vesta/bin/
chmod 0755 /usr/local/vesta/bin/v-run-user-docker-command

cat >"$fixture/getent" <<EOF
#!/usr/bin/env bash
case "\$1:\$2" in
  passwd:1101|passwd:alice)
    case "\$(cat '$fixture/passwd-mode')" in
      normal) echo 'alice:x:1101:1101:Alice:/home/alice:/bin/bash' ;;
      uid-mismatch) echo 'alice:x:1102:1101:Alice:/home/alice:/bin/bash' ;;
      actor-mismatch) echo 'bob:x:1101:1101:Bob:/home/bob:/bin/bash' ;;
      nologin) echo 'alice:x:1101:1101:Alice:/home/alice:/usr/sbin/nologin' ;;
    esac ;;
  group:vesta-compose-users) echo 'vesta-compose-users:x:2201:alice' ;;
  *) exit 2 ;;
esac
EOF
cat >"$fixture/id" <<'EOF'
#!/usr/bin/env bash
case "${1-}:${2-}" in
  -u:alice) echo 1101 ;;
  -G:alice) echo '1101 2201' ;;
  -nG:alice) echo 'alice vesta-compose-users' ;;
  -g:) echo 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$fixture/getent" "$fixture/id"
mount --bind "$fixture/getent" /usr/bin/getent
mount --bind "$fixture/id" /usr/bin/id

write_user() {
    local suspended="$1" shell="$2" limit="$3"
    printf "SUSPENDED='%s'\nSHELL='%s'\nDOCKER_PROJECTS='%s'\n" \
        "$suspended" "$shell" "$limit" >/usr/local/vesta/data/users/alice/user.conf
    chmod 0600 /usr/local/vesta/data/users/alice/user.conf
}
write_user no bash 2
printf 'normal\n' >"$fixture/passwd-mode"
cat >/usr/local/vesta/data/users/alice/docker-projects/app/project.conf <<'EOF'
OWNER='alice'
PROJECT='app'
PROFILE='standard'
REVISION='1'
EOF
chmod 0600 /usr/local/vesta/data/users/alice/docker-projects/app/project.conf
: >/usr/local/vesta/data/users/alice/docker-projects/app/compose.yaml
: >/usr/local/vesta/data/users/alice/docker-projects/app/policy.conf
printf '{}\n' >/usr/local/vesta/data/users/alice/docker-projects/app/runtime/canonical.json

cat >"$fixture/fake-command" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s' "\${0##*/}" >>'$fixture/docker.log'
printf ' <%s>' "\$@" >>'$fixture/docker.log'
if [[ -e '$fixture/hold-owner' ]]; then
    : >'$fixture/operation-entered'
    for _ in {1..200}; do
        [[ -e '$fixture/release-operation' ]] && break
        sleep 0.025
    done
    [[ -e '$fixture/release-operation' ]] || exit 70
fi
source /usr/local/vesta/func/vx/compose/main.sh
printf ' actor=%s\n' "\${_VX_COMPOSE_AUDIT_ACTOR-root}" >>'$fixture/docker.log'
vx_compose_owner_audit alice broker-child succeeded 'fixture authoritative event'
EOF
chmod 0755 "$fixture/fake-command"
for command in v-list-docker-projects v-list-docker-project v-run-docker-project-action v-run-docker-project-probe \
    v-backup-docker-project v-add-docker-project-route v-delete-docker-project-route \
    v-acknowledge-docker-project-alert; do
    cp "$fixture/fake-command" "/usr/local/vesta/bin/$command"
done

broker=(env -i SUDO_USER=alice SUDO_UID=1101 SUDO_GID=1101 /usr/local/vesta/bin/v-run-user-docker-command)
expect_allow() {
    local expected="$1"; shift
    : >"$fixture/docker.log"
    "${broker[@]}" "$@" >/dev/null 2>&1 || fail "broker denied: $*"
    grep -Fq "$expected" "$fixture/docker.log" || fail "wrong dispatch for: $*"
    grep -Fq 'actor=alice' "$fixture/docker.log" || fail 'clean child actor context missing'
}
expect_deny() {
    : >"$fixture/docker.log"
    ! "${broker[@]}" "$@" >/dev/null 2>&1 || fail "broker allowed: $*"
    [[ ! -s "$fixture/docker.log" ]] || fail "denial reached fake Docker: $*"
}

expect_allow 'v-list-docker-projects <alice> <json>' projects json
expect_allow 'v-list-docker-project <alice> <app> <json>' show app json
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <start>' start app
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <recreate> <web>' recreate app web
expect_allow 'v-run-docker-project-probe <alice> <alice> <app> <ready> <json>' probe app ready json
expect_allow 'v-backup-docker-project <alice> <app>' backup app
expect_allow 'v-add-docker-project-route <alice> <alice> <app> <app.example.com> <web> <8080> <http> </>' route-add app app.example.com web 8080
expect_allow 'v-add-docker-project-route <alice> <alice> <app> <app.example.com> <web> <443> <https> </api>' route-add app app.example.com web 443 https /api
expect_allow 'v-delete-docker-project-route <alice> <app> <app.example.com>' route-delete app app.example.com
expect_allow 'v-acknowledge-docker-project-alert <alice> <alice> <app> <alert-1>' alert-ack app alert-1

# A direct root child invocation cannot forge audit identity through the old
# environment variable because no validated broker descriptor is inherited.
env -i VESTA=/usr/local/vesta VESTA_COMPOSE_BROKER_ACTOR=mallory \
    /usr/local/vesta/bin/v-run-docker-project-action alice alice app start \
    >/dev/null 2>&1
jq -e 'select(.ACTION == "broker-child") | .ACTOR == "root"' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'direct child environment forged authoritative actor'
! jq -e 'select(.ACTION == "broker-child") | .ACTOR == "mallory"' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'forged actor reached authoritative audit'
: >"$fixture/docker.log"
! env -i SUDO_USER=alice SUDO_UID=1101 SUDO_GID=1101 \
    VESTA_COMPOSE_BROKER_ACTOR=mallory \
    /usr/local/vesta/bin/v-run-user-docker-command start app \
    >/dev/null 2>&1 || fail 'broker accepted old actor environment'
[[ ! -s "$fixture/docker.log" ]] || fail 'forged broker environment reached fake Docker'

wait_for_file() {
    local path="$1"
    for _ in {1..200}; do
        [[ -e "$path" ]] && return 0
        sleep 0.025
    done
    return 1
}

# An authorized operation retains the owner lock until its child finishes.
touch "$fixture/hold-owner"
: >"$fixture/docker.log"
"${broker[@]}" start app >/dev/null 2>&1 & operation_pid=$!
wait_for_file "$fixture/operation-entered" || fail 'authorized operation did not start'
(
    source /usr/local/vesta/func/vx/compose/main.sh
    : >"$fixture/revocation-waiting"
    vx_compose_shell_access_lock_acquire alice
    : >"$fixture/revocation-acquired"
    write_user yes bash 2
    vx_compose_shell_access_lock_release
) & revocation_pid=$!
wait_for_file "$fixture/revocation-waiting" || fail 'revocation did not begin'
sleep 0.1
[[ ! -e "$fixture/revocation-acquired" ]] || fail 'revocation bypassed active owner lock'
touch "$fixture/release-operation"
wait "$operation_pid" || fail 'authorized operation did not finish'
wait "$revocation_pid" || fail 'revocation did not finish'
wait_for_file "$fixture/revocation-acquired" || fail 'revocation never acquired owner lock'
expect_deny start app
[[ "$(wc -l <"$fixture/docker.log")" == 0 ]] || fail 'post-revocation action reached fake Docker'
rm -f "$fixture/hold-owner" "$fixture/release-operation"
write_user no bash 2

# A late enable/package failure leaves the root deny marker authoritative even
# if active user metadata has already been persisted.
source /usr/local/vesta/func/vx/compose/main.sh
vx_compose_shell_access_lock_acquire alice
vx_compose_shell_access_deny_establish alice
vx_compose_shell_access_lock_release
expect_deny start app
vx_compose_shell_group_grant_if_eligible() { return 0; }
vx_compose_shell_access_lock_acquire alice
vx_compose_shell_access_transition_complete alice
vx_compose_shell_access_lock_release
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <start>' start app

# The existing project lock still serializes independent project workers.
cat >"$fixture/project-worker" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/vesta/func/vx/compose/main.sh
vx_compose_prepare_owner_roots() {
    install -d -m 0750 /usr/local/vesta/data/users/alice/docker-projects/.locks
}
vx_compose_lock_acquire alice app
: >'$fixture/project-entered.'"\$1"
for _ in {1..200}; do
    [[ -e '$fixture/project-release.'"\$1" ]] && break
    sleep 0.025
done
[[ -e '$fixture/project-release.'"\$1" ]]
vx_compose_lock_release
EOF
chmod 0755 "$fixture/project-worker"
"$fixture/project-worker" one & project_one=$!
wait_for_file "$fixture/project-entered.one" || fail 'first project worker did not enter'
"$fixture/project-worker" two & project_two=$!
sleep 0.1
[[ ! -e "$fixture/project-entered.two" ]] || fail 'project lock did not serialize workers'
touch "$fixture/project-release.one"
wait "$project_one" || fail 'first project worker failed'
wait_for_file "$fixture/project-entered.two" || fail 'second project worker never entered'
touch "$fixture/project-release.two"
wait "$project_two" || fail 'second project worker failed'

for denied in 'unknown' '--help' 'start --owner' 'start alice' 'start app extra' \
    'show app yaml' 'probe app bad/name json' 'logs app web 2001' 'start app;touch' \
    'start bob' 'start admin'; do
    read -r -a denied_args <<<"$denied"
    expect_deny "${denied_args[@]}"
done
for denied in 'backup app custom.tar' 'backup-policy app' 'ingress-consumers app' \
    'monitoring-update app' 'rollback app' 'rollback app 1' 'reconcile app' \
    'reconcile app abc 1' 'route-add app app.example.com web 0' \
    'route-add app app.example.com web 65536' 'route-add app app.example.com web 80 ftp' \
    'route-delete app invalid' 'alert-ack app bad/name'; do
    read -r -a denied_args <<<"$denied"
    expect_deny "${denied_args[@]}"
done
expect_deny start $'app\nother'
# shellcheck disable=SC2016
expect_deny start '$(touch /tmp/shell-broker-canary)'
# shellcheck disable=SC2016
expect_deny start '`touch_/tmp/shell-broker-canary`'
[[ ! -e /tmp/shell-broker-canary ]] || fail 'command canary executed'

write_user no bash 0; expect_deny start app
write_user yes bash 2; expect_deny start app
write_user no nologin 2; expect_deny start app
write_user no bash 2
printf 'uid-mismatch\n' >"$fixture/passwd-mode"; expect_deny start app
printf 'actor-mismatch\n' >"$fixture/passwd-mode"; expect_deny start app
printf 'normal\n' >"$fixture/passwd-mode"

for mode in 0620 0602 0622; do
    chmod "$mode" /usr/local/vesta/data/users/alice/docker-projects/app/project.conf
    expect_deny start app
done
chmod 0600 /usr/local/vesta/data/users/alice/docker-projects/app/project.conf
printf "OWNER='bob'\nPROJECT='app'\nPROFILE='standard'\n" >/usr/local/vesta/data/users/alice/docker-projects/app/project.conf
chmod 0600 /usr/local/vesta/data/users/alice/docker-projects/app/project.conf
expect_deny start app

jq -e 'select(.ACTION == "broker-child") | .ACTOR == "alice"' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'authoritative child audit actor is not alice'
! jq -e 'select(.ACTION == "broker-child") | (.ACTOR == "root" or .ACTOR == "admin" or .ACTOR == "mallory")' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'authoritative child audit contains forged actor'

echo 'Executable broker fixture passed.'
