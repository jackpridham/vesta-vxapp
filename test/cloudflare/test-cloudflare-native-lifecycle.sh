#!/bin/bash
set -u

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
vesta_root="$work_root/vesta"
home_root="$work_root/home"
domain='s-aaaaaaaaaa.managed.example.test'
zone_id='0123456789abcdef0123456789abcdef'

cleanup() {
    [[ "${VX_CLOUDFLARE_KEEP_TEST_ROOT:-no}" != yes ]] || {
        printf 'test root retained: %s\n' "$work_root" >&2
        return
    }
    [[ "$work_root" == /tmp/* && -d "$work_root" ]] \
        && /usr/bin/rm -rf -- "$work_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

assert_file_contains() {
    /usr/bin/grep -Fq -- "$2" "$1" || fail "$3"
}

assert_file_order() {
    local file=$1 first=$2 second=$3 message=$4 first_line second_line
    first_line=$(/usr/bin/grep -nF -- "$first" "$file" \
        | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)
    second_line=$(/usr/bin/grep -nF -- "$second" "$file" \
        | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)
    [[ -n "$first_line" && -n "$second_line" \
        && "$first_line" -lt "$second_line" ]] || fail "$message"
}

run_vesta() {
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_HOME="$home_root" "$@"
}

run_vesta_internal_ssl() {
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_HOME="$home_root" \
        VX_CLOUDFLARE_INTERNAL_ORIGIN_SSL=1 "$@"
}

expect_failure() {
    local expected=$1 description=$2
    shift 2
    "$@" >"$work_root/failure.out" 2>&1
    local result=$?
    [[ "$result" -eq "$expected" ]] \
        || fail "$description (expected exit $expected, got $result: $(<"$work_root/failure.out"))"
}

write_record_metadata() {
    local metadata="$vesta_root/data/vx/cloudflare/records/alice/$domain.conf"
    local metadata_zone=${1:-$zone_id}
    /usr/bin/mkdir -p "${metadata%/*}"
    {
        printf "VALID='yes'\n"
        printf "USER='alice'\n"
        printf "DOMAIN='%s'\n" "$domain"
        printf "ZONE_ID='%s'\n" "$metadata_zone"
    } >"$metadata"
}

write_certificate_metadata() {
    local metadata="$vesta_root/data/vx/cloudflare/certificates/alice/$domain.conf"
    local metadata_zone=${1:-$zone_id}
    local valid=${2:-yes}
    /usr/bin/mkdir -p "${metadata%/*}"
    {
        printf "VALID='%s'\n" "$valid"
        printf "USER='alice'\n"
        printf "DOMAIN='%s'\n" "$domain"
        printf "ZONE_ID='%s'\n" "$metadata_zone"
        printf "HOSTNAMES='%s,custom.example.test'\n" "$domain"
    } >"$metadata"
}

clear_metadata() {
    /usr/bin/rm -rf -- "$vesta_root/data/vx/cloudflare/records/alice" \
        "$vesta_root/data/vx/cloudflare/certificates/alice"
}

reset_domain() {
    local ssl=${1:-no} letsencrypt=${2:-no}
    /usr/bin/rm -rf -- "$vesta_root/data/users/alice/ssl" \
        "$home_root/alice/web/$domain" "$home_root/alice/conf/web"
    /usr/bin/mkdir -p "$vesta_root/data/users/alice/ssl" \
        "$home_root/alice/web/$domain/private" "$home_root/alice/conf/web"
    printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='' SSL='%s' SSL_HOME='same' LETSENCRYPT='%s' SUSPENDED='no' TPL='default' PROXY=''\n" \
        "$domain" "$ssl" "$letsencrypt" \
        >"$vesta_root/data/users/alice/web.conf"
    : >"$vesta_root/native-lifecycle.log"
    /usr/bin/rm -f -- "$vesta_root/data/vx/cloudflare/reconcile-fail-once" \
        "$vesta_root/data/vx/cloudflare/origin-reconcile-fail-once" \
        "$vesta_root/data/vx/cloudflare/primary-cleanup-fail-once" \
        "$vesta_root/data/vx/cloudflare/origin-cleanup-fail-once" \
        "$vesta_root/restart-web-fail-once"
}

install_old_certificate_files() {
    local suffix value
    for suffix in crt key pem ca; do
        value="old-$suffix"
        printf '%s\n' "$value" \
            >"$vesta_root/data/users/alice/ssl/$domain.$suffix"
        printf '%s\n' "$value" \
            >"$home_root/alice/conf/web/ssl.$domain.$suffix"
    done
}

/usr/bin/mkdir -p "$vesta_root/bin" "$vesta_root/conf" \
    "$vesta_root/func/vx/cloudflare" "$vesta_root/data/users/alice" \
    "$vesta_root/data/vx/cloudflare" "$vesta_root/log" "$home_root"
/usr/bin/ln -s "$repo_root/test/cloudflare/fixtures/native-lifecycle-main-stub" \
    "$vesta_root/func/main.sh"
/usr/bin/ln -s "$repo_root/test/cloudflare/fixtures/native-lifecycle-cloudflare-stub" \
    "$vesta_root/func/vx/cloudflare/main.sh"
: >"$vesta_root/func/domain.sh"
: >"$vesta_root/func/ip.sh"

for command in v-change-web-domain-ip v-delete-web-domains \
    v-add-vx-cloudflare-web-alias v-change-web-domain-sslcert \
    v-add-web-domain-ssl v-delete-web-domain-ssl v-add-letsencrypt-domain \
    v-delete-letsencrypt-domain v-list-vx-cloudflare-web-domain-status \
    v-delete-vx-cloudflare-web-domain; do
    /usr/bin/ln -s "$repo_root/bin/$command" "$vesta_root/bin/$command"
done

printf "WEB_SYSTEM='nginx'\nWEB_SSL='yes'\nPROXY_SYSTEM=''\nVESTA_CERTIFICATE=''\nMAIL_CERTIFICATE=''\nUPDATE_HOSTNAME_SSL=''\n" \
    >"$vesta_root/conf/vesta.conf"

cat >"$vesta_root/bin/v-restart-web" <<'EOF'
#!/bin/bash
printf 'restart-web\n' >>"$VESTA/native-lifecycle.log"
if [ -f "$VESTA/restart-web-fail-once" ]; then
    /usr/bin/rm -f -- "$VESTA/restart-web-fail-once"
    exit 23
fi
exit 0
EOF
cat >"$vesta_root/bin/v-restart-proxy" <<'EOF'
#!/bin/bash
printf 'restart-proxy\n' >>"$VESTA/native-lifecycle.log"
exit 0
EOF
cat >"$vesta_root/bin/v-add-web-domain-alias" <<'EOF'
#!/bin/bash
printf 'native-alias %s %s\n' "$2" "$3" >>"$VESTA/native-lifecycle.log"
exit 0
EOF
cat >"$vesta_root/bin/v-delete-web-domain" <<'EOF'
#!/bin/bash
printf 'native-delete %s\n' "$2" >>"$VESTA/native-lifecycle.log"
[ "$2" != fail.example.test ] || exit 15
/usr/bin/sed -i "/^DOMAIN='$2' /d" "$VESTA/data/users/$1/web.conf"
exit 0
EOF
/usr/bin/chmod 755 "$vesta_root/bin/v-restart-web" \
    "$vesta_root/bin/v-restart-proxy" "$vesta_root/bin/v-add-web-domain-alias" \
    "$vesta_root/bin/v-delete-web-domain"

# The status adapter distinguishes no authority, degraded partial authority,
# and a fully validated exact record+certificate pair.
reset_domain no no
clear_metadata
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'unmanaged status read failed'
assert_eq "$status" unmanaged 'metadata-free site status is wrong'
write_record_metadata
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'record-only status read failed'
assert_eq "$status" degraded 'record-only site was not degraded'
write_certificate_metadata
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'managed status read failed'
assert_eq "$status" managed 'exact metadata pair was not managed'
write_certificate_metadata "$zone_id" no
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'invalid certificate metadata status read failed'
assert_eq "$status" degraded 'invalid exact metadata did not fail closed'
/usr/bin/rm -f -- "$vesta_root/data/vx/cloudflare/records/alice/$domain.conf"
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'certificate-only status read failed'
assert_eq "$status" degraded 'certificate-only site was not degraded'
clear_metadata
/usr/bin/mkdir -p "$vesta_root/data/vx/cloudflare/records/alice"
/usr/bin/ln -s "$work_root/missing-record-metadata" \
    "$vesta_root/data/vx/cloudflare/records/alice/$domain.conf"
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-web-domain-status" \
    alice "$domain") || fail 'unsafe metadata-path status read failed'
assert_eq "$status" degraded 'unsafe exact metadata path did not fail closed'

# A generated technical name is not alias authority without its exact record
# metadata. The same exact row succeeds after matching metadata is present.
reset_domain no no
clear_metadata
expect_failure 10 'unowned generated alias target was accepted' run_vesta \
    "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain" \
    custom.example.test no
[[ ! -s "$vesta_root/native-lifecycle.log" ]] \
    || fail 'unowned alias target reached the native alias command'
write_record_metadata
run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain" \
    custom.example.test no >/dev/null \
    || fail 'exact metadata-owned alias target was rejected'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "native-alias $domain custom.example.test" \
    'owned alias target did not delegate to native state'

# Unmanaged IP changes stay native-only. Exact managed changes reconcile, and
# a provider failure restores local state then reconciles that restored IP.
reset_domain no no
clear_metadata
run_vesta "$vesta_root/bin/v-change-web-domain-ip" alice "$domain" \
    192.0.2.20 no >/dev/null || fail 'unmanaged IP change failed'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "IP='192.0.2.20'" \
    'unmanaged IP state was not updated'
if /usr/bin/grep -Fq 'reconcile ' "$vesta_root/native-lifecycle.log"; then
    fail 'unmanaged generated name reached provider reconciliation'
fi

reset_domain no no
write_record_metadata
run_vesta "$vesta_root/bin/v-change-web-domain-ip" alice "$domain" \
    192.0.2.21 no >/dev/null || fail 'managed IP change failed'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "IP='192.0.2.21'" \
    'managed IP state was not updated'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.21" 'managed IP was not reconciled'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "origin-reconcile $domain 192.0.2.21" \
    'managed IP did not run Origin/provider preflight'
assert_file_order "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.21" \
    "origin-reconcile $domain 192.0.2.21" \
    'Origin/provider preflight ran before primary DNS readback'

reset_domain no no
write_record_metadata
: >"$vesta_root/data/vx/cloudflare/reconcile-fail-once"
expect_failure 15 'provider IP failure did not propagate' run_vesta \
    "$vesta_root/bin/v-change-web-domain-ip" alice "$domain" 192.0.2.22 no
assert_file_contains "$vesta_root/data/users/alice/web.conf" "IP='192.0.2.10'" \
    'provider failure did not restore native IP state'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.22" 'failed new IP reconciliation was not attempted'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.10" 'restored IP was not reconciled'

reset_domain no no
write_record_metadata
write_certificate_metadata
: >"$vesta_root/data/vx/cloudflare/origin-reconcile-fail-once"
expect_failure 15 'Origin/provider IP preflight failure did not propagate' \
    run_vesta "$vesta_root/bin/v-change-web-domain-ip" alice "$domain" \
    192.0.2.24 no
assert_file_contains "$vesta_root/data/users/alice/web.conf" "IP='192.0.2.10'" \
    'Origin/provider preflight failure did not restore native IP state'
assert_file_order "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.24" \
    "origin-reconcile $domain 192.0.2.24" \
    'Origin/provider failure was not preceded by primary DNS readback'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "reconcile $domain 192.0.2.10" \
    'Origin/provider failure did not reconcile the restored primary IP'

reset_domain no no
clear_metadata
write_certificate_metadata
expect_failure 15 'certificate-only degraded IP change was accepted' run_vesta \
    "$vesta_root/bin/v-change-web-domain-ip" alice "$domain" 192.0.2.23 no
assert_file_contains "$vesta_root/data/users/alice/web.conf" "IP='192.0.2.10'" \
    'degraded IP guard changed native state'

# Generic SSL paths fail closed on either exact metadata type. Unmanaged root
# operation remains unchanged, while the narrow internal VX capability can
# install, replace, and remove Origin material.
cert_source="$work_root/certificates"
/usr/bin/mkdir -p "$cert_source"
printf 'new-certificate\n' >"$cert_source/$domain.crt"
printf 'new-key\n' >"$cert_source/$domain.key"
printf 'new-ca\n' >"$cert_source/$domain.ca"

reset_domain no no
clear_metadata
/usr/bin/mkdir -p "$vesta_root/data/vx/cloudflare/records/alice"
/usr/bin/ln -s "$work_root/missing-record-metadata" \
    "$vesta_root/data/vx/cloudflare/records/alice/$domain.conf"
expect_failure 10 'unsafe exact metadata path bypassed native SSL guard' run_vesta \
    "$vesta_root/bin/v-add-web-domain-ssl" alice "$domain" "$cert_source" same no

reset_domain no no
clear_metadata
run_vesta "$vesta_root/bin/v-add-web-domain-ssl" alice "$domain" \
    "$cert_source" same no >/dev/null || fail 'unmanaged native SSL add changed behavior'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "SSL='yes'" \
    'unmanaged native SSL add did not update state'

reset_domain no no
write_record_metadata
expect_failure 10 'managed native SSL add was accepted' run_vesta \
    "$vesta_root/bin/v-add-web-domain-ssl" alice "$domain" "$cert_source" same no
run_vesta_internal_ssl "$vesta_root/bin/v-add-web-domain-ssl" alice "$domain" \
    "$cert_source" same no >/dev/null \
    || fail 'internal Origin SSL add capability was rejected'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "SSL='yes'" \
    'internal Origin SSL add did not update state'

reset_domain yes no
clear_metadata
write_certificate_metadata
install_old_certificate_files
expect_failure 10 'certificate-owned native SSL change was accepted' run_vesta \
    "$vesta_root/bin/v-change-web-domain-sslcert" alice "$domain" \
    "$cert_source" no
run_vesta_internal_ssl "$vesta_root/bin/v-change-web-domain-sslcert" alice \
    "$domain" "$cert_source" no >/dev/null \
    || fail 'internal Origin SSL change capability was rejected'
assert_file_contains "$vesta_root/data/users/alice/ssl/$domain.crt" \
    'new-certificate' 'internal Origin SSL replacement was not installed'
if /usr/bin/find -P "$home_root/alice/web/$domain/private" -mindepth 1 \
    -maxdepth 1 -type d -name 'tmp.*' -print -quit | /usr/bin/grep -q .; then
    fail 'internal Origin SSL replacement retained tenant-tree staging state'
fi

reset_domain yes no
clear_metadata
write_record_metadata
install_old_certificate_files
: >"$vesta_root/restart-web-fail-once"
expect_failure 23 'SSL restart failure did not propagate' run_vesta_internal_ssl \
    "$vesta_root/bin/v-change-web-domain-sslcert" alice "$domain" \
    "$cert_source" yes
assert_file_contains "$vesta_root/data/users/alice/ssl/$domain.crt" \
    'old-crt' 'restart failure did not restore canonical certificate'
assert_file_contains "$home_root/alice/conf/web/ssl.$domain.crt" \
    'old-crt' 'restart failure did not restore rendered certificate'
if /usr/bin/find -P "$home_root/alice/web/$domain/private" -mindepth 1 \
    -maxdepth 1 -type d -name 'tmp.*' -print -quit | /usr/bin/grep -q .; then
    fail 'restored internal Origin SSL retained tenant-tree staging state'
fi

reset_domain yes no
clear_metadata
write_record_metadata
install_old_certificate_files
expect_failure 10 'managed native SSL delete was accepted' run_vesta \
    "$vesta_root/bin/v-delete-web-domain-ssl" alice "$domain" no
run_vesta_internal_ssl "$vesta_root/bin/v-delete-web-domain-ssl" alice \
    "$domain" no >/dev/null 2>&1 \
    || fail 'internal Origin SSL delete capability was rejected'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "SSL='no'" \
    'internal Origin SSL delete did not update state'

# ACME add/delete never accept the internal Origin capability and fail before
# any network or child SSL mutation when either exact metadata path remains.
reset_domain yes yes
clear_metadata
write_certificate_metadata
expect_failure 10 'managed LetsEncrypt add was accepted' run_vesta \
    "$vesta_root/bin/v-add-letsencrypt-domain" alice "$domain" ''
expect_failure 10 'managed LetsEncrypt delete was accepted with internal capability' \
    run_vesta_internal_ssl "$vesta_root/bin/v-delete-letsencrypt-domain" \
    alice "$domain" no

# Both managed deletion entry points confirm the exact primary DNS deletion
# before Origin certificate revocation. A later Origin failure leaves native
# state and certificate authority intact for an idempotent retry.
reset_domain no no
clear_metadata
write_record_metadata
write_certificate_metadata
run_vesta "$repo_root/bin/v-delete-web-domain" alice "$domain" no \
    >/dev/null || fail 'native managed web-domain deletion failed'
assert_file_order "$vesta_root/native-lifecycle.log" \
    "cleanup-primary $domain" "cleanup-origin $domain" \
    'native managed deletion revoked Origin before primary DNS readback'
if /usr/bin/grep -Fq "DOMAIN='$domain'" \
    "$vesta_root/data/users/alice/web.conf"; then
    fail 'native state remained after both provider cleanups succeeded'
fi

reset_domain no no
clear_metadata
write_record_metadata
write_certificate_metadata
: >"$vesta_root/data/vx/cloudflare/origin-cleanup-fail-once"
expect_failure 15 'native Origin cleanup failure did not propagate' run_vesta \
    "$repo_root/bin/v-delete-web-domain" alice "$domain" no
assert_file_order "$vesta_root/native-lifecycle.log" \
    "cleanup-primary $domain" "cleanup-origin $domain" \
    'native failure path revoked Origin before primary DNS readback'
[[ ! -e "$vesta_root/data/vx/cloudflare/records/alice/$domain.conf" ]] \
    || fail 'confirmed primary metadata remained after its deletion'
[[ -f "$vesta_root/data/vx/cloudflare/certificates/alice/$domain.conf" ]] \
    || fail 'failed Origin cleanup lost exact certificate authority'
assert_file_contains "$vesta_root/data/users/alice/web.conf" "DOMAIN='$domain'" \
    'native state was deleted after Origin cleanup failure'
: >"$vesta_root/native-lifecycle.log"
run_vesta "$repo_root/bin/v-delete-web-domain" alice "$domain" no \
    >/dev/null || fail 'native managed deletion retry failed'
if /usr/bin/grep -Fq 'cleanup-primary ' "$vesta_root/native-lifecycle.log"; then
    fail 'native retry repeated an already confirmed primary deletion'
fi
assert_file_contains "$vesta_root/native-lifecycle.log" \
    "cleanup-origin $domain" 'native retry did not resume Origin cleanup'

reset_domain no no
clear_metadata
write_record_metadata
write_certificate_metadata
delete_status=$(run_vesta \
    "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" alice "$domain") \
    || fail 'explicit managed provider deletion failed'
assert_eq "$delete_status" deleted \
    'explicit managed provider deletion status was not aggregated'
assert_file_order "$vesta_root/native-lifecycle.log" \
    "cleanup-primary $domain" "cleanup-origin $domain" \
    'explicit managed deletion revoked Origin before primary DNS readback'
delete_status=$(run_vesta \
    "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" alice "$domain") \
    || fail 'explicit managed provider deletion retry failed'
assert_eq "$delete_status" unchanged \
    'explicit managed provider deletion was not idempotent'

reset_domain no no
clear_metadata
write_record_metadata
write_certificate_metadata
: >"$vesta_root/data/vx/cloudflare/primary-cleanup-fail-once"
expect_failure 15 'primary cleanup failure did not stop explicit deletion' \
    run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$domain"
[[ -f "$vesta_root/data/vx/cloudflare/certificates/alice/$domain.conf" ]] \
    || fail 'primary cleanup failure revoked exact Origin authority'
if /usr/bin/grep -Fq 'cleanup-origin ' "$vesta_root/native-lifecycle.log"; then
    fail 'explicit deletion attempted Origin cleanup after primary failure'
fi

# The bulk adapter stops on a failed exact child deletion and returns that
# failure. v-delete-user already checks this result before local user removal.
clear_metadata
printf "DOMAIN='ok.example.test' IP='192.0.2.10' SSL='no' SUSPENDED='no'\nDOMAIN='fail.example.test' IP='192.0.2.10' SSL='no' SUSPENDED='no'\nDOMAIN='later.example.test' IP='192.0.2.10' SSL='no' SUSPENDED='no'\n" \
    >"$vesta_root/data/users/alice/web.conf"
: >"$vesta_root/native-lifecycle.log"
expect_failure 15 'bulk web delete swallowed child failure' run_vesta \
    "$vesta_root/bin/v-delete-web-domains" alice no
assert_file_contains "$vesta_root/native-lifecycle.log" \
    'native-delete ok.example.test' 'bulk delete did not start in order'
assert_file_contains "$vesta_root/native-lifecycle.log" \
    'native-delete fail.example.test' 'bulk delete did not expose failing child'
if /usr/bin/grep -Fq 'native-delete later.example.test' \
    "$vesta_root/native-lifecycle.log"; then
    fail 'bulk delete continued after a child provider failure'
fi
if /usr/bin/grep -Fq 'restart-web' "$vesta_root/native-lifecycle.log"; then
    fail 'bulk delete restarted services after a child failure'
fi
/usr/bin/grep -Fq 'check_result "$?" "web domain deletion failed"' \
    "$repo_root/bin/v-delete-user" \
    || fail 'v-delete-user does not preserve bulk web deletion failure'

printf 'PASS: Cloudflare native lifecycle guards and rollback\n'
