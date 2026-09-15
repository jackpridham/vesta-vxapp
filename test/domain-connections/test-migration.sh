#!/usr/bin/env bash
set -euo pipefail
# Root fixtures exercise the same protected registry/lock boundary as a host.
if ((EUID)); then exec sudo -n bash "$0" "$@"; fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
export VESTA="$tmp/vesta" HOMEDIR="$tmp/home" BIN="$tmp/vesta/bin" FIXTURE="$tmp" REPO="$repo"
export WEB_SYSTEM=nginx PROXY_SYSTEM=nginx SSL_CERT_FILE="$tmp/ca.crt"
mkdir -p "$BIN" "$VESTA/func/vx" "$VESTA/data/users/Alice/ssl" "$VESTA/conf" "$HOMEDIR/Alice/conf/web" "$HOMEDIR/Alice/web"
cp -a "$repo/func/vx/cloudflare" "$repo/func/vx/domain-connections" "$VESTA/func/vx/"
cp "$repo/func/vx/graceful-apply.sh" "$VESTA/func/vx/"
# Substitute only external HTTPS/configtest endpoints; native observation,
# matching, TLS recovery, and binding logic remain the actual implementation.
sed -i "s@/usr/bin/curl@${tmp}/curl@g;s@/usr/sbin/service@${tmp}/service@g" "$VESTA/func/vx/domain-connections/native.sh"
sed -i "s@/usr/bin/systemctl@${tmp}/systemctl@g;s@/usr/sbin/nginx@${tmp}/nginx@g;s@/usr/sbin/service@${tmp}/service@g" "$VESTA/func/vx/graceful-apply.sh"
cat >"$tmp/load" <<'LOAD'
source "$VESTA/func/vx/cloudflare/main.sh"
source "$VESTA/func/vx/proxy.sh"
source "$VESTA/func/vx/domain-connections/main.sh"
source "$VESTA/func/vx/domain-connections/migration.sh"
source "$VESTA/func/domain.sh"
increase_user_value() { :; }
LOAD
cat >"$VESTA/func/domain.sh" <<'DOMAIN'
get_domain_values() {
    vx_domain_connection_native_row "$user" "$domain" || return 1
    local key
    for key in SSL TPL PROXY ALIAS IP; do printf -v "$key" '%s' "$(vx_domain_connection_native_value "$VX_DC_ROW" "$key")"; done
}
get_real_ip() { printf '%s\n' "$1"; }
prepare_web_domain_values() { :; }
add_web_config() {
    local suffix=conf row hostname id target names
    [[ "$2" != *.stpl ]] || suffix=ssl.conf
    if vx_domain_connection_native_row "$user" "$domain"; then row=$VX_DC_ROW
    else row="DOMAIN='$domain' ALIAS='$ALIAS' VX_CONNECTION_ID='${VX_CONNECTION_ID:-}' PROXY_TARGET='$PROXY_TARGET'"; fi
    names="$domain $(vx_domain_connection_native_value "$row" ALIAS | tr ',' ' ')"
    id=$(vx_domain_connection_native_value "$row" VX_CONNECTION_ID)
    target=$(vx_domain_connection_native_value "$row" PROXY_TARGET)
    eval "$row"
    docroot="$HOMEDIR/$user/web/$domain/public_html"
    PROXY_TEMPLATE=${PROXY:-vx-proxy}
    vx_proxy_prepare_template_values
    printf 'server_name %s;\nssl_certificate ssl.%s.pem;\nreturn 200 "%s";\nproxy_pass %s;\n' "$names" "$domain" "$id" "$target" >"$HOMEDIR/$user/conf/web/$domain.$1.$suffix"
    printf '%s\n' "$VX_PROXY_LOCATION_BLOCK" >>"$HOMEDIR/$user/conf/web/$domain.$1.$suffix"
}
DOMAIN
cat >"$tmp/service" <<'SERVICE'
#!/bin/bash
if [[ "${2:-}" == reload ]]; then exec "$BIN/v-restart-web"; fi
[[ ! -f "$FIXTURE/fail-config" ]] || { rm "$FIXTURE/fail-config"; exit 1; }
# Exact server-name uniqueness across the independently rendered SNI vhosts.
python3 - "$HOMEDIR/Alice/conf/web" <<'PY'
import pathlib,sys
names=[]
for p in pathlib.Path(sys.argv[1]).glob('*.ssl.conf'):
    names+=p.read_text().splitlines()[0].removeprefix('server_name ').removesuffix(';').split()
assert len(names)==len(set(names)),names
PY
SERVICE
printf '#!/bin/bash\n[[ "$1" != show ]] || echo 1024\nexit 0\n' >"$tmp/systemctl"
printf '#!/bin/bash\nexec "$FIXTURE/service" nginx configtest\n' >"$tmp/nginx"
chmod +x "$tmp/systemctl" "$tmp/nginx"
cat >"$tmp/curl" <<'CURL'
#!/bin/bash
hostname=${!#}; hostname=${hostname#https://}; hostname=${hostname%%/*}
source "$FIXTURE/load"
vx_domain_connection_record_read "$hostname" | jq -r .CONNECTION_ID
CURL
cat >"$BIN/v-restart-web" <<'RESTART'
#!/bin/bash
[[ "${1:-}" != no ]] || exit 0
[[ ! -f "$FIXTURE/fail-restart" ]] || { rm "$FIXTURE/fail-restart"; exit 1; }
cp -a "$HOMEDIR/Alice/conf/web" "$FIXTURE/served.new"
rm -rf "$FIXTURE/served"
mv "$FIXTURE/served.new" "$FIXTURE/served"
RESTART
cp "$BIN/v-restart-web" "$BIN/v-restart-proxy"
cat >"$BIN/v-add-vx-managed-web-domain" <<'ALLOCATE'
#!/bin/bash
source "$FIXTURE/load"
[[ ! -f "$FIXTURE/fail-allocation" ]] || exit 1
row=$(cat "$FIXTURE/base.row")
vx_cf_migration_row_replace "$row" DOMAIN s-0123456789.vxapp.io; row=$VX_CF_MIGRATION_ROW
vx_cf_migration_row_replace "$row" ALIAS ''; row=$VX_CF_MIGRATION_ROW
vx_cf_migration_row_replace "$row" LETSENCRYPT no; row=$VX_CF_MIGRATION_ROW
printf '%s\n' "$row" >>"$VESTA/data/users/Alice/web.conf"
VX_CF_ZONE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
vx_cf_write_metadata Alice s-0123456789.vxapp.io bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 93.184.216.34
vx_cf_write_certificate_metadata Alice s-0123456789.vxapp.io fixturecertificate s-0123456789.vxapp.io "$(printf '%s\n' s-0123456789.vxapp.io | sha256sum | cut -d' ' -f1)"
for ext in crt key pem; do cp "$VESTA/data/users/Alice/ssl/example.com.$ext" "$VESTA/data/users/Alice/ssl/s-0123456789.vxapp.io.$ext"; done
printf '%s\n' s-0123456789.vxapp.io
ALLOCATE
# Exercise the actual public native create adapter. Only OS user/service/log
# effects are mapped to the isolated fixture; native guards and row logic run.
sed "s@/var/log/@$tmp/log/@g" "$repo/bin/v-add-web-domain" >"$BIN/v-add-web-domain"
mkdir -p "$tmp/os" "$tmp/log/nginx/domains" "$VESTA/data/templates/web/skel"
printf '<html>fixture</html>\n' >"$VESTA/data/templates/web/skel/index.html"
cat >"$tmp/os/sudo" <<'SUDO'
#!/bin/bash
shift 2
exec "$@"
SUDO
printf '#!/bin/bash\nexit 0\n' >"$tmp/os/chown"
chmod +x "$tmp/os/"*
export PATH="$tmp/os:$PATH"
cat >"$VESTA/func/main.sh" <<'MAIN'
BIN="$VESTA/bin" USER_DATA="$VESTA/data/users/$user" WEBTPL="$VESTA/data/templates/web"
WEB_TEMPLATE=default BACKEND_TEMPLATE=default PROXY_TEMPLATE=vx-proxy
WEB_BACKEND='' E_FORBIDEN=4 E_UPDATE=19 OK=0 ARGUMENTS='' conf='' alias_number=0
source "$FIXTURE/load"
check_result() { [[ "$1" == 0 ]] || exit "$1"; }
check_args() { :; }
is_format_valid() { :; }
is_system_enabled() { :; }
is_object_valid() { :; }
is_object_unsuspended() { :; }
is_package_full() { :; }
is_domain_new() { vx_domain_connection_native_hostname_in_use "$2" || exit 4; }
is_dir_symlink() { [[ ! -L "$1" ]] || exit 1; }
if_dir_exists() { [[ ! -e "$1" ]] || exit 1; }
is_ip_valid() { :; }
format_domain() { :; }
format_domain_idn() { :; }
format_aliases() { :; }
increase_ip_value() { :; }
log_history() { :; }
log_event() { :; }
add_object_key() {
    vx_domain_connection_migration_row "$user" "$3" || return 1
    vx_cf_migration_row_value "$VX_DCM_ROW" "$4" && return 0
    vx_domain_connection_migration_set_row "$user" "$3" "$VX_DCM_ROW" "$4" ''
}
update_object_value() {
    vx_domain_connection_migration_row "$user" "$3" || return 1
    vx_domain_connection_migration_set_row "$user" "$3" "$VX_DCM_ROW" "${4#'$'}" "$5"
}
MAIN
: >"$VESTA/func/ip.sh"
cp "$repo/func/vx/proxy.sh" "$VESTA/func/vx/proxy.sh"
cat >"$BIN/v-delete-vx-cloudflare-web-domain" <<'DELETE'
#!/bin/bash
source "$FIXTURE/load"
[[ ! -f "$FIXTURE/fail-cleanup" ]] || { rm "$FIXTURE/fail-cleanup"; exit 1; }
vx_cf_remove_metadata "$1" "$2"
DELETE
cat >"$BIN/v-add-letsencrypt-domain" <<'ACME'
#!/bin/bash
source "$FIXTURE/load"
vx_domain_connection_native_guard "$1" "$2" issue || exit 1
[[ ! -f "$FIXTURE/fail-acme" ]] || { rm "$FIXTURE/fail-acme"; exit 1; }
vx_domain_connection_migration_row "$1" "$2" || exit 1
vx_domain_connection_migration_set_row "$1" "$2" "$VX_DCM_ROW" LETSENCRYPT yes || exit 1
# External ACME returns a distinct accepted replacement certificate.
cp "$FIXTURE/replacement.crt" "$VESTA/data/users/$1/ssl/$2.crt"
cp "$FIXTURE/replacement.crt" "$VESTA/data/users/$1/ssl/$2.pem"
cp "$FIXTURE/replacement.crt" "$HOMEDIR/$1/conf/web/ssl.$2.pem"
vx_domain_connection_native_record_load "$VX_DOMAIN_CONNECTION_RECORD"
vx_domain_connection_native_render
ACME
printf '#!/bin/bash\nexit 0\n' >"$BIN/v-update-user-counters"
cp "$BIN/v-update-user-counters" "$BIN/v-update-sys-ip-counters"
chmod +x "$BIN/"* "$tmp/service" "$tmp/curl"
source "$tmp/load"
vx_domain_connection_migration_service_root() { printf '%s/etc\n' "$FIXTURE"; }
# DNS lookup is an external effect; retain a deterministic read-only inventory.
vx_domain_connection_dns_query() { printf '%s\n' 93.184.216.34; }
vx_domain_connection_target_read_json() { printf '%s\n' '{"TARGET_FQDN":"connect.vxapp.io","IPV4":"93.184.216.34","IPV6":""}'; }
# Observe uses a subshell of this test and therefore retains the target readback.
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj /CN=MigrationFixtureCA -keyout "$tmp/ca.key" -out "$tmp/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=example.com -keyout "$tmp/site.key" -out "$tmp/site.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:example.com,DNS:www.example.com,DNS:s-aaaaaaaaaa.vxapp.io,DNS:s-0123456789.vxapp.io\n' >"$tmp/extensions"
openssl x509 -req -in "$tmp/site.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -CAcreateserial -days 3 -extfile "$tmp/extensions" -out "$tmp/site.crt" >/dev/null 2>&1
openssl x509 -req -in "$tmp/site.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -set_serial 123456 -days 3 -extfile "$tmp/extensions" -out "$tmp/replacement.crt" >/dev/null 2>&1
base="DOMAIN='example.com' IP='93.184.216.34' ALIAS='www.example.com' SSL='yes' SSL_HOME='same' LETSENCRYPT='yes' TPL='default' BACKEND='default' PROXY='vx-proxy' PROXY_EXT='css' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:8080' PROXY_PRESERVE_HOST='yes' PROXY_PROFILE='standard' PROXY_TIMEOUT='60' PROXY_HEADERS='' PROXY_PATH='/' SUSPENDED='no'"
printf '%s\n' "$base" >"$tmp/base.row"
reset_fixture() {
    rm -rf "$VESTA/data/vx" "$VESTA/data/users/Alice/ssl" "$HOMEDIR/Alice/conf/web" "$HOMEDIR/Alice/web"
    mkdir -p "$VESTA/data/users/Alice/ssl" "$HOMEDIR/Alice/conf/web" "$HOMEDIR/Alice/web" "$tmp/etc/nginx/conf.d"
    : >"$tmp/etc/nginx/conf.d/vesta.conf"
    printf '%s\n' "$base" >"$VESTA/data/users/Alice/web.conf"
    printf "WEB_DOMAINS='3'\n" >"$VESTA/data/users/Alice/user.conf"
    cp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/example.com.crt"
    cp "$tmp/site.key" "$VESTA/data/users/Alice/ssl/example.com.key"
    cp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/example.com.pem"
    vx_domain_connection_prepare
    mkdir -p "$VESTA/data/vx/cloudflare"
    printf "API_TOKEN='fixture-token-not-a-secret'\nZONE_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'\nACCOUNT_EMAIL='fixture@example.com'\nZONE_NAME='vxapp.io'\n" >"$VESTA/data/vx/cloudflare/config.conf"
    chmod 600 "$VESTA/data/vx/cloudflare/config.conf"
    vx_domain_connection_migration_render_parent Alice example.com
    vx_domain_connection_native_restart
}
prepare_fixture() {
    vx_domain_connection_migration_prepare Alice "$1" >/dev/null
    plan=$(vx_domain_connection_migration_path Alice "$1")
    revision=$(jq -r .assessment.revision "$plan/plan.json")
}
assert_routes() {
    python3 - "$FIXTURE/served" <<'PY'
import pathlib,sys
seen={}
for p in pathlib.Path(sys.argv[1]).glob('*.ssl.conf'):
    content=p.read_text()
    for name in content.splitlines()[0].removeprefix('server_name ').removesuffix(';').split():
        assert name not in seen
        seen[name]=content
for name in ['example.com','www.example.com']:
    assert 'proxy_pass http://127.0.0.1:8080;' in seen[name]
PY
}
reset_fixture
before=$(vx_domain_connection_migration_revision Alice)
vx_domain_connection_migration_assess Alice example.com >/dev/null
[[ $(vx_domain_connection_migration_revision Alice) == "$before" ]]
prepare_fixture example.com
vx_domain_connection_migration_apply Alice example.com "$revision" >/dev/null
[[ $(jq -r .state "$plan/plan.json") == applied ]]
assert_routes
[[ $(wc -l <"$VESTA/data/users/Alice/web.conf") == 3 ]]
for name in example.com www.example.com; do
    vx_domain_connection_record_read "$name" | jq -e '.STATE=="degraded" and .GENERATION==1' >/dev/null
    cmp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/$name.crt"
done
vx_domain_connection_migration_apply Alice example.com "$revision" >/dev/null
# A changed generation refuses rollback, preserving the changed authority.
cp "$(vx_domain_connection_record_path example.com)" "$tmp/record"
jq '.GENERATION=2' "$tmp/record" >"$(vx_domain_connection_record_path example.com)"
rollback_revision=$(jq -r .expectedRevision "$plan/plan.json")
! vx_domain_connection_migration_rollback Alice example.com "$rollback_revision"
cp "$tmp/record" "$(vx_domain_connection_record_path example.com)"
vx_domain_connection_migration_rollback Alice example.com "$rollback_revision"
assert_routes
cmp "$tmp/base.row" "$VESTA/data/users/Alice/web.conf"
# No mutation on quota rejection, revision mismatch, or named production scope.
reset_fixture
printf "WEB_DOMAINS='2'\n" >"$VESTA/data/users/Alice/user.conf"
! vx_domain_connection_migration_prepare Alice example.com
[[ $(wc -l <"$VESTA/data/users/Alice/web.conf") == 1 ]]
reset_fixture
prepare_fixture example.com
printf '\n' >>"$VESTA/data/users/Alice/user.conf"
! vx_domain_connection_migration_apply Alice example.com "$revision"
! vx_domain_connection_migration_execution_allowed Jack9f6fa castlesoncommand.com.au
# A different owner wins the hostname lock between preparation and apply.
# Migration waits for that exact lock, then rejects the changed reservation;
# it cannot overwrite the concurrent owner's durable claim.
reset_fixture; prepare_fixture example.com
mkfifo "$tmp/claim-ready" "$tmp/claim-release"
(
    vx_domain_connection_owner_lock Bob
    vx_domain_connection_lock www.example.com
    printf 'ready\n' >"$tmp/claim-ready"
    read -r signal <"$tmp/claim-release"
    vx_domain_connection_record_write www.example.com "$(vx_domain_connection_migration_record Bob s-bbbbbbbbbb.vxapp.io www.example.com competing-claim)"
) & claimant=$!
read -r signal <"$tmp/claim-ready"
(set +e; vx_domain_connection_migration_apply Alice example.com "$revision" >/dev/null; printf '%s\n' "$?" >"$tmp/claim-result") & migration=$!
printf 'release\n' >"$tmp/claim-release"
wait "$claimant"; wait "$migration"
[[ $(cat "$tmp/claim-result") == 9 ]]
vx_domain_connection_record_read www.example.com | jq -e '.OWNER=="Bob"' >/dev/null
[[ $(wc -l <"$VESTA/data/users/Alice/web.conf") == 1 ]]
rm "$tmp/claim-ready" "$tmp/claim-release"
# Both config acceptance and restart failure retain old apex/www and certificate.
for failure in fail-config fail-restart; do
    reset_fixture; prepare_fixture example.com; touch "$tmp/$failure"
    ! vx_domain_connection_migration_apply Alice example.com "$revision"
    [[ $(jq -r .state "$plan/plan.json") == rolled_back ]]
    assert_routes
    cmp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/example.com.crt"
done
# Failed provider cleanup is retryable only against its updated exact revision.
reset_fixture; prepare_fixture example.com
vx_domain_connection_migration_apply Alice example.com "$revision" >/dev/null
touch "$tmp/fail-cleanup"
! vx_domain_connection_migration_rollback Alice example.com "$(jq -r .expectedRevision "$plan/plan.json")"
[[ $(jq -r .state "$plan/plan.json") == recovery_required ]]
vx_domain_connection_migration_rollback Alice example.com "$(jq -r .expectedRevision "$plan/plan.json")"
assert_routes
# Existing managed alias entitlement crosses the batch using its old SAN
# certificate; native TLS installation replaces it before Origin SAN retirement.
reset_managed() {
    reset_fixture
    local row=$base
    vx_cf_migration_row_replace "$row" DOMAIN s-aaaaaaaaaa.vxapp.io; row=$VX_CF_MIGRATION_ROW
    vx_cf_migration_row_replace "$row" ALIAS example.com,www.example.com; row=$VX_CF_MIGRATION_ROW
    vx_cf_migration_row_replace "$row" LETSENCRYPT no; row=$VX_CF_MIGRATION_ROW
    printf '%s\n' "$row" >"$VESTA/data/users/Alice/web.conf"
    for ext in crt key pem; do mv "$VESTA/data/users/Alice/ssl/example.com.$ext" "$VESTA/data/users/Alice/ssl/s-aaaaaaaaaa.vxapp.io.$ext"; done
    rm -f "$HOMEDIR/Alice/conf/web/"*
    VX_CF_ZONE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    vx_cf_write_metadata Alice s-aaaaaaaaaa.vxapp.io bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 93.184.216.34
    vx_cf_write_certificate_metadata Alice s-aaaaaaaaaa.vxapp.io fixtureorigin example.com,s-aaaaaaaaaa.vxapp.io,www.example.com "$(printf '%s\n' example.com s-aaaaaaaaaa.vxapp.io www.example.com | sha256sum | cut -d' ' -f1)"
    vx_domain_connection_migration_render_parent Alice s-aaaaaaaaaa.vxapp.io
    vx_domain_connection_native_restart
}
reset_managed
prepare_fixture s-aaaaaaaaaa.vxapp.io
vx_domain_connection_migration_apply Alice s-aaaaaaaaaa.vxapp.io "$revision" >/dev/null
assert_routes
for name in example.com www.example.com; do cmp "$tmp/replacement.crt" "$VESTA/data/users/Alice/ssl/$name.crt"; done
cmp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/s-aaaaaaaaaa.vxapp.io.crt"
# Connected/DNS readiness is required independently, then origin retirement is
# explicitly recorded as irreversible even when provider cleanup loses response.
! vx_domain_connection_migration_finalize Alice s-aaaaaaaaaa.vxapp.io "$(jq -r .expectedRevision "$plan/plan.json")"
for name in example.com www.example.com; do vx_domain_connection_worker_update "$name" 1 connected https_accepted '{}' true; done
vx_cf_origin_reconcile() { return 1; }
! vx_domain_connection_migration_finalize Alice s-aaaaaaaaaa.vxapp.io "$(jq -r .expectedRevision "$plan/plan.json")"
[[ $(jq -r .state "$plan/plan.json") == recovery_required && $(jq -r .originRetired "$plan/plan.json") == true ]]
! vx_domain_connection_migration_rollback Alice s-aaaaaaaaaa.vxapp.io "$(jq -r .expectedRevision "$plan/plan.json")"
assert_routes
vx_cf_origin_reconcile() {
    VX_CF_ZONE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    vx_cf_write_certificate_metadata "$1" "$2" replacementorigin "$2" "$(printf '%s\n' "$2" | sha256sum | cut -d' ' -f1)"
}
vx_domain_connection_migration_finalize Alice s-aaaaaaaaaa.vxapp.io "$(jq -r .expectedRevision "$plan/plan.json")"
[[ $(jq -r .state "$plan/plan.json") == finalized ]]
vx_cf_load_certificate_metadata Alice s-aaaaaaaaaa.vxapp.io
[[ "$VX_CF_CERT_META_HOSTNAMES" == s-aaaaaaaaaa.vxapp.io ]]
vx_domain_connection_migration_finalize Alice s-aaaaaaaaaa.vxapp.io "$(jq -r .expectedRevision "$plan/plan.json")"
assert_routes
reset_managed; prepare_fixture s-aaaaaaaaaa.vxapp.io; touch "$tmp/fail-acme"
! vx_domain_connection_migration_apply Alice s-aaaaaaaaaa.vxapp.io "$revision"
[[ $(jq -r .state "$plan/plan.json") == rolled_back ]]
assert_routes
cmp "$tmp/site.crt" "$VESTA/data/users/Alice/ssl/s-aaaaaaaaaa.vxapp.io.crt"
printf '%s\n' 'migration: assessment, actual native adapter handover, LE/OriginCA continuity, alias splitting, quota, replay, config/restart/ACME recovery, partial cleanup/finalize and drift passed'
