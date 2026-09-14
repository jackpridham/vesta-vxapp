#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID != 0 ]]; then exec sudo -n bash "$0" "$@"; fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
export VESTA="$tmp/vesta"; mkdir -p "$VESTA/data/users/alice" "$VESTA/bin"
ln -s "$root/func" "$VESTA/func"
printf "DOMAIN='technical.example.net' PROXY='vx-proxy' PROXY_MODE='proxy' PROXY_TARGET='http://127.0.0.1:3000' LETSENCRYPT='no' SSL='yes' SUSPENDED='no'\n" >"$VESTA/data/users/alice/web.conf"; printf "WEB_DOMAINS='unlimited'\n" >"$VESTA/data/users/alice/user.conf"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$VESTA/bin/v-add-letsencrypt-domain"; chmod 0700 "$VESTA/bin/v-add-letsencrypt-domain"
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=func/vx/domain-connections/main.sh
source "$root/func/vx/domain-connections/main.sh"
vx_domain_connection_prepare
chmod 0700 "$(vx_domain_connection_root)" "$(vx_domain_connection_hostname_root)"
/usr/bin/jq '.ENROLLMENT="enabled"|.CONNECTION_LIMIT=2' "$(vx_domain_connection_root)/config.json" >"$tmp/config"; mv "$tmp/config" "$(vx_domain_connection_root)/config.json"; chmod 0600 "$(vx_domain_connection_root)/config.json"
vx_domain_connection_dns_proof_observe() { printf '%s\n' '{"PROOF":true}'; }
vx_domain_connection_target_read_json() { printf '%s\n' '{"TARGET_FQDN":"connect.example.net","IPV4":"203.0.113.9","IPV6":"","INGRESS_FAMILIES":["IPv4"]}'; }
vx_domain_connection_dns_observe() { printf '%s\n' '{"ROUTED":true,"SAFE":true,"CAA":true,"DNSSEC":"secure"}'; }
vx_cf_native_web_authority_preflight() { VX_CF_WEB_AUTHORITY_STATE=managed; }
vx_domain_connection_native_create() { return 0; }
vx_domain_connection_native_issue() { return 0; }
vx_domain_connection_native_observe() { printf '%s\n' '{"NATIVE_CHILD_PRESENT":true,"TLS_STATE":"accepted","HTTPS_IDENTITY":true,"CONFIG_VALID":true}'; }
vx_domain_connection_native_cleanup() { return 0; }
record="$(vx_domain_connection_create alice technical.example.net shop.example.com request-0001)"
id="$(jq -r .CONNECTION_ID <<<"$record")"
[[ "$(jq -r .STATE <<<"$record")" == pending_verification ]] || fail create
vx_domain_connection_public_json "$record" | jq -e '.connection.instructions | any(.recordType == "CNAME" and .value == "connect.example.net")' >/dev/null || fail scalar_target_projection
vx_domain_connection_capability_json | jq -e '.capabilities.ingress.ipv4 == ["203.0.113.9"]' >/dev/null || fail scalar_capability_projection
[[ "$(vx_domain_connection_create alice technical.example.net shop.example.com request-0001 | jq -r .CONNECTION_ID)" == "$id" ]] || fail idempotency
if vx_domain_connection_create bob technical.example.net shop.example.com request-0002 >/dev/null 2>&1; then fail collision; fi
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
[[ "$(vx_domain_connection_find_id alice technical.example.net "$id" | jq -r .STATE)" == connected ]] || fail transitions
vx_domain_connection_disconnect alice technical.example.net "$id" >/dev/null
[[ "$(vx_domain_connection_disconnect alice technical.example.net "$id" | jq -r .GENERATION)" == 2 ]] || fail disconnect_idempotency
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
[[ "$(vx_domain_connection_find_id alice technical.example.net "$id" | jq -r .STATE)" == disconnected ]] || fail cleanup
if vx_domain_connection_worker_update shop.example.com 1 connected stale '{}' true; then fail stale_generation; fi
expired="$(vx_domain_connection_create alice technical.example.net expired.example.com request-0005)"
expired_id="$(jq -r .CONNECTION_ID <<<"$expired")"; expired_path="$(vx_domain_connection_record_path expired.example.com)"
jq '.PROOF_EXPIRES_AT="2000-01-01T00:00:00Z"' "$expired_path" >"$tmp/expired"; mv "$tmp/expired" "$expired_path"; chmod 0600 "$expired_path"
vx_domain_connection_reconcile alice technical.example.net "$expired_id" >/dev/null
[[ "$(vx_domain_connection_find_id alice technical.example.net "$expired_id" | jq -r .STATE)" == failed ]] || fail proof_expiry
if vx_domain_connection_create alice technical.example.net com.au request-0003 >/dev/null 2>&1; then fail psl; fi
if vx_domain_connection_create alice technical.example.net 127.0.0.1 request-0004 >/dev/null 2>&1; then fail ip; fi
path="$(vx_domain_connection_record_path shop.example.com)"; [[ "$(stat -c %a "$path")" == 600 ]] || fail permissions
echo 'domain connection state tests passed'

# Use the real namespace/parent/quota helpers with only DNS, managed Cloudflare
# evidence, and external native operations isolated from the fixture host.
reset_case() {
    rm -f "$(vx_domain_connection_hostname_root)"/*.json
    printf '%s\n' '{"VERSION":1,"ENROLLMENT":"enabled","CONNECTION_LIMIT":0}' >"$(vx_domain_connection_root)/config.json"
    printf "WEB_DOMAINS='unlimited'\n" >"$VESTA/data/users/alice/user.conf"
}
# Shared provider zone membership is not ownership of every customer name.
# Reserve the exact infrastructure target, existing native names and the
# generated technical namespace while permitting ordinary same-zone claims.
(
    reset_case
    VX_CF_ZONE_NAME=example.net
    vx_domain_connection_create alice technical.example.net dc-a-20260915.example.net request-same-zone >/dev/null || fail same_zone_customer
    if vx_domain_connection_create alice technical.example.net connect.example.net request-target >/dev/null 2>&1; then fail infrastructure_target_claim; fi
    if vx_domain_connection_create alice technical.example.net technical.example.net request-technical >/dev/null 2>&1; then fail existing_technical_claim; fi
    if vx_domain_connection_create alice technical.example.net s-0123456789.example.net request-reserved >/dev/null 2>&1; then fail generated_technical_namespace; fi
)
mkdir -p "$VESTA/data/users/bob"
cp "$VESTA/data/users/alice/"{web,user}.conf "$VESTA/data/users/bob/"
reset_case
vx_domain_connection_create alice technical.example.net race.example.com concurrent-a >"$tmp/race-a" 2>/dev/null & a=$!
vx_domain_connection_create bob technical.example.net race.example.com concurrent-b >"$tmp/race-b" 2>/dev/null & b=$!
a_rc=0; b_rc=0; wait "$a" || a_rc=$?; wait "$b" || b_rc=$?
[[ $((a_rc+b_rc)) == 10 ]] || fail concurrent_claim
[[ $(vx_domain_connection_records | jq -s length) == 1 ]] || fail unique_namespace

reset_case
printf "WEB_DOMAINS='2'\n" >"$VESTA/data/users/alice/user.conf"
vx_domain_connection_create alice technical.example.net quota-a.example.com request-quota-a >"$tmp/quota-a" 2>/dev/null & a=$!
vx_domain_connection_create alice technical.example.net quota-b.example.com request-quota-b >"$tmp/quota-b" 2>/dev/null & b=$!
a_rc=0; b_rc=0; wait "$a" || a_rc=$?; wait "$b" || b_rc=$?
[[ $((a_rc+b_rc)) == 11 ]] || fail concurrent_quota
vx_domain_connection_quota_json alice | jq -e '.used==2 and .available==0' >/dev/null || fail pending_quota
hostname=$(vx_domain_connection_records | jq -r .HOSTNAME)
printf "DOMAIN='%s' VX_CONNECTION_ID='fixture'\n" "$hostname" >>"$VESTA/data/users/alice/web.conf"
vx_domain_connection_quota_json alice | jq -e '.used==2 and .available==0' >/dev/null || fail native_double_count
sed -i '$d' "$VESTA/data/users/alice/web.conf"

reset_case
printf "DOMAIN='legacy.example.org' ALIAS='www.legacy.example.org,shop.legacy.example.org'\n" >>"$VESTA/data/users/bob/web.conf"
if vx_domain_connection_create alice technical.example.net shop.legacy.example.org request-legacy >/dev/null 2>&1; then fail legacy_alias_collision; fi
if vx_domain_connection_create alice nonexistent.example.net unknown.example.com request-parent >/dev/null 2>&1; then fail missing_parent; fi
record=$(vx_domain_connection_create alice technical.example.net fresh.example.com request-fresh)
id=$(jq -r .CONNECTION_ID <<<"$record"); path=$(vx_domain_connection_record_path fresh.example.com)
record=$(jq '.PROOF_EXPIRES_AT="2000-01-01T00:00:00Z"' <<<"$record"); vx_domain_connection_record_write fresh.example.com "$record"
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
vx_domain_connection_quota_json alice | jq -e '.used==1' >/dev/null || fail expired_quota_release
new=$(vx_domain_connection_create bob technical.example.net fresh.example.com request-reclaimed)
jq -e --arg old "$id" '.GENERATION==2 and .CONNECTION_ID!=$old and .OWNER=="bob"' >/dev/null <<<"$new" || fail safe_reclaim
if vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null 2>&1; then fail stale_id_reconcile; fi

before=$(find "$(vx_domain_connection_root)" -type f -printf '%p %m %T@\n' -exec sha256sum {} \; | sort)
vx_domain_connection_list bob technical.example.net >/dev/null
vx_domain_connection_public_json "$new" >/dev/null
vx_domain_connection_capability_json >/dev/null
vx_domain_connection_worker_health_json >/dev/null
after=$(find "$(vx_domain_connection_root)" -type f -printf '%p %m %T@\n' -exec sha256sum {} \; | sort)
[[ $before == "$after" ]] || fail readonly_status
vx_domain_connection_public_json "$(jq '.HOSTNAME="example.com"' <<<"$new")" | jq -e '.connection.instructions|any(.recordType=="A" and .name=="@")' >/dev/null || fail apex_instruction
ln "$path" "$tmp/hardlink"
if vx_domain_connection_record_read fresh.example.com >/dev/null 2>&1; then fail hardlink_read; fi
if vx_domain_connection_record_write fresh.example.com "$new" >/dev/null 2>&1; then fail hardlink_write; fi
rm "$tmp/hardlink"
mv "$path" "$tmp/record.saved"; ln -s "$tmp/record.saved" "$path"
if vx_domain_connection_list bob technical.example.net >/dev/null 2>&1; then fail symlink_list; fi
rm "$path"; mv "$tmp/record.saved" "$path"
chmod 0644 "$path"
if vx_domain_connection_record_read fresh.example.com >/dev/null 2>&1; then fail wrong_file_mode; fi
chmod 0600 "$path"
mv "$VESTA/data/vx" "$VESTA/data/vx.saved"; ln -s "$VESTA/data/vx.saved" "$VESTA/data/vx"
if vx_domain_connection_prepare >/dev/null 2>&1; then fail symlink_ancestor; fi
rm "$VESTA/data/vx"; mv "$VESTA/data/vx.saved" "$VESTA/data/vx"

reset_case
record=$(vx_domain_connection_create alice technical.example.net health.example.com request-health); id=$(jq -r .CONNECTION_ID <<<"$record")
record=$(jq '.STATE="connected" | .INITIAL_TLS_ACCEPTED=true | .CLEANUP.NATIVE_CHILD=true' <<<"$record"); vx_domain_connection_record_write health.example.com "$record"
vx_domain_connection_dns_observe() { printf '%s\n' '{"ROUTED":false,"SAFE":true,"MATCHES":true,"CAA":true}'; }
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="degraded"' >/dev/null || fail connected_dns_degrades
record=$(vx_domain_connection_record_read health.example.com | jq '.STATE="pending_dns"'); vx_domain_connection_record_write health.example.com "$record"
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="pending_dns"' >/dev/null || fail matches_bypass
vx_domain_connection_dns_observe() { printf '%s\n' '{"ROUTED":true,"SAFE":true,"CAA":true,"DNSSEC":"secure"}'; }
vx_domain_connection_native_issue() { echo issue >>"$tmp/issue.log"; return 0; }
record=$(vx_domain_connection_record_read health.example.com | jq '.STATE="pending_tls" | .OPERATION={KIND:"issue",GENERATION:.GENERATION}'); vx_domain_connection_record_write health.example.com "$record"
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="connected"' >/dev/null || fail lost_issue_response
[[ ! -e "$tmp/issue.log" ]] || fail repeated_accepted_issue
vx_domain_connection_disconnect alice technical.example.net "$id" >/dev/null
vx_domain_connection_native_cleanup() {
    [[ -n ${VX_DOMAIN_CONNECTION_OWNER_LOCK_FD:-} && -n ${VX_DOMAIN_CONNECTION_LOCK_FD:-} ]] || fail worker_locks
    jq -e '.OPERATION.KIND=="cleanup" and .CLEANUP.NATIVE_GENERATION==1' "$1" >/dev/null || fail cleanup_intent
    [[ -f "$tmp/allow-cleanup" ]]
}
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="recovery_required"' >/dev/null || fail cleanup_failure_retained
vx_domain_connection_disconnect alice technical.example.net "$id" | jq -e '.GENERATION==2 and .CLEANUP.NATIVE_GENERATION==1' >/dev/null || fail retry_delete_generation
touch "$tmp/allow-cleanup"
printf '%s\n' '{"VERSION":1,"ENROLLMENT":"disabled","CONNECTION_LIMIT":0}' >"$(vx_domain_connection_root)/config.json"
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="disconnected"' >/dev/null || fail cleanup_with_enrollment_disabled
vx_domain_connection_disconnect alice technical.example.net "$id" | jq -e '.GENERATION==2' >/dev/null || fail completed_delete_idempotent

reset_case
record=$(vx_domain_connection_create alice technical.example.net batch.example.com request-batch)
for i in {1..23}; do
    hostname="batch$i.example.com"
    vx_domain_connection_record_write "$hostname" "$(jq --arg hostname "$hostname" '.HOSTNAME=$hostname' <<<"$record")"
done
vx_domain_connection_worker_run() { echo "$1" >>"$tmp/batch.log"; }
vx_domain_connection_update_all
[[ $(wc -l <"$tmp/batch.log") == 20 ]] || fail bounded_batch
vx_domain_connection_worker_health_json | jq -e '.processed==20 and .lastCompletedAt!=null' >/dev/null || fail worker_health
printf '%s\n' 'domain connection concurrency, authority, quota, recovery, and bounded worker tests passed'

# Exercise the shipped read adapters, rather than duplicating their JSON.
mkdir -p "$VESTA/conf" "$VESTA/log"
printf '%s\n' "WEB_SYSTEM='nginx'" >"$VESTA/conf/vesta.conf"
cp "$root/bin/v-list-vx-web-domain-connections" "$root/bin/v-list-vx-web-domain-connection-capability" "$VESTA/bin/"
"$VESTA/bin/v-list-vx-web-domain-connections" alice technical.example.net json | jq -e '.version==1 and (.connections|length)==24 and .quota.used==25 and (.connections[0].proof.recordValue|length)>0' >/dev/null || fail public_list_adapter
"$VESTA/bin/v-list-vx-web-domain-connection-capability" json | jq -e '.version==1 and .capabilities.enrollmentEnabled==true and .capabilities.ingress.ipv4==[]' >/dev/null || fail default_target_capability
printf '%s\n' 'public cached adapters passed'

reset_case
record=$(vx_domain_connection_create alice technical.example.net resume.example.com request-resume)
id=$(jq -r .CONNECTION_ID <<<"$record")
record=$(jq '.STATE="pending_tls"' <<<"$record"); vx_domain_connection_record_write resume.example.com "$record"
vx_domain_connection_native_observe() {
    local tls=missing present=false identity=false
    [[ ! -e "$tmp/native-created" ]] || present=true
    [[ ! -e "$tmp/native-issued" ]] || tls=issued
    [[ ! -e "$tmp/native-activated" ]] || { tls=accepted; identity=true; }
    jq -cn --arg tls "$tls" --argjson present "$present" --argjson identity "$identity" '{NATIVE_CHILD_PRESENT:$present,TLS_STATE:$tls,HTTPS_IDENTITY:$identity,CONFIG_VALID:$identity}'
}
vx_domain_connection_native_create() {
    vx_domain_connection_native_context "$1" || fail real_native_context
    jq -e '.OPERATION.KIND=="create" and .CLEANUP.NATIVE_CHILD==true' "$1" >/dev/null || fail create_durable_intent
    echo create >>"$tmp/native-calls"; touch "$tmp/native-created"; return 1
}
vx_domain_connection_native_issue() {
    vx_domain_connection_native_context "$1" || fail initial_issue_context
    jq -e '.OPERATION.KIND=="issue"' "$1" >/dev/null || fail issue_durable_intent
    echo issue >>"$tmp/native-calls"; touch "$tmp/native-issued"; return 1
}
vx_domain_connection_native_activate() {
    vx_domain_connection_native_context "$1" || fail activate_context
    jq -e '.OPERATION.KIND=="activate"' "$1" >/dev/null || fail activate_durable_intent
    echo activate >>"$tmp/native-calls"; touch "$tmp/native-activated"
}
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="recovery_required"' >/dev/null || fail lost_create_response_retained
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="pending_tls"' >/dev/null || fail lost_issue_response_retained
vx_domain_connection_reconcile alice technical.example.net "$id" | jq -e '.STATE=="connected" and .INITIAL_TLS_ACCEPTED==true' >/dev/null || fail resumed_native_acceptance
[[ $(cat "$tmp/native-calls") == $'create\nissue\nactivate' ]] || fail native_call_repetition
vx_domain_connection_reconcile alice technical.example.net "$id" >/dev/null
[[ $(wc -l <"$tmp/native-calls") == 3 ]] || fail worker_became_renewer
vx_domain_connection_disconnect alice technical.example.net "$id" >/dev/null
( unset -f vx_domain_connection_native_cleanup; vx_domain_connection_reconcile alice technical.example.net "$id" 2>/dev/null ) | jq -e '.STATE=="recovery_required"' >/dev/null || fail absent_cleanup_helper_success
printf '%s\n' 'durable native create/issue/activate response-loss tests passed'
