#!/bin/bash
set -u

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
vesta_root="$work_root/vesta"
stub_curl="$repo_root/test/cloudflare/fixtures/curl-stub"

cleanup() {
    [[ "$work_root" == /tmp/* && -d "$work_root" ]] \
        && /usr/bin/rm -rf -- "$work_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected $2, got $1)"
}

run_vesta() {
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$stub_curl" "$@"
}

/usr/bin/mkdir -p "$vesta_root/bin" "$vesta_root/conf" \
    "$vesta_root/data/users/alice" "$vesta_root/data/ips" "$vesta_root/log"
/usr/bin/ln -s "$repo_root/func" "$vesta_root/func"
for command in v-configure-vx-cloudflare v-list-vx-cloudflare-status \
    v-change-vx-dns-provider v-add-vx-managed-web-domain \
    v-reconcile-vx-cloudflare-web-domain v-delete-vx-cloudflare-web-domain \
    v-add-vx-cloudflare-web-alias; do
    /usr/bin/ln -s "$repo_root/bin/$command" "$vesta_root/bin/$command"
done
for command in v-add-web-domain v-delete-web-domain v-add-web-domain-alias; do
    /usr/bin/ln -s "$repo_root/test/cloudflare/fixtures/native-web-stub" \
        "$vesta_root/bin/$command"
done

printf "DNS_SYSTEM='bind9'\nVX_MANAGED_DNS_PROVIDER='local'\nWEB_SYSTEM='nginx'\n" \
    >"$vesta_root/conf/vesta.conf"
printf "SUSPENDED='no' WEB_DOMAINS='unlimited' WEB_ALIASES='unlimited'\n" \
    >"$vesta_root/data/users/alice/user.conf"
: >"$vesta_root/data/users/alice/web.conf"
printf "NAT='192.0.2.20' OWNER='admin' STATUS='shared'\n" \
    >"$vesta_root/data/ips/192.0.2.10"

status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
assert_eq "$status" not_configured 'initial status is not sanitized'

input="$work_root/cloudflare.input"
printf "API_TOKEN='fixture_token_12345678901234567890'\n" >"$input"
printf "ZONE_ID='0123456789abcdef0123456789abcdef'\n" >>"$input"
printf "ACCOUNT_EMAIL='operator@example.test'\n" >>"$input"
/usr/bin/chmod 0600 "$input"
configure_output=$(run_vesta "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$input") || fail 'configuration failed'
assert_eq "$configure_output" ready 'configuration output is not value-free'

config="$vesta_root/data/vx/cloudflare/config.conf"
[[ "$(/usr/bin/stat -c '%a' "$config")" == 600 ]] \
    || fail 'configuration mode is not 0600'
[[ "$(/usr/bin/stat -c '%a' "${config%/*}")" == 700 ]] \
    || fail 'configuration parent mode is not 0700'
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
assert_eq "$status" ready 'configured status is not ready'
json_status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status" json)
assert_eq "$json_status" '{"status":"ready"}' 'JSON status is not stable'

run_vesta "$vesta_root/bin/v-change-vx-dns-provider" cloudflare-managed \
    || fail 'provider selection failed'
/usr/bin/grep -q "^DNS_SYSTEM='bind9'$" "$vesta_root/conf/vesta.conf" \
    || fail 'DNS_SYSTEM was changed'

domain_one=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" alice \
    192.0.2.10 no none) || fail 'managed create failed'
[[ "$domain_one" =~ ^s-[a-f0-9]{10}\.managed\.example\.test$ ]] \
    || fail 'generated domain has the wrong shape'
[[ -f "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf" ]] \
    || fail 'record metadata is missing'
[[ "$(/usr/bin/stat -c '%a' "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf")" == 600 ]] \
    || fail 'record metadata mode is not 0600'

reconcile=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'no-op reconcile failed'
assert_eq "$reconcile" unchanged 'no-op reconcile was not unchanged'

/usr/bin/sed -i "s/NAT='192.0.2.20'/NAT='192.0.2.21'/" \
    "$vesta_root/data/ips/192.0.2.10"
reconcile=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'drift reconcile failed'
assert_eq "$reconcile" updated 'drift reconcile was not updated'

before_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
: >"$vesta_root/data/vx/cloudflare/native-add-fail"
if failed_create=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" alice \
    192.0.2.10 no none); then
    fail 'partial native create unexpectedly succeeded'
fi
/usr/bin/rm -f -- "$vesta_root/data/vx/cloudflare/native-add-fail"
[[ "$failed_create" == 'Error: native_create_failed' ]] \
    || fail 'partial native create did not return a stable failure'
after_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
assert_eq "$after_domains" "$before_domains" 'partial native create was not compensated'

unowned_domain=s-1111111111.managed.example.test
printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='' SUSPENDED='no'\n" \
    "$unowned_domain" >>"$vesta_root/data/users/alice/web.conf"
printf 'id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nname=%s\naddress=192.0.2.21\n' \
    "$unowned_domain" >"$vesta_root/data/vx/cloudflare/stub-record.conf"
if unowned_output=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$unowned_domain"); then
    fail 'unowned existing record was adopted'
fi
[[ "$unowned_output" == 'Error: ownership_mismatch' ]] \
    || fail 'unowned record failure is not stable'
/usr/bin/sed -i "/^DOMAIN='$unowned_domain' /d" "$vesta_root/data/users/alice/web.conf"
printf 'id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nname=%s\naddress=192.0.2.21\n' \
    "$domain_one" >"$vesta_root/data/vx/cloudflare/stub-record.conf"

run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain_one" \
    custom.example.test || fail 'custom alias delegation failed'
/usr/bin/grep -q "native-alias $domain_one custom.example.test" \
    "$vesta_root/data/vx/cloudflare/native-calls.log" \
    || fail 'custom alias did not use native alias state'

delete_status=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'exact deletion failed'
assert_eq "$delete_status" deleted 'delete status is incorrect'
[[ ! -e "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf" ]] \
    || fail 'metadata remained after deletion'
/usr/bin/grep -q '^delete$' "$vesta_root/data/vx/cloudflare/stub-calls.log" \
    || fail 'exact provider deletion was not called'

delete_status=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'idempotent deletion failed'
assert_eq "$delete_status" unchanged 'idempotent deletion is not unchanged'

before_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
printf 'metadata_failure\n' >"$vesta_root/data/vx/cloudflare/stub-scenario"
if metadata_failure=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" \
    alice 192.0.2.10 no none); then
    fail 'metadata-write failure unexpectedly succeeded'
fi
[[ "$metadata_failure" == 'Error: state_error' ]] \
    || fail 'metadata-write failure is not stable'
[[ ! -s "$vesta_root/data/vx/cloudflare/stub-record.conf" ]] \
    || fail 'metadata-write failure orphaned a provider record'
after_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
assert_eq "$after_domains" "$before_domains" \
    'metadata-write failure did not remove the local website'
for metadata_path in "$vesta_root/data/vx/cloudflare/records/alice/"*.conf; do
    [[ -L "$metadata_path" ]] && /usr/bin/unlink "$metadata_path"
done
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

duplicate_domain=s-2222222222.managed.example.test
printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='' SUSPENDED='no'\n" \
    "$duplicate_domain" >>"$vesta_root/data/users/alice/web.conf"
printf 'duplicate\n' >"$vesta_root/data/vx/cloudflare/stub-scenario"
if duplicate_output=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$duplicate_domain"); then
    fail 'duplicate provider records were accepted'
fi
[[ "$duplicate_output" == 'Error: ambiguous_record' ]] \
    || fail 'duplicate record failure is not stable'
/usr/bin/sed -i "/^DOMAIN='$duplicate_domain' /d" "$vesta_root/data/users/alice/web.conf"
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

for scenario in unauthorized forbidden rate_limited timeout malformed; do
    printf '%s\n' "$scenario" >"$vesta_root/data/vx/cloudflare/stub-scenario"
    failure_status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
    case "$scenario:$failure_status" in
        unauthorized:unauthorized|forbidden:unauthorized|rate_limited:rate_limited|\
        timeout:timeout|malformed:malformed_response) ;;
        *) fail "typed provider failure is wrong for $scenario" ;;
    esac
done
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

[[ ! -e "$vesta_root/data/vx/cloudflare/stub-record.conf" \
    || ! -s "$vesta_root/data/vx/cloudflare/stub-record.conf" ]] \
    || fail 'provider record remained after exact deletion'
if /usr/bin/grep -R -F 'fixture_token_12345678901234567890' \
    "$vesta_root/log" "$vesta_root/data/users" >/dev/null 2>&1; then
    fail 'protected token leaked to logs or user state'
fi

/usr/bin/grep -n 'vx_cf_cleanup.*"\$user".*"\$domain"' \
    "$repo_root/bin/v-delete-web-domain" >/dev/null \
    || fail 'native deletion cleanup hook is missing'
/usr/bin/grep -n 'managed web domains cannot be renamed' \
    "$repo_root/bin/v-change-web-domain-name" >/dev/null \
    || fail 'managed rename guard is missing'

printf 'PASS: Cloudflare managed-domain provider and lifecycle\n'
