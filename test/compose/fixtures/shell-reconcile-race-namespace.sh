#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$1"
fixture="$2/reconcile-race"
fail() { echo "FAIL: $1" >&2; exit 1; }

mount -t tmpfs tmpfs /usr/local
mount -t tmpfs tmpfs /run/lock
mkdir -p /usr/local/vesta/{bin,func/vx/compose,data/users/alice} "$fixture"
cp -a "$repo_root/func/vx/compose/." /usr/local/vesta/func/vx/compose/
cp "$repo_root/bin/v-sync-docker-shell-access" \
    "$repo_root/bin/v-sync-docker-shell-access-all" /usr/local/vesta/bin/
chmod 0755 /usr/local/vesta/bin/v-sync-docker-shell-access{,-all}

membership="$fixture/membership"
membership_lock="$fixture/membership.lock"
printf '\n' >"$membership"
printf "SUSPENDED='no'\nSHELL='bash'\nDOCKER_PROJECTS='2'\n" \
    >/usr/local/vesta/data/users/alice/user.conf
chmod 0600 /usr/local/vesta/data/users/alice/user.conf

cat >"$fixture/getent" <<EOF
#!/usr/bin/env bash
case "\${1-}:\${2-}" in
    group:vesta-compose-users)
        printf 'vesta-compose-users:x:2201:%s\n' "\$(cat '$membership')"
        ;;
    passwd:alice|passwd:bob)
        user=\${2-}
        printf '%s:x:1101:1101:User:/home/%s:/bin/bash\n' "\$user" "\$user"
        ;;
    *) exit 2 ;;
esac
EOF
cat >"$fixture/id" <<EOF
#!/usr/bin/env bash
user=\${2-}
case "\${1-}" in
    -u) printf '1101\n' ;;
    -G) printf '1101 2201\n' ;;
    -nG)
        groups=users
        members=\$(cat '$membership')
        [[ ",\$members," != *",\$user,"* ]] || groups="\$groups vesta-compose-users"
        printf '%s\n' "\$groups"
        ;;
    -g) printf '0\n' ;;
    *) exit 2 ;;
esac
EOF
cat >"$fixture/usermod" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
user=\${@: -1}
exec 8>'$membership_lock'
flock -x 8
members=\$(cat '$membership')
if [[ ",\$members," != *",\$user,"* ]]; then
    [[ -z "\$members" ]] && printf '%s\n' "\$user" >'$membership' \
        || printf '%s,%s\n' "\$members" "\$user" >'$membership'
fi
flock -u 8
if [[ "\$user" == alice ]]; then
    : >'$fixture/alice-granted'
    for _ in {1..400}; do
        [[ -e '$fixture/release-alice' ]] && exit 0
        sleep 0.025
    done
    exit 70
fi
EOF
cat >"$fixture/gpasswd" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
user=\$2
exec 8>'$membership_lock'
flock -x 8
awk -v user="\$user" -v RS=, -v ORS=, '\$0 != user { print }' '$membership' \
    | sed 's/,$//' >'$membership.new'
mv '$membership.new' '$membership'
EOF
chmod 0755 "$fixture/getent" "$fixture/id" "$fixture/usermod" "$fixture/gpasswd"
mount --bind "$fixture/getent" /usr/bin/getent
mount --bind "$fixture/id" /usr/bin/id
mount --bind "$fixture/usermod" /usr/sbin/usermod
mount --bind "$fixture/gpasswd" /usr/bin/gpasswd

wait_for_file() {
    local path="$1"
    for _ in {1..400}; do
        [[ -e "$path" ]] && return 0
        sleep 0.025
    done
    return 1
}

VX_COMPOSE_RECONCILE_LOCK_ROOT=/run/lock/vesta-compose-reconcile \
    /usr/local/vesta/bin/v-sync-docker-shell-access-all >"$fixture/full.out" &
full_pid=$!
wait_for_file "$fixture/alice-granted" || fail 'full reconciliation did not reach the scan barrier'

mkdir -p /usr/local/vesta/data/users/bob
printf "SUSPENDED='no'\nSHELL='bash'\nDOCKER_PROJECTS='2'\n" \
    >/usr/local/vesta/data/users/bob/user.conf
chmod 0600 /usr/local/vesta/data/users/bob/user.conf
/usr/local/vesta/bin/v-sync-docker-shell-access bob \
    || fail 'concurrent per-owner grant failed'
[[ ",$(cat "$membership")," == *,bob,* ]] || fail 'concurrent grant did not add bob'

touch "$fixture/release-alice"
wait "$full_pid" || fail "full reconciliation failed: $(cat "$fixture/full.out")"
[[ ",$(cat "$membership")," == *,bob,* ]] \
    || fail 'stale full-reconciliation cleanup removed a concurrent grant'

echo 'Shell-access reconciliation race fixture passed.'
