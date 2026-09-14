#!/usr/bin/env bash
# Execute the production validator against fixture service binaries. Real
# per-process descriptor limits prove nginx checks inherit the service limit
# without changing the caller's limit or accepting a failed configuration.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export VX_CONFIGTEST_FIXTURE="$work"
source "$root/func/vx/domain-connections/native.sh"
# Replace only external binary paths in the production function for this test.
validator=$(declare -f vx_domain_connection_native_configtest)
validator=${validator//\/usr\/bin\/systemctl/$work/systemctl}
validator=${validator//\/usr\/sbin\/apache2ctl/$work/apache2ctl}
validator=${validator//\/usr\/sbin\/nginx/$work/nginx}
validator=${validator//\/usr\/sbin\/service/$work/service}
eval "$validator"
restart_helper=$(declare -f vx_domain_connection_native_restart)
restart_helper=${restart_helper//\/usr\/bin\/systemctl/$work/systemctl}
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
printf 'unsupported-service-configtest\n' >>"$VX_CONFIGTEST_FIXTURE/effects"
exit 3
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
    printf '#!/bin/bash\nexit 0\n' >"$work/$command"
done
cat >"$work/v-restart-service" <<'STUB'
#!/bin/bash
printf 'fallback %s\n' "$1" >>"$VX_CONFIGTEST_FIXTURE/effects"
[[ ! -f "$VX_CONFIGTEST_FIXTURE/fallback-no-effect" ]] || exit 0
rm -f "$VX_CONFIGTEST_FIXTURE/$1-inactive"
STUB
chmod +x "$work/"v-restart-*
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
printf 'PASS: native validators, isolated descriptor limit and actual restart state\n'
