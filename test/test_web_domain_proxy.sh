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

assert_file_matches() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    grep -Eq -- "$pattern" "$file" || fail "$message"
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
assert_target_valid 'https://backend.example.test/app'
assert_target_invalid 'ftp://backend.example.test'
assert_target_invalid 'http://backend.example.test/a path'
assert_target_invalid 'http://backend.example.test/;return'
assert_target_invalid ''

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
PROXY_MODE='proxy'
PROXY_TARGET='http://127.0.0.1:8420'
PROXY_PRESERVE_HOST='yes'
vx_proxy_prepare_template_values
assert_contains "$VX_PROXY_LOCATION_BLOCK" 'location / {' 'native proxy is not an ordinary catch-all prefix location'
[[ "$VX_PROXY_LOCATION_BLOCK" != *'location ^~ /'* ]] || fail 'native proxy would suppress the ACME regex location'

# SSL installation must reload the owned domain record, render the native
# proxy SSL template, and leave proxy authority untouched.
SSL_COMMAND="$ROOT/bin/v-add-web-domain-ssl"
assert_file_contains "$SSL_COMMAND" "get_domain_values 'web'" 'SSL command does not load domain proxy state'
assert_file_contains "$SSL_COMMAND" 'add_web_config "$PROXY_SYSTEM" "$PROXY.stpl"' 'SSL command does not render the enabled proxy SSL template'
if grep -Eq 'vx_proxy_clear_web_conf|update_object_value.*PROXY_(TARGET|HEADERS)' "$SSL_COMMAND"; then
    fail 'SSL command clears or rewrites native proxy target/header authority'
fi

# Renewal eligibility remains state- and window-bound and renewal delegates to
# the standard issuance command.
RENEW_COMMAND="$ROOT/bin/v-update-letsencrypt-ssl"
assert_file_contains "$RENEW_COMMAND" "search_objects 'web' 'LETSENCRYPT' 'yes' 'DOMAIN'" 'renewal does not select letsencrypt-enabled domains'
assert_file_matches "$RENEW_COMMAND" 'if \[\[ "\$days_valid" -lt 31 \]\]; then' 'renewal window is not constrained to certificates below 31 days'
assert_file_contains "$RENEW_COMMAND" 'v-add-letsencrypt-domain $user $domain $aliases' 'renewal does not delegate to v-add-letsencrypt-domain'

if [ "$FAILED" -ne 0 ]; then
    exit "$FAILED"
fi

echo 'Web domain proxy tests passed.'
