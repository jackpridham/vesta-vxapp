#!/bin/bash
set -u

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
vesta_root="$work_root/vesta"
strict_stub="$repo_root/test/cloudflare/fixtures/strict-lifecycle-stub"

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
    [[ "$1" == "$2" ]] || fail "$3 (expected $2, got $1)"
}

run_vesta() {
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" "$@"
}

/usr/bin/mkdir -p "$vesta_root/bin" "$vesta_root/conf" \
    "$vesta_root/data/users/alice" "$vesta_root/data/ips" "$vesta_root/log" \
    "$vesta_root/home/alice/conf/web"
/usr/bin/ln -s "$repo_root/func" "$vesta_root/func"
for command in v-configure-vx-cloudflare v-list-vx-cloudflare-status \
    v-change-vx-dns-provider v-add-vx-managed-web-domain \
    v-reconcile-vx-cloudflare-web-domain v-delete-vx-cloudflare-web-domain \
    v-add-vx-cloudflare-web-alias v-reconcile-vx-cloudflare-origin-ssl \
    v-delete-vx-cloudflare-origin-ssl; do
    /usr/bin/ln -s "$repo_root/bin/$command" "$vesta_root/bin/$command"
done
for command in v-add-web-domain v-delete-web-domain v-add-web-domain-alias \
    v-delete-web-domain-alias v-add-web-domain-ssl \
    v-change-web-domain-sslcert v-delete-web-domain-ssl; do
    /usr/bin/ln -s "$strict_stub" \
        "$vesta_root/bin/$command"
done

printf "DNS_SYSTEM='bind9'\nVX_MANAGED_DNS_PROVIDER='local'\nWEB_SYSTEM='nginx'\nHOMEDIR='%s'\n" \
    "$vesta_root/home" >"$vesta_root/conf/vesta.conf"
printf "SUSPENDED='no' WEB_DOMAINS='unlimited' WEB_ALIASES='unlimited'\n" \
    >"$vesta_root/data/users/alice/user.conf"
: >"$vesta_root/data/users/alice/web.conf"
printf "NAT='192.0.2.20' OWNER='admin' STATUS='shared'\n" \
    >"$vesta_root/data/ips/192.0.2.10"

status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
assert_eq "$status" not_configured 'initial status is not sanitized'

cloudflare_root="$vesta_root/data/vx/cloudflare"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj '/C=US/O=Cloudflare Test/OU=Cloudflare Origin SSL Certificate Authority' \
    -keyout "$cloudflare_root/stub-origin-ca.key" \
    -out "$cloudflare_root/stub-origin-ca.pem" >/dev/null 2>&1 \
    || fail 'test Origin CA generation failed'
/usr/bin/chmod 0600 "$cloudflare_root/stub-origin-ca.key" \
    "$cloudflare_root/stub-origin-ca.pem"

input="$work_root/cloudflare.input"
printf "API_TOKEN='fixture_token_12345678901234567890'\n" >"$input"
printf "ZONE_ID='0123456789abcdef0123456789abcdef'\n" >>"$input"
printf "ACCOUNT_EMAIL='operator@example.test'\n" >>"$input"
/usr/bin/chmod 0600 "$input"
printf 'edge_missing\n' >"$cloudflare_root/stub-scenario"
if missing_edge_config=$(run_vesta "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$input"); then
    fail 'configuration accepted a zone without primary edge coverage'
fi
assert_eq "$missing_edge_config" 'Error: edge_certificate_missing' \
    'primary edge preflight failure is not stable'
[[ ! -e "$cloudflare_root/config.conf" ]] \
    || fail 'failed edge preflight replaced Cloudflare configuration'
: >"$cloudflare_root/stub-scenario"
configure_output=$(run_vesta "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$input") || fail 'configuration failed'
assert_eq "$configure_output" ready 'configuration output is not value-free'

config="$vesta_root/data/vx/cloudflare/config.conf"
[[ "$(/usr/bin/stat -c '%a' "$config")" == 600 ]] \
    || fail 'configuration mode is not 0600'
[[ "$(/usr/bin/stat -c '%a' "${config%/*}")" == 700 ]] \
    || fail 'configuration parent mode is not 0700'
strict_state="$cloudflare_root/stub-zone-0123456789abcdef0123456789abcdef-ssl"
assert_eq "$(<"$strict_state")" strict 'configuration did not enforce Full (strict)'
/usr/bin/grep -q '^ssl-patch 0123456789abcdef0123456789abcdef strict$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'strict setting PATCH was not sent through protected transport'
patch_count_before=$(/usr/bin/grep -c '^ssl-patch ' "$cloudflare_root/stub-calls.log")
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
assert_eq "$status" ready 'configured status is not ready'
json_status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status" json)
assert_eq "$json_status" '{"status":"ready"}' 'JSON status is not stable'
patch_count_after=$(/usr/bin/grep -c '^ssl-patch ' "$cloudflare_root/stub-calls.log")
assert_eq "$patch_count_after" "$patch_count_before" \
    'read-only status performed a mutating strict probe'
/usr/bin/grep -q '^origin-list$' "$cloudflare_root/stub-calls.log" \
    || fail 'status omitted the Origin CA read preflight'
/usr/bin/grep -q '^edge-list 0123456789abcdef0123456789abcdef$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'status omitted primary edge certificate coverage'

printf 'full\n' >"$strict_state"
status=$(run_vesta "$vesta_root/bin/v-list-vx-cloudflare-status")
assert_eq "$status" strict_not_enabled 'status accepted non-strict zone mode'

run_vesta "$vesta_root/bin/v-change-vx-dns-provider" cloudflare-managed \
    || fail 'provider selection failed'
assert_eq "$(<"$strict_state")" strict 'provider enable did not restore Full (strict)'
/usr/bin/grep -q "^DNS_SYSTEM='bind9'$" "$vesta_root/conf/vesta.conf" \
    || fail 'DNS_SYSTEM was changed'

before_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
printf 'non_a_collision\n' >"$cloudflare_root/stub-scenario"
if non_a_collision=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" \
    alice 192.0.2.10 no none); then
    fail 'allocator accepted an occupied non-A Cloudflare hostname'
fi
assert_eq "$non_a_collision" 'Error: collision_limit' \
    'non-A provider collision did not exhaust bounded allocation'
after_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
assert_eq "$after_domains" "$before_domains" \
    'non-A provider collision reached native website creation'
: >"$cloudflare_root/stub-scenario"

migration_source=migration.example.test
migration_target=s-3333333333.managed.example.test
printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='a-record.example.test' SSL='no' SUSPENDED='no'\n" \
    "$migration_source" >>"$vesta_root/data/users/alice/web.conf"
alias_strict_state="$cloudflare_root/stub-zone-fedcba9876543210fedcba9876543210-ssl"
printf 'strict\n' >"$alias_strict_state"
patch_count_before=$(/usr/bin/grep -c '^ssl-patch ' "$cloudflare_root/stub-calls.log")
migration_preflight=$(
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" /bin/bash -c '
            BIN="$VESTA/bin"
            source "$VESTA/func/vx/cloudflare/main.sh"
            source "$VESTA/conf/vesta.conf"
            vx_cf_lock_acquire || exit 91
            vx_cf_migration_preflight_locked "$1" "$2" "$3" || exit 92
            printf "%s|%s|%s\n" "$VX_CF_STATUS" \
                "$VX_CF_MIGRATION_HOSTNAMES_CSV" "$VX_CF_WEB_ADDRESS"
            vx_cf_lock_release || exit 93
        ' _ alice "$migration_source" "$migration_target"
) || fail 'GET-only migration preflight failed'
assert_eq "$migration_preflight" \
    'ready|a-record.example.test,migration.example.test,s-3333333333.managed.example.test|192.0.2.20' \
    'migration preflight did not derive the exact hypothetical final state'
patch_count_after=$(/usr/bin/grep -c '^ssl-patch ' "$cloudflare_root/stub-calls.log")
assert_eq "$patch_count_after" "$patch_count_before" \
    'migration preflight mutated a zone strict setting'
/usr/bin/sed -i "/^DOMAIN='$migration_source' /d" \
    "$vesta_root/data/users/alice/web.conf"

observed_target=s-4444444444.managed.example.test
observed_record_id_file="$work_root/observed-record-id"
observed_certificate_id_file="$work_root/observed-certificate-id"
printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='%s,a-record.example.test' SSL='no' SUSPENDED='no'\n" \
    "$observed_target" "$migration_source" \
    >>"$vesta_root/data/users/alice/web.conf"
observer_apply_status=$(
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" \
        VX_CLOUDFLARE_INTERNAL_MIGRATION=1 \
        VX_CF_TEST_RECORD_OBSERVER="$observed_record_id_file" \
        VX_CF_TEST_CERTIFICATE_OBSERVER="$observed_certificate_id_file" \
        /bin/bash -c '
            BIN="$VESTA/bin"
            source "$VESTA/func/vx/cloudflare/main.sh"
            source "$VESTA/conf/vesta.conf"
            vx_cf_migration_observe_record_id() {
                (umask 077; printf "%s\n" "$1" >"$VX_CF_TEST_RECORD_OBSERVER")
            }
            vx_cf_migration_observe_certificate_id() {
                (umask 077; printf "%s\n" "$1" >"$VX_CF_TEST_CERTIFICATE_OBSERVER")
            }
            vx_cf_lock_acquire || exit 91
            vx_cf_reconcile_locked "$1" "$2" || exit 92
            vx_cf_origin_reconcile_locked "$1" "$2" no || exit 93
            result=$VX_CF_STATUS
            vx_cf_lock_release || exit 94
            printf "%s\n" "$result"
        ' _ alice "$observed_target"
) || fail 'same-shell migration observers rejected a managed apply'
assert_eq "$observer_apply_status" ssl_ready \
    'observer-backed Origin apply returned the wrong status'
[[ "$(<"$observed_record_id_file")" =~ ^[a-f0-9]{32}$ ]] \
    || fail 'record observer did not receive the exact created ID'
[[ "$(<"$observed_certificate_id_file")" =~ ^[A-Za-z0-9_-]{1,64}$ ]] \
    || fail 'certificate observer did not receive the exact created ID'
[[ "$(/usr/bin/stat -c '%a' "$observed_record_id_file")" == 600 \
    && "$(/usr/bin/stat -c '%a' "$observed_certificate_id_file")" == 600 ]] \
    || fail 'fixture observers did not protect captured IDs'
/usr/bin/grep -q "^native-ssl-migration $observed_target$" \
    "$cloudflare_root/native-calls.log" \
    || fail 'internal Origin child omitted the parent migration capability'

mutation_count_before=$(/usr/bin/grep -Ec \
    '^(create |update$|delete$|origin-create |origin-delete |ssl-patch )' \
    "$cloudflare_root/stub-calls.log" || :)
managed_verify=$(
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" /bin/bash -c '
            BIN="$VESTA/bin"
            source "$VESTA/func/vx/cloudflare/main.sh"
            source "$VESTA/conf/vesta.conf"
            vx_cf_lock_acquire || exit 91
            vx_cf_verify_managed_site_locked "$1" "$2" || exit 92
            printf "%s\n" "$VX_CF_STATUS"
            vx_cf_lock_release || exit 93
        ' _ alice "$observed_target"
) || fail 'read-only exact managed-site verification failed'
assert_eq "$managed_verify" managed \
    'exact managed-site verification returned the wrong status'
mutation_count_after=$(/usr/bin/grep -Ec \
    '^(create |update$|delete$|origin-create |origin-delete |ssl-patch )' \
    "$cloudflare_root/stub-calls.log" || :)
assert_eq "$mutation_count_after" "$mutation_count_before" \
    'managed-site verification performed a provider mutation'

VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
    VX_CLOUDFLARE_TEST_CURL="$strict_stub" /bin/bash -c '
        BIN="$VESTA/bin"
        source "$VESTA/func/vx/cloudflare/main.sh"
        source "$VESTA/conf/vesta.conf"
        vx_cf_lock_acquire || exit 91
        vx_cf_cleanup_locked "$1" "$2" || exit 92
        vx_cf_origin_cleanup_locked "$1" "$2" || exit 93
        vx_cf_lock_release || exit 94
    ' _ alice "$observed_target" \
    || fail 'observer-backed managed fixture cleanup failed'
/usr/bin/sed -i "/^DOMAIN='$observed_target' /d" \
    "$vesta_root/data/users/alice/web.conf"
/usr/bin/rm -f -- "$vesta_root/data/users/alice/ssl/$observed_target."{crt,key,ca,pem} \
    "$vesta_root/home/alice/conf/web/ssl.$observed_target."{crt,key,ca,pem}

observer_failure_target=s-5555555555.managed.example.test
printf "DOMAIN='%s' IP='192.0.2.10' ALIAS='' SSL='no' SUSPENDED='no'\n" \
    "$observer_failure_target" >>"$vesta_root/data/users/alice/web.conf"
record_observer_failure=$(
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" /bin/bash -c '
            BIN="$VESTA/bin"
            source "$VESTA/func/vx/cloudflare/main.sh"
            source "$VESTA/conf/vesta.conf"
            vx_cf_migration_observe_record_id() { return 1; }
            vx_cf_lock_acquire || exit 91
            if vx_cf_reconcile_locked "$1" "$2"; then exit 92; fi
            result=$VX_CF_STATUS
            vx_cf_lock_release || exit 93
            printf "%s\n" "$result"
        ' _ alice "$observer_failure_target"
) || fail 'record observer failure harness failed'
assert_eq "$record_observer_failure" state_error \
    'record observer failure did not return state_error'
[[ ! -s "$cloudflare_root/stub-record.conf" \
    && ! -e "$cloudflare_root/records/alice/$observer_failure_target.conf" ]] \
    || fail 'record observer failure was not exactly compensated'

origin_creates_before=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
certificate_observer_failure=$(
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" /bin/bash -c '
            BIN="$VESTA/bin"
            source "$VESTA/func/vx/cloudflare/main.sh"
            source "$VESTA/conf/vesta.conf"
            vx_cf_migration_observe_certificate_id() { return 1; }
            vx_cf_lock_acquire || exit 91
            vx_cf_reconcile_locked "$1" "$2" || exit 92
            if vx_cf_origin_reconcile_locked "$1" "$2" no; then exit 93; fi
            result=$VX_CF_STATUS
            vx_cf_cleanup_locked "$1" "$2" || exit 94
            vx_cf_lock_release || exit 95
            printf "%s\n" "$result"
        ' _ alice "$observer_failure_target"
) || fail 'certificate observer failure harness failed'
assert_eq "$certificate_observer_failure" state_error \
    'certificate observer failure did not return state_error'
origin_creates_after=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
assert_eq "$origin_creates_after" "$((origin_creates_before + 1))" \
    'certificate observer failure did not reach ID parsing'
failed_observer_certificate_id=$(/usr/bin/grep '^origin-create ' \
    "$cloudflare_root/stub-calls.log" | /usr/bin/tail -n1 \
    | /usr/bin/cut -d ' ' -f2)
/usr/bin/grep -q "^origin-delete $failed_observer_certificate_id$" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'certificate observer failure did not revoke the exact new ID'
[[ ! -e "$cloudflare_root/certificates/alice/$observer_failure_target.conf" ]] \
    || fail 'certificate observer failure created certificate metadata'
/usr/bin/sed -i "/^DOMAIN='$observer_failure_target' /d" \
    "$vesta_root/data/users/alice/web.conf"

domain_one=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" alice \
    192.0.2.10 no none) || fail 'managed create failed'
[[ "$domain_one" =~ ^s-[a-f0-9]{10}\.managed\.example\.test$ ]] \
    || fail 'generated domain has the wrong shape'
[[ -f "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf" ]] \
    || fail 'record metadata is missing'
[[ "$(/usr/bin/stat -c '%a' "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf")" == 600 ]] \
    || fail 'record metadata mode is not 0600'
certificate_metadata="$vesta_root/data/vx/cloudflare/certificates/alice/$domain_one.conf"
[[ -f "$certificate_metadata" ]] || fail 'certificate metadata is missing'
record_metadata="$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf"
first_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
[[ "$first_certificate_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] \
    || fail 'certificate ID is not protected exact authority'
/usr/bin/openssl x509 -in "$vesta_root/data/users/alice/ssl/$domain_one.crt" \
    -noout -checkhost "$domain_one" >/dev/null 2>&1 \
    || fail 'installed certificate does not cover the generated domain'
/usr/bin/grep -q "native-ssl .* $domain_one" \
    "$vesta_root/data/vx/cloudflare/native-calls.log" \
    || fail 'Origin certificate did not use native Vesta SSL installation'
/usr/bin/grep -q "native-ssl .* $domain_one internal=1$" \
    "$vesta_root/data/vx/cloudflare/native-calls.log" \
    || fail 'Origin SSL install omitted the exact internal capability'

authority_status() {
    VESTA="$vesta_root" /bin/bash -c '
        source "$VESTA/func/vx/cloudflare/main.sh"
        source "$VESTA/conf/vesta.conf"
        if vx_cf_native_web_authority_preflight "$1" "$2"; then
            printf "%s\n" "$VX_CF_WEB_AUTHORITY_STATE"
        else
            printf "blocked:%s\n" "${VX_CF_STATUS:-state_error}"
        fi
    ' _ alice "$domain_one"
}

assert_eq "$(authority_status)" managed \
    'exact authority pair failed native lifecycle preflight'
authority_snapshot="$work_root/authority.snapshot"
/usr/bin/mv -- "$certificate_metadata" "$authority_snapshot"
assert_eq "$(authority_status)" blocked:ownership_mismatch \
    'record-only authority did not fail closed'
/usr/bin/mv -- "$authority_snapshot" "$certificate_metadata"
/usr/bin/mv -- "$record_metadata" "$authority_snapshot"
printf "BROKEN='yes'\n" >"$record_metadata"
/usr/bin/chmod 0600 "$record_metadata"
assert_eq "$(authority_status)" blocked:state_error \
    'malformed authority did not fail closed'
/usr/bin/rm -f -- "$record_metadata"
/usr/bin/mv -- "$authority_snapshot" "$record_metadata"
/usr/bin/mv -- "$record_metadata" "$authority_snapshot"
/usr/bin/ln -s "$authority_snapshot" "$record_metadata"
assert_eq "$(authority_status)" blocked:ownership_mismatch \
    'symlink authority did not fail closed'
/usr/bin/unlink "$record_metadata"
/usr/bin/mv -- "$authority_snapshot" "$record_metadata"

other_zone_input="$work_root/cloudflare-other-zone.input"
printf "API_TOKEN='fixture_other_token_12345678901234567890'\n" >"$other_zone_input"
printf "ZONE_ID='11111111111111111111111111111111'\n" >>"$other_zone_input"
printf "ACCOUNT_EMAIL='operator@example.test'\n" >>"$other_zone_input"
/usr/bin/chmod 0600 "$other_zone_input"
if zone_rotation=$(run_vesta "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$other_zone_input"); then
    fail 'configuration stranded metadata under a different zone'
fi
assert_eq "$zone_rotation" 'Error: managed_zone_in_use' \
    'cross-zone configuration guard is not stable'
/usr/bin/grep -q "^ZONE_ID='0123456789abcdef0123456789abcdef'$" "$config" \
    || fail 'rejected cross-zone configuration changed authority'

rotated_input="$work_root/cloudflare-rotated.input"
printf "API_TOKEN='fixture_rotated_token_12345678901234567890'\n" >"$rotated_input"
printf "ZONE_ID='0123456789abcdef0123456789abcdef'\n" >>"$rotated_input"
printf "ACCOUNT_EMAIL='operator@example.test'\n" >>"$rotated_input"
/usr/bin/chmod 0600 "$rotated_input"
rotated_output=$(run_vesta "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$rotated_input") || fail 'same-zone token rotation failed'
assert_eq "$rotated_output" ready 'same-zone token rotation status is wrong'
/usr/bin/grep -q "^API_TOKEN='fixture_rotated_token_12345678901234567890'$" "$config" \
    || fail 'same-zone token rotation was not persisted'

reconcile=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'no-op reconcile failed'
assert_eq "$reconcile" unchanged 'no-op reconcile was not unchanged'

/usr/bin/sed -i "s/NAT='192.0.2.20'/NAT='192.0.2.21'/" \
    "$vesta_root/data/ips/192.0.2.10"
reconcile=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'drift reconcile failed'
assert_eq "$reconcile" updated 'drift reconcile was not updated'

# Metadata is exact provider identity. A provider-side rename must update that
# ID in place, never create a replacement based only on a desired-name lookup.
/usr/bin/sed -i 's/^name=.*/name=provider-renamed.managed.example.test/' \
    "$cloudflare_root/stub-record.conf"
printf 'dns-rename-reconcile-start\n' >>"$cloudflare_root/stub-calls.log"
dns_creates_before=$(/usr/bin/grep -c '^create ' "$cloudflare_root/stub-calls.log")
dns_updates_before=$(/usr/bin/grep -c '^update$' "$cloudflare_root/stub-calls.log")
reconcile=$(run_vesta "$vesta_root/bin/v-reconcile-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'provider-side DNS rename reconcile failed'
assert_eq "$reconcile" updated 'provider-side DNS rename was not updated in place'
first_rename_call=$(/usr/bin/sed -n \
    '/^dns-rename-reconcile-start$/ { n; p; q; }' \
    "$cloudflare_root/stub-calls.log")
assert_eq "$first_rename_call" read \
    'DNS reconcile did not validate the exact metadata ID first'
dns_creates_after=$(/usr/bin/grep -c '^create ' "$cloudflare_root/stub-calls.log")
dns_updates_after=$(/usr/bin/grep -c '^update$' "$cloudflare_root/stub-calls.log")
assert_eq "$dns_creates_after" "$dns_creates_before" \
    'provider-side DNS rename created a replacement record'
assert_eq "$dns_updates_after" "$((dns_updates_before + 1))" \
    'provider-side DNS rename did not update the exact record ID'
assert_eq "$(/usr/bin/sed -n 's/^name=//p' "$cloudflare_root/stub-record.conf")" \
    "$domain_one" 'provider-side DNS rename was not healed'

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

printf 'origin_failure\n' >"$vesta_root/data/vx/cloudflare/stub-scenario"
if origin_create_failure=$(run_vesta \
    "$vesta_root/bin/v-add-vx-managed-web-domain" alice 192.0.2.10 no none); then
    fail 'Origin certificate failure left a managed site active'
fi
[[ "$origin_create_failure" == 'Error: unauthorized' ]] \
    || fail 'initial Origin certificate failure is not stable'
after_domains=$(/usr/bin/wc -l <"$vesta_root/data/users/alice/web.conf")
assert_eq "$after_domains" "$before_domains" \
    'Origin certificate failure did not remove the local website'
[[ ! -s "$vesta_root/data/vx/cloudflare/stub-record.conf" ]] \
    || fail 'Origin certificate failure did not remove the DNS record'
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

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

origin_creates_before=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
if unproxied_alias=$(run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" \
    alice "$domain_one" unproxied.example.test); then
    fail 'unproxied custom alias was certified'
fi
assert_eq "$unproxied_alias" 'Error: native_alias_failed' \
    'unproxied alias failure is not stable'
! /usr/bin/grep -q "ALIAS='[^']*unproxied.example.test" \
    "$vesta_root/data/users/alice/web.conf" \
    || fail 'unproxied alias remained in native state'
origin_creates_after=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
assert_eq "$origin_creates_after" "$origin_creates_before" \
    'unproxied alias reached Origin certificate issuance'

if uncovered_alias=$(run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" \
    alice "$domain_one" edge.noedge.test); then
    fail 'custom alias without active edge coverage was certified'
fi
assert_eq "$uncovered_alias" 'Error: native_alias_failed' \
    'alias edge coverage failure is not stable'
! /usr/bin/grep -q "ALIAS='[^']*edge.noedge.test" \
    "$vesta_root/data/users/alice/web.conf" \
    || fail 'uncovered alias remained in native state'
origin_creates_after=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
assert_eq "$origin_creates_after" "$origin_creates_before" \
    'uncovered alias reached Origin certificate issuance'

run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain_one" \
    custom.example.test || fail 'custom alias delegation failed'
/usr/bin/grep -q "native-alias $domain_one custom.example.test" \
    "$vesta_root/data/vx/cloudflare/native-calls.log" \
    || fail 'custom alias did not use native alias state'
second_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
[[ "$second_certificate_id" =~ ^[A-Za-z0-9_-]{1,64}$ \
    && "$second_certificate_id" != "$first_certificate_id" ]] \
    || fail 'alias addition did not rotate the Origin certificate'
/usr/bin/openssl x509 -in "$vesta_root/data/users/alice/ssl/$domain_one.crt" \
    -noout -checkhost custom.example.test >/dev/null 2>&1 \
    || fail 'rotated certificate does not cover the custom alias'
/usr/bin/grep -q "origin-delete $first_certificate_id" \
    "$vesta_root/data/vx/cloudflare/stub-calls.log" \
    || fail 'superseded Origin certificate was not revoked'
/usr/bin/grep -q \
    '^alias-dns fedcba9876543210fedcba9876543210 custom.example.test CNAME$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'custom alias exact DNS/CNAME preflight was omitted'
/usr/bin/grep -q '^edge-list fedcba9876543210fedcba9876543210$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'custom alias active edge coverage was omitted'
/usr/bin/grep -q \
    '^ssl-patch fedcba9876543210fedcba9876543210 strict$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'custom alias zone did not enforce Full (strict)'

origin_creates_before=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
printf 'alias_route_drift\n' >"$cloudflare_root/stub-scenario"
if unhealthy_route=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no); then
    fail 'healthy certificate shortcut bypassed alias route preflight'
fi
assert_eq "$unhealthy_route" 'Error: alias_dns_mismatch' \
    'healthy certificate route failure is not stable'
assert_eq "$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")" \
    "$second_certificate_id" 'failed route preflight changed certificate authority'
origin_creates_after=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
assert_eq "$origin_creates_after" "$origin_creates_before" \
    'failed route preflight reached Origin certificate issuance'
: >"$cloudflare_root/stub-scenario"

primary_edge_before=$(/usr/bin/grep -c \
    '^edge-list 0123456789abcdef0123456789abcdef$' \
    "$cloudflare_root/stub-calls.log")
alias_edge_before=$(/usr/bin/grep -c \
    '^edge-list fedcba9876543210fedcba9876543210$' \
    "$cloudflare_root/stub-calls.log")
primary_strict_before=$(/usr/bin/grep -c \
    '^ssl-patch 0123456789abcdef0123456789abcdef strict$' \
    "$cloudflare_root/stub-calls.log")
alias_strict_before=$(/usr/bin/grep -c \
    '^ssl-patch fedcba9876543210fedcba9876543210 strict$' \
    "$cloudflare_root/stub-calls.log")
alias_dns_before=$(/usr/bin/grep -c \
    '^alias-dns fedcba9876543210fedcba9876543210 custom.example.test CNAME$' \
    "$cloudflare_root/stub-calls.log")
healthy_reconcile=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no) \
    || fail 'healthy Origin reconcile failed after provider preflight'
assert_eq "$healthy_reconcile" ssl_unchanged \
    'healthy Origin reconcile did not reuse the current certificate'
assert_eq "$(/usr/bin/grep -c \
    '^edge-list 0123456789abcdef0123456789abcdef$' \
    "$cloudflare_root/stub-calls.log")" "$((primary_edge_before + 1))" \
    'healthy shortcut omitted primary edge preflight'
assert_eq "$(/usr/bin/grep -c \
    '^edge-list fedcba9876543210fedcba9876543210$' \
    "$cloudflare_root/stub-calls.log")" "$((alias_edge_before + 1))" \
    'healthy shortcut omitted alias edge preflight'
assert_eq "$(/usr/bin/grep -c \
    '^ssl-patch 0123456789abcdef0123456789abcdef strict$' \
    "$cloudflare_root/stub-calls.log")" "$((primary_strict_before + 1))" \
    'healthy shortcut omitted configured-zone strict enforcement'
assert_eq "$(/usr/bin/grep -c \
    '^ssl-patch fedcba9876543210fedcba9876543210 strict$' \
    "$cloudflare_root/stub-calls.log")" "$((alias_strict_before + 1))" \
    'healthy shortcut omitted alias-zone strict enforcement'
assert_eq "$(/usr/bin/grep -c \
    '^alias-dns fedcba9876543210fedcba9876543210 custom.example.test CNAME$' \
    "$cloudflare_root/stub-calls.log")" "$((alias_dns_before + 1))" \
    'healthy shortcut omitted exact alias DNS preflight'

ssl_root="$vesta_root/data/users/alice/ssl"
rendered_ssl_root="$vesta_root/home/alice/conf/web"
printf 'corrupt-rendered-private-key\n' \
    >"$rendered_ssl_root/ssl.$domain_one.key"
drift_reconcile=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no) \
    || fail 'rendered certificate drift did not self-heal'
assert_eq "$drift_reconcile" ssl_ready \
    'rendered certificate drift reconcile status is wrong'
drift_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
[[ "$drift_certificate_id" != "$second_certificate_id" ]] \
    || fail 'rendered certificate drift reused stale provider authority'
/usr/bin/openssl x509 -in "$ssl_root/$domain_one.crt" -pubkey -noout 2>/dev/null \
    | /usr/bin/openssl pkey -pubin -outform DER 2>/dev/null \
    | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1 \
    >"$work_root/installed-cert-key.digest"
/usr/bin/openssl pkey -in "$ssl_root/$domain_one.key" -pubout -outform DER \
    2>/dev/null | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1 \
    >"$work_root/installed-private-key.digest"
/usr/bin/cmp -s "$work_root/installed-cert-key.digest" \
    "$work_root/installed-private-key.digest" \
    || fail 'drift self-heal installed a mismatched certificate/key pair'
/usr/bin/grep -q "origin-delete $second_certificate_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'drift self-heal did not revoke superseded exact authority'
for extension in crt key ca pem; do
    /usr/bin/cmp -s "$ssl_root/$domain_one.$extension" \
        "$rendered_ssl_root/ssl.$domain_one.$extension" \
        || fail "rendered $extension did not match canonical SSL state"
done
/usr/bin/cat "$ssl_root/$domain_one.crt" "$ssl_root/$domain_one.ca" \
    >"$work_root/expected-origin.pem"
/usr/bin/cmp -s "$work_root/expected-origin.pem" "$ssl_root/$domain_one.pem" \
    || fail 'canonical PEM is not exact CRT+CA'

printf 'corrupt-canonical-pem\n' >"$ssl_root/$domain_one.pem"
/usr/bin/cp -f -- "$ssl_root/$domain_one.pem" \
    "$rendered_ssl_root/ssl.$domain_one.pem"
pem_drift_reconcile=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no) \
    || fail 'canonical PEM drift did not self-heal'
assert_eq "$pem_drift_reconcile" ssl_ready \
    'canonical PEM drift reconcile status is wrong'
pem_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
[[ "$pem_certificate_id" != "$drift_certificate_id" ]] \
    || fail 'canonical PEM drift reused stale provider authority'
/usr/bin/grep -q "origin-delete $drift_certificate_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'canonical PEM drift did not revoke superseded exact authority'
/usr/bin/cat "$ssl_root/$domain_one.crt" "$ssl_root/$domain_one.ca" \
    >"$work_root/expected-origin.pem"
/usr/bin/cmp -s "$work_root/expected-origin.pem" "$ssl_root/$domain_one.pem" \
    || fail 'canonical PEM drift did not restore exact CRT+CA'
for extension in crt key ca pem; do
    /usr/bin/cmp -s "$ssl_root/$domain_one.$extension" \
        "$rendered_ssl_root/ssl.$domain_one.$extension" \
        || fail "PEM drift left rendered $extension stale"
done

old_native_hashes=$(/usr/bin/sha256sum \
    "$ssl_root/$domain_one."{crt,key,ca,pem} \
    "$rendered_ssl_root/ssl.$domain_one."{crt,key,ca,pem})
old_transaction_id=$pem_certificate_id
/usr/bin/rm -f -- "$cloudflare_root/stub-native-install-failed-once"
/usr/bin/rm -f -- "$cloudflare_root/stub-revoke-failed-once"
printf 'native_install_revoke_failure\n' >"$cloudflare_root/stub-scenario"
if native_install_failure=$(run_vesta \
    "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain_one" \
    restore.example.test); then
    fail 'partial native Origin SSL install unexpectedly succeeded'
fi
assert_eq "$native_install_failure" 'Error: native_alias_failed' \
    'partial native install failure is not stable'
: >"$cloudflare_root/stub-scenario"
new_native_hashes=$(/usr/bin/sha256sum \
    "$ssl_root/$domain_one."{crt,key,ca,pem} \
    "$rendered_ssl_root/ssl.$domain_one."{crt,key,ca,pem})
assert_eq "$new_native_hashes" "$old_native_hashes" \
    'partial native install did not restore exact SSL state'
restored_metadata_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
assert_eq "$restored_metadata_id" "$old_transaction_id" \
    'partial native install did not restore certificate metadata'
! /usr/bin/grep -q "ALIAS='[^']*restore.example.test" \
    "$vesta_root/data/users/alice/web.conf" \
    || fail 'partial native install left the alias attached'
failed_install_id=$(/usr/bin/grep '^origin-create ' "$cloudflare_root/stub-calls.log" \
    | /usr/bin/tail -n1 | /usr/bin/cut -d ' ' -f2)
rollback_pending_ids=$(/usr/bin/sed -n \
    "s/^PENDING_REVOKE_IDS='\([^']*\)'$/\1/p" "$certificate_metadata")
assert_eq "$rollback_pending_ids" "$failed_install_id" \
    'failed rollback revoke lost durable new certificate authority'
/usr/bin/grep -q "origin-delete-failed $failed_install_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'fixture did not exercise the post-rollback revoke failure'
rollback_retry=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no) \
    || fail 'post-rollback pending certificate cleanup did not retry'
assert_eq "$rollback_retry" ssl_unchanged \
    'post-rollback pending cleanup replaced healthy restored SSL'
rollback_pending_ids=$(/usr/bin/sed -n \
    "s/^PENDING_REVOKE_IDS='\([^']*\)'$/\1/p" "$certificate_metadata")
assert_eq "$rollback_pending_ids" '' \
    'successful post-rollback pending cleanup was not cleared'
/usr/bin/grep -q "origin-delete $failed_install_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'post-rollback retry did not revoke the exact pending ID'

/usr/bin/rm -f -- "$cloudflare_root/stub-revoke-failed-once"
printf 'old_revoke_failure\n' >"$cloudflare_root/stub-scenario"
run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain_one" \
    a-record.example.test || fail 'replacement failed when old revoke was transient'
: >"$cloudflare_root/stub-scenario"
pending_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$certificate_metadata")
[[ "$pending_certificate_id" != "$old_transaction_id" ]] \
    || fail 'replacement did not install after transient old revoke failure'
pending_revoke_ids=$(/usr/bin/sed -n \
    "s/^PENDING_REVOKE_IDS='\([^']*\)'$/\1/p" "$certificate_metadata")
assert_eq "$pending_revoke_ids" "$old_transaction_id" \
    'failed superseded revoke did not preserve exact durable authority'
/usr/bin/grep -q "origin-delete-failed $old_transaction_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'fixture did not exercise the superseded revoke failure'
/usr/bin/grep -q \
    '^alias-dns fedcba9876543210fedcba9876543210 a-record.example.test A$' \
    "$cloudflare_root/stub-calls.log" \
    || fail 'custom alias exact DNS/A ingress preflight was omitted'
pending_retry=$(run_vesta \
    "$vesta_root/bin/v-reconcile-vx-cloudflare-origin-ssl" alice "$domain_one" no) \
    || fail 'future reconcile did not retry pending certificate cleanup'
assert_eq "$pending_retry" ssl_unchanged \
    'pending revoke retry changed a healthy current certificate'
pending_revoke_ids=$(/usr/bin/sed -n \
    "s/^PENDING_REVOKE_IDS='\([^']*\)'$/\1/p" "$certificate_metadata")
assert_eq "$pending_revoke_ids" '' 'successful pending revoke was not cleared'
/usr/bin/grep -q "origin-delete $old_transaction_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'future reconcile did not revoke the pending exact ID'
second_certificate_id=$pending_certificate_id

metadata_snapshot="$work_root/certificate-metadata.snapshot"
/usr/bin/cp -- "$certificate_metadata" "$metadata_snapshot"
/usr/bin/rm -f -- "$certificate_metadata"
/usr/bin/ln -s /dev/null "$certificate_metadata"
old_native_hashes=$(/usr/bin/sha256sum "$ssl_root/$domain_one."{crt,key,ca,pem})
metadata_failure_origin_creates=$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")
metadata_failure_native_calls=$(/usr/bin/wc -l \
    <"$cloudflare_root/native-calls.log")
if certificate_metadata_failure=$(run_vesta \
    "$vesta_root/bin/v-add-vx-cloudflare-web-alias" alice "$domain_one" \
    metadatafail.example.test); then
    fail 'certificate metadata failure unexpectedly installed a replacement'
fi
assert_eq "$certificate_metadata_failure" 'Error: native_alias_failed' \
    'certificate metadata failure is not stable'
/usr/bin/unlink "$certificate_metadata"
/usr/bin/mv -- "$metadata_snapshot" "$certificate_metadata"
new_native_hashes=$(/usr/bin/sha256sum "$ssl_root/$domain_one."{crt,key,ca,pem})
assert_eq "$new_native_hashes" "$old_native_hashes" \
    'certificate metadata failure changed native SSL state'
assert_eq "$(/usr/bin/grep -c '^origin-create ' \
    "$cloudflare_root/stub-calls.log")" "$metadata_failure_origin_creates" \
    'unsafe certificate authority reached Origin issuance'
assert_eq "$(/usr/bin/wc -l <"$cloudflare_root/native-calls.log")" \
    "$metadata_failure_native_calls" \
    'unsafe certificate authority reached native alias mutation'
! /usr/bin/grep -q "ALIAS='[^']*metadatafail.example.test" \
    "$vesta_root/data/users/alice/web.conf" \
    || fail 'certificate metadata failure left the alias attached'

printf 'origin_failure\n' >"$vesta_root/data/vx/cloudflare/stub-scenario"
if alias_failure=$(run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" \
    alice "$domain_one" rollback.example.test); then
    fail 'failed Origin certificate issue left an alias attached'
fi
[[ "$alias_failure" == 'Error: native_alias_failed' ]] \
    || fail 'alias certificate failure is not stable'
! /usr/bin/grep -q "ALIAS='[^']*rollback.example.test" \
    "$vesta_root/data/users/alice/web.conf" \
    || fail 'alias certificate failure did not restore alias state'
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

printf 'origin_mismatch\n' >"$vesta_root/data/vx/cloudflare/stub-scenario"
if mismatch_failure=$(run_vesta "$vesta_root/bin/v-add-vx-cloudflare-web-alias" \
    alice "$domain_one" mismatch.example.test); then
    fail 'mismatched Origin certificate response was accepted'
fi
[[ "$mismatch_failure" == 'Error: native_alias_failed' ]] \
    || fail 'mismatched Origin response failure is not stable'
latest_created_id=$(/usr/bin/grep '^origin-create ' \
    "$vesta_root/data/vx/cloudflare/stub-calls.log" | /usr/bin/tail -n1 \
    | /usr/bin/cut -d ' ' -f2)
/usr/bin/grep -q "origin-delete $latest_created_id" \
    "$vesta_root/data/vx/cloudflare/stub-calls.log" \
    || fail 'mismatched issued certificate was not compensated'
: >"$vesta_root/data/vx/cloudflare/stub-scenario"

already_revoked_pending_id=99999999999999999999999999999999999999999999999
/usr/bin/sed -i \
    "s/^PENDING_REVOKE_IDS=''$/PENDING_REVOKE_IDS='$already_revoked_pending_id'/" \
    "$certificate_metadata"
delete_status=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'exact deletion failed'
assert_eq "$delete_status" deleted 'delete status is incorrect'
[[ ! -e "$vesta_root/data/vx/cloudflare/records/alice/$domain_one.conf" ]] \
    || fail 'metadata remained after deletion'
[[ ! -e "$certificate_metadata" ]] \
    || fail 'certificate metadata remained after deletion'
/usr/bin/grep -q "origin-delete $second_certificate_id" \
    "$vesta_root/data/vx/cloudflare/stub-calls.log" \
    || fail 'current exact Origin certificate was not revoked on deletion'
/usr/bin/grep -q "origin-get $already_revoked_pending_id" \
    "$cloudflare_root/stub-calls.log" \
    || fail 'delete did not retry idempotent pending certificate cleanup'
/usr/bin/grep -q '^delete$' "$vesta_root/data/vx/cloudflare/stub-calls.log" \
    || fail 'exact provider deletion was not called'

delete_status=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$domain_one") || fail 'idempotent deletion failed'
assert_eq "$delete_status" unchanged 'idempotent deletion is not unchanged'

revoked_domain=$(run_vesta "$vesta_root/bin/v-add-vx-managed-web-domain" alice \
    192.0.2.10 no none) || fail 'already-revoked cleanup fixture create failed'
revoked_metadata="$cloudflare_root/certificates/alice/$revoked_domain.conf"
revoked_certificate_id=$(/usr/bin/sed -n \
    "s/^CERTIFICATE_ID='\([^']*\)'$/\1/p" "$revoked_metadata")
/usr/bin/rm -f -- \
    "$cloudflare_root/stub-certificates/$revoked_certificate_id.json" \
    "$cloudflare_root/stub-certificates/$revoked_certificate_id.pem" \
    "$cloudflare_root/stub-certificates/$revoked_certificate_id.csr"
revoked_delete=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$revoked_domain") || fail 'already-revoked certificate cleanup failed'
assert_eq "$revoked_delete" deleted 'already-revoked cleanup status is wrong'
[[ ! -e "$revoked_metadata" ]] \
    || fail 'already-revoked certificate metadata remained after cleanup'
revoked_delete=$(run_vesta "$vesta_root/bin/v-delete-vx-cloudflare-web-domain" \
    alice "$revoked_domain") || fail 'already-revoked cleanup was not idempotent'
assert_eq "$revoked_delete" unchanged \
    'already-revoked second cleanup was not unchanged'

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

/usr/bin/grep -n 'vx_cf_native_web_cleanup.*"\$user".*"\$domain"' \
    "$repo_root/bin/v-delete-web-domain" >/dev/null \
    || fail 'native deletion cleanup hook is missing'
/usr/bin/grep -n 'managed web domains cannot be renamed' \
    "$repo_root/bin/v-change-web-domain-name" >/dev/null \
    || fail 'managed rename guard is missing'
/usr/bin/grep -n 'vx_cf_reconcile_alias_change' \
    "$repo_root/bin/v-add-web-domain-alias" "$repo_root/bin/v-delete-web-domain-alias" \
    >/dev/null || fail 'generic alias paths can bypass Origin certificate rotation'

printf 'PASS: Cloudflare managed-domain provider and lifecycle\n'
