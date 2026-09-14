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
cat >"$work/systemctl" <<'STUB'
#!/bin/bash
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
printf 'PASS: native service validators and isolated descriptor limit\n'
