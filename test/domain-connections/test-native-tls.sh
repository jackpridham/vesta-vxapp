#!/usr/bin/env bash
# Execute native adapters and real registry/render/state helpers in a private
# Vesta tree. Only host effects (services, OS ownership, ACME and HTTPS transport)
# are fixtures. No listener, real account, provider or CA is mutated.
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
if [[ $EUID != 0 ]]; then exec sudo -n /bin/bash "$0"; fi
bash "$root/test/domain-connections/test-native-configtest.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export VESTA="$work/vesta" VX_NATIVE_TEST_REPO="$root"
export PATH="$work/os:$PATH"
mkdir -p "$work/os" "$VESTA"/{bin,conf,log,func/vx/domain-connections,data/users/alice/ssl,data/users/bob,data/queue,data/tmp,data/templates/web/nginx,test-etc/nginx/conf.d,test-etc/apache2/conf.d,test-logs/apache2/domains} "$work/home/alice/conf/web"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() { if "$@" >"$work/failure" 2>&1; then fail "unexpected success: $*"; fi; }
expect_forbidden() {
    local status=0
    "$@" >"$work/failure" 2>&1 || status=$?
    [[ $status == 10 ]] || { cat "$work/failure"; fail "expected forbidden (10), got $status: $*"; }
}
for command in chown; do printf '#!/bin/bash\nexit 0\n' >"$work/os/$command"; done
cat >"$work/os/sudo" <<'STUB'
#!/bin/bash
[[ $1 != -u ]] || shift 2
exec "$@"
STUB
chmod +x "$work/os/"*
cat >"$VESTA/func/main.sh" <<'STUB'
source "$VX_NATIVE_TEST_REPO/func/main.sh"
HOMEDIR="${VESTA%/vesta}/home"
increase_ip_value() { :; }
decrease_ip_value() { :; }
send_notice() { :; }
# Ownership of fixture IPs belongs to the private test tree.
STUB
cat >"$VESTA/func/ip.sh" <<'STUB'
source "$VX_NATIVE_TEST_REPO/func/ip.sh"
is_ip_valid() { :; }
increase_ip_value() { :; }
decrease_ip_value() { :; }
STUB
mkdir -p "$VESTA/data/ips"
printf "IP='8.8.8.8' NAT=''\n" >"$VESTA/data/ips/8.8.8.8"
ln -s "$root/func/vx/cloudflare" "$VESTA/func/vx/cloudflare"
ln -s "$root/func/vx/proxy.sh" "$VESTA/func/vx/proxy.sh"
cat >"$VESTA/func/vx/domain-connections/main.sh" <<'STUB'
source "$VX_NATIVE_TEST_REPO/func/vx/domain-connections/main.sh"
# Keep the production restart helper; replace only its external service-state
# observer because this fixture does not start host daemons.
restart_helper=$(declare -f vx_domain_connection_native_restart)
restart_helper=${restart_helper//\/usr\/bin\/systemctl/$VESTA/bin/systemctl}
eval "$restart_helper"
vx_domain_connection_native_configtest() {
    printf 'configtest\n' >>"$VESTA/effects"
    [[ ! -f "$VESTA/config-fail" ]]
}
vx_domain_connection_native_https_identity() {
    printf 'https %s %s\n' "$1" "$2" >>"$VESTA/effects"
    [[ ! -f "$VESTA/https-fail" ]] || return 60
    [[ ! -f "$VESTA/https-wrong" ]] || { printf wrong-site; return; }
    vx_domain_connection_record_read "$1" | /usr/bin/jq -r .CONNECTION_ID
}
STUB
# Redirect fixed host filesystem paths only; execute the shipped renderer.
python3 - "$root" "$VESTA" <<'PY'
import pathlib,sys
repo,vesta=map(pathlib.Path,sys.argv[1:])
s=(repo/'func/domain.sh').read_text().replace('/etc/',str(vesta/'test-etc')+'/').replace('/usr/local/vesta/conf/vesta.conf',str(vesta/'conf/vesta.conf'))
(vesta/'func/domain.sh').write_text(s)
for name in ['v-add-web-domain','v-add-web-domain-ssl','v-change-web-domain-sslcert','v-delete-web-domain-ssl','v-add-web-domain-alias','v-delete-web-domain-alias','v-change-web-domain-ip','v-change-web-domain-name','v-change-web-domain-proxy-options','v-suspend-web-domain','v-delete-web-domain','v-delete-web-domains','v-delete-user','v-list-web-domain','v-list-web-domains','v-update-letsencrypt-ssl']:
 s=(repo/'bin'/name).read_text().replace('/var/log/',str(vesta/'test-logs')+'/').replace('/usr/local/vesta/log/',str(vesta/'log')+'/').replace('source /etc/profile', ': # fixture already supplies the scheduler environment').replace('/etc/',str(vesta/'test-etc')+'/').replace('/hdd/home/',str(vesta/'test-hdd/home')+'/')
 p=vesta/'bin'/name;p.write_text(s);p.chmod(0o755)
PY
for command in v-restart-web v-restart-proxy; do
cat >"$VESTA/bin/$command" <<'STUB'
#!/bin/bash
[[ $1 != no ]] || exit 0
printf 'restart %s\n' "${0##*/}" >>"$VESTA/effects"
if [[ -f "$VESTA/restart-fail-once" ]]; then rm "$VESTA/restart-fail-once"; exit 23; fi
STUB
chmod +x "$VESTA/bin/$command"
done
cat >"$VESTA/bin/v-update-user-counters" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$VESTA/bin/systemctl" <<'STUB'
#!/bin/bash
[[ "$1 $2" == 'is-active --quiet' ]]
STUB
# ACME fixture returns genuine X.509/key material through the real native SSL
# adapters; install, copy, state mutation and rollback remain production logic.
cat >"$VESTA/bin/v-add-letsencrypt-domain" <<'STUB'
#!/bin/bash
user=$1 domain=$2
source "$VESTA/func/main.sh"
source "$VESTA/func/domain.sh"
source "$VESTA/func/vx/domain-connections/main.sh"
source "$VESTA/conf/vesta.conf"
vx_domain_connection_native_guard "$user" "$domain" issue || exit 10
[[ -z $3 ]] || exit 10
if [[ -f "$VESTA/acme-block" ]]; then
    trap '' TERM
    printf '%s\n' "$BASHPID" >"$VESTA/acme-pid"
    sleep 30 &
    printf '%s\n' "$!" >"$VESTA/acme-child-pid"
    wait
fi
vx_domain_connection_native_write_challenge fixture-token fixture-thumbprint || exit 10
printf 'acme %s\n' "$domain" >>"$VESTA/effects"
[[ ! -f "$VESTA/acme-fail" ]] || exit 15
vx_domain_connection_native_install_certificate "$VESTA/certificates" || exit $?
update_object_value web DOMAIN "$domain" '$LETSENCRYPT' yes
STUB
chmod +x "$VESTA/bin/"*
cat >"$VESTA/conf/vesta.conf" <<'CONF'
WEB_SYSTEM='apache2'
WEB_SSL='yes'
WEB_PORT='8080'
WEB_SSL_PORT='8443'
WEB_BACKEND=''
PROXY_SYSTEM='nginx'
PROXY_PORT='80'
PROXY_SSL_PORT='443'
CRON_SYSTEM='cron'
CONF
cat >"$VESTA/data/users/alice/user.conf" <<'CONF'
USER='alice'
SUSPENDED='no'
WEB_DOMAINS='10'
WEB_ALIASES='10'
WEB_TEMPLATE='default'
BACKEND_TEMPLATE=''
PROXY_TEMPLATE='default'
U_WEB_DOMAINS='1'
U_WEB_ALIASES='0'
U_WEB_SSL='1'
CONF
: >"$VESTA/data/users/bob/web.conf"
: >"$VESTA/test-etc/nginx/conf.d/vesta.conf"
: >"$VESTA/test-etc/apache2/conf.d/vesta.conf"
mkdir -p "$VESTA/data/templates/web/"{apache2,skel/public_html,skel/document_errors}
printf '<VirtualHost %%ip%%:%%web_port%%>\nServerName %%domain%%\n</VirtualHost>\n' >"$VESTA/data/templates/web/apache2/default.tpl"
cp "$VESTA/data/templates/web/apache2/default."{tpl,stpl}
cp "$root/install/debian/12/templates/web/nginx/vx-proxy."{tpl,stpl} "$VESTA/data/templates/web/nginx/"
printf 'tenant skeleton\n' >"$VESTA/data/templates/web/skel/public_html/index.html"
user=alice
source "$VESTA/func/main.sh"
source "$VESTA/func/domain.sh"
source "$VESTA/func/ip.sh"
source "$VESTA/conf/vesta.conf"
source "$VESTA/func/vx/domain-connections/main.sh"
parent=s-aaaaaaaaaa.managed.example.test
host=www.customer.fixture.net
id=0123456789abcdef0123456789abcdef
printf "DOMAIN='%s' IP='8.8.8.8' IP6='' ALIAS='' TPL='default' BACKEND='' PROXY='vx-proxy' PROXY_EXT='jpg' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:8088' PROXY_PRESERVE_HOST='no' PROXY_PROFILE='standard' PROXY_TIMEOUT='60' PROXY_HEADERS='BusinessGUID: fixture-business-secret' PROXY_PATH='/app' SSL='yes' SSL_HOME='same' LETSENCRYPT='no' SUSPENDED='no' STATS=''\n" "$parent" >"$USER_DATA/web.conf"
vx_cf_prepare_layout
cat >"$(vx_cf_config_path)" <<'CONF'
API_TOKEN='fixture-token-not-a-real-credential'
ZONE_ID='0123456789abcdef0123456789abcdef'
ACCOUNT_EMAIL='fixture@example.net'
ZONE_NAME='managed.example.test'
CONF
chmod 600 "$(vx_cf_config_path)"
vx_cf_load_config
vx_cf_write_metadata alice "$parent" "$id" 8.8.8.8
VX_CF_CERT_HOSTNAMES=("$parent")
VX_CF_CERT_HOSTNAMES_DIGEST=$(printf '%s\n' "$parent" | vx_cf_hostname_digest)
vx_cf_write_certificate_metadata alice "$parent" fixture-certificate "$parent" "$VX_CF_CERT_HOSTNAMES_DIGEST"
vx_domain_connection_prepare
record=$(vx_domain_connection_record_path "$host")
payload=$(jq -cn --arg hostname "$host" --arg parent "$parent" --arg id "$id" '{VERSION:1,OWNER:"alice",HOSTNAME:$hostname,TECHNICAL_FQDN:$parent,CONNECTION_ID:$id,GENERATION:1,STATE:"pending_tls",PROOF_TOKEN:"verified-proof-token",CLEANUP:{}}')
vx_domain_connection_record_write "$host" "$payload"
vx_domain_connection_owner_lock alice
vx_domain_connection_lock "$host"
# Root flags cannot bypass the actual inherited lock requirement.
expect_failure env VX_DOMAIN_CONNECTION_NATIVE_CREATE=1 VX_DOMAIN_CONNECTION_RECORD="$record" "$BIN/v-add-web-domain" alice "$host" 8.8.8.8 no none ''
mv "$BIN/v-add-web-domain" "$BIN/v-add-web-domain-real"
cat >"$BIN/v-add-web-domain" <<'STUB'
#!/bin/bash
"$VESTA/bin/v-add-web-domain-real" "$@" || exit $?
exit 23
STUB
chmod +x "$BIN/v-add-web-domain"
vx_domain_connection_native_create "$record" || { cat "$work/failure"; fail 'native child creation'; }
vx_domain_connection_native_row alice "$host" || fail 'www primary was stripped'
[[ $(vx_domain_connection_native_value "$VX_DC_ROW" ALIAS) == '' ]] || fail 'implicit alias'
[[ $(vx_domain_connection_native_value "$VX_DC_ROW" PROXY_HEADERS) == 'BusinessGUID: fixture-business-secret' ]] || fail 'binding lost header authority'
rendered="$HOMEDIR/alice/conf/web/$host.nginx.conf"
grep -Fq 'location ^~ /.well-known/acme-challenge/' "$rendered" || fail 'challenge missing'
grep -Fq 'return 404;' "$rendered" || fail 'holding missing'
grep -Fq 'if ($http_host !~* ^(www\.customer\.fixture\.net)(:[0-9]+)?$) { return 444; }' "$rendered" || fail 'unknown Host guard missing'
! grep -Eq 'proxy_pass|document_errors|include ' "$rendered" || fail 'holding exposed tenant content'
! grep -Fq "www.$host" "$USER_DATA/web.conf" || fail 'www alias was added'
! grep -Fq 'fixture-business-secret' "$VESTA/effects" || fail 'header leaked through effects'
# Idempotent exact readback supports a lost create response, but a changed
# generation, alias or binding is never adopted as success.
vx_domain_connection_native_create "$record" || fail 'lost-response readback'
update_object_value web DOMAIN "$host" '$VX_CONNECTION_GENERATION' 9
expect_failure vx_domain_connection_native_create "$record"
update_object_value web DOMAIN "$host" '$VX_CONNECTION_GENERATION' 1
expect_forbidden "$BIN/v-add-web-domain-alias" alice "$host" extra.example.net no
expect_forbidden "$BIN/v-delete-web-domain-alias" alice "$host" extra.example.net no
expect_forbidden "$BIN/v-change-web-domain-ip" alice "$host" 8.8.4.4 no
expect_forbidden "$BIN/v-change-web-domain-name" alice "$host" renamed.example.net no
expect_forbidden "$BIN/v-change-web-domain-proxy-options" alice "$host" proxy http://127.0.0.1:8888 standard no 60 '' no
expect_forbidden "$BIN/v-suspend-web-domain" alice "$host" no
expect_forbidden "$BIN/v-delete-web-domain" alice "$host" no
expect_forbidden "$BIN/v-delete-web-domain-ssl" alice "$host" no
expect_forbidden "$BIN/v-delete-web-domain" alice "$parent" no
expect_forbidden "$BIN/v-delete-web-domains" alice no
expect_forbidden "$BIN/v-delete-user" alice
# JSON linkage is visible while inherited private header values remain native.
list_json=$("$BIN/v-list-web-domain" alice "$host" json)
jq -e --arg parent "$parent" --arg host "$host" '.[$host].VX_CONNECTION_PARENT==$parent and .[$host].PROXY_HEADERS==""' <<<"$list_json" >/dev/null || fail 'linked row projection'
# Local generated certs test the installation path, not public CA issuance.
mkdir -p "$VESTA/certificates"
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" -keyout "$VESTA/certificates/$host.key" -out "$VESTA/certificates/$host.crt" >/dev/null 2>&1
(umask 077; vx_domain_connection_native_issue "$record") || fail 'initial install'
[[ $(cat "$HOMEDIR/alice/web/$host/public_html/.well-known/acme-challenge/fixture-token") == fixture-token.fixture-thumbprint ]] || fail 'native challenge write'
# Read the challenge as an unprivileged HTTP worker, starting at public_html
# so unrelated fixture ancestry permissions do not affect this assertion.
python3 - "$HOMEDIR/alice/web/$host/public_html" <<'PY'
import os,sys
os.chdir(sys.argv[1]); os.setgroups([]); os.setgid(65534); os.setuid(65534)
assert open('.well-known/acme-challenge/fixture-token').read().strip() == 'fixture-token.fixture-thumbprint'
PY
# Match the worker source graph in a fresh shell: no preloaded domain/IP
# functions. Native activation must load its own renderer dependencies.
VX_DOMAIN_CONNECTION_OWNER_LOCK_FD="$VX_DOMAIN_CONNECTION_OWNER_LOCK_FD" VX_DOMAIN_CONNECTION_LOCK_FD="$VX_DOMAIN_CONNECTION_LOCK_FD" /bin/bash -c 'user=alice; source "$VESTA/func/main.sh"; source "$VESTA/conf/vesta.conf"; source "$VESTA/func/vx/domain-connections/main.sh"; vx_domain_connection_native_activate "$1"' _ "$record" || fail 'worker activation dependency closure'
grep -Eq 'listen[[:space:]]+8\.8\.8\.8:443([[:space:]]|;)' "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf" || fail 'native listener IP'
# An unresolved native IP must fail before overwriting any accepted config.
before_render=$(sha256sum "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf")
mv "$VESTA/data/ips/8.8.8.8" "$VESTA/ip.saved"
expect_failure vx_domain_connection_native_render
[[ $(sha256sum "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf") == "$before_render" ]] || fail 'unresolved IP changed config'
mv "$VESTA/ip.saved" "$VESTA/data/ips/8.8.8.8"
# Public HTTPS transport is a fixture; mismatched identity, trust failure and
# missing admitted ingress must all remain unaccepted.
vx_domain_connection_target_read_json() { printf '{"IPV4":"8.8.8.8","IPV6":""}\n'; }
observed=$(vx_domain_connection_native_observe "$record")
jq -e '.TLS_STATE=="accepted" and .HTTPS_IDENTITY and .CONFIG_VALID' <<<"$observed" >/dev/null || fail "acceptance: $observed"
touch "$VESTA/https-fail"
! vx_domain_connection_native_observe "$record" | jq -e '.HTTPS_IDENTITY' >/dev/null || fail 'trusted HTTPS failure accepted'
rm "$VESTA/https-fail"
touch "$VESTA/https-wrong"
! vx_domain_connection_native_observe "$record" | jq -e '.HTTPS_IDENTITY' >/dev/null || fail 'wrong site accepted'
rm "$VESTA/https-wrong"
# Replacement plus failed restart must retain the accepted certificate/config.
old_cert=$(sha256sum "$USER_DATA/ssl/$host.crt")
old_config=$(sha256sum "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf")
# Cancel the actual issue transaction through the worker's outer timeout.
# Its inner timeout must stop both the ACME adapter and its descendants.
touch "$VESTA/acme-block"
timeout_status=0
VX_DOMAIN_CONNECTION_OWNER_LOCK_FD="$VX_DOMAIN_CONNECTION_OWNER_LOCK_FD" VX_DOMAIN_CONNECTION_LOCK_FD="$VX_DOMAIN_CONNECTION_LOCK_FD" /usr/bin/timeout --kill-after=10 2 /bin/bash -c 'user=alice; source "$VESTA/func/main.sh"; source "$VESTA/conf/vesta.conf"; source "$VESTA/func/vx/domain-connections/main.sh"; vx_domain_connection_native_issue "$1"' _ "$record" || timeout_status=$?
[[ "$timeout_status" == 124 ]] || fail 'issue timeout did not execute'
python3 - "$VESTA/acme-pid" "$VESTA/acme-child-pid" <<'PY'
import pathlib,sys,time
for filename in sys.argv[1:]:
    pid = pathlib.Path(filename).read_text().strip()
    stat = pathlib.Path('/proc')/pid/'stat'
    for _ in range(50):
        if not stat.exists() or stat.read_text().split()[2] == 'Z': break
        time.sleep(.02)
    else: raise AssertionError('ACME process survived worker cancellation')
PY
rm "$VESTA/acme-block"
jq -e '.RECOVERY.required' "$record" >/dev/null || fail 'timeout lost recovery snapshot'
vx_domain_connection_native_recover "$record" || fail 'timeout recovery'
[[ $(sha256sum "$USER_DATA/ssl/$host.crt") == "$old_cert" ]] || fail 'timeout changed certificate'
openssl req -x509 -newkey rsa:2048 -nodes -days 4 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" -keyout "$VESTA/certificates/$host.key" -out "$VESTA/certificates/$host.crt" >/dev/null 2>&1
touch "$VESTA/restart-fail-once"
expect_failure vx_domain_connection_native_issue "$record"
[[ $(sha256sum "$USER_DATA/ssl/$host.crt") == "$old_cert" ]] || fail 'certificate rollback'
[[ $(sha256sum "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf") == "$old_config" ]] || fail 'config rollback'
[[ $(find "$(vx_domain_connection_root)" -maxdepth 1 -type d -name '.native-tls.*' | wc -l) == 0 ]] || fail 'successful rollback retained secret artifacts'
# A failed rollback retains a protected recovery artifact, then a later
# bounded attempt can restore it without new issuance or changing the parent.
touch "$VESTA/config-fail"
expect_failure vx_domain_connection_native_issue "$record"
jq -e '.RECOVERY.required and .STATE=="recovery_required"' "$record" >/dev/null || fail 'missing recovery state'
rm "$VESTA/config-fail"
vx_domain_connection_native_recover "$record" || fail 'recovery retry'
jq -e '.RECOVERY.required==false' "$record" >/dev/null || fail 'recovery not cleared'
# The actual native scheduler acquires the same locks and records renewal.
vx_domain_connection_record_write "$host" "$(jq '.STATE="connected"' "$record")"
vx_domain_connection_unlock
vx_domain_connection_owner_unlock
cat >"$BIN/v-list-users" <<'STUB'
#!/bin/bash
printf 'alice\n'
STUB
chmod +x "$BIN/v-list-users"
"$BIN/v-update-letsencrypt-ssl" >/dev/null 2>&1 || fail 'native scheduled renewal'
jq -e '.RENEWAL.successful and (.RENEWAL.lastAttemptAt|type=="string")' "$record" >/dev/null || fail 'renewal result missing'
vx_domain_connection_owner_lock alice
vx_domain_connection_lock "$host"
# Execute the shipped ACME client, not the fake CA adapter, for a reused valid
# authorization. Only account provisioning and HTTP transport are fixtures;
# CSR generation, parsing, native certificate replacement and state are real.
mv "$BIN/v-add-letsencrypt-domain" "$BIN/v-add-letsencrypt-domain-fixture"
python3 - "$root/bin/v-add-letsencrypt-domain" "$BIN/v-add-letsencrypt-domain" "$VESTA" <<'PY'
import pathlib,sys
source,destination,vesta = sys.argv[1:]
p = pathlib.Path(destination)
p.write_text(pathlib.Path(source).read_text().replace('/usr/local/vesta/log/',vesta+'/log/'))
p.chmod(0o755)
PY
cp "$root/test/domain-connections/fixtures/native-acme-curl" "$work/os/curl"
printf '#!/bin/bash\nexit 0\n' >"$BIN/v-add-letsencrypt-user"
cat >"$BIN/v-generate-ssl-cert" <<'STUB'
#!/bin/bash
openssl req -new -key "$VESTA/certificates/$1.key" -subj "/CN=$1" -out "$VESTA/certificates/$1.csr" || exit
printf 'DIR: %s\n' "$VESTA/certificates"
STUB
chmod +x "$BIN/v-add-letsencrypt-user" "$BIN/v-generate-ssl-cert"
printf "KID='https://acme-v02.api.letsencrypt.org/acme/acct/fixture' THUMB='fixture-thumbprint'\n" >"$USER_DATA/ssl/le.conf"
cp "$VESTA/certificates/$host.key" "$USER_DATA/ssl/user.key"
mkdir -p "$VESTA/data/users/admin"
printf 'v-update-letsencrypt-ssl\n' >"$VESTA/data/users/admin/cron.conf"
old_cert=$(sha256sum "$USER_DATA/ssl/$host.crt")
openssl req -x509 -newkey rsa:2048 -nodes -days 6 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" -keyout "$VESTA/certificates/$host.key" -out "$VESTA/certificates/$host.crt" >/dev/null 2>&1
touch "$VESTA/acme-auth-pending"
expect_failure vx_domain_connection_native_issue "$record"
[[ $(sha256sum "$USER_DATA/ssl/$host.crt") == "$old_cert" ]] || fail 'pending authorization changed certificate'
! grep -Fxq /acme/finalize/fixture "$VESTA/acme-transport-effects" || fail 'pending authorization skipped challenge'
rm "$VESTA/acme-auth-pending" "$VESTA/acme-transport-effects"
vx_domain_connection_native_issue "$record" || fail 'real ACME client reused authorization'
[[ $(sha256sum "$USER_DATA/ssl/$host.crt") != "$old_cert" ]] || fail 'reused authorization did not replace certificate'
grep -Fxq /acme/finalize/fixture "$VESTA/acme-transport-effects" || fail 'ready order not finalized'
[[ $(wc -l <"$VESTA/acme-transport-effects") == 5 ]] || fail 'unexpected ACME challenge request'
rm "$work/os/curl"
mv "$BIN/v-add-letsencrypt-domain-fixture" "$BIN/v-add-letsencrypt-domain"
# Missing registry cannot disable child guards or expose it during rebuild.
vx_domain_connection_native_record_load "$record"
mv "$record" "$record.saved"
expect_failure "$BIN/v-delete-web-domain" alice "$host" no
expect_failure vx_domain_connection_native_render
mv "$record.saved" "$record"
# Restored HTTPS state renders holding until fresh proof has succeeded.
vx_domain_connection_record_write "$host" "$(jq '.STATE="pending_verification" | .REASON="restored_proof_required"' "$record")"
vx_domain_connection_native_render || fail 'restore holding render'
! grep -Fq proxy_pass "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf" || fail 'restore exposed content before proof'
vx_domain_connection_record_write "$host" "$(jq '.STATE="pending_tls" | .REASON="proof_accepted"' "$record")"
vx_domain_connection_native_activate "$record" || fail 'restore proof activation'
grep -Fq proxy_pass "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf" || fail 'restore did not resume serving'
# Unsafe ingress is rejected before the HTTPS transport is called.
vx_domain_connection_target_read_json() { printf '{"IPV4":"127.0.0.1","IPV6":""}\n'; }
before_https=$(grep -c '^https ' "$VESTA/effects")
! vx_domain_connection_native_observe "$record" | jq -e '.HTTPS_IDENTITY' >/dev/null || fail 'private ingress accepted'
[[ $(grep -c '^https ' "$VESTA/effects") == "$before_https" ]] || fail 'unsafe ingress reached transport'
# Current native quota and other owners' primary/alias rows stay authoritative.
printf "DOMAIN='other.example.net' ALIAS='taken.example.net'\n" >"$VESTA/data/users/bob/web.conf"
expect_failure vx_domain_connection_native_hostname_in_use taken.example.net
sed -i "s/WEB_DOMAINS='10'/WEB_DOMAINS='1'/" "$USER_DATA/user.conf"
expect_failure "$BIN/v-add-web-domain" alice free.example.net 8.8.8.8 no none ''
# Parent keeps its independent OriginCA lifecycle and never enters LE.
vx_domain_connection_native_row alice "$parent"
[[ $(vx_domain_connection_native_value "$VX_DC_ROW" LETSENCRYPT) == no ]] || fail 'parent entered LE'
# Native delete can lose its response after deleting the authority row but
# before removing the vhosts. The next bounded cleanup replays only that saved
# exact child and never treats row absence as successful route cleanup.
vx_domain_connection_record_write "$host" "$(jq '.GENERATION=2 | .STATE="disconnecting" | .CLEANUP.NATIVE_GENERATION=1' "$record")"
update_object_value web DOMAIN "$host" '$VX_CONNECTION_GENERATION' 9
expect_failure vx_domain_connection_native_cleanup "$record"
update_object_value web DOMAIN "$host" '$VX_CONNECTION_GENERATION' 1
mv "$BIN/v-delete-web-domain" "$BIN/v-delete-web-domain-real"
cat >"$BIN/v-delete-web-domain" <<'STUB'
#!/bin/bash
if [[ -f "$VESTA/delete-interrupt" ]]; then
    rm "$VESTA/delete-interrupt"
    sed -i "/^DOMAIN='$2' /d" "$VESTA/data/users/$1/web.conf"
    exit 23
fi
exec "$VESTA/bin/v-delete-web-domain-real" "$@"
STUB
chmod +x "$BIN/v-delete-web-domain"
touch "$VESTA/delete-interrupt"
expect_failure vx_domain_connection_native_cleanup "$record"
[[ -f "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf" ]] || fail 'delete interruption fixture did not preserve vhost'
vx_domain_connection_native_cleanup "$record" || fail 'exact cleanup retry'
! vx_domain_connection_native_row alice "$host" || fail 'cleanup kept child row'
[[ ! -f "$HOMEDIR/alice/conf/web/$host.nginx.ssl.conf" ]] || fail 'cleanup kept route'
vx_domain_connection_native_row alice "$parent" || fail 'cleanup deleted parent'
vx_domain_connection_native_cleanup "$record" || fail 'cleanup idempotency'
printf 'PASS: native child creation, holding, authority, TLS install, rollback and HTTPS observations\n'
