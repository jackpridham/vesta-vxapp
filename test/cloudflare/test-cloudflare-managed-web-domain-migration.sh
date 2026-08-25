#!/bin/bash

set -u -o pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
vesta_root="$work_root/vesta"
home_root="$work_root/home"
log_root="$work_root/log/nginx/domains"
etc_root="$work_root/etc"
passwd_file="$work_root/passwd"
cloudflare_root="$vesta_root/data/vx/cloudflare"
strict_stub="$repo_root/test/cloudflare/fixtures/strict-lifecycle-stub"
source_domain=migration.example.test
source_alias_one=a-record.example.test
source_alias_two=migration.managed.example.test
second_source=$source_alias_one
plan=migrate-suspended-sites
zone_id=0123456789abcdef0123456789abcdef

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

provider_mutation_count() {
    /usr/bin/grep -Ec \
        '^(create |update$|delete$|origin-create |origin-delete |ssl-patch )' \
        "$cloudflare_root/stub-calls.log" 2>/dev/null || :
}

native_mutation_count() {
    local lifecycle=0 ssl=0

    [[ ! -f "$cloudflare_root/migration-native.log" ]] \
        || lifecycle=$(/usr/bin/wc -l <"$cloudflare_root/migration-native.log")
    [[ ! -f "$cloudflare_root/native-calls.log" ]] \
        || ssl=$(/usr/bin/wc -l <"$cloudflare_root/native-calls.log")
    printf '%s\n' "$((lifecycle + ssl))"
}

artifact_fingerprint() {
    local artifact=$1 file

    {
        /usr/bin/find -P "$artifact" -printf '%P\t%y\t%m\t%u\t%g\t%s\n' \
            | LC_ALL=C /usr/bin/sort
        while IFS= read -r -d '' file; do
            printf '%s\t%s\n' "${file#"$artifact"/}" \
                "$(/usr/bin/sha256sum -- "$file" | /usr/bin/cut -d ' ' -f1)"
        done < <(/usr/bin/find -P "$artifact" -type f -print0 \
            | LC_ALL=C /usr/bin/sort -z)
    } | /usr/bin/sha256sum | /usr/bin/cut -d ' ' -f1
}

assert_sanitized_json() {
    local output=$1 expected_status=$2 expected_pending=$3 expected_applied=$4
    local expected_rolled_back=$5 expected_failed=$6 keys
    local expected_total=${7:-1}

    /usr/bin/jq -e . >/dev/null 2>&1 <<<"$output" \
        || fail 'migration output is not valid JSON'
    keys=$(/usr/bin/jq -r 'keys | join(",")' <<<"$output")
    assert_eq "$keys" 'applied,failed,pending,rolled_back,status,total' \
        'migration JSON exposed fields beyond status and counts'
    assert_eq "$(/usr/bin/jq -r .status <<<"$output")" "$expected_status" \
        'migration status is wrong'
    assert_eq "$(/usr/bin/jq -r .total <<<"$output")" "$expected_total" \
        'migration total count is wrong'
    assert_eq "$(/usr/bin/jq -r .pending <<<"$output")" "$expected_pending" \
        'migration pending count is wrong'
    assert_eq "$(/usr/bin/jq -r .applied <<<"$output")" "$expected_applied" \
        'migration applied count is wrong'
    assert_eq "$(/usr/bin/jq -r .rolled_back <<<"$output")" \
        "$expected_rolled_back" 'migration rollback count is wrong'
    assert_eq "$(/usr/bin/jq -r .failed <<<"$output")" "$expected_failed" \
        'migration failure count is wrong'
    [[ "$output" != *"$source_domain"* \
        && "$output" != *"$source_alias_one"* \
        && "$output" != *"$source_alias_two"* \
        && "$output" != *"${generated_domain:-never-a-domain}"* \
        && "$output" != *"${failure_target:-never-a-failure-domain}"* \
        && "$output" != *"$zone_id"* \
        && ! "$output" =~ [a-f0-9]{32} ]] \
        || fail 'migration output exposed a domain or provider identifier'
}

run_migration() {
    VESTA="$vesta_root" VX_CLOUDFLARE_TEST_MODE=yes \
        VX_CLOUDFLARE_TEST_CURL="$strict_stub" \
        VX_CLOUDFLARE_MIGRATION_LOG_ROOT="$log_root" \
        VX_CLOUDFLARE_MIGRATION_ETC_ROOT="$etc_root" \
        VX_CLOUDFLARE_MIGRATION_PASSWD_FILE="$passwd_file" "$@"
}

snapshot_native_state() {
    local destination=$1 extension

    /usr/bin/mkdir -p "$destination"
    /usr/bin/cp -a -- "$vesta_root/data/users/alice/web.conf" \
        "$destination/web.conf"
    /usr/bin/cp -a -- "$vesta_root/data/users/alice/user.conf" \
        "$destination/user.conf"
    /usr/bin/cp -a -- "$passwd_file" "$destination/passwd"
    /usr/bin/mkdir -p "$destination/source-ssl"
    for extension in crt key ca pem; do
        /usr/bin/cp -a -- \
            "$vesta_root/data/users/alice/ssl/$source_domain.$extension" \
            "$destination/source-ssl/$extension"
    done
    /usr/bin/cp -a -- "$home_root/alice/web/$source_domain" \
        "$destination/docroot"
    /usr/bin/cp -a -- "$home_root/alice/conf/web" "$destination/rendered"
    /usr/bin/cp -a -- "$log_root/$source_domain.log" \
        "$log_root/$source_domain.error.log" "$log_root/$source_domain.bytes" \
        "$destination/"
}

assert_source_ssl_matches_snapshot() {
    local snapshot=$1 extension source_path saved_path

    for extension in crt key ca pem; do
        source_path="$vesta_root/data/users/alice/ssl/$source_domain.$extension"
        saved_path="$snapshot/source-ssl/$extension"
        /usr/bin/cmp -s -- "$saved_path" "$source_path" \
            || fail "retained source SSL $extension content changed"
        assert_eq "$(/usr/bin/stat -c '%a:%u:%g:%s' "$source_path")" \
            "$(/usr/bin/stat -c '%a:%u:%g:%s' "$saved_path")" \
            "retained source SSL $extension metadata changed"
    done
}

assert_native_matches_snapshot() {
    local snapshot=$1

    /usr/bin/cmp -s -- "$snapshot/web.conf" \
        "$vesta_root/data/users/alice/web.conf" \
        || fail 'web.conf was not restored byte-for-byte'
    /usr/bin/cmp -s -- "$snapshot/user.conf" \
        "$vesta_root/data/users/alice/user.conf" \
        || fail 'user.conf counters or suspension were not restored'
    /usr/bin/cmp -s -- "$snapshot/passwd" "$passwd_file" \
        || fail 'FTP home relationship was not restored'
    assert_source_ssl_matches_snapshot "$snapshot"
    /usr/bin/diff -ruN -- "$snapshot/docroot" \
        "$home_root/alice/web/$source_domain" >/dev/null \
        || fail 'source document root was not restored exactly'
    /usr/bin/diff -ruN -- "$snapshot/rendered" \
        "$home_root/alice/conf/web" >/dev/null \
        || fail 'rendered web state was not restored exactly'
    if ! { /usr/bin/cmp -s -- "$snapshot/$source_domain.log" \
            "$log_root/$source_domain.log" \
            && /usr/bin/cmp -s -- "$snapshot/$source_domain.error.log" \
                "$log_root/$source_domain.error.log" \
            && /usr/bin/cmp -s -- "$snapshot/$source_domain.bytes" \
                "$log_root/$source_domain.bytes"; }; then
        fail 'domain log files were not restored exactly'
    fi
}

prepare_compensated_plan() {
    failure_plan=$1
    printf 'normal\n' >"$cloudflare_root/stub-scenario"
    failure_prepare_output=$(run_migration \
        "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
        "$failure_plan" --user alice --json) \
        || fail "$failure_plan prepare failed"
    assert_sanitized_json "$failure_prepare_output" prepared 1 0 0 0
    failure_artifact="$cloudflare_root/migrations/$failure_plan"
    failure_target=$(/usr/bin/jq -er '.[0].generated_primary' \
        "$failure_artifact/mapping.json") \
        || fail "$failure_plan mapping omitted its generated primary"
}

assert_compensated_failure() {
    local label=$1 failure_output suffix

    calls_before=$(/usr/bin/wc -l <"$cloudflare_root/stub-calls.log")
    if failure_output=$(run_migration \
        "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
        "$failure_plan" --json); then
        fail "$label failure injection was accepted"
    fi
    printf 'normal\n' >"$cloudflare_root/stub-scenario"
    assert_sanitized_json "$failure_output" failed 0 0 1 1
    assert_native_matches_snapshot "$native_snapshot"
    [[ ! -e "$home_root/alice/web/$failure_target" \
        && ! -L "$home_root/alice/web/$failure_target" \
        && ! -e "$cloudflare_root/records/alice/$failure_target.conf" \
        && ! -L "$cloudflare_root/records/alice/$failure_target.conf" \
        && ! -e "$cloudflare_root/certificates/alice/$failure_target.conf" \
        && ! -L "$cloudflare_root/certificates/alice/$failure_target.conf" \
        && ! -s "$cloudflare_root/stub-record.conf" ]] \
        || fail "$label failure retained target authority"
    for suffix in log error.log bytes; do
        [[ ! -e "$log_root/$failure_target.$suffix" \
            && ! -L "$log_root/$failure_target.$suffix" ]] \
            || fail "$label failure retained a target log"
    done
    stage_calls="$work_root/$failure_plan-provider-calls.log"
    /usr/bin/tail -n "+$((calls_before + 1))" \
        "$cloudflare_root/stub-calls.log" >"$stage_calls"
}

/usr/bin/mkdir -p "$vesta_root/bin" "$vesta_root/conf" \
    "$vesta_root/data/users/alice/ssl" "$vesta_root/data/ips" \
    "$vesta_root/log" "$cloudflare_root" \
    "$home_root/alice/web/$source_domain/public_html" \
    "$home_root/alice/web/$source_domain/uploads" \
    "$home_root/alice/conf/web" "$log_root" "$etc_root"
/usr/bin/ln -s "$repo_root/func" "$vesta_root/func"
/usr/bin/ln -s "$repo_root/install" "$vesta_root/install"

for command in v-configure-vx-cloudflare v-list-vx-cloudflare-status \
    v-change-vx-dns-provider; do
    /usr/bin/ln -s "$repo_root/bin/$command" "$vesta_root/bin/$command"
done
for command in v-add-web-domain-ssl v-change-web-domain-sslcert \
    v-delete-web-domain-ssl; do
    /usr/bin/ln -s "$strict_stub" "$vesta_root/bin/$command"
done

lifecycle_stub="$work_root/migration-native-stub"
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' "if [[ \"\${0##*/}\" == v-rebuild-web-domains ]]; then"
    printf '%s\n' "    [[ \"\${VX_CLOUDFLARE_INTERNAL_MIGRATION:-}\" == 1 ]] || exit 93"
    printf '%s\n' '    source "$VESTA/conf/vesta.conf"'
    printf '%s\n' '    rendered="$HOMEDIR/$1/conf/web"'
    printf '%s\n' '    etc_root=${VX_CLOUDFLARE_MIGRATION_ETC_ROOT:-$VESTA/data/vx/cloudflare/test-etc}'
    printf '%s\n' '    while IFS= read -r row || [[ -n "$row" ]]; do'
    printf '%s\n' '        domain=$(/usr/bin/sed -n "s/^DOMAIN='\''\([^'\'']*\)'\''.*/\1/p" <<<"$row")'
    printf '%s\n' '        ssl=$(/usr/bin/sed -n "s/.* SSL='\''\([^'\'']*\)'\''.*/\1/p" <<<"$row")'
    printf '%s\n' '        proxy=$(/usr/bin/sed -n "s/.* PROXY='\''\([^'\'']*\)'\''.*/\1/p" <<<"$row")'
    printf '%s\n' '        stats=$(/usr/bin/sed -n "s/.* STATS='\''\([^'\'']*\)'\''.*/\1/p" <<<"$row")'
    printf '%s\n' '        tpl=$(/usr/bin/sed -n "s/.* TPL='\''\([^'\'']*\)'\''.*/\1/p" <<<"$row")'
    printf '%s\n' '        [[ -n "$domain" ]] || exit 95'
    printf '%s\n' '        /usr/bin/mkdir -p -- "$rendered"'
    printf '%s\n' '        printf "web vhost\n" >"$rendered/$domain.$WEB_SYSTEM.conf"'
    printf '%s\n' '        if [[ "$ssl" == yes ]]; then'
    printf '%s\n' '            printf "web SSL vhost\n" >"$rendered/$domain.$WEB_SYSTEM.ssl.conf"'
    printf '%s\n' '        fi'
    printf '%s\n' '        if [[ -n "${PROXY_SYSTEM:-}" && -n "$proxy" && "$proxy" != no ]]; then'
    printf '%s\n' '            printf "proxy vhost\n" >"$rendered/$domain.$PROXY_SYSTEM.conf"'
    printf '%s\n' '            if [[ "$ssl" == yes ]]; then'
    printf '%s\n' '                printf "proxy SSL vhost\n" >"$rendered/$domain.$PROXY_SYSTEM.ssl.conf"'
    printf '%s\n' '            fi'
    printf '%s\n' '        fi'
    printf '%s\n' '        if [[ -n "$stats" && "$stats" != no ]]; then'
    printf '%s\n' '            printf "statistics config\n" >"$rendered/$stats.$domain.conf"'
    printf '%s\n' '        fi'
    printf '%s\n' '        if [[ "$tpl" =~ ^PHP-FPM-([0-9])([0-9])(-ioncube)?$ ]]; then'
    printf '%s\n' '            version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"'
    printf '%s\n' '            pool=pool.d'
    printf '%s\n' '            [[ -z "${BASH_REMATCH[3]}" ]] || pool=pool.d-ioncube'
    printf '%s\n' '            /usr/bin/mkdir -p -- "$etc_root/php/$version/fpm/$pool"'
    printf '%s\n' '            printf "PHP pool\n" >"$etc_root/php/$version/fpm/$pool/$domain.conf"'
    printf '%s\n' '        fi'
    printf '%s\n' '        if [[ -f "$VESTA/data/vx/cloudflare/fixture-omit-next-stats-render" ]]; then'
    printf '%s\n' '            /usr/bin/rm -f -- "$rendered/$stats.$domain.conf" \
                "$VESTA/data/vx/cloudflare/fixture-omit-next-stats-render"'
    printf '%s\n' '        fi'
    printf '%s\n' '    done <"$VESTA/data/users/$1/web.conf"'
    printf '%s\n' 'fi'
    printf '%s\n' "printf \"%s %s\\\\n\" \"\${0##*/}\" \"\${1:-}\" >>\"\$VESTA/data/vx/cloudflare/migration-native.log\""
    printf '%s\n' 'if [[ "${0##*/}" == v-restart-web \
        && -f "$VESTA/data/vx/cloudflare/fixture-fail-next-restart" ]]; then'
    printf '%s\n' '    /usr/bin/rm -f -- \
        "$VESTA/data/vx/cloudflare/fixture-fail-next-restart"'
    printf '%s\n' '    exit 94'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
} >"$lifecycle_stub"
/usr/bin/chmod 0755 "$lifecycle_stub"
for command in v-rebuild-web-domains v-restart-web v-restart-proxy; do
    /usr/bin/ln -s "$lifecycle_stub" "$vesta_root/bin/$command"
done

printf "BIN='%s/bin'\nDNS_SYSTEM='bind9'\nVX_MANAGED_DNS_PROVIDER='local'\nWEB_SYSTEM='apache2'\nPROXY_SYSTEM='nginx'\nHOMEDIR='%s'\nVESTA_CERTIFICATE='alice:%s'\n" \
    "$vesta_root" "$home_root" "$source_domain" \
    >"$vesta_root/conf/vesta.conf"
printf "SUSPENDED='yes' WEB_DOMAINS='1' WEB_ALIASES='3' U_WEB_DOMAINS='1' U_WEB_ALIASES='3'\nU_WEB_SSL='0'\n" \
    >"$vesta_root/data/users/alice/user.conf"
original_row="DOMAIN='$source_domain' IP='192.0.2.10' IP6='' ALIAS='$source_alias_one,$source_alias_two,$source_alias_one' TPL='PHP-FPM-82' SSL='no' SSL_HOME='same' LETSENCRYPT='yes' FTP_USER='alice_ftp' FTP_PATH='/uploads' FTP_MD5='fixture-md5' BACKEND='PHP-8_2' PROXY='hosting' PROXY_EXT='jpg,png,css' STATS='awstats' STATS_USER='stats' STATS_CRYPT='fixture-crypt' U_DISK='321' U_BANDWIDTH='654' SUSPENDED='yes' TIME='12:34:56' DATE='2026-08-25'"
printf '%s\n' "$original_row" >"$vesta_root/data/users/alice/web.conf"
printf "NAT='192.0.2.20' OWNER='admin' STATUS='shared'\n" \
    >"$vesta_root/data/ips/192.0.2.10"
printf 'alice_ftp:x:1001:1001::%s/alice/web/%s/uploads:/usr/sbin/nologin\n' \
    "$home_root" "$source_domain" >"$passwd_file"
printf 'source payload\n' \
    >"$home_root/alice/web/$source_domain/public_html/index.html"
printf 'private upload\n' \
    >"$home_root/alice/web/$source_domain/uploads/preserved.txt"
printf 'rendered source configuration\n' \
    >"$home_root/alice/conf/web/$source_domain.apache2.conf"
printf 'access log\n' >"$log_root/$source_domain.log"
printf 'error log\n' >"$log_root/$source_domain.error.log"
printf '321\n' >"$log_root/$source_domain.bytes"
for ssl_suffix in crt key ca pem; do
    printf 'retained source %s\n' "$ssl_suffix" \
        >"$vesta_root/data/users/alice/ssl/$source_domain.$ssl_suffix"
done
/usr/bin/chmod 0644 "$vesta_root/data/users/alice/ssl/$source_domain.crt"
/usr/bin/chmod 0600 "$vesta_root/data/users/alice/ssl/$source_domain.key"
/usr/bin/chmod 0640 "$vesta_root/data/users/alice/ssl/$source_domain.ca" \
    "$vesta_root/data/users/alice/ssl/$source_domain.pem"
/usr/bin/touch -t 202401020304.05 \
    "$vesta_root/data/users/alice/ssl/$source_domain."{crt,key,ca,pem}
: >"$cloudflare_root/stub-scenario"
: >"$cloudflare_root/stub-calls.log"
: >"$cloudflare_root/migration-native.log"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj '/C=US/O=Cloudflare Test/OU=Cloudflare Origin SSL Certificate Authority' \
    -keyout "$cloudflare_root/stub-origin-ca.key" \
    -out "$cloudflare_root/stub-origin-ca.pem" >/dev/null 2>&1 \
    || fail 'test Origin CA generation failed'
/usr/bin/chmod 0600 "$cloudflare_root/stub-origin-ca.key" \
    "$cloudflare_root/stub-origin-ca.pem"

provider_input="$work_root/cloudflare.input"
printf "API_TOKEN='fixture_token_12345678901234567890'\nZONE_ID='%s'\nACCOUNT_EMAIL='operator@example.test'\n" \
    "$zone_id" >"$provider_input"
/usr/bin/chmod 0600 "$provider_input"
run_migration "$vesta_root/bin/v-configure-vx-cloudflare" \
    --config-file "$provider_input" >/dev/null \
    || fail 'Cloudflare fixture configuration failed'
run_migration "$vesta_root/bin/v-change-vx-dns-provider" cloudflare-managed \
    >/dev/null || fail 'Cloudflare managed provider selection failed'
printf 'strict\n' \
    >"$cloudflare_root/stub-zone-fedcba9876543210fedcba9876543210-ssl"
assert_eq "$(run_migration "$vesta_root/bin/v-list-vx-cloudflare-status")" ready \
    'Cloudflare fixture is not externally ready'

empty_user=empty
empty_plan=empty-managed-plan
/usr/bin/mkdir -p "$vesta_root/data/users/$empty_user"
printf '\n' >"$vesta_root/data/users/$empty_user/web.conf"
printf "SUSPENDED='no' WEB_DOMAINS='0' WEB_ALIASES='0' U_WEB_DOMAINS='0' U_WEB_ALIASES='0'\nU_WEB_SSL='0'\n" \
    >"$vesta_root/data/users/$empty_user/user.conf"
empty_prepare_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    "$empty_plan" --user "$empty_user" --json) \
    || fail 'empty managed-provider plan prepare failed'
assert_sanitized_json "$empty_prepare_output" prepared 0 0 0 0 0
empty_artifact="$cloudflare_root/migrations/$empty_plan"
empty_fingerprint=$(artifact_fingerprint "$empty_artifact") \
    || fail 'empty plan fingerprint failed'
run_migration "$vesta_root/bin/v-change-vx-dns-provider" local >/dev/null \
    || fail 'local provider selection failed'
calls_before=$(/usr/bin/wc -l <"$cloudflare_root/stub-calls.log")
if local_prepare_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    local-empty-plan --user "$empty_user" --json); then
    fail 'migration prepare accepted local provider for an empty inventory'
fi
assert_sanitized_json "$local_prepare_output" provider_not_ready 0 0 0 1 0
[[ ! -e "$cloudflare_root/migrations/local-empty-plan" ]] \
    || fail 'local-provider prepare published an empty plan'
if local_apply_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
    "$empty_plan" --json); then
    fail 'migration apply accepted local provider for an empty plan'
fi
assert_sanitized_json "$local_apply_output" provider_not_ready 0 0 0 1 0
if local_rollback_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/rollback.sh" \
    "$empty_plan" --json); then
    fail 'migration rollback accepted local provider for an empty plan'
fi
assert_sanitized_json "$local_rollback_output" provider_not_ready 0 0 0 1 0
assert_eq "$(artifact_fingerprint "$empty_artifact")" "$empty_fingerprint" \
    'local-provider rejection mutated the empty plan'
assert_eq "$(/usr/bin/wc -l <"$cloudflare_root/stub-calls.log")" \
    "$calls_before" 'local-provider rejection reached the provider API'
run_migration "$vesta_root/bin/v-change-vx-dns-provider" cloudflare-managed \
    >/dev/null || fail 'Cloudflare managed provider restoration failed'

native_snapshot="$work_root/native-before"
snapshot_native_state "$native_snapshot"

configured_strict_state="$cloudflare_root/stub-zone-$zone_id-ssl"
printf 'full\n' >"$configured_strict_state"
if provider_not_ready_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    provider-not-ready --user alice --json); then
    fail 'migration prepare accepted a provider that was not externally ready'
fi
assert_sanitized_json "$provider_not_ready_output" provider_not_ready 0 0 0 1 0
[[ ! -e "$cloudflare_root/migrations/provider-not-ready" ]] \
    || fail 'provider-not-ready prepare published an artifact'
printf 'strict\n' >"$configured_strict_state"

degraded_metadata="$cloudflare_root/records/alice/$source_domain.conf"
/usr/bin/mkdir -p "${degraded_metadata%/*}"
/usr/bin/chmod 0700 "${degraded_metadata%/*}"
printf "SCHEMA='1'\n" >"$degraded_metadata"
/usr/bin/chmod 0600 "$degraded_metadata"
if degraded_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    degraded-authority --user alice --json); then
    fail 'migration prepare accepted degraded partial provider authority'
fi
assert_sanitized_json "$degraded_output" degraded 0 0 0 1 0
[[ ! -e "$cloudflare_root/migrations/degraded-authority" ]] \
    || fail 'degraded prepare published an artifact'
/usr/bin/rm -f -- "$degraded_metadata"
/usr/bin/rmdir -- "${degraded_metadata%/*}"
assert_native_matches_snapshot "$native_snapshot"

two_site_plan=two-site-allocation
original_aliases="$source_alias_one,$source_alias_two,$source_alias_one"
two_site_first_row=${original_row/"ALIAS='$original_aliases'"/"ALIAS='$source_alias_two'"}
second_row="DOMAIN='$second_source' IP='192.0.2.10' IP6='' ALIAS='' TPL='PHP-FPM-82' SSL='no' SSL_HOME='same' LETSENCRYPT='no' FTP_USER='' FTP_PATH='' FTP_MD5='' BACKEND='' PROXY='hosting' PROXY_EXT='jpg,png,css' STATS='' STATS_USER='' STATS_CRYPT='' U_DISK='0' U_BANDWIDTH='0' SUSPENDED='yes' TIME='12:35:00' DATE='2026-08-25'"
printf '%s\n%s\n' "$two_site_first_row" "$second_row" \
    >"$vesta_root/data/users/alice/web.conf"
/usr/bin/mkdir -p "$home_root/alice/web/$second_source/public_html"
printf 'second source payload\n' \
    >"$home_root/alice/web/$second_source/public_html/index.html"
printf 'second rendered configuration\n' \
    >"$home_root/alice/conf/web/$second_source.nginx.conf"
printf 'second access log\n' >"$log_root/$second_source.log"
printf 'second error log\n' >"$log_root/$second_source.error.log"
printf '0\n' >"$log_root/$second_source.bytes"
mutations_before=$(provider_mutation_count)
two_site_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    "$two_site_plan" --user alice --json) \
    || fail 'two-site migration prepare failed'
assert_sanitized_json "$two_site_output" prepared 2 0 0 0 2
two_site_mapping="$cloudflare_root/migrations/$two_site_plan/mapping.json"
assert_eq "$(/usr/bin/jq -r '[.[].generated_primary] | unique | length' \
    "$two_site_mapping")" 2 \
    'two-site prepare did not reserve distinct generated primaries'
/usr/bin/jq -e --arg source "$second_source" '
    any(.[]; .former_primary == $source and .final_aliases == [$source])
' "$two_site_mapping" >/dev/null \
    || fail 'no-alias site did not retain its former primary as the sole alias'
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'two-site prepare performed a provider mutation'
printf '%s\n' "$original_row" >"$vesta_root/data/users/alice/web.conf"
/usr/bin/rm -rf -- "$home_root/alice/web/$second_source"
/usr/bin/rm -f -- "$home_root/alice/conf/web/$second_source.nginx.conf" \
    "$log_root/$second_source.log" "$log_root/$second_source.error.log" \
    "$log_root/$second_source.bytes"
assert_native_matches_snapshot "$native_snapshot"

mutations_before=$(provider_mutation_count)
calls_before=$(/usr/bin/wc -l <"$cloudflare_root/stub-calls.log")
prepare_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    "$plan" --user alice --json) || fail 'migration prepare failed'
assert_sanitized_json "$prepare_output" prepared 1 0 0 0
assert_native_matches_snapshot "$native_snapshot"
mutations_after=$(provider_mutation_count)
assert_eq "$mutations_after" "$mutations_before" \
    'migration prepare performed a provider mutation'
[[ ! -e "$cloudflare_root/stub-record.conf" \
    && ! -e "$cloudflare_root/records/alice" \
    && ! -e "$cloudflare_root/certificates/alice" ]] \
    || fail 'migration prepare changed provider or ownership state'
/usr/bin/tail -n "+$((calls_before + 1))" "$cloudflare_root/stub-calls.log" \
    >"$work_root/prepare-provider-calls.log"
[[ -s "$work_root/prepare-provider-calls.log" ]] \
    || fail 'migration prepare did not perform provider readback'
if /usr/bin/grep -Eq \
    '^(create |update$|delete$|origin-create |origin-delete |ssl-patch )' \
    "$work_root/prepare-provider-calls.log"; then
    fail 'migration prepare provider log was not GET-only'
fi

artifact="$cloudflare_root/migrations/$plan"
[[ -d "$artifact" && ! -L "$artifact" ]] \
    || fail 'migration prepare did not publish its protected artifact'
assert_eq "$(/usr/bin/head -n1 "$artifact/plan.tsv")" \
    $'ITEM\tUSER\tSOURCE\tTARGET\tHOSTNAMES_SHA256\tADDRESS\tRETAIN_SOURCE_SSL' \
    'migration plan did not use the seven-column retained-SSL schema'
assert_eq "$(/usr/bin/awk -F '\t' 'NR == 2 { print $7 }' \
    "$artifact/plan.tsv")" yes \
    'exact system-certificate reference did not retain source SSL'
while IFS= read -r -d '' artifact_path; do
    if [[ -L "$artifact_path" ]]; then
        fail 'migration artifact contains a symlink'
    elif [[ -d "$artifact_path" ]]; then
        assert_eq "$(/usr/bin/stat -c '%a' "$artifact_path")" 700 \
            'migration artifact directory is not 0700'
    elif [[ -f "$artifact_path" ]]; then
        assert_eq "$(/usr/bin/stat -c '%a' "$artifact_path")" 600 \
            'migration artifact file is not 0600'
        assert_eq "$(/usr/bin/stat -c '%h' "$artifact_path")" 1 \
            'migration artifact file is multiply linked'
    else
        fail 'migration artifact contains a special file'
    fi
done < <(/usr/bin/find -P "$artifact" -print0)

generated_domain=$(/usr/bin/jq -er '.[0].generated_primary' \
    "$artifact/mapping.json") || fail 'prepared mapping omitted its generated primary'
[[ "$generated_domain" =~ ^s-[a-z0-9]{10}\.managed\.example\.test$ ]] \
    || fail 'prepared mapping contains an invalid generated primary'

drifted_row=${original_row/"PROXY='hosting'"/"PROXY='drift'"}
[[ "$drifted_row" != "$original_row" ]] \
    || fail 'migration drift fixture did not change its authoritative row'
printf '%s\n' "$drifted_row" >"$vesta_root/data/users/alice/web.conf"
mutations_before=$(provider_mutation_count)
if drift_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
    "$plan" --json); then
    fail 'migration apply accepted drift from the immutable plan'
fi
assert_sanitized_json "$drift_output" drift 1 0 0 1
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'drift rejection reached a provider mutation'
printf '%s\n' "$original_row" >"$vesta_root/data/users/alice/web.conf"

apply_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
    "$plan" --json) || fail 'migration apply failed'
assert_sanitized_json "$apply_output" applied 0 1 0 0

applied_row=$(/usr/bin/grep -F "DOMAIN='$generated_domain' " \
    "$vesta_root/data/users/alice/web.conf") \
    || fail 'migration apply did not persist the generated primary'
expected_aliases="$source_domain,$source_alias_one,$source_alias_two"
assert_file_contains "$vesta_root/data/users/alice/web.conf" \
    "DOMAIN='$generated_domain'" 'generated primary was not authoritative'
[[ "$applied_row" == *" ALIAS='$expected_aliases' "* \
    && "$applied_row" == *" LETSENCRYPT='no' "* \
    && "$applied_row" == *" SSL='yes' "* \
    && "$applied_row" == *" FTP_USER='alice_ftp' "* \
    && "$applied_row" == *" FTP_PATH='/uploads' "* \
    && "$applied_row" == *" BACKEND='PHP-8_2' "* \
    && "$applied_row" == *" PROXY='hosting' "* \
    && "$applied_row" == *" PROXY_EXT='jpg,png,css' "* \
    && "$applied_row" == *" STATS='awstats' "* \
    && "$applied_row" == *" U_DISK='321' "* \
    && "$applied_row" == *" U_BANDWIDTH='654' "* \
    && "$applied_row" == *" SUSPENDED='yes' "* ]] \
    || fail 'migration apply did not preserve the suspended multi-alias/proxy row'
[[ -d "$home_root/alice/web/$generated_domain" \
    && ! -e "$home_root/alice/web/$source_domain" ]] \
    || fail 'migration apply did not move the domain document root'
for log_suffix in log error.log bytes; do
    [[ -f "$log_root/$generated_domain.$log_suffix" \
        && ! -e "$log_root/$source_domain.$log_suffix" ]] \
        || fail 'migration apply did not move every domain log'
done
for ssl_suffix in crt key ca pem; do
    [[ -f "$vesta_root/data/users/alice/ssl/$generated_domain.$ssl_suffix" \
        && -f "$home_root/alice/conf/web/ssl.$generated_domain.$ssl_suffix" ]] \
        || fail 'migration apply did not install canonical and rendered SSL'
done
for rendered_artifact in \
    "$home_root/alice/conf/web/$generated_domain.apache2.conf" \
    "$home_root/alice/conf/web/$generated_domain.apache2.ssl.conf" \
    "$home_root/alice/conf/web/$generated_domain.nginx.conf" \
    "$home_root/alice/conf/web/$generated_domain.nginx.ssl.conf" \
    "$home_root/alice/conf/web/awstats.$generated_domain.conf" \
    "$etc_root/php/8.2/fpm/pool.d/$generated_domain.conf"; do
    [[ -f "$rendered_artifact" && ! -L "$rendered_artifact" ]] \
        || fail 'migration apply omitted a required native rendered artifact'
done
assert_source_ssl_matches_snapshot "$native_snapshot"
[[ -f "$cloudflare_root/records/alice/$generated_domain.conf" \
    && -f "$cloudflare_root/certificates/alice/$generated_domain.conf" ]] \
    || fail 'migration apply omitted protected provider ownership metadata'
assert_eq "$(/usr/bin/cut -d: -f6 "$passwd_file")" \
    "$home_root/alice/web/$generated_domain/uploads" \
    'migration apply did not preserve the FTP subpath relationship'
/usr/bin/cmp -s -- "$native_snapshot/user.conf" \
    "$vesta_root/data/users/alice/user.conf" \
    || fail 'migration apply changed suspension or counters'
assert_file_contains "$cloudflare_root/migration-native.log" \
    'v-rebuild-web-domains alice' \
    'suspended user was not rebuilt through the internal migration capability'
assert_eq "$(/usr/bin/grep -c '^v-rebuild-web-domains alice$' \
    "$cloudflare_root/migration-native.log")" 1 \
    'migration apply did not perform exactly one final rebuild'
assert_eq "$(/usr/bin/grep -c '^v-restart-web yes$' \
    "$cloudflare_root/migration-native.log")" 1 \
    'migration apply did not perform exactly one web restart'
assert_eq "$(/usr/bin/grep -c '^v-restart-proxy yes$' \
    "$cloudflare_root/migration-native.log")" 1 \
    'migration apply did not perform exactly one proxy restart'
assert_eq "$(/usr/bin/grep -c "^create $generated_domain$" \
    "$cloudflare_root/stub-calls.log")" 1 \
    'migration apply did not create exactly its generated A record'
for custom_hostname in "$source_domain" "$source_alias_one" "$source_alias_two"; do
    if /usr/bin/grep -Fqx "create $custom_hostname" \
        "$cloudflare_root/stub-calls.log"; then
        fail 'migration apply mutated custom DNS aliases'
    fi
done

mutations_before=$(provider_mutation_count)
native_before=$(native_mutation_count)
web_sha_before=$(/usr/bin/sha256sum "$vesta_root/data/users/alice/web.conf" \
    | /usr/bin/cut -d ' ' -f1)
apply_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
    "$plan" --json) || fail 'idempotent migration apply failed'
assert_sanitized_json "$apply_output" applied 0 1 0 0
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'idempotent apply repeated a provider mutation'
assert_eq "$(native_mutation_count)" "$native_before" \
    'idempotent apply repeated a native mutation'
assert_eq "$(/usr/bin/sha256sum "$vesta_root/data/users/alice/web.conf" \
    | /usr/bin/cut -d ' ' -f1)" "$web_sha_before" \
    'idempotent apply changed authoritative web state'

/usr/bin/sed -i "s/^U_WEB_SSL='0'$/U_WEB_SSL='1'/" \
    "$vesta_root/data/users/alice/user.conf"
/usr/bin/grep -Fqx "U_WEB_SSL='1'" \
    "$vesta_root/data/users/alice/user.conf" \
    || fail 'fixture did not model the migration-owned SSL counter change'
/usr/bin/cp -a -- "$vesta_root/data/users/alice/user.conf" \
    "$work_root/user-before-unrelated-drift.conf"
/usr/bin/sed -i "s/^U_WEB_SSL='1'$/U_WEB_SSL='2'/" \
    "$vesta_root/data/users/alice/user.conf"
/usr/bin/cp -a -- "$vesta_root/data/users/alice/user.conf" \
    "$work_root/user-with-extra-ssl-counter.conf"
mutations_before=$(provider_mutation_count)
native_before=$(native_mutation_count)
if rollback_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/rollback.sh" \
    "$plan" --json); then
    fail 'migration rollback accepted an unrelated SSL counter increment'
fi
assert_sanitized_json "$rollback_output" drift 0 1 0 1
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'SSL-counter-drifted rollback mutated provider state'
assert_eq "$(native_mutation_count)" "$native_before" \
    'SSL-counter-drifted rollback mutated native lifecycle state'
/usr/bin/cmp -s -- "$work_root/user-with-extra-ssl-counter.conf" \
    "$vesta_root/data/users/alice/user.conf" \
    || fail 'SSL-counter-drifted rollback changed user.conf'
/usr/bin/cp -a -- "$work_root/user-before-unrelated-drift.conf" \
    "$vesta_root/data/users/alice/user.conf"
/usr/bin/sed -i "s/SUSPENDED='yes'/SUSPENDED='no'/" \
    "$vesta_root/data/users/alice/user.conf"
/usr/bin/cp -a -- "$vesta_root/data/users/alice/user.conf" \
    "$work_root/user-with-unrelated-drift.conf"
mutations_before=$(provider_mutation_count)
native_before=$(native_mutation_count)
if rollback_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/rollback.sh" \
    "$plan" --json); then
    fail 'migration rollback accepted unrelated user.conf drift'
fi
assert_sanitized_json "$rollback_output" drift 0 1 0 1
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'drifted rollback mutated provider state'
assert_eq "$(native_mutation_count)" "$native_before" \
    'drifted rollback mutated native lifecycle state'
/usr/bin/cmp -s -- "$work_root/user-with-unrelated-drift.conf" \
    "$vesta_root/data/users/alice/user.conf" \
    || fail 'drifted rollback overwrote unrelated user.conf state'
/usr/bin/cp -a -- "$work_root/user-before-unrelated-drift.conf" \
    "$vesta_root/data/users/alice/user.conf"

alias_strict_state="$cloudflare_root/stub-zone-fedcba9876543210fedcba9876543210-ssl"
printf 'full\n' >"$alias_strict_state"
rollback_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/rollback.sh" \
    "$plan" --json) || fail 'migration rollback failed'
printf 'strict\n' >"$alias_strict_state"
assert_sanitized_json "$rollback_output" rolled_back 0 0 1 0
assert_native_matches_snapshot "$native_snapshot"
[[ ! -e "$home_root/alice/web/$generated_domain" \
    && ! -e "$log_root/$generated_domain.log" \
    && ! -e "$cloudflare_root/records/alice/$generated_domain.conf" \
    && ! -e "$cloudflare_root/certificates/alice/$generated_domain.conf" ]] \
    || fail 'migration rollback left generated native or provider state behind'

mutations_before=$(provider_mutation_count)
native_before=$(native_mutation_count)
rollback_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/rollback.sh" \
    "$plan" --json) || fail 'idempotent migration rollback failed'
assert_sanitized_json "$rollback_output" rolled_back 0 0 1 0
assert_eq "$(provider_mutation_count)" "$mutations_before" \
    'idempotent rollback repeated a provider mutation'
assert_eq "$(native_mutation_count)" "$native_before" \
    'idempotent rollback repeated a native mutation'
assert_native_matches_snapshot "$native_snapshot"

prepare_compensated_plan compensated-native-install
printf 'native_install_failure\n' >"$cloudflare_root/stub-scenario"
assert_compensated_failure 'certificate installation'
if ! { /usr/bin/grep -Fqx "create $failure_target" "$stage_calls" \
        && /usr/bin/grep -Fqx delete "$stage_calls" \
        && /usr/bin/grep -q '^origin-create ' "$stage_calls" \
        && /usr/bin/grep -q '^origin-delete ' "$stage_calls"; }; then
    fail 'certificate-install failure did not compensate both provider identities'
fi

migration_wrapper="$work_root/migration-stage-wrapper.sh"
{
    printf 'source %q\n' "$repo_root/func/vx/cloudflare/migration.sh"
    printf '%s\n' \
        'eval "$(declare -f vx_cf_migration_paths_forward | /usr/bin/sed '\''1s/^vx_cf_migration_paths_forward /vx_cf_migration_paths_forward_fixture_real /'\'')"' \
        'eval "$(declare -f vx_cf_migration_replace_exact_row | /usr/bin/sed '\''1s/^vx_cf_migration_replace_exact_row /vx_cf_migration_replace_exact_row_fixture_real /'\'')"' \
        'eval "$(declare -f vx_cf_mutate_record | /usr/bin/sed '\''1s/^vx_cf_mutate_record /vx_cf_mutate_record_fixture_real /'\'')"' \
        'eval "$(declare -f vx_cf_write_metadata | /usr/bin/sed '\''1s/^vx_cf_write_metadata /vx_cf_write_metadata_fixture_real /'\'')"' \
        'vx_cf_migration_paths_forward() {' \
        '    vx_cf_migration_paths_forward_fixture_real "$@" || return' \
        '    if [[ -f "$(vx_cf_root)/fixture-fail-after-rename" ]]; then' \
        '        /usr/bin/rm -f -- "$(vx_cf_root)/fixture-fail-after-rename"' \
        '        return 91' \
        '    fi' \
        '}' \
        'vx_cf_migration_replace_exact_row() {' \
        '    vx_cf_migration_replace_exact_row_fixture_real "$@" || return' \
        '    if [[ "$1" == "$VESTA/data/users/alice/web.conf"' \
        '        && -f "$(vx_cf_root)/fixture-fail-after-alias-row" ]]; then' \
        '        /usr/bin/rm -f -- "$(vx_cf_root)/fixture-fail-after-alias-row"' \
        '        return 92' \
        '    fi' \
        '}' \
        'vx_cf_mutate_record() {' \
        '    vx_cf_mutate_record_fixture_real "$@" || return' \
        '    if [[ "$1" == POST && "$2" == dns_records' \
        '        && -f "$(vx_cf_root)/fixture-fail-after-dns-create" ]]; then' \
        '        /usr/bin/rm -f -- "$(vx_cf_root)/fixture-fail-after-dns-create"' \
        '        return 93' \
        '    fi' \
        '}' \
        'vx_cf_write_metadata() {' \
        '    vx_cf_write_metadata_fixture_real "$@" || return' \
        '    if [[ -f "$(vx_cf_root)/fixture-fail-after-metadata-write" ]]; then' \
        '        /usr/bin/rm -f -- "$(vx_cf_root)/fixture-fail-after-metadata-write"' \
        '        return 94' \
        '    fi' \
        '}'
} >"$migration_wrapper"
/usr/bin/chmod 0600 "$migration_wrapper"
/usr/bin/rm -- "$vesta_root/func"
/usr/bin/mkdir -p "$vesta_root/func/vx/cloudflare"
/usr/bin/ln -s "$repo_root/func/main.sh" "$vesta_root/func/main.sh"
/usr/bin/ln -s "$repo_root/func/vx/cloudflare/main.sh" \
    "$vesta_root/func/vx/cloudflare/main.sh"
/usr/bin/ln -s "$migration_wrapper" \
    "$vesta_root/func/vx/cloudflare/migration.sh"

prepare_compensated_plan fail-after-rename
printf 'fail\n' >"$cloudflare_root/fixture-fail-after-rename"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-fail-after-rename"
assert_compensated_failure 'post-rename'
if /usr/bin/grep -Fqx "create $failure_target" "$stage_calls"; then
    fail 'post-rename failure reached DNS creation'
fi

prepare_compensated_plan fail-after-alias-row
printf 'fail\n' >"$cloudflare_root/fixture-fail-after-alias-row"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-fail-after-alias-row"
assert_compensated_failure 'post-alias-row update'
if /usr/bin/grep -Fqx "create $failure_target" "$stage_calls"; then
    fail 'post-alias-row failure reached DNS creation'
fi

prepare_compensated_plan fail-after-dns-create
printf 'fail\n' >"$cloudflare_root/fixture-fail-after-dns-create"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-fail-after-dns-create"
assert_compensated_failure 'post-DNS-create'
if ! { /usr/bin/grep -Fqx "create $failure_target" "$stage_calls" \
        && /usr/bin/grep -Fqx delete "$stage_calls"; }; then
    fail 'post-DNS-create failure did not delete its exact generated A record'
fi
if /usr/bin/grep -q '^origin-create ' "$stage_calls"; then
    fail 'post-DNS-create failure reached certificate creation'
fi

prepare_compensated_plan fail-after-metadata-write
printf 'fail\n' >"$cloudflare_root/fixture-fail-after-metadata-write"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-fail-after-metadata-write"
assert_compensated_failure 'post-metadata-write'
if ! { /usr/bin/grep -Fqx "create $failure_target" "$stage_calls" \
        && /usr/bin/grep -Fqx delete "$stage_calls"; }; then
    fail 'post-metadata-write failure did not remove exact provider authority'
fi
if /usr/bin/grep -q '^origin-create ' "$stage_calls"; then
    fail 'post-metadata-write failure reached certificate creation'
fi

prepare_compensated_plan fail-after-restart
printf 'fail\n' >"$cloudflare_root/fixture-fail-next-restart"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-fail-next-restart"
assert_compensated_failure 'post-provision restart'
if ! { /usr/bin/grep -Fqx "create $failure_target" "$stage_calls" \
        && /usr/bin/grep -Fqx delete "$stage_calls" \
        && /usr/bin/grep -q '^origin-create ' "$stage_calls" \
        && /usr/bin/grep -q '^origin-delete ' "$stage_calls"; }; then
    fail 'restart failure did not compensate both exact provider identities'
fi

prepare_compensated_plan missing-rendered-artifact
printf 'omit\n' >"$cloudflare_root/fixture-omit-next-stats-render"
/usr/bin/chmod 0600 "$cloudflare_root/fixture-omit-next-stats-render"
assert_compensated_failure 'missing rendered statistics artifact'
if ! { /usr/bin/grep -Fqx "create $failure_target" "$stage_calls" \
        && /usr/bin/grep -Fqx delete "$stage_calls" \
        && /usr/bin/grep -q '^origin-create ' "$stage_calls" \
        && /usr/bin/grep -q '^origin-delete ' "$stage_calls"; }; then
    fail 'missing rendered artifact did not compensate provider identities'
fi

deletion_plan=post-migration-native-delete
deletion_prepare_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/prepare.sh" \
    "$deletion_plan" --user alice --json) \
    || fail 'native-deletion migration prepare failed'
assert_sanitized_json "$deletion_prepare_output" prepared 1 0 0 0
deletion_artifact="$cloudflare_root/migrations/$deletion_plan"
deletion_target=$(/usr/bin/jq -er '.[0].generated_primary' \
    "$deletion_artifact/mapping.json") \
    || fail 'native-deletion mapping omitted its generated primary'
deletion_apply_output=$(run_migration \
    "$vesta_root/install/migrations/cloudflare-managed-web-domains/apply.sh" \
    "$deletion_plan" --json) || fail 'native-deletion migration apply failed'
assert_sanitized_json "$deletion_apply_output" applied 0 1 0 0

safe_native_dir="$work_root/safe-native-bin"
/usr/bin/mkdir -p "$safe_native_dir"
/usr/bin/ln -s "$strict_stub" "$safe_native_dir/v-delete-web-domain"
safe_delete="$work_root/safe-native-delete"
{
    printf '%s\n' '#!/bin/bash' 'set -u -o pipefail'
    printf '%s\n' 'source "$VESTA/func/vx/cloudflare/main.sh"' \
        'source "$VESTA/conf/vesta.conf"' \
        'user=$1' 'domain=$2'
    printf 'expected_web_root=%q\n' "$home_root/alice/web"
    printf 'expected_log_root=%q\n' "$log_root"
    printf 'native_delete=%q\n' "$safe_native_dir/v-delete-web-domain"
    printf '%s\n' \
        '[[ "$user" == alice && "$domain" =~ ^s-[a-z0-9]{10}\.managed\.example\.test$ ]] || exit 90' \
        'fixture_cleanup_locked() {' \
        '    if vx_cf_metadata_exists "$user" "$domain"; then' \
        '        vx_cf_cleanup_locked "$user" "$domain" || return' \
        '    fi' \
        '    if vx_cf_certificate_metadata_exists "$user" "$domain"; then' \
        '        vx_cf_origin_cleanup_locked "$user" "$domain" || return' \
        '    fi' \
        '}' \
        'vx_cf_with_lock fixture_cleanup_locked || exit 91' \
        'VESTA="$VESTA" "$native_delete" "$user" "$domain" no || exit 92' \
        'domain_root="$expected_web_root/$domain"' \
        '[[ -d "$domain_root" && ! -L "$domain_root" ]] || exit 93' \
        '/usr/bin/find -P "$domain_root" -mindepth 1 -delete || exit 94' \
        '/usr/bin/rmdir -- "$domain_root" || exit 95' \
        '/usr/bin/rm -f -- "$expected_log_root/$domain.log" "$expected_log_root/$domain.error.log" "$expected_log_root/$domain.bytes"' \
        '/usr/bin/rm -f -- "$HOMEDIR/$user/conf/web/$domain.nginx.conf"' \
        '/usr/bin/sed -i "/^alice_ftp:/d" "$VX_CLOUDFLARE_MIGRATION_PASSWD_FILE"'
} >"$safe_delete"
/usr/bin/chmod 0755 "$safe_delete"
delete_calls_before=$(/usr/bin/wc -l <"$cloudflare_root/stub-calls.log")
run_migration "$safe_delete" alice "$deletion_target" >/dev/null \
    || fail 'safe synthetic native deletion failed'
/usr/bin/tail -n "+$((delete_calls_before + 1))" \
    "$cloudflare_root/stub-calls.log" >"$work_root/native-delete-provider-calls.log"
assert_eq "$(/usr/bin/grep -c '^delete$' \
    "$work_root/native-delete-provider-calls.log")" 1 \
    'native deletion did not remove exactly one generated A record'
assert_eq "$(/usr/bin/grep -c '^origin-delete ' \
    "$work_root/native-delete-provider-calls.log")" 1 \
    'native deletion did not remove exactly one generated certificate'
if /usr/bin/grep -Eq '^(create |update$|ssl-patch )' \
    "$work_root/native-delete-provider-calls.log"; then
    fail 'native deletion performed an unrelated provider mutation'
fi
[[ ! -e "$vesta_root/data/users/alice/ssl/$deletion_target.crt" \
    && ! -e "$home_root/alice/web/$deletion_target" \
    && ! -e "$cloudflare_root/records/alice/$deletion_target.conf" \
    && ! -e "$cloudflare_root/certificates/alice/$deletion_target.conf" \
    && ! -s "$cloudflare_root/stub-record.conf" ]] \
    || fail 'native deletion retained generated native or provider authority'
assert_source_ssl_matches_snapshot "$native_snapshot"
for custom_hostname in "$source_domain" "$source_alias_one" "$source_alias_two"; do
    if /usr/bin/grep -Fqx "create $custom_hostname" \
        "$cloudflare_root/stub-calls.log"; then
        fail 'native deletion fixture mutated custom DNS'
    fi
done

printf 'PASS: Cloudflare managed web-domain migration\n'
