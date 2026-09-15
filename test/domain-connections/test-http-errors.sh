#!/usr/bin/env bash
set -Eeuo pipefail
# The unchanged HTTP handler has absolute Vesta/sudo paths. Isolate those mounts;
# never install fixture users, keys, or commands in the host's Vesta tree.
if [[ ${1:-} != --isolated ]]; then
    exec sudo -n unshare --mount --net --propagation private bash "$0" --isolated
fi
ip link set lo up
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/local/vesta"
mount --bind "$tmp/local" /usr/local
export VESTA=/usr/local/vesta
mkdir -p "$VESTA"/{bin,conf,conf_web,data/keys,data/users/alice,data/users/bob,log,web/api}
ln -s "$root/func" "$VESTA/func"
cp "$root/web/api/index.php" "$VESTA/web/api/"
cp "$root/bin/"{v-add-vx-web-domain-connection,v-check-api-key} "$VESTA/bin/"
printf '127.0.0.1\n' >"$VESTA/conf_web/allow_ip_for_api.conf"
touch "$VESTA/data/keys/fixture-api-key-0001"
# Only managed-provider evidence is substituted. Parent binding, reservation,
# quota, enrollment, public projection and authentication use shipped code.
cat >"$VESTA/conf/vesta.conf" <<'CONF'
WEB_SYSTEM=nginx
source "$VESTA/func/vx/cloudflare/main.sh"
vx_cf_native_web_authority_preflight() { VX_CF_WEB_AUTHORITY_STATE=managed; }
CONF
for owner in alice bob; do
    printf "WEB_DOMAINS='unlimited'\n" >"$VESTA/data/users/$owner/user.conf"
    printf "DOMAIN='technical.example.net' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:3000' LETSENCRYPT='no' SSL='yes' SUSPENDED='no'\n" >"$VESTA/data/users/$owner/web.conf"
done
# Record the real child status and invocation count; do not inject outcomes.
cat >"$tmp/sudo" <<'DISPATCH'
#!/bin/bash
export VESTA=/usr/local/vesta
"$@"
result=$?
printf '%s %s\n' "$(basename "$1")" "$result" >>"$VESTA/log/dispatch"
exit "$result"
DISPATCH
chmod 0755 "$tmp/sudo"
mount --bind "$tmp/sudo" /usr/bin/sudo
source "$root/func/vx/domain-connections/main.sh"
vx_domain_connection_prepare
python3 - <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.parse
import urllib.request

vesta = Path(os.environ['VESTA'])
config = vesta / 'data/vx/domain-connections/config.json'
dispatch = vesta / 'log/dispatch'
command = vesta / 'bin/v-add-vx-web-domain-connection'

def enrollment(enabled):
    config.write_text(json.dumps({'VERSION': 1, 'ENROLLMENT': 'enabled' if enabled else 'disabled', 'CONNECTION_LIMIT': 0}))

def arguments(hostname, request, owner='alice'):
    return [owner, 'technical.example.net', hostname, request, 'json']

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
with (vesta / 'log/http').open('w') as log:
    server = subprocess.Popen(['php', '-S', f'127.0.0.1:{port}', '-t', str(vesta / 'web')], stdout=log, stderr=log)
    try:
        url = f'http://127.0.0.1:{port}/api/'
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                assert server.poll() is None, 'HTTP server exited'
                time.sleep(.05)
        else:
            raise AssertionError('HTTP server unavailable')

        def http(args, expected_status, returncode=False, key='fixture-api-key-0001'):
            before = dispatch.read_text().splitlines() if dispatch.exists() else []
            post = {'hash': key, 'cmd': command.name, **{f'arg{i}': arg for i, arg in enumerate(args, 1)}}
            if returncode:
                post['returncode'] = 'yes'
            with urllib.request.urlopen(url, urllib.parse.urlencode(post).encode(), timeout=20) as response:
                assert response.status == 200
                body = response.read().decode().strip()
            after = dispatch.read_text().splitlines() if dispatch.exists() else []
            if key != 'fixture-api-key-0001':
                assert after == before, 'unauthenticated command invocation'
                assert body == 'Error: authentication failed'
            else:
                assert after[len(before):] == ['v-check-api-key 0', f'{command.name} {expected_status}'], (body, after[len(before):], (vesta / "log/http").read_text())
            return body

        def failure(label, args, code, status):
            expected = {'version': 1, 'error': {'code': code, 'exitCode': status}}
            body = http(args, status)
            assert json.loads(body) == expected, (label, body)
            # Strict equality also excludes owners, reservation IDs, proof and prose.
            print(f'HTTP 200 {label}: {body} (child exit {status}; one mutation)')
            cli = subprocess.run([str(command), *args], capture_output=True, text=True)
            assert cli.returncode == status and json.loads(cli.stdout) == expected
            shell = subprocess.run([str(command), *args[:-1]], capture_output=True, text=True)
            assert shell.returncode == status and shell.stdout.strip() == 'Error: unable to create domain connection'
            assert http(args, status, returncode=True) == str(status)

        http(arguments('auth.example.com', 'request-auth'), 0, key='invalid-key')
        enrollment(True)
        bob = json.loads(http(arguments('conflict.example.com', 'request-private-bob', 'bob'), 0))
        assert bob['connection']['generation'] == 1
        failure('conflict', arguments('conflict.example.com', 'request-conflict'), 'hostname_conflict', 4)
        (vesta / 'data/users/alice/user.conf').write_text("WEB_DOMAINS='1'\n")
        failure('quota', arguments('quota.example.com', 'request-quota'), 'quota_exceeded', 8)
        (vesta / 'data/users/alice/user.conf').write_text("WEB_DOMAINS='unlimited'\n")
        success_args = arguments('success.example.com', 'request-success')
        success = json.loads(http(success_args, 0))
        assert set(success) == {'version', 'connection', 'quota'} and success['version'] == 1
        assert success['connection']['connectionID'] and success['connection']['generation'] == 1
        assert success['quota'] == {'used': 2, 'available': None}
        assert json.loads(http(success_args, 0)) == success
        assert http(success_args, 0, returncode=True) == '0'
        enrollment(False)
        failure('disabled', arguments('disabled.example.com', 'request-disabled'), 'enrollment_disabled', 11)
        assert json.loads(http(success_args, 0)) == success, 'replay after disabled enrollment'
        enrollment(True)
        failure('invalid', arguments('127.0.0.1', 'request-invalid'), 'native_failure', 2)
        # Unknown storage/authority failures must not claim conflict/quota/disabled.
        config.chmod(0o644)
        failure('unsafe authority', arguments('unknown.example.com', 'request-unknown'), 'native_failure', 2)
        config.chmod(0o600)
        config.write_text('{invalid-json')
        failure('unreadable enrollment', arguments('config.example.com', 'request-config'), 'native_failure', 11)
        enrollment(True)
        (vesta / 'data/users/alice/user.conf').write_text("WEB_DOMAINS='invalid'\n")
        failure('unreadable quota', arguments('quota-invalid.example.com', 'request-quota-invalid'), 'native_failure', 8)
        invalid = http(['missing', 'technical.example.net', 'invalid.example.com', 'request-missing', 'json'], 3)
        assert invalid.startswith('Error:') and '"error"' not in invalid
        print('Authenticated HTTP, CLI/status compatibility, sanitization and idempotent replay passed')
    finally:
        server.terminate()
        server.wait(timeout=5)
PY
