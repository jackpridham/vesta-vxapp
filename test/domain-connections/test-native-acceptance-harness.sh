#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
test_root=$(/usr/bin/mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture_sha=$(printf fixture | /usr/bin/sha256sum | /usr/bin/awk '{print $1}')

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$test_root/bin"
cat >"$test_root/bin/dig" <<'EOF'
#!/bin/bash
if [[ ${VX_TEST_FAIL_DNS:-} == 1 ]]; then
    printf 'unavailable.acceptance.example.test.\n'
    exit 0
fi
case "${*: -1}" in CNAME) printf 'connect.acceptance.example.test.\n' ;; A) printf '203.0.113.10\n' ;; esac
EOF
cat >"$test_root/bin/curl" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resolve)
            [[ $2 != s-*.example.test:443:203.0.113.10 ]] || exit 1
            shift 2
            ;;
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf fixture >"$output"
printf 200
EOF
cat >"$test_root/bin/ssh" <<'EOF'
#!/bin/bash
if [[ $* == *'/bin/bash -s --'* ]]; then
    : "${TEST_RENEW_LOG:?}"
    printf 'renew\n' >>"$TEST_RENEW_LOG"
    exit 0
fi
[[ $* == *'env VESTA=/usr/local/vesta'* ]] || exit 1
for arg in "$@"; do
    [[ $arg == -n ]] && break
done
[[ ${arg:-} == -n ]] || cat >/dev/null
case "$*" in
  *capability*) printf '%s\n' '{"version":1,"capabilities":{"connectionTarget":"connect.acceptance.example.test","ingress":{"ipv4":["203.0.113.10"],"ipv6":[],"supportsApex":true}}}' ;;
  *) printf '%s\n' '{"version":1,"connections":[{"connectionID":"one","hostname":"one.example.test","state":"connected","observations":{"native":{"CONFIG_VALID":true}}},{"connectionID":"two","hostname":"two.example.test","state":"connected"}]}' ;;
esac
EOF
chmod +x "$test_root/bin"/*

config="$test_root/config.json"
cat >"$config" <<EOF
{"schema":1,"target":{"ssh_host":"192.168.200.100","public_ingress_ipv4":"203.0.113.10"},"connection_target":"connect.acceptance.example.test","resolvers":["1.1.1.1","8.8.8.8"],"sites":[{"owner":"Jack9f6fa","technical_fqdn":"s-one.example.test","customer_fqdn":"one.example.test","www_fqdn":"www.one.example.test","connection_id":"one","challenge_path":"/.well-known/acme-challenge/one","challenge_sha256":"$fixture_sha","site_sha256":"$fixture_sha","technical_sha256":"$fixture_sha","proxy":{"enabled":true,"hostname":"proxy.one.example.test","site_sha256":"$fixture_sha"}},{"owner":"bob","technical_fqdn":"s-two.example.test","customer_fqdn":"two.example.test","www_fqdn":"www.two.example.test","connection_id":"two","challenge_path":"/.well-known/acme-challenge/two","challenge_sha256":"$fixture_sha","site_sha256":"$fixture_sha","technical_sha256":"$fixture_sha","proxy":{"enabled":false}}]}
EOF
chmod 600 "$config"
output=$(PATH="$test_root/bin:$PATH" "$repo_root/test/domain-connections/run-native-acceptance.sh" --config-file "$config") \
    || fail 'protected read-only fixture did not pass'
printf '%s\n' "$output"
grep -Fq 'registry connected one.example.test                     PASS' <<<"$output" \
    || fail 'first site was not evaluated'
grep -Fq 'registry connected two.example.test                     PASS' <<<"$output" \
    || fail 'second site was not evaluated'
grep -Fq 'trusted customer HTTPS/SNI www.two.example.test         PASS' <<<"$output" \
    || fail 'second site DNS and HTTPS proof was not evaluated'
if PATH="$test_root/bin:$PATH" "$repo_root/test/domain-connections/run-native-acceptance.sh" --config-file "$config" --apply >/dev/null 2>&1; then
    fail 'apply ran without explicit disposable-domain authorization'
fi

failed_apply="$test_root/failed-apply.json"
jq '.apply={authorized:true,allowed_mutations:["certificate_rotation"],disposable_domains:[.sites[] | .customer_fqdn,.www_fqdn]}' "$config" >"$failed_apply"
chmod 600 "$failed_apply"
renew_log="$test_root/renew.log"
: >"$renew_log"
if TEST_RENEW_LOG="$renew_log" VX_TEST_FAIL_DNS=1 PATH="$test_root/bin:$PATH" \
    "$repo_root/test/domain-connections/run-native-acceptance.sh" --config-file "$failed_apply" --apply >/dev/null 2>&1; then
    fail 'apply continued after required read-only precheck failure'
fi
[[ ! -s "$renew_log" ]] || fail 'renewal ran after required read-only precheck failure'

jq '.target.public_ingress_ipv4 = "192.168.1.1"' "$config" >"$test_root/private.json"
chmod 600 "$test_root/private.json"
if PATH="$test_root/bin:$PATH" "$repo_root/test/domain-connections/run-native-acceptance.sh" --config-file "$test_root/private.json" >/dev/null 2>&1; then
    fail 'private ingress was accepted'
fi

jq '.sites[1].owner = .sites[0].owner' "$config" >"$test_root/same-owner.json"
chmod 600 "$test_root/same-owner.json"
if PATH="$test_root/bin:$PATH" "$repo_root/test/domain-connections/run-native-acceptance.sh" --config-file "$test_root/same-owner.json" >/dev/null 2>&1; then
    fail 'duplicate acceptance owners were accepted'
fi

! grep -Eq 'curl.*(-k|--insecure)' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'harness permits insecure TLS'
grep -Fq 'ssh -n -o BatchMode=yes' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'read-only remote checks can consume the site loop input'
! sed -n '/remote_native_renew()/,/^}/p' "$repo_root/test/domain-connections/run-native-acceptance.sh" | grep -Fq 'ssh -n' \
    || fail 'renewal adapter must retain its stdin heredoc'
grep -Fq 'debian@192.168.200.100 sudo -n --' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'harness does not use the authorized sudo SSH boundary'
grep -Fq 'vx_domain_connection_native_renew' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'controlled rotation bypasses protected native renewal'
grep -Fq 'export VESTA=/usr/local/vesta' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'controlled rotation does not export the Vesta runtime'
grep -Fq 'source "$VESTA/conf/vesta.conf"' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'controlled rotation does not load web and proxy runtime configuration'
! grep -Fq 'v-add-letsencrypt-domain' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'controlled rotation calls the raw LetsEncrypt command'
! grep -Fq 'curl_proof "$technical" 443' "$repo_root/test/domain-connections/run-native-acceptance.sh" \
    || fail 'technical HTTPS is pinned to origin ingress'
printf 'PASS: native acceptance harness\n'
