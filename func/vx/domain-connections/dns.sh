#!/usr/bin/env bash

VX_DOMAIN_CONNECTION_DNS_MAX_BYTES=8192
VX_DOMAIN_CONNECTION_DNS_MAX_CHAIN=8

vx_domain_connection_dns_binary() {
    if [[ "${VX_CLOUDFLARE_TEST_MODE:-}" == yes && -x "${VX_DOMAIN_CONNECTION_TEST_DIG:-}" ]]; then printf '%s\n' "$VX_DOMAIN_CONNECTION_TEST_DIG"; else printf '/usr/bin/dig\n'; fi
}
vx_domain_connection_dns_query() {
    local name=$1 type=$2 binary result
    if [[ "$type" == TXT && "$name" == _vx-verify.* ]]; then
        vx_cf_valid_domain "${name#_vx-verify.}" || return 1
    else
        vx_cf_valid_domain "$name" || return 1
    fi
    [[ "$type" =~ ^(A|AAAA|CAA|CNAME|TXT)$ ]] || return 1
    binary=$(vx_domain_connection_dns_binary)
    result=$(/usr/bin/timeout 5 "$binary" +time=2 +tries=1 +short "$name" "$type" 2>/dev/null | /usr/bin/head -c "$VX_DOMAIN_CONNECTION_DNS_MAX_BYTES") || return 1
    [[ ${#result} -lt $VX_DOMAIN_CONNECTION_DNS_MAX_BYTES ]] || return 1
    printf '%s\n' "$result"
}
vx_domain_connection_dns_status() {
    local name=$1 binary result
    vx_cf_valid_domain "$name" || return 1; binary=$(vx_domain_connection_dns_binary)
    result=$(/usr/bin/timeout 5 "$binary" +time=2 +tries=1 +dnssec +comments "$name" A 2>/dev/null | /usr/bin/head -c "$VX_DOMAIN_CONNECTION_DNS_MAX_BYTES") || return 1
    [[ ${#result} -lt $VX_DOMAIN_CONNECTION_DNS_MAX_BYTES && -n "$result" ]] || return 1
    if [[ "$result" =~ status:[[:space:]]*NOERROR ]]; then printf 'ok\n'
    elif [[ "$result" =~ status:[[:space:]]*SERVFAIL ]]; then printf 'servfail\n'
    elif [[ "$result" =~ status:[[:space:]]*(NXDOMAIN|REFUSED) ]]; then printf 'unavailable\n'
    else return 1; fi
}
vx_domain_connection_dns_name() { local n=${1%.}; n=${n,,}; vx_cf_valid_domain "$n" && printf '%s\n' "$n"; }
vx_domain_connection_dns_public_ipv4() {
    /usr/bin/python3 - "$1" <<'PY'
import ipaddress, sys
try: raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)
except ValueError: raise SystemExit(1)
PY
}
vx_domain_connection_dns_global_ipv6() {
    /usr/bin/python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip=ipaddress.ip_address(sys.argv[1])
    raise SystemExit(0 if ip.version == 6 and ip.is_global and ip.ipv4_mapped is None else 1)
except ValueError: raise SystemExit(1)
PY
}
vx_domain_connection_dns_proof_observe() {
    local hostname=$1 token=$2 name answer proof=false
    name="_vx-verify.$hostname"; vx_cf_valid_domain "$hostname" && [[ "$token" =~ ^[A-Za-z0-9._-]{16,256}$ ]] || return 1
    while IFS= read -r answer; do answer=${answer//\"/}; answer=${answer//[[:space:]]/}; [[ "$answer" == "$token" ]] && { proof=true; break; }; done < <(vx_domain_connection_dns_query "$name" TXT 2>/dev/null || :)
    /usr/bin/jq -cn --arg name "$name" --argjson proof "$proof" '{PROOF:$proof,NAME:$name}'
}
vx_domain_connection_dns_caa_ok() {
    local current=$1 answer flags tag value allow=false
    while :; do
        answer=$(vx_domain_connection_dns_query "$current" CAA 2>/dev/null) || return 1
        if [[ -n "$answer" ]]; then
            while read -r flags tag value; do
                [[ "$flags" =~ ^[0-9]+$ && "$tag" =~ ^[A-Za-z0-9-]+$ ]] || return 1
                tag=${tag,,}; value=${value//\"/}
                (( flags & 128 )) && [[ "$tag" != issue && "$tag" != issuewild && "$tag" != iodef ]] && return 1
                [[ "$tag" == issue && "$value" =~ ^letsencrypt\.org([[:space:]]*;.*)?$ ]] && allow=true
            done <<<"$answer"
            [[ "${allow:-false}" == true ]] && return 0
            return 1
        fi
        current=${current#*.}; [[ "$current" == *.* ]] || return 0
        vx_domain_connection_psl_public_suffix "$current" && return 0
    done
}
vx_domain_connection_dns_observe() {
    local hostname=$1 target=$2 config=${3:-} current cname status error='' safe=true routed=false caa=false dnssec=unknown value i
    local -a chain addresses aaaa
    vx_cf_valid_domain "$hostname" && vx_cf_valid_domain "$target" || return 1
    [[ -n "$config" ]] || config=$(vx_domain_connection_target_read_json 2>/dev/null || printf '{}')
    /usr/bin/jq -e '(.IPV4|type=="string") and (.IPV6|type=="string")' >/dev/null <<<"$config" || config='{}'
    status=$(vx_domain_connection_dns_status "$hostname" 2>/dev/null || printf unavailable)
    if [[ "$status" == servfail ]]; then error=servfail; dnssec=bogus
    elif [[ "$status" != ok ]]; then error=resolver_unavailable; fi
    current=$hostname; chain=("$current")
    for ((i=0;i<VX_DOMAIN_CONNECTION_DNS_MAX_CHAIN;i++)); do
        cname=$(vx_domain_connection_dns_query "$current" CNAME 2>/dev/null | /usr/bin/head -n1 || :)
        [[ -z "$cname" ]] && break; cname=$(vx_domain_connection_dns_name "$cname" 2>/dev/null || :)
        [[ -n "$cname" ]] || { error=malformed_cname; break; }
        for value in "${chain[@]}"; do [[ "$value" != "$cname" ]] || { error=cname_loop; break 2; }; done
        chain+=("$cname"); current=$cname
    done
    ((${#chain[@]} <= VX_DOMAIN_CONNECTION_DNS_MAX_CHAIN)) || error=cname_limit
    mapfile -t addresses < <(vx_domain_connection_dns_query "$current" A 2>/dev/null | /usr/bin/sort -u)
    mapfile -t aaaa < <(vx_domain_connection_dns_query "$current" AAAA 2>/dev/null | /usr/bin/sort -u)
    if [[ -z "$error" && ${#addresses[@]} -gt 0 ]]; then
        routed=true
        if ((${#chain[@]} > 1)); then [[ "$current" == "$target" ]] || safe=false
        else [[ "$(vx_domain_connection_psl_registrable_domain "$hostname" 2>/dev/null)" == "$hostname" ]] || safe=false; fi
        for value in "${addresses[@]}"; do [[ -n "$value" ]] || continue; vx_domain_connection_dns_public_ipv4 "$value" && [[ "$value" == "$(/usr/bin/jq -r '.IPV4 // empty' <<<"$config")" ]] || safe=false; done
        for value in "${aaaa[@]}"; do [[ -n "$value" ]] || continue; vx_domain_connection_dns_global_ipv6 "$value" && [[ "$value" == "$(/usr/bin/jq -r '.IPV6 // empty' <<<"$config")" ]] || safe=false; done
    else safe=false; [[ -n "$error" ]] || error=not_routed; fi
    vx_domain_connection_dns_caa_ok "$hostname" && caa=true
    /usr/bin/jq -cn --argjson routed "$routed" --argjson safe "$safe" --argjson caa "$caa" --arg dnssec "$dnssec" --arg error "$error" --argjson chain "$(printf '%s\n' "${chain[@]}"|jq -Rsc 'split("\n")[:-1]')" --argjson addresses "$(printf '%s\n' "${addresses[@]}"|jq -Rsc 'split("\n")|map(select(length>0))')" --argjson aaaa "$(printf '%s\n' "${aaaa[@]}"|jq -Rsc 'split("\n")|map(select(length>0))')" '{PROOF:false,ROUTED:$routed,SAFE:$safe,CAA:$caa,DNSSEC:$dnssec,DNS:{TXT_PROOF:false,CHAIN:$chain,ADDRESSES:$addresses,AAAA:$aaaa,ERROR:(if $error=="" then null else $error end)}}'
}
