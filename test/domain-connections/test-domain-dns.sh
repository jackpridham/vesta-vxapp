#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd); tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
export VESTA="$tmp/vesta" VX_CLOUDFLARE_TEST_MODE=yes; mkdir -p "$VESTA/func"; ln -s "$root/func/vx" "$VESTA/func/vx"
fixture="$tmp/dig"; export VX_DOMAIN_CONNECTION_TEST_DIG="$fixture"
cat >"$fixture" <<'EOF'
#!/bin/bash
n="${@: -2:1}"; t="${@: -1}"
case "$*" in
    *+comments*) [[ "$n" == servfail.example.com ]] && echo 'status: SERVFAIL' || echo 'status: NOERROR'; exit ;;
esac
case "$n:$t" in
    _vx-verify.valid.example.com:TXT) echo '"proof-token-1234567890"' ;;
    www.valid.example.com:CNAME|www.valid.example.com:CAA) echo edge.valid.example.com. ;;
    edge.valid.example.com:CNAME|edge.valid.example.com:CAA|private.example.com:CNAME|private.example.com:CAA|servfail.example.com:CNAME|servfail.example.com:CAA) echo connect.example.com. ;;
    www.nocaa.example.com:CNAME|www.nocaa.example.com:CAA) echo target.nocaa.example.com. ;;
    www.denied.example.com:CNAME|www.denied.example.com:CAA) echo target.denied.example.com. ;;
    www.alias-policy.example.com:CNAME|www.alias-policy.example.com:CAA) echo target.alias-target.example.net. ;;
    connect.example.com:A|apex.com.au:A|target.nocaa.example.com:A|target.denied.example.com:A|iodef.example.com:A|malformed.example.com:A) echo 8.8.8.8 ;;
    bad.example.com:CNAME) echo loop.example.com. ;;
    loop.example.com:CNAME) echo bad.example.com. ;;
    caa.example.com:CAA) echo '128 unknown "x"' ;;
    iodef.example.com:CAA) echo '0 iodef "mailto:security@example.com"' ;;
    malformed.example.com:CAA) echo '0 issue letsencrypt.org' ;;
    target.denied.example.com:CAA) echo '0 issue "other-ca.invalid"' ;;
    alias-policy.example.com:CAA) echo '0 issue "letsencrypt.org"' ;;
    alias-target.example.net:CAA) echo '0 issue "other-ca.invalid"' ;;
    target.nocaa.example.com:CAA|nocaa.example.com:CAA|example.com:CAA) ;;
    *:CAA) echo '0 issue "letsencrypt.org"' ;;
esac
EOF
chmod 0700 "$fixture"
source "$root/func/vx/cloudflare/main.sh"; source "$root/func/vx/domain-connections/state.sh"; source "$root/func/vx/domain-connections/dns.sh"
config='{"IPV4":"8.8.8.8","IPV6":""}'
! vx_domain_connection_dns_public_ipv4 192.0.2.1
! vx_domain_connection_dns_public_ipv4 10.0.0.1
! vx_domain_connection_dns_global_ipv6 ::ffff:10.0.0.1
jq -e '.PROOF' <<<"$(vx_domain_connection_dns_proof_observe valid.example.com proof-token-1234567890)" >/dev/null
jq -e '.ROUTED and .SAFE and .CAA' <<<"$(vx_domain_connection_dns_observe www.valid.example.com connect.example.com "$config")" >/dev/null
jq -e '.ROUTED and .SAFE and .CAA' <<<"$(vx_domain_connection_dns_observe apex.com.au connect.example.com "$config")" >/dev/null
jq -e '.ROUTED and .SAFE and .CAA' <<<"$(vx_domain_connection_dns_observe www.nocaa.example.com connect.example.com "$config")" >/dev/null
jq -e '.CAA==false' <<<"$(vx_domain_connection_dns_observe www.denied.example.com connect.example.com "$config")" >/dev/null
jq -e '. == true' <<<"$(vx_domain_connection_dns_caa_ok www.alias-policy.example.com && echo true || echo false)" >/dev/null
jq -e '.ROUTED and .SAFE and .CAA' <<<"$(vx_domain_connection_dns_observe iodef.example.com connect.example.com "$config")" >/dev/null
jq -e '.CAA==false' <<<"$(vx_domain_connection_dns_observe malformed.example.com connect.example.com "$config")" >/dev/null
jq -e '.ROUTED==false and .DNS.ERROR=="cname_loop"' <<<"$(vx_domain_connection_dns_observe bad.example.com connect.example.com "$config")" >/dev/null
jq -e '.CAA==false' <<<"$(vx_domain_connection_dns_observe caa.example.com connect.example.com "$config")" >/dev/null
jq -e '.DNSSEC=="bogus" and .CAA==false' <<<"$(vx_domain_connection_dns_observe servfail.example.com connect.example.com "$config")" >/dev/null
echo 'domain DNS tests passed'
