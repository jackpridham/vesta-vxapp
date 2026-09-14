#!/bin/bash
set -u
if [[ $EUID != 0 ]]; then exec sudo -n bash "$0" "$@"; fi

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
work_root=$(/usr/bin/mktemp -d)
vesta_root="$work_root/vesta"
cleanup() { [[ "${VX_DOMAIN_CONNECTION_KEEP_TEST_ROOT:-no}" == yes ]] || /usr/bin/rm -rf -- "$work_root"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3 (expected $2, got $1)"; }

/usr/bin/mkdir -p "$vesta_root/data/vx/cloudflare/runtime"
/usr/bin/ln -s "$repo_root/func" "$vesta_root/func"
VESTA="$vesta_root"
source "$repo_root/func/vx/cloudflare/main.sh"
source "$repo_root/func/vx/domain-connections/target.sh"
vx_cf_prepare_layout || fail 'Cloudflare layout setup failed'
printf "API_TOKEN='fixture_token_12345678901234567890'\nZONE_ID='0123456789abcdef0123456789abcdef'\nACCOUNT_EMAIL='operator@example.test'\nZONE_NAME='managed.example.test'\n" >"$vesta_root/data/vx/cloudflare/config.conf"
/usr/bin/chmod 0600 "$vesta_root/data/vx/cloudflare/config.conf"
state_root="$work_root/records"; /usr/bin/mkdir -p "$state_root"
transport_log="$work_root/transport.log"

# The Cloudflare managed-domain suite exercises the real protected curl
# transport. This focused fake keeps the exact target-record protocol visible.
vx_cf_transport() {
    local method=$1 path=$2 output=$3 body=${4:-} type='' name='' address='' id='' comment='' record
    printf '%s %s\n' "$method" "$path" >>"$transport_log"
    if [[ -n "$body" ]]; then
        comment=$(/usr/bin/jq -r '.comment // empty' "$body"); type=$(/usr/bin/jq -r .type "$body"); name=$(/usr/bin/jq -r .name "$body"); address=$(/usr/bin/jq -r .content "$body")
        [[ "$(/usr/bin/jq -r .proxied "$body")" == false ]] || return 91
    fi
    case "$method:$path" in
        GET:dns_records\?*)
            name=${path#*name=}; name=${name%%&*}; type=''
            [[ "$path" != *type=* ]] || { type=${path#*type=}; type=${type%%&*}; }
            local items='[]' item record_type
            for record in "$state_root"/*; do
                [[ -f "$record" ]] || continue
                record_type=${record##*/}
                [[ -z "$type" || "$record_type" == "$type" ]] || continue
                [[ "$(sed -n 's/^name=//p' "$record")" == "$name" ]] || continue
                item=$(jq -cn --arg id "$(sed -n 's/^id=//p' "$record")" --arg type "$record_type" --arg name "$name" --arg address "$(sed -n 's/^address=//p' "$record")" --arg comment "$(sed -n 's/^comment=//p' "$record")" '{id:$id,type:$type,name:$name,content:$address,ttl:1,proxied:false,comment:$comment}')
                items=$(jq -cn --argjson items "$items" --argjson item "$item" '$items+[$item]')
            done
            jq -cn --argjson items "$items" '{success:true,result:$items}' >"$output"
            return 0 ;;
        GET:dns_records/*)
            id=${path#dns_records/}
            for record in "$state_root"/*; do
                [[ -f "$record" && "$(/usr/bin/sed -n 's/^id=//p' "$record")" == "$id" ]] || continue
                type=${record##*/}; name=$(/usr/bin/sed -n 's/^name=//p' "$record"); address=$(/usr/bin/sed -n 's/^address=//p' "$record")
                /usr/bin/jq -n --arg id "$id" --arg type "$type" --arg name "$name" --arg address "$address" '{success:true,result:{id:$id,type:$type,name:$name,content:$address,ttl:1,proxied:false}}' >"$output"; return 0
            done
            printf '{"success":false,"errors":[]}' >"$output"; return 0 ;;
        POST:dns_records|PUT:dns_records/*) ;;
        *) return 92 ;;
    esac
    [[ "$method" == POST ]] && id=$( [[ "$type" == A ]] && printf aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ) || id=${path#dns_records/}
    printf 'id=%s\nname=%s\naddress=%s\ncomment=%s\n' "$id" "$name" "$address" "$comment" >"$state_root/$type"
    /usr/bin/jq -n --arg id "$id" --arg type "$type" --arg name "$name" --arg address "$address" '{success:true,result:{id:$id,type:$type,name:$name,content:$address,ttl:1,proxied:false}}' >"$output"
    [[ "${VX_TEST_CRASH_AFTER_MUTATION:-no}" != yes ]] || exit 99
    [[ "${VX_TEST_LOST_RESPONSE:-no}" != yes ]] || return 28
}

input="$work_root/target.input"
write_input() { printf "TARGET_FQDN='connect.managed.example.test'\nIPV4='%s'\nIPV6='%s'\nIPV6_ACCEPTED='%s'\nCOORDINATED_INGRESS_CHANGE='%s'\n" "$1" "$2" "$3" "$4" >"$input"; /usr/bin/chmod 0600 "$input"; }
write_input 192.0.2.20 '' no no
vx_domain_connection_target_configure_from_file "$input" || fail "initial target configure failed: ${VX_DOMAIN_CONNECTION_TARGET_STATUS:-}"
capability=$(vx_domain_connection_target_read_json) || fail 'capability read failed'
assert_eq "$capability" '{"TARGET_FQDN":"connect.managed.example.test","IPV4":"192.0.2.20","IPV6":"","INGRESS_FAMILIES":["IPv4"]}' 'capability is unstable'
/usr/bin/grep -q '^POST dns_records$' "$transport_log" || fail 'target record was not created'

write_input 192.0.2.21 '' no no
VX_TEST_LOST_RESPONSE=yes vx_domain_connection_target_configure_from_file "$input" || fail 'lost PUT response was not reconciled by exact readback'
assert_eq "$(/usr/bin/sed -n 's/^address=//p' "$state_root/A")" 192.0.2.21 'target did not converge after lost response'

/usr/bin/mkdir -p "$vesta_root/data/vx/domain-connections/hostnames"
printf '{}' >"$vesta_root/data/vx/domain-connections/hostnames/claimed.json"
/usr/bin/chmod 0700 "$vesta_root/data/vx/domain-connections/hostnames"; /usr/bin/chmod 0600 "$vesta_root/data/vx/domain-connections/hostnames/claimed.json"
write_input 192.0.2.22 '' no no
if vx_domain_connection_target_configure_from_file "$input"; then fail 'ingress changed with connections without coordination'; fi
assert_eq "$VX_DOMAIN_CONNECTION_TARGET_STATUS" connections_require_coordination 'ingress guard is unstable'

write_input 192.0.2.21 2001:db8::20 yes yes
vx_domain_connection_target_configure_from_file "$input" || fail 'accepted IPv6 target did not configure'
capability=$(vx_domain_connection_target_read_json) || fail 'IPv6 capability read failed'
[[ "$capability" == *'"INGRESS_FAMILIES":["IPv4","IPv6"]'* ]] || fail 'IPv6 capability not exposed after acceptance'

dig_stub="$work_root/dig"; printf '#!/bin/bash\nprintf "connect.managed.example.test.\\n"\n' >"$dig_stub"; /usr/bin/chmod 0700 "$dig_stub"
observation=$(VX_CLOUDFLARE_TEST_MODE=yes VX_DOMAIN_CONNECTION_TEST_DIG="$dig_stub" vx_domain_connection_target_dns_observe customer.example.test connect.managed.example.test) || fail 'DNS observation failed'
assert_eq "$observation" '{"HOSTNAME":"customer.example.test","TARGET_FQDN":"connect.managed.example.test","CNAME":"connect.managed.example.test","MATCHES":true}' 'DNS observation is not exact'
printf 'ok\n'

# Simulate a process exit after provider POST, before any config write. The
# next process must use the protected intent plus exact provider comment.
rm -f "$vesta_root/data/vx/domain-connections/target.conf" "$state_root/A" "$state_root/AAAA"
write_input 192.0.2.30 '' no yes
( VX_TEST_CRASH_AFTER_MUTATION=yes vx_domain_connection_target_configure_from_file "$input" ) && fail 'simulated provider crash did not exit'
[[ -f "$vesta_root/data/vx/domain-connections/target-operation.json" && ! -e "$vesta_root/data/vx/domain-connections/target.conf" ]] || fail 'durable pre-POST intent missing'
vx_cf_assert_zone_rotation_safe ffffffffffffffffffffffffffffffff && fail 'pending target allowed zone rotation'
assert_eq "$VX_CF_STATUS" managed_zone_in_use 'pending target zone guard status'
vx_domain_connection_target_configure_from_file "$input" || fail 'restart lost-response recovery failed'
[[ ! -e "$vesta_root/data/vx/domain-connections/target-operation.json" ]] || fail 'accepted target retained operation'
vx_cf_assert_zone_rotation_safe ffffffffffffffffffffffffffffffff && fail 'target-only authority allowed zone rotation'
vx_cf_assert_zone_rotation_safe 0123456789abcdef0123456789abcdef || fail 'same target zone rejected'

# Retain accepted config until both families complete, including process loss
# after A was updated. Different requested changes cannot erase that intent.
accepted=$(sha256sum "$vesta_root/data/vx/domain-connections/target.conf")
write_input 192.0.2.31 2001:db8::31 yes yes
( VX_TEST_CRASH_AFTER_MUTATION=yes vx_domain_connection_target_configure_from_file "$input" ) && fail 'partial-family crash did not exit'
[[ $(sha256sum "$vesta_root/data/vx/domain-connections/target.conf") == "$accepted" ]] || fail 'partial mutation replaced accepted config'
write_input 192.0.2.32 2001:db8::31 yes yes
vx_domain_connection_target_configure_from_file "$input" && fail 'different request replaced interrupted intent'
assert_eq "$VX_DOMAIN_CONNECTION_TARGET_STATUS" target_recovery_required 'pending target request mismatch'
write_input 192.0.2.31 2001:db8::31 yes yes
vx_domain_connection_target_configure_from_file "$input" || fail 'partial-family recovery failed'

# A provider record without this operation's marker is never adopted, even
# when its DNS payload equals the interrupted desired payload.
rm -f "$vesta_root/data/vx/domain-connections/target.conf" "$state_root/A" "$state_root/AAAA"
write_input 192.0.2.40 '' no yes
( VX_TEST_CRASH_AFTER_MUTATION=yes vx_domain_connection_target_configure_from_file "$input" ) && fail 'unrelated fixture crash did not exit'
sed -i 's/^comment=.*/comment=unrelated/' "$state_root/A"
vx_domain_connection_target_configure_from_file "$input" && fail 'unrelated provider record adopted'
assert_eq "$VX_DOMAIN_CONNECTION_TARGET_STATUS" ownership_mismatch 'unrelated record rejection'
printf '%s\n' 'target restart recovery, partial-family preservation, and zone guards passed'
