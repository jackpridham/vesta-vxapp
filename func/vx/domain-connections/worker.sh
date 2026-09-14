#!/usr/bin/env bash

vx_domain_connection_worker_update() {
    local hostname=$1 expected_generation=$2 state=$3 reason=$4 observations=$5 success=$6 record now next attempts delay
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    [[ $(jq -r .GENERATION <<<"$record") == "$expected_generation" ]] || return 9
    now=$(vx_domain_connection_now)
    attempts=$(jq -r '.ATTEMPTS // 0' <<<"$record")
    if [[ $success == true ]]; then
        attempts=0; delay=60
        [[ $state != connected ]] || delay=3600
    else
        ((attempts+=1)); ((attempts<=7)) || attempts=7
        delay=$((30 * (1 << attempts)))
        ((delay<=3600)) || delay=3600
    fi
    next=$(date -u -d "+$delay seconds" +%Y-%m-%dT%H:%M:%SZ)
    record=$(jq --arg state "$state" --arg reason "$reason" --arg now "$now" --arg next "$next" --argjson observations "$observations" --argjson success "$success" --argjson attempts "$attempts" '
        .STATE=$state | .REASON=$reason | .LAST_CHECKED_AT=$now | .NEXT_CHECK_AT=$next | .ATTEMPTS=$attempts | .OBSERVATIONS=$observations |
        if $success then .LAST_SUCCESSFUL_AT=$now else . end |
        if $state=="disconnected" then .RESERVATION_RELEASED=true | .CLEANUP.NATIVE_CHILD=false | .NEXT_CHECK_AT=null | del(.OPERATION)
        elif $state=="failed" and $reason=="proof_expired" then .RESERVATION_RELEASED=true | .NEXT_CHECK_AT=null
        elif $state=="connected" then .INITIAL_TLS_ACCEPTED=true | del(.OPERATION) else . end' <<<"$record") || return 1
    vx_domain_connection_record_write "$hostname" "$record"
}

vx_domain_connection_worker_intent() {
    local hostname=$1 generation=$2 kind=$3 record
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    [[ $(jq -r .GENERATION <<<"$record") == "$generation" ]] || return 9
    record=$(jq --arg kind "$kind" --arg now "$(vx_domain_connection_now)" '.OPERATION={KIND:$kind,GENERATION:.GENERATION,STARTED_AT:$now} | if $kind=="create" then .CLEANUP.NATIVE_CHILD=true else . end' <<<"$record") || return 1
    vx_domain_connection_record_write "$hostname" "$record"
}

vx_domain_connection_reconcile_record() (
    local hostname=$1 expected_owner=${2:-} expected_id=${3:-} record owner generation state token observation target native_result reason next_state kind rc=0
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    owner=$(jq -r .OWNER <<<"$record")
    vx_domain_connection_owner_lock "$owner" || return 1
    vx_domain_connection_lock "$hostname" || return 1
    record=$(vx_domain_connection_record_read "$hostname") || return 1
    [[ $(jq -r .OWNER <<<"$record") == "$owner" ]] || return 9
    [[ -z $expected_owner || $owner == "$expected_owner" ]] || return 9
    [[ -z $expected_id || $(jq -r .CONNECTION_ID <<<"$record") == "$expected_id" ]] || return 9
    generation=$(jq -r .GENERATION <<<"$record"); state=$(jq -r .STATE <<<"$record"); token=$(jq -r .PROOF_TOKEN <<<"$record")
    export VX_DOMAIN_CONNECTION_RECORD="$(vx_domain_connection_record_path "$hostname")" VX_DOMAIN_CONNECTION_NATIVE_TLS=1
    export VX_DOMAIN_CONNECTION_OWNER_LOCK_FD VX_DOMAIN_CONNECTION_LOCK_FD
    if jq -e '.RECOVERY.required==true' >/dev/null <<<"$record"; then
        if ! vx_domain_connection_native_recover "$VX_DOMAIN_CONNECTION_RECORD"; then
            vx_domain_connection_worker_update "$hostname" "$generation" recovery_required certificate_recovery_failed '{}' false || return 1
            vx_domain_connection_record_read "$hostname"; return 0
        fi
        record=$(vx_domain_connection_record_read "$hostname") || return 1
        state=$(jq -r 'if .INITIAL_TLS_ACCEPTED==true or .OPERATION.KIND=="renew" then "degraded" else "pending_tls" end' <<<"$record")
        record=$(jq --arg state "$state" '.STATE=$state | del(.OPERATION)' <<<"$record")
        vx_domain_connection_record_write "$hostname" "$record" || return 1
    fi
    if [[ $state == recovery_required ]] && [[ $(jq -r .REASON <<<"$record") == restored_recovery_required ]]; then
        token=$(head -c 32 /dev/urandom | sha256sum | cut -c1-48)
        record=$(jq --arg token "$token" --arg expires "$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ)" '.PROOF_TOKEN=$token | .PROOF_EXPIRES_AT=$expires | .STATE="pending_verification" | .REASON="restored_awaiting_fresh_proof" | .CLEANUP.NATIVE_CHILD=true' <<<"$record")
        vx_domain_connection_record_write "$hostname" "$record" || return 1
        state=pending_verification
    fi
    if [[ $state == recovery_required ]]; then
        kind=$(jq -r '.OPERATION.KIND // empty' <<<"$record")
        if [[ $kind == cleanup ]]; then state=disconnecting
        elif [[ $kind == create || $kind == activate ]] && jq -e '.RECOVERY.required != true' >/dev/null <<<"$record"; then state=pending_tls
        else printf '%s\n' "$record"; return 0; fi
        record=$(jq --arg state "$state" '.STATE=$state' <<<"$record")
        vx_domain_connection_record_write "$hostname" "$record" || return 1
    fi
    if [[ $state == pending_dns || $state == pending_tls ]] && [[ $(vx_domain_connection_now) > $(jq -r .PROOF_EXPIRES_AT <<<"$record") ]] && jq -e '.CLEANUP.NATIVE_CHILD!=true and .OPERATION==null' >/dev/null <<<"$record"; then
        vx_domain_connection_worker_update "$hostname" "$generation" failed proof_expired '{}' false || return 1
        vx_domain_connection_record_read "$hostname"; return 0
    fi
    case "$state" in
        pending_verification)
            if [[ $(vx_domain_connection_now) > $(jq -r .PROOF_EXPIRES_AT <<<"$record") ]]; then
                # Only an untouched reservation can expire and become reusable.
                if jq -e '.CLEANUP.NATIVE_CHILD != true and .OPERATION == null' >/dev/null <<<"$record"; then
                    vx_domain_connection_worker_update "$hostname" "$generation" failed proof_expired '{}' false || return 1
                else vx_domain_connection_worker_update "$hostname" "$generation" recovery_required proof_expired_with_native_intent '{}' false || return 1; fi
            else
                observation=$(vx_domain_connection_dns_proof_observe "$hostname" "$token") || observation='{"PROOF":false,"REASON":"dns_observation_failed"}'
                if jq -e '.PROOF==true' >/dev/null <<<"$observation"; then next_state=pending_dns; reason=proof_accepted; else next_state=pending_verification; reason=proof_not_observed; fi
                vx_domain_connection_worker_update "$hostname" "$generation" "$next_state" "$reason" "$observation" "$([[ $next_state == pending_dns ]] && echo true || echo false)" || return 1
            fi ;;
        pending_dns|pending_tls|connected|degraded)
            target=$(vx_domain_connection_target_read_json) || target='{}'
            observation=$(vx_domain_connection_dns_observe "$hostname" "$(jq -r '.TARGET_FQDN // empty' <<<"$target")") || observation='{"ROUTED":false,"SAFE":false,"REASON":"dns_observation_failed"}'
            if ! jq -e '.ROUTED==true and .SAFE==true and .CAA==true and .DNSSEC!="bogus"' >/dev/null <<<"$observation"; then
                next_state=pending_dns; [[ $state != connected && $state != degraded ]] || next_state=degraded
                vx_domain_connection_worker_update "$hostname" "$generation" "$next_state" dns_not_ready "$(jq -cn --argjson dns "$observation" '{dns:$dns}')" false || return 1
            elif [[ $state == pending_dns ]]; then
                vx_domain_connection_worker_update "$hostname" "$generation" pending_tls dns_accepted "$(jq -cn --argjson dns "$observation" '{dns:$dns}')" true || return 1
            else
                # Readback first reconciles lost issue/activation responses and
                # prevents the connection worker becoming a second renewer.
                native_result=$(vx_domain_connection_native_observe "$VX_DOMAIN_CONNECTION_RECORD") || native_result='{}'
                if [[ $state == pending_tls ]] && ! jq -e '.NATIVE_CHILD_PRESENT==true' >/dev/null <<<"$native_result"; then
                    vx_domain_connection_worker_intent "$hostname" "$generation" create || return 1
                    if ! vx_domain_connection_native_create "$VX_DOMAIN_CONNECTION_RECORD"; then
                        vx_domain_connection_worker_update "$hostname" "$generation" recovery_required native_create_failed '{}' false || return 1
                        vx_domain_connection_record_read "$hostname"; return 0
                    fi
                    native_result=$(vx_domain_connection_native_observe "$VX_DOMAIN_CONNECTION_RECORD") || native_result='{}'
                fi
                if [[ $state == pending_tls ]] && ! jq -e '.TLS_STATE=="accepted" or .TLS_STATE=="issued"' >/dev/null <<<"$native_result"; then
                    if jq -e '.INITIAL_TLS_ACCEPTED==true' "$VX_DOMAIN_CONNECTION_RECORD" >/dev/null; then
                        vx_domain_connection_worker_update "$hostname" "$generation" degraded certificate_renewal_required '{}' false || return 1
                        vx_domain_connection_record_read "$hostname"; return 0
                    fi
                    vx_domain_connection_worker_intent "$hostname" "$generation" issue || return 1
                    if ! vx_domain_connection_native_issue "$VX_DOMAIN_CONNECTION_RECORD"; then
                        record=$(vx_domain_connection_record_read "$hostname") || return 1
                        if [[ $(jq -r .STATE <<<"$record") != recovery_required ]]; then
                            vx_domain_connection_worker_update "$hostname" "$generation" pending_tls certificate_issue_pending '{}' false || return 1
                        fi
                        vx_domain_connection_record_read "$hostname"; return 0
                    fi
                    native_result=$(vx_domain_connection_native_observe "$VX_DOMAIN_CONNECTION_RECORD") || native_result='{}'
                fi
                if jq -e '.TLS_STATE=="issued"' >/dev/null <<<"$native_result"; then
                    vx_domain_connection_worker_intent "$hostname" "$generation" activate || return 1
                    if ! vx_domain_connection_native_activate "$VX_DOMAIN_CONNECTION_RECORD"; then
                        vx_domain_connection_worker_update "$hostname" "$generation" recovery_required native_activate_failed '{}' false || return 1
                        vx_domain_connection_record_read "$hostname"; return 0
                    fi
                    native_result=$(vx_domain_connection_native_observe "$VX_DOMAIN_CONNECTION_RECORD") || native_result='{}'
                fi
                observation=$(jq -cn --argjson dns "$observation" --argjson native "$native_result" '{dns:$dns,native:$native}') || return 1
                if jq -e '.native.TLS_STATE=="accepted" and .native.HTTPS_IDENTITY==true and .native.CONFIG_VALID==true' >/dev/null <<<"$observation"; then
                    vx_domain_connection_worker_update "$hostname" "$generation" connected https_accepted "$observation" true || return 1
                else
                    next_state=degraded; [[ $state != pending_tls ]] || next_state=pending_tls
                    vx_domain_connection_worker_update "$hostname" "$generation" "$next_state" tls_not_accepted "$observation" false || return 1
                fi
            fi ;;
        disconnecting)
            vx_domain_connection_worker_intent "$hostname" "$generation" cleanup || return 1
            if vx_domain_connection_native_cleanup "$VX_DOMAIN_CONNECTION_RECORD"; then
                vx_domain_connection_worker_update "$hostname" "$generation" disconnected cleanup_complete '{}' true || return 1
            else vx_domain_connection_worker_update "$hostname" "$generation" recovery_required cleanup_failed '{}' false || return 1; fi ;;
    esac
    vx_domain_connection_record_read "$hostname"
)

vx_domain_connection_reconcile() {
    local record
    record=$(vx_domain_connection_find_id "$1" "$2" "$3") || return 2
    vx_domain_connection_reconcile_record "$(jq -r .HOSTNAME <<<"$record")" "$1" "$3"
}

vx_domain_connection_reconcile_bounded() {
    local record
    record=$(vx_domain_connection_find_id "$1" "$2" "$3") || return 2
    vx_domain_connection_worker_run "$(jq -r .HOSTNAME <<<"$record")" "$1" "$3"
}

# The timeout kills the process group, including native command descendants.
# Durable operation intent remains for exact readback on the next attempt.
vx_domain_connection_worker_run() {
    local seconds=${4:-90}
    /usr/bin/timeout --kill-after=10 "$seconds" /bin/bash -c 'source "$VESTA/func/main.sh"; source "$VESTA/conf/vesta.conf"; source "$VESTA/func/vx/domain-connections/main.sh"; vx_domain_connection_reconcile_record "$1" "${2:-}" "${3:-}"' _ "$1" "${2:-}" "${3:-}"
}

vx_domain_connection_update_all() (
    local records hostname count=0 started=$SECONDS now health root remaining
    vx_domain_connection_prepare || return 1
    vx_domain_connection_open_lock "$(vx_domain_connection_root)/.worker.lock" VX_DOMAIN_CONNECTION_WORKER_LOCK_FD || return 1
    records=$(vx_domain_connection_records) || return 1
    now=$(vx_domain_connection_now)
    while IFS= read -r hostname; do
        [[ -n $hostname ]] || continue
        ((count<20 && SECONDS-started<120)) || break
        remaining=$((120-(SECONDS-started))); ((remaining<=90)) || remaining=90
        vx_domain_connection_worker_run "$hostname" '' '' "$remaining" >/dev/null || :
        ((count+=1))
    done < <(jq -sr --arg now "$now" 'map(select(.NEXT_CHECK_AT!=null and .NEXT_CHECK_AT<=$now and .STATE!="disconnected" and .STATE!="failed")) | sort_by(.NEXT_CHECK_AT) | .[].HOSTNAME' <<<"$records")
    root=$(vx_domain_connection_root)
    health=$(mktemp "$root/.health.XXXXXX") || return 1
    jq -cn --arg now "$(vx_domain_connection_now)" --argjson processed "$count" '{lastCompletedAt:$now,processed:$processed}' >"$health" || return 1
    chmod 600 "$health" && mv -f "$health" "$root/worker-health.json"
)

vx_domain_connection_worker_health_json() {
    local records now health='{}' root
    records=$(vx_domain_connection_records) || return 1
    now=$(vx_domain_connection_now); root=$(vx_domain_connection_root)
    if [[ -e "$root/worker-health.json" || -L "$root/worker-health.json" ]]; then
        vx_domain_connection_safe_path "$root/worker-health.json" file || return 1
        health=$(cat "$root/worker-health.json") || return 1
    fi
    jq -cs --arg now "$now" --argjson health "$health" '{checkedAt:$now,lastCompletedAt:($health.lastCompletedAt // null),processed:($health.processed // 0),overdue:(map(select(.NEXT_CHECK_AT!=null and .NEXT_CHECK_AT<$now and .STATE!="disconnected" and .STATE!="failed"))|length)}' <<<"$records"
}
