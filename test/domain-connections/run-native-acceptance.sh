#!/bin/bash
# info: run the separately-authorized native customer-domain live acceptance
# options: --config-file ROOT_ONLY_FILE [--apply]

# This is deliberately an operator harness, not a domain lifecycle command.
# It only contacts the fixed authorized staging host and publicly routable
# ingress declared in a root-owned configuration file.
set -euo pipefail
umask 077

config_file=
apply=no

usage() {
    printf '%s\n' 'Usage: run-native-acceptance.sh --config-file ROOT_ONLY_FILE [--apply]'
}

fail() {
    printf '%s\n' "native acceptance: $1" >&2
    exit 1
}

redacted_fail() {
    # Configuration can contain challenge values.  Do not let tool diagnostics
    # turn those values into CI logs.
    fail 'configuration or live proof is unavailable'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-file) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; config_file=$2; shift 2 ;;
        --apply) apply=yes; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ -n "$config_file" ]] || { usage >&2; exit 2; }
[[ -f "$config_file" && ! -L "$config_file" ]] || redacted_fail
config_owner_mode=$(/usr/bin/stat -c '%u:%a' "$config_file" 2>/dev/null) || redacted_fail
if [[ "$apply" == yes ]]; then
    [[ $EUID -eq 0 && "$config_owner_mode" == 0:600 ]] || \
        fail 'apply requires a root-owned mode-0600 configuration and root operator'
else
    [[ "$config_owner_mode" == "$(id -u):600" ]] || \
        fail 'configuration must be owned by the invoking operator and mode 0600'
fi
command -v jq >/dev/null || fail 'jq is required'
command -v dig >/dev/null || fail 'dig is required'
command -v curl >/dev/null || fail 'curl is required'
command -v ssh >/dev/null || fail 'ssh is required'

jq -e '
  .schema == 1 and
  (.target|type == "object") and
  .target.ssh_host == "192.168.200.100" and
  (.target.public_ingress_ipv4|type == "string") and
  (.connection_target|type == "string" and test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
  (.resolvers|type == "array" and length >= 2) and
  (.sites|type == "array" and length == 2 and ([.[].owner]|unique|length) == 2) and
  all(.sites[];
    (.owner|type == "string" and test("^[A-Za-z][A-Za-z0-9_-]{0,31}$")) and
    (.technical_fqdn|type == "string" and test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
    (.customer_fqdn|type == "string" and test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
    (.www_fqdn|type == "string" and test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
    (.connection_id|type == "string" and test("^[A-Za-z0-9_-]{1,80}$")) and
    (.challenge_path|type == "string" and test("^/.well-known/acme-challenge/[A-Za-z0-9_-]{1,128}$")) and
    (.challenge_sha256|type == "string" and test("^[a-f0-9]{64}$")) and
    (.site_sha256|type == "string" and test("^[a-f0-9]{64}$")) and
    (.technical_sha256|type == "string" and test("^[a-f0-9]{64}$")) and
    (.proxy|type == "object" and (.enabled|type == "boolean") and
      (if .enabled then
        (.hostname|type == "string" and test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")) and
        (.site_sha256|type == "string" and test("^[a-f0-9]{64}$"))
       else true end))
  )
' "$config_file" >/dev/null 2>&1 || redacted_fail

is_public_ipv4() {
    local ip=$1 a b c d
    IFS=. read -r a b c d <<<"$ip"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
    ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
    ((a != 0 && a != 10 && a != 127 && a != 192 && a < 224)) || return 1
    ! ((a == 169 && b == 254)) || return 1
    ! ((a == 172 && b >= 16 && b <= 31)) || return 1
    ! ((a == 100 && b >= 64 && b <= 127)) || return 1
}

ingress=$(jq -r '.target.public_ingress_ipv4' "$config_file")
connection_target=$(jq -r '.connection_target' "$config_file")
is_public_ipv4 "$ingress" || fail 'declared ingress is not publicly routable IPv4'
while IFS= read -r resolver; do
    is_public_ipv4 "$resolver" || fail 'declared resolver is not publicly routable IPv4'
done < <(jq -r '.resolvers[]' "$config_file")

remote() {
    # The target and account are fixed. Commands use sudo's argument boundary;
    # only schema-validated identifiers are ever passed after it.
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes \
        debian@192.168.200.100 sudo -n -- "$@"
}

remote_native_renew() {
    # This static adapter reaches the protected native renewal function.  The
    # owner and hostname are positional arguments after `--`, never shell text.
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes \
        debian@192.168.200.100 "sudo -n -- /bin/bash -s -- $1 $2" <<'SCRIPT'
set -e
VESTA=/usr/local/vesta
BIN=$VESTA/bin
source "$VESTA/func/main.sh"
source "$VESTA/func/vx/domain-connections/main.sh"
vx_domain_connection_native_renew "$1" "$2"
SCRIPT
}

sha256_body() {
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
}

curl_to_ip() {
    local host=$1 port=$2 path=$3 expected_sha=$4 address=$5 output status actual_sha scheme
    [[ $port == 443 ]] && scheme=https || scheme=http
    output=$(/usr/bin/mktemp)
    # --resolve pins the socket to the admitted public ingress while retaining
    # the requested hostname for Host and SNI.  Never use -k here.
    status=$(curl --fail --silent --show-error --connect-timeout 15 --max-time 30 \
        --proto '=http,https' --tlsv1.2 --resolve "$host:$port:$address" \
        --output "$output" --write-out '%{http_code}' \
        "$scheme://$host$path") || {
            /usr/bin/rm -f -- "$output"; return 1;
        }
    actual_sha=$(sha256_body "$output")
    /usr/bin/rm -f -- "$output"
    [[ "$status" == 200 && "$actual_sha" == "$expected_sha" ]]
}

curl_proof() { curl_to_ip "$1" "$2" "$3" "$4" "$ingress"; }

dns_exact() {
    local resolver=$1 host=$2 type=$3 expected=$4 actual
    actual=$(dig +short +time=5 +tries=1 "@$resolver" "$host" "$type" 2>/dev/null | \
        /usr/bin/sed 's/\.$//' | /usr/bin/sort -u)
    [[ "$actual" == "$expected" ]]
}

dns_public_a() {
    local resolver=$1 host=$2 address
    address=$(dig +short +time=5 +tries=1 "@$resolver" "$host" A 2>/dev/null | /usr/bin/sort -u)
    [[ "$address" != *$'\n'* ]] && is_public_ipv4 "$address"
}

report() { printf '%-55s %s\n' "$1" "$2"; }
failed=0
check() {
    local label=$1; shift
    if "$@"; then report "$label" PASS; else report "$label" UNAVAILABLE; failed=1; fi
}

check_registry() {
    local owner=$1 technical=$2 connection=$3 payload
    payload=$(remote /usr/local/vesta/bin/v-list-vx-web-domain-connections "$owner" "$technical" json 2>/dev/null) || return 1
    jq -e --arg id "$connection" '
      any((if type == "array" then . else (.connections // []) end)[]?;
        (.connectionID // .CONNECTION_ID // .connection_id) == $id and
        ((.STATE // .state) == "connected"))
    ' <<<"$payload" >/dev/null 2>&1
}

check_capability() {
    local payload
    payload=$(remote /usr/local/vesta/bin/v-list-vx-web-domain-connection-capability json 2>/dev/null) || return 1
    jq -e --arg target "$connection_target" --arg ingress "$ingress" '
      .version == 1 and
      .capabilities.connectionTarget == $target and
      (.capabilities.ingress.ipv4 | index($ingress) != null) and
      .capabilities.ingress.supportsApex == true
    ' <<<"$payload" >/dev/null 2>&1
}

check_proxy() {
    local owner=$1 technical=$2 customer=$3 proxy_host=$4 expected_sha=$5 resolver address payload
    payload=$(remote /usr/local/vesta/bin/v-list-vx-web-domain-connections "$owner" "$technical" json 2>/dev/null) || return 1
    jq -e --arg domain "$customer" '
      .connections[]? | select(.hostname == $domain) |
      .observations.native.CONFIG_VALID == true
    ' <<<"$payload" >/dev/null 2>&1 || return 1
    resolver=$(jq -r '.resolvers[0]' "$config_file")
    address=$(dig +short +time=5 +tries=1 "@$resolver" "$proxy_host" A 2>/dev/null | /usr/bin/sort -u)
    [[ "$address" != *$'\n'* ]] && is_public_ipv4 "$address" || return 1
    curl_to_ip "$proxy_host" 443 / "$expected_sha" "$address"
}

check 'published native connection capability' check_capability

while IFS=$'\t' read -r owner technical customer www connection challenge_path challenge_sha site_sha technical_sha proxy_enabled; do
    for resolver in $(jq -r '.resolvers[]' "$config_file"); do
        check "DNS CNAME $www via $resolver" dns_exact "$resolver" "$www" CNAME "$connection_target"
        check "DNS apex A $customer via $resolver" dns_exact "$resolver" "$customer" A "$ingress"
    done
    check "registry connected $customer" check_registry "$owner" "$technical" "$connection"
    check "public port 80 challenge $customer" curl_proof "$customer" 80 "$challenge_path" "$challenge_sha"
    check "trusted customer HTTPS/SNI $customer" curl_proof "$customer" 443 / "$site_sha"
    check "trusted customer HTTPS/SNI $www" curl_proof "$www" 443 / "$site_sha"
    check "retained technical HTTPS/SNI $technical" curl_proof "$technical" 443 / "$technical_sha"
    if [[ "$proxy_enabled" == true ]]; then
        proxy_host=$(jq -r --arg d "$customer" '.sites[]|select(.customer_fqdn == $d)|.proxy.hostname' "$config_file")
        proxy_sha=$(jq -r --arg d "$customer" '.sites[]|select(.customer_fqdn == $d)|.proxy.site_sha256' "$config_file")
        check "customer proxy public DNS $proxy_host" dns_public_a "$(jq -r '.resolvers[0]' "$config_file")" "$proxy_host"
        check "configured proxy compatibility $customer" check_proxy "$owner" "$technical" "$customer" "$proxy_host" "$proxy_sha"
    fi
done < <(jq -r '.sites[] | [.owner,.technical_fqdn,.customer_fqdn,.www_fqdn,.connection_id,.challenge_path,.challenge_sha256,.site_sha256,.technical_sha256,.proxy.enabled] | @tsv' "$config_file")

if [[ "$apply" == yes ]]; then
    jq -e '
      .apply.authorized == true and
      (.apply.allowed_mutations == ["certificate_rotation"]) and
      (.apply.disposable_domains|type == "array") and
      ([.sites[] | .customer_fqdn, .www_fqdn] - .apply.disposable_domains | length == 0)
    ' "$config_file" >/dev/null 2>&1 || fail 'apply requires explicit disposable-domain certificate-rotation authorization'
    while IFS=$'\t' read -r owner customer; do
        before=$(remote /usr/bin/openssl x509 -noout -serial -in "/usr/local/vesta/data/users/$owner/ssl/$customer.crt" 2>/dev/null) || { report "controlled certificate rotation $customer" UNAVAILABLE; failed=1; continue; }
        remote_native_renew "$owner" "$customer" >/dev/null 2>&1 || { report "controlled certificate rotation $customer" UNAVAILABLE; failed=1; continue; }
        after=$(remote /usr/bin/openssl x509 -noout -serial -in "/usr/local/vesta/data/users/$owner/ssl/$customer.crt" 2>/dev/null) || { report "controlled certificate rotation $customer" UNAVAILABLE; failed=1; continue; }
        [[ "$before" != "$after" ]] && report "controlled certificate rotation $customer" PASS || { report "controlled certificate rotation $customer" UNAVAILABLE; failed=1; }
    done < <(jq -r '.sites[] | [.owner,.customer_fqdn] | @tsv' "$config_file")
    report 'scheduled renewal' 'NOT PROVEN (controlled rotation is not scheduled renewal)'
else
    report 'controlled certificate rotation' 'NOT RUN (use --apply with protected disposable-domain authorization)'
    report 'scheduled renewal' 'NOT PROVEN (read-only acceptance does not invoke the scheduler)'
fi

[[ $failed -eq 0 ]] || exit 1
