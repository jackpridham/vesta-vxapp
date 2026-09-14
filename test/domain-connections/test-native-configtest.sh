#!/usr/bin/env bash
# Execute the production validator against fixture service binaries. Real
# per-process descriptor limits prove nginx checks inherit the service limit
# without changing the caller's limit or accepting a failed configuration.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export VX_CONFIGTEST_FIXTURE="$work"
source "$root/func/vx/graceful-apply.sh"
source "$root/func/vx/domain-connections/native.sh"
# Replace only external binary paths in the production function for this test.
validator=$(declare -f vx_graceful_apply_configtest)
validator=${validator//\/usr\/bin\/systemctl/$work/systemctl}
validator=${validator//\/usr\/sbin\/apache2ctl/$work/apache2ctl}
validator=${validator//\/usr\/sbin\/nginx/$work/nginx}
validator=${validator//\/usr\/sbin\/service/$work/service}
eval "$validator"
apply_helper=$(declare -f vx_graceful_apply)
apply_helper=${apply_helper//\/usr\/bin\/systemctl/$work/systemctl}
apply_helper=${apply_helper//\/usr\/sbin\/service/$work/service}
eval "$apply_helper"
restart_helper=$(declare -f vx_domain_connection_native_restart)
eval "$restart_helper"
cat >"$work/systemctl" <<'STUB'
#!/bin/bash
if [[ "$1 $2" == 'is-active --quiet' ]]; then
    [[ ! -f "$VX_CONFIGTEST_FIXTURE/$3-inactive" ]]; exit
fi
[[ "$*" == 'show nginx --property=LimitNOFILESoft --value' ]] || exit 1
printf '%s\n' 256
STUB
cat >"$work/apache2ctl" <<'STUB'
#!/bin/bash
[[ "$*" == configtest ]] || exit 1
printf 'apache-validator\n' >>"$VX_CONFIGTEST_FIXTURE/effects"
[[ ! -f "$VX_CONFIGTEST_FIXTURE/apache-invalid" ]]
STUB
cat >"$work/nginx" <<'STUB'
#!/bin/bash
[[ "$*" == -t && $(ulimit -Sn) == 256 ]] || exit 1
printf 'nginx-validator\n' >>"$VX_CONFIGTEST_FIXTURE/effects"
[[ ! -f "$VX_CONFIGTEST_FIXTURE/nginx-invalid" ]]
STUB
cat >"$work/service" <<'STUB'
#!/bin/bash
case "$2" in
    configtest) printf 'unsupported-service-configtest\n' >>"$VX_CONFIGTEST_FIXTURE/effects"; exit 3 ;;
    reload)
        printf 'reload %s\n' "$1" >>"$VX_CONFIGTEST_FIXTURE/effects"
        [[ ! -f "$VX_CONFIGTEST_FIXTURE/$1-reload-fail" ]] || exit 1
        [[ ! -f "$VX_CONFIGTEST_FIXTURE/$1-reload-stops" ]] \
            || touch "$VX_CONFIGTEST_FIXTURE/$1-inactive"
        ;;
esac
STUB
chmod +x "$work/"{systemctl,apache2ctl,nginx,service}
(
    ulimit -Sn 128
    WEB_SYSTEM=apache2 PROXY_SYSTEM=nginx
    vx_domain_connection_native_configtest
    [[ $(ulimit -Sn) == 128 ]] || { echo 'FAIL: validator changed caller descriptor limit'; exit 1; }
    [[ $(cat "$work/effects") == $'apache-validator\nnginx-validator' ]] || { echo 'FAIL: wrong service validators'; exit 1; }
    touch "$work/nginx-invalid"
    if vx_domain_connection_native_configtest; then echo 'FAIL: invalid nginx configuration accepted'; exit 1; fi
    rm "$work/nginx-invalid"
    touch "$work/apache-invalid"
    if vx_domain_connection_native_configtest; then echo 'FAIL: invalid Apache configuration accepted'; exit 1; fi
)
rm "$work/apache-invalid"
BIN=$work WEB_SYSTEM=apache2 PROXY_SYSTEM=nginx
for command in v-restart-web v-restart-proxy; do
    printf '#!/bin/bash\nprintf "scheduled %s\\n" "${0##*/}" >>"$VX_CONFIGTEST_FIXTURE/effects"\nexit 0\n' >"$work/$command"
done
cat >"$work/v-restart-service" <<'STUB'
#!/bin/bash
printf 'fallback %s\n' "$1" >>"$VX_CONFIGTEST_FIXTURE/effects"
[[ ! -f "$VX_CONFIGTEST_FIXTURE/fallback-no-effect" ]] || exit 0
rm -f "$VX_CONFIGTEST_FIXTURE/$1-inactive"
STUB
chmod +x "$work/"v-restart-*
before=$(wc -l <"$work/effects")
vx_domain_connection_native_restart
effects=$(tail -n +"$((before+1))" "$work/effects")
[[ "$effects" == $'apache-validator\nnginx-validator\nreload apache2\nreload nginx' ]] \
    || { echo 'FAIL: active services did not receive reload-only apply'; exit 1; }
touch "$work/nginx-reload-stops"
if vx_domain_connection_native_restart; then echo 'FAIL: accepted reload which stopped active service'; exit 1; fi
[[ ! -f "$work/nginx-reload-stops" ]] || :
rm "$work/nginx-reload-stops" "$work/nginx-inactive"
touch "$work/apache2-inactive"
vx_domain_connection_native_restart
[[ ! -f "$work/apache2-inactive" ]] || { echo 'FAIL: stopped Apache was not recovered'; exit 1; }
grep -Fxq 'fallback apache2' "$work/effects"
touch "$work/apache2-inactive" "$work/fallback-no-effect"
if vx_domain_connection_native_restart; then echo 'FAIL: false successful restart accepted'; exit 1; fi
rm "$work/fallback-no-effect"
touch "$work/nginx-invalid"
before=$(wc -l <"$work/effects")
if vx_domain_connection_native_restart; then echo 'FAIL: restarted invalid configuration'; exit 1; fi
[[ $(tail -n +"$((before+1))" "$work/effects") != *fallback* ]] || { echo 'FAIL: invalid config reached restart'; exit 1; }
/usr/bin/rm -f -- "$work/nginx-invalid"
before=$(wc -l <"$work/effects")
vx_graceful_apply no no apache2 nginx
[[ $(wc -l <"$work/effects") == "$before" ]] || { echo 'FAIL: restart=no applied a service change'; exit 1; }
/usr/bin/mkdir -p "$work/data/queue"
VESTA=$work SCHEDULED_RESTART=yes vx_graceful_apply '' no apache2 nginx
grep -Fxq "$work/v-apply-vx-graceful-services web proxy now" "$work/data/queue/restart.pipe" \
    || { echo 'FAIL: scheduled graceful apply was not queued'; exit 1; }
before=$(wc -l <"$work/data/queue/restart.pipe")
SCHEDULED_RESTART=yes vx_domain_connection_native_restart
[[ $(wc -l <"$work/data/queue/restart.pipe") == "$before" ]] \
    || { echo 'FAIL: native apply was deferred'; exit 1; }
printf 'PASS: native validators, isolated descriptor limit and actual restart state\n'
