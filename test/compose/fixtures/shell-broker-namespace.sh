#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$1"
fixture="$2"
fail() { echo "FAIL: $1" >&2; exit 1; }

mount -t tmpfs tmpfs /usr/local
mount -t tmpfs tmpfs /run/lock
mkdir -p /usr/local/shell-broker-fixture
mount --bind "$fixture" /usr/local/shell-broker-fixture
fixture=/usr/local/shell-broker-fixture
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /var/tmp
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
for argument in "\$@"; do
    if [[ "\$argument" =~ ^/tmp/vx-compose-web[.][a-f0-9]{32}/compose[.]yaml$ ]]; then
        [[ -f "\$argument" && ! -L "\$argument"
            && "\$(stat -c '%u:%g:%a:%F' "\${argument%/*}")" == '0:0:700:directory'
            && "\$(stat -c '%u:%g:%a:%F' "\$argument")" == '0:0:600:regular file' ]] || exit 71
        printf ' <%s:%s>' "\${argument##*/}" "\$(stat -c '%s' "\$argument")" >>'$fixture/docker.log'
        if [[ -e '$fixture/delete-compose-source' ]]; then
            rm -f -- "\$argument"
            rmdir -- "\${argument%/*}"
        fi
    elif [[ "\$argument" =~ ^/var/tmp/vesta-compose-shell[.][A-Za-z0-9]{8}/(secret|registry)[.]input$ ]]; then
        [[ -f "\$argument" && ! -L "\$argument" ]] || exit 71
        printf ' <%s:%s>' "\${argument##*/}" "\$(stat -c '%s' "\$argument")" >>'$fixture/docker.log'
    else
        printf ' <%s>' "\$argument" >>'$fixture/docker.log'
    fi
done
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
for command in \
    v-list-docker-projects v-list-docker-compose-quota v-list-docker-registries \
    v-list-docker-project v-list-docker-project-definition v-validate-docker-project \
    v-list-docker-project-health v-list-docker-project-alerts v-list-docker-project-routes \
    v-list-docker-project-backups v-list-docker-secrets v-list-docker-project-operation \
    v-list-docker-project-drift v-run-docker-project-probe v-list-docker-project-logs \
    v-list-docker-project-stats v-run-docker-project-action v-stage-docker-project-preview \
    v-apply-docker-project-preview v-add-docker-secret v-change-docker-secret \
    v-delete-docker-secret v-add-docker-registry v-change-docker-registry \
    v-delete-docker-registry v-delete-docker-project v-backup-docker-project \
    v-restore-docker-project v-preview-docker-project-rollback \
    v-apply-docker-project-rollback v-preview-docker-project-reconcile \
    v-reconcile-docker-project v-add-docker-project-route v-delete-docker-project-route \
    v-acknowledge-docker-project-alert; do
    cp "$fixture/fake-command" "/usr/local/vesta/bin/$command"
done

broker=(env -i SUDO_USER=alice SUDO_UID=1101 SUDO_GID=1101 /usr/local/vesta/bin/v-run-user-docker-command)
: >"$fixture/covered-operations"
expect_allow() {
    local expected="$1"; shift
    printf '%s\n' "$1" >>"$fixture/covered-operations"
    : >"$fixture/docker.log"
    "${broker[@]}" "$@" >/dev/null 2>&1 || fail "broker denied: $*"
    grep -Fxq "$expected actor=alice" "$fixture/docker.log" || fail "wrong dispatch for: $*"
}
expect_allow_stdin() {
    local expected="$1" input="$2"; shift 2
    printf '%s\n' "$1" >>"$fixture/covered-operations"
    : >"$fixture/docker.log"
    printf '%s' "$input" | "${broker[@]}" "$@" >/dev/null 2>&1 \
        || fail "broker denied stdin operation: $*"
    grep -Fxq "$expected actor=alice" "$fixture/docker.log" \
        || fail "wrong stdin dispatch for: $* :: $(<"$fixture/docker.log")"
    ! compgen -G '/tmp/vx-compose-web.*' >/dev/null \
        || fail "broker retained Compose stdin snapshot for: $*"
    ! compgen -G '/var/tmp/vesta-compose-shell.*' >/dev/null \
        || fail "broker retained protected stdin snapshot for: $*"
}
expect_deny() {
    : >"$fixture/docker.log"
    ! "${broker[@]}" "$@" >/dev/null 2>&1 || fail "broker allowed: $*"
    [[ ! -s "$fixture/docker.log" ]] || fail "denial reached fake Docker: $*"
}

digest_a=$(printf 'a%.0s' {1..64})
digest_b=$(printf 'b%.0s' {1..64})
preview_id=$(printf 'c%.0s' {1..32})
name_63="n$(printf 'x%.0s' {1..62})"
name_64="n$(printf 'x%.0s' {1..63})"

# Exact argv coverage for every operation in the 39-operation tenant catalog.
expect_allow 'v-list-docker-projects <alice> <json>' projects
expect_allow 'v-list-docker-project <alice> <app> <plain>' show app plain
expect_allow 'v-list-docker-project-definition <alice> <app> <json>' definition app
expect_allow 'v-list-docker-compose-quota <alice> <plain>' quota plain
expect_allow 'v-validate-docker-project <alice> <app> <json>' validate app
expect_allow 'v-list-docker-project-health <alice> <app> <plain>' health app plain
expect_allow 'v-list-docker-project-logs <alice> <app> <> <100>' logs app
expect_allow 'v-list-docker-project-stats <alice> <app> <5m> <plain>' stats app 5m plain
expect_allow 'v-list-docker-project-alerts <alice> <app> <json>' alerts app
expect_allow 'v-list-docker-project-operation <alice> <alice> <app> <json>' operation app
expect_allow 'v-list-docker-project-routes <alice> <app> <plain>' routes app plain
expect_allow 'v-list-docker-project-backups <alice> <app> <json>' backups app
expect_allow 'v-list-docker-secrets <alice> <app> <plain>' secrets app plain
expect_allow 'v-list-docker-registries <alice> <json>' registries
expect_allow 'v-list-docker-project-drift <alice> <alice> <app> <plain>' drift app plain
expect_allow "v-run-docker-project-probe <alice> <alice> <app> <$name_63> <json>" probe app "$name_63"
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <start>' start app
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <stop>' stop app
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <restart>' restart app
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <recreate> <web>' recreate app web
expect_allow 'v-run-docker-project-action <alice> <alice> <app> <deploy>' deploy app
expect_allow_stdin 'v-stage-docker-project-preview <alice> <alice> <app> <compose.yaml:12> <standard> <change>' 'compose-data' preview app change
touch "$fixture/delete-compose-source"
expect_allow_stdin 'v-stage-docker-project-preview <alice> <alice> <app> <compose.yaml:12> <standard> <change>' 'compose-data' preview app change
rm -f "$fixture/delete-compose-source"
expect_allow "v-apply-docker-project-preview <alice> <alice> <app> <$preview_id> <$digest_a> <$digest_b> <1>" apply app "$preview_id" "$digest_a" "$digest_b" 1
expect_allow "v-apply-docker-project-preview <alice> <alice> <new-app> <$preview_id> <$digest_a> <$digest_b> <0>" apply new-app "$preview_id" "$digest_a" "$digest_b" 0
expect_allow 'v-backup-docker-project <alice> <app>' backup app
expect_allow 'v-restore-docker-project <alice> <app> <managed:backup-1> <validate>' restore app backup-1 validate
expect_allow 'v-restore-docker-project <alice> <app> <managed:backup-1> <apply>' restore app backup-1 apply
expect_allow 'v-preview-docker-project-rollback <alice> <alice> <app> <1>' rollback-preview app 1
expect_allow "v-apply-docker-project-rollback <alice> <alice> <app> <1> <2> <$digest_a> <$digest_b>" rollback-apply app 1 2 "$digest_a" "$digest_b"
expect_allow 'v-preview-docker-project-reconcile <alice> <alice> <app>' reconcile-preview app
expect_allow "v-reconcile-docker-project <alice> <alice> <app> <$digest_a> <1>" reconcile-apply app "$digest_a" 1
expect_allow_stdin 'v-add-docker-secret <alice> <app> <api-key> <secret.input:12>' 'secret-value' secret-add app api-key
expect_allow_stdin 'v-change-docker-secret <alice> <app> <api-key> <secret.input:12>' 'secret-value' secret-change app api-key
expect_allow 'v-delete-docker-secret <alice> <app> <api-key>' secret-delete app api-key
expect_allow_stdin 'v-add-docker-registry <alice> <registry-1> <alice> <registry.input:17>' 'registry-password' registry-add registry-1 alice
expect_allow_stdin 'v-change-docker-registry <alice> <registry-1> <alice> <registry.input:17>' 'registry-password' registry-change registry-1 alice
expect_allow 'v-delete-docker-registry <alice> <registry-1>' registry-delete registry-1
expect_allow 'v-add-docker-project-route <alice> <alice> <app> <app.example.com> <web> <8080> <http> </>' route-add app app.example.com web 8080
expect_allow 'v-add-docker-project-route <alice> <alice> <app> <app.example.com> <web> <443> <https> </api>' route-add app app.example.com web 443 https /api
expect_allow 'v-delete-docker-project-route <alice> <app> <app.example.com>' route-delete app app.example.com
expect_allow 'v-acknowledge-docker-project-alert <alice> <alice> <app> <alert-1>' alert-ack app alert-1
expect_allow 'v-delete-docker-project <alice> <app> <keep-data>' remove app keep-data
expect_deny probe app "$name_64"

awk '
    /^```tsv compose-shell-catalog$/ { catalog=1; next }
    catalog && /^```$/ { exit }
    catalog { print $1 }
' "$repo_root/.docs/contracts/compose-shell-access.md" | sort -u >"$fixture/catalog-operations"
sort -u "$fixture/covered-operations" >"$fixture/covered-operations.sorted"
cmp -s "$fixture/catalog-operations" "$fixture/covered-operations.sorted" \
    || fail 'executable broker fixture does not cover the complete catalog'

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

expect_interrupted_preview_cleanup() {
    local signal="$1" upload_fd upload_pid root_seen=no
    mkfifo "$fixture/upload-$signal"
    exec {upload_fd}<>"$fixture/upload-$signal"
    set -m
    "${broker[@]}" preview app change <&"$upload_fd" >/dev/null 2>&1 &
    upload_pid=$!
    set +m
    for _ in {1..200}; do
        if compgen -G '/tmp/vx-compose-web.*' >/dev/null; then
            root_seen=yes
            break
        fi
        kill -0 "$upload_pid" 2>/dev/null || break
        sleep 0.025
    done
    [[ "$root_seen" == yes ]] || fail "$signal preview did not create a snapshot root"
    kill -s "$signal" -- "-$upload_pid"
    ! wait "$upload_pid" || fail "$signal preview succeeded after interruption"
    exec {upload_fd}>&-
    rm -f "$fixture/upload-$signal"
    ! compgen -G '/tmp/vx-compose-web.*' >/dev/null \
        || fail "$signal preview retained Compose stdin snapshot"
}

expect_interrupted_preview_cleanup INT
expect_interrupted_preview_cleanup TERM

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
expect_deny apply app "$preview_id" "$digest_a" "$digest_b" 0

jq -e 'select(.ACTION == "broker-child") | .ACTOR == "alice"' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'authoritative child audit actor is not alice'
! jq -e 'select(.ACTION == "broker-child") | (.ACTOR == "root" or .ACTOR == "admin" or .ACTOR == "mallory")' \
    /usr/local/vesta/data/users/alice/docker-audit.log >/dev/null \
    || fail 'authoritative child audit contains forged actor'

echo 'Executable broker fixture passed.'
