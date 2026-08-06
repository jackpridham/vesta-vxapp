#!/bin/bash

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAILED=0
E_ARGS=2
E_INVALID=22

fail() {
    echo "FAIL: $1" >&2
    FAILED=1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [ "$actual" = "$expected" ] || fail "$message (expected '$expected', got '$actual')"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$message (missing '$needle')"
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    local message="$3"
    grep -Fq -- "$needle" "$file" || fail "$message"
}

check_result() {
    exit "$1"
}

# shellcheck source=../func/vx/proxy.sh
source "$ROOT/func/vx/proxy.sh"

# Create-style named option parsing, including repeated custom headers.
vx_proxy_parse_long_options \
    --proxy-target 'http://127.0.0.1:8420' \
    --proxy-mode proxy \
    --proxy-profile application \
    --proxy-preserve-host yes \
    --proxy-timeout 75 \
    --header 'X-Business-GUID: EXAMPLE-GUID' \
    --header 'X-Another-Header: example'
assert_equal 'http://127.0.0.1:8420' "$VX_PROXY_OPTION_TARGET" 'named target was not parsed'
assert_equal 'proxy' "$VX_PROXY_OPTION_MODE" 'named mode was not parsed'
assert_equal 'application' "$VX_PROXY_OPTION_PROFILE" 'named profile was not parsed'
assert_equal 'yes' "$VX_PROXY_OPTION_PRESERVE_HOST" 'named preserve-host was not parsed'
assert_equal '75' "$VX_PROXY_OPTION_TIMEOUT" 'named timeout was not parsed'
assert_equal 'X-Business-GUID: EXAMPLE-GUID||X-Another-Header: example' "$VX_PROXY_OPTION_HEADERS" 'repeated headers were not serialized'

assert_target_valid() {
    PROXY_TARGET="$1"
    vx_proxy_validate_target >/dev/null 2>&1 || fail "valid target rejected: $1"
}

assert_target_invalid() {
    PROXY_TARGET="$1"
    if (vx_proxy_validate_target) >/dev/null 2>&1; then
        fail "malformed target accepted: $1"
    fi
}

assert_target_valid 'http://127.0.0.1:8420'
assert_target_valid 'http://127.0.0.1'
assert_target_valid 'https://backend.example.test/app'
assert_target_valid 'https://backend.example.test:443/app?source=test'
assert_target_valid 'http://[::1]:8420/app'
assert_target_valid 'https://[2001:db8::10]/app?source=test'
assert_target_invalid 'ftp://backend.example.test'
assert_target_invalid 'http://backend.example.test/a path'
assert_target_invalid 'http://backend.example.test/;return'
assert_target_invalid 'http:///path'
assert_target_invalid 'https://:443'
assert_target_invalid 'http://?query'
assert_target_invalid 'http://@/path'
assert_target_invalid 'http://user@/path'
assert_target_invalid 'http://user@:8420/path'
assert_target_invalid 'http://backend.example.test:'
assert_target_invalid 'http://backend.example.test:abc'
assert_target_invalid 'http://backend.example.test:0'
assert_target_invalid 'http://backend.example.test:65536'
assert_target_invalid 'http://backend.example.test:70000'
assert_target_invalid 'http://backend.example.test:999999999999999999999999'
assert_target_invalid 'http://2001:db8::10/path'
assert_target_invalid 'http://[::1/path'
assert_target_invalid 'http://::1]/path'
assert_target_invalid 'http://[]:8420/path'
assert_target_invalid 'http://[backend.example.test]:8420/path'
assert_target_invalid ''

for target_and_host in \
    'http://127.0.0.1:8420|127.0.0.1' \
    'https://backend.example.test/app|backend.example.test' \
    'http://[::1]:8420/app|[::1]' \
    'https://[2001:db8::10]/app|[2001:db8::10]'; do
    PROXY_TARGET="${target_and_host%%|*}"
    assert_equal "${target_and_host#*|}" "$(vx_proxy_target_host)" \
        "target host was parsed incorrectly for $PROXY_TARGET"
done

PROXY_HEADERS='X-Business-GUID: EXAMPLE-GUID'
vx_proxy_validate_headers >/dev/null 2>&1 || fail 'valid business GUID header was rejected'
for invalid_header in 'MissingColon' ': empty-name' 'X-Empty:' 'Bad Name: value' 'X-Test: bad;value' 'X-Test: bad|value'; do
    PROXY_HEADERS="$invalid_header"
    if (vx_proxy_validate_headers) >/dev/null 2>&1; then
        fail "unrenderable header accepted: $invalid_header"
    fi
done

for valid_mode in proxy redirect redirect-temp; do
    PROXY_MODE="$valid_mode"
    vx_proxy_validate_mode >/dev/null 2>&1 || fail "valid mode rejected: $valid_mode"
done
PROXY_MODE='forward'
(vx_proxy_validate_mode) >/dev/null 2>&1 && fail 'invalid mode accepted'

for valid_profile in standard websocket application streaming media; do
    PROXY_PROFILE="$valid_profile"
    vx_proxy_validate_profile >/dev/null 2>&1 || fail "valid profile rejected: $valid_profile"
done
PROXY_PROFILE='privileged'
(vx_proxy_validate_profile) >/dev/null 2>&1 && fail 'invalid profile accepted'

for valid_timeout in 1 60 3600; do
    PROXY_TIMEOUT="$valid_timeout"
    vx_proxy_validate_timeout >/dev/null 2>&1 || fail "valid timeout rejected: $valid_timeout"
done
for invalid_timeout in 0 3601 -1 1.5 abc ''; do
    PROXY_TIMEOUT="$invalid_timeout"
    (vx_proxy_validate_timeout) >/dev/null 2>&1 && fail "invalid timeout accepted: $invalid_timeout"
done

# Render the full application-profile block.
PROXY='vx-proxy'
PROXY_TEMPLATE='vx-proxy'
PROXY_MODE='proxy'
PROXY_TARGET='http://127.0.0.1:8420'
PROXY_PROFILE='application'
PROXY_PRESERVE_HOST='yes'
PROXY_TIMEOUT='75'
PROXY_HEADERS='X-Business-GUID: EXAMPLE-GUID||X-Another-Header: example'
PROXY_PATH='/'
vx_proxy_prepare_template_values
rendered="$VX_PROXY_LOCATION_BLOCK"
assert_contains "$rendered" 'proxy_pass http://127.0.0.1:8420;' 'proxy target was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Real-IP $remote_addr;' 'X-Real-IP was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' 'X-Forwarded-For was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Forwarded-Proto $scheme;' 'X-Forwarded-Proto was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Forwarded-Host $host;' 'X-Forwarded-Host was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Forwarded-Port $server_port;' 'X-Forwarded-Port was not rendered'
assert_contains "$rendered" 'proxy_set_header Host $host;' 'preserved Host was not rendered'
assert_contains "$rendered" 'proxy_http_version 1.1;' 'HTTP/1.1 was not rendered'
assert_contains "$rendered" 'proxy_set_header Upgrade $http_upgrade;' 'application upgrade behavior was not rendered'
assert_contains "$rendered" 'proxy_read_timeout 75s;' 'proxy timeout was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Business-GUID "EXAMPLE-GUID";' 'business GUID header was not rendered'
assert_contains "$rendered" 'proxy_set_header X-Another-Header "example";' 'second custom header was not rendered'

PROXY_PRESERVE_HOST='no'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'proxy_set_header Host 127.0.0.1;' 'upstream Host was not rendered when preservation was disabled'

PROXY_TARGET='http://[::1]:8420'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'proxy_set_header Host [::1];' 'bracketed IPv6 Host was not rendered when preservation was disabled'

PROXY_MODE='redirect'
PROXY_TARGET='https://redirect.example.test'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'return 301 https://redirect.example.test$request_uri;' 'permanent redirect was not rendered'
PROXY_MODE='redirect-temp'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'return 302 https://redirect.example.test$request_uri;' 'temporary redirect was not rendered'

DOMAIN_HELPER="$ROOT/func/domain.sh"
assert_file_contains "$DOMAIN_HELPER" 'vx_proxy_prepare_template_values' 'domain rendering does not prepare native proxy values'
assert_file_contains "$DOMAIN_HELPER" 'vx_proxy_apply_template_blocks' 'domain rendering does not apply the native proxy block'

INSTALL_TPL="$ROOT/install/debian/10/templates/web/nginx/vx-proxy.tpl"
INSTALL_STPL="$ROOT/install/debian/10/templates/web/nginx/vx-proxy.stpl"
MIRROR_TPL="$ROOT/example-of-linux-root-folder/usr/local/vesta/data/templates/web/nginx/vx-proxy.tpl"
MIRROR_STPL="$ROOT/example-of-linux-root-folder/usr/local/vesta/data/templates/web/nginx/vx-proxy.stpl"
cmp -s "$INSTALL_TPL" "$MIRROR_TPL" || fail 'HTTP installer and synthetic-root proxy templates differ'
cmp -s "$INSTALL_STPL" "$MIRROR_STPL" || fail 'HTTPS installer and synthetic-root proxy templates differ'
for template in "$INSTALL_TPL" "$INSTALL_STPL" "$MIRROR_TPL" "$MIRROR_STPL"; do
    assert_file_contains "$template" '%vx_proxy_location_block%' "$template lacks the native proxy location placeholder"
done
assert_file_contains "$INSTALL_TPL" 'include %home%/%user%/conf/web/nginx.%domain%.conf*;' 'HTTP proxy template does not include ACME fragments'
assert_file_contains "$INSTALL_STPL" 'include %home%/%user%/conf/web/snginx.%domain%.conf*;' 'HTTPS proxy template does not include ACME fragments'

# Nginx regex locations take precedence over an ordinary prefix location. The
# issuance command must generate that regex and the native block must remain a
# plain catch-all prefix for HTTP-01 to be answered locally.
LE_COMMAND="$ROOT/bin/v-add-letsencrypt-domain"
assert_file_contains "$LE_COMMAND" 'location ~ "^/\.well-known/acme-challenge/(.*)$" {' 'ACME command does not generate its HTTP-01 regex location'
DELETE_COMMAND="$ROOT/bin/v-delete-web-domain-proxy"
assert_file_contains "$DELETE_COMMAND" 'restored_proxy=$(get_user_value '\''$PROXY_TEMPLATE'\'')' \
    'native proxy disable does not resolve the ordinary owner proxy template'
assert_file_contains "$DELETE_COMMAND" 'add_web_config "$PROXY_SYSTEM" "$restored_proxy.tpl"' \
    'native proxy disable does not restore the ordinary HTTP frontend'
assert_file_contains "$DELETE_COMMAND" 'add_web_config "$PROXY_SYSTEM" "$restored_proxy.stpl"' \
    'native proxy disable does not restore the ordinary HTTPS frontend'
assert_file_contains "$DELETE_COMMAND" 'vx_proxy_clear_web_conf' \
    'native proxy disable does not clear native target/header state'
PROXY_MODE='proxy'
PROXY_TARGET='http://127.0.0.1:8420'
PROXY_PRESERVE_HOST='yes'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'location / {' 'native proxy is not an ordinary catch-all prefix location'
[[ "$VX_PROXY_LOCATION_BLOCK" != *'location ^~ /'* ]] || fail 'native proxy would suppress the ACME regex location'

TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

run_ssl_behavior_test() {
    local fixture="$TEST_TMP/ssl"
    local vesta="$fixture/vesta"
    local home="$fixture/home"
    local certs="$fixture/certs"
    local log="$fixture/calls.log"
    local test_domain='proxy.example.test'

    mkdir -p "$vesta/func" "$vesta/conf" "$vesta/data/users/alice/ssl" \
        "$vesta/bin" "$home/alice/conf/web" "$certs"
    printf '%s\n' certificate > "$certs/$test_domain.crt"
    printf '%s\n' private-key > "$certs/$test_domain.key"

    cat > "$vesta/func/main.sh" <<'EOF'
USER_DATA="$VESTA/data/users/$user"
BIN="$VESTA/bin"
check_args() { :; }
is_format_valid() { :; }
is_system_enabled() { :; }
is_object_valid() { :; }
is_object_unsuspended() { :; }
is_object_value_empty() { :; }
is_web_domain_cert_valid() { :; }
format_domain() { :; }
format_domain_idn() { :; }
get_domain_values() {
    IP='192.0.2.10'
    TPL='default'
    PROXY='vx-proxy'
    PROXY_TARGET='http://127.0.0.1:8420'
    PROXY_HEADERS='X-Business-GUID: EXAMPLE-GUID'
}
get_real_ip() { printf '%s\n' "$1"; }
prepare_web_domain_values() { :; }
add_web_config() {
    printf 'render|%s|%s|%s|%s\n' "$1" "$2" "$PROXY_TARGET" "$PROXY_HEADERS" >> "$TEST_LOG"
}
increase_user_value() { :; }
update_object_value() {
    case "$4" in
        '$PROXY_TARGET'|'$PROXY_HEADERS')
            printf 'unexpected-proxy-update|%s\n' "$4" >> "$TEST_LOG"
            ;;
    esac
}
check_result() { return "$1"; }
log_history() { :; }
log_event() {
    printf 'final|%s|%s\n' "$PROXY_TARGET" "$PROXY_HEADERS" >> "$TEST_LOG"
}
EOF
    : > "$vesta/func/domain.sh"
    : > "$vesta/func/ip.sh"
    cat > "$vesta/conf/vesta.conf" <<EOF
HOMEDIR='$home'
WEB_SYSTEM='nginx'
WEB_SSL='yes'
PROXY_SYSTEM='nginx'
VESTA_CERTIFICATE=''
MAIL_CERTIFICATE=''
UPDATE_HOSTNAME_SSL=''
EOF
    printf '#!/bin/sh\nexit 0\n' > "$vesta/bin/v-restart-web"
    printf '#!/bin/sh\nexit 0\n' > "$vesta/bin/v-restart-proxy"
    chmod +x "$vesta/bin/v-restart-web" "$vesta/bin/v-restart-proxy"

    TEST_LOG="$log" VESTA="$vesta" "$ROOT/bin/v-add-web-domain-ssl" \
        alice "$test_domain" "$certs" same no >/dev/null 2>&1 || {
        fail 'stubbed v-add-web-domain-ssl execution failed'
        return
    }

    assert_file_contains "$log" \
        'render|nginx|vx-proxy.stpl|http://127.0.0.1:8420|X-Business-GUID: EXAMPLE-GUID' \
        'enabled native proxy did not render PROXY.stpl with its persisted values'
    assert_file_contains "$log" \
        'final|http://127.0.0.1:8420|X-Business-GUID: EXAMPLE-GUID' \
        'SSL installation did not preserve proxy target and headers'
    if grep -Fq 'unexpected-proxy-update|' "$log"; then
        fail 'SSL installation rewrote proxy target or header authority'
    fi
}

run_renewal_behavior_test() {
    local fixture="$TEST_TMP/renewal"
    local vesta="$fixture/vesta"
    local log="$fixture/calls.log"
    local cert_dir="$vesta/data/users/alice/ssl"
    local state="$fixture/web.state"

    mkdir -p "$vesta/func" "$vesta/conf" "$vesta/bin" "$cert_dir"
    cat > "$state" <<'EOF'
renew.example.test|yes
future.example.test|yes
disabled.example.test|no
EOF
    cat > "$vesta/func/main.sh" <<'EOF'
search_objects() {
    local state_domain state_letsencrypt
    printf 'search|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$TEST_LOG"
    if [ "$1|$2|$3|$4" = 'web|LETSENCRYPT|yes|DOMAIN' ]; then
        while IFS='|' read -r state_domain state_letsencrypt; do
            [ "$state_letsencrypt" = "$3" ] && printf '%s\n' "$state_domain"
        done < "$TEST_STATE"
    fi
}
get_web_counter() { printf '0\n'; }
alter_web_counter() { printf '1\n'; }
send_email_to_admin() { :; }
EOF
    cat > "$vesta/conf/vesta.conf" <<EOF
BIN='$vesta/bin'
EOF
    cat > "$vesta/bin/v-list-users" <<'EOF'
#!/bin/sh
printf 'alice\n'
EOF
    cat > "$vesta/bin/v-add-letsencrypt-domain" <<'EOF'
#!/bin/sh
printf 'renew|%s|%s|%s\n' "$1" "$2" "$3" >> "$TEST_LOG"
EOF
    chmod +x "$vesta/bin/v-list-users" "$vesta/bin/v-add-letsencrypt-domain"

    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj '/CN=renew.example.test' \
        -addext 'subjectAltName=DNS:renew.example.test,DNS:www.renew.example.test' \
        -keyout "$fixture/renew.key" -out "$cert_dir/renew.example.test.crt" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
        -subj '/CN=future.example.test' \
        -addext 'subjectAltName=DNS:future.example.test' \
        -keyout "$fixture/future.key" -out "$cert_dir/future.example.test.crt" >/dev/null 2>&1

    TEST_LOG="$log" TEST_STATE="$state" VESTA="$vesta" "$ROOT/bin/v-update-letsencrypt-ssl" \
        >/dev/null 2>"$fixture/stderr.log" || {
        fail 'stubbed v-update-letsencrypt-ssl execution failed'
        return
    }

    assert_file_contains "$log" 'search|web|LETSENCRYPT|yes|DOMAIN' \
        'renewal did not select through LETSENCRYPT=yes domain state'
    assert_file_contains "$log" 'renew|alice|renew.example.test|www.renew.example.test' \
        'in-window certificate did not delegate to v-add-letsencrypt-domain'
    if grep -Fq 'renew|alice|future.example.test|' "$log"; then
        fail 'out-of-window certificate was renewed'
    fi
    if grep -Fq 'disabled.example.test' "$log"; then
        fail 'domain outside the LETSENCRYPT=yes selection was renewed'
    fi
}

run_ssl_behavior_test
run_renewal_behavior_test

if [ "$FAILED" -ne 0 ]; then
    exit "$FAILED"
fi

echo 'Web domain proxy tests passed.'
