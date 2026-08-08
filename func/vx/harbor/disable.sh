#!/usr/bin/env bash

VX_HARBOR_DISABLE_TOKEN_TTL=300

vx_harbor_disable_plan_locked() {
    local root now expires owners blockers token plan source
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    root="$(vx_harbor_root)"; vx_harbor_provider_enabled || return 1
    now="$(/usr/bin/date -u +%s)"; expires=$((now + VX_HARBOR_DISABLE_TOKEN_TTL))
    owners='[]'; blockers='[]'
    if /usr/bin/find "$root/owners" -maxdepth 1 -type f -name '*.json' -print -quit | /usr/bin/grep -q .; then owners="$(/usr/bin/jq -s '[.[]|{OWNER,NAMESPACE,STATE}]|sort_by(.OWNER)' "$root"/owners/*.json)" || return 1; fi
    if /usr/bin/find "$root/operations" -maxdepth 1 -type f -name '*.json' ! -name 'provider-disable.json' -print -quit | /usr/bin/grep -q .; then blockers="$(/usr/bin/find "$root/operations" -maxdepth 1 -type f -name '*.json' ! -name 'provider-disable.json' -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/jq -s '[.[]|select(.STATE=="pending" or .STATE=="failed")|{OWNER,STATE}]')" || return 1; fi
    token="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    plan="$(/usr/bin/jq -cn --arg token "$token" --argjson created "$now" --argjson expires "$expires" --argjson owners "$owners" --argjson blockers "$blockers" '{SCHEMA:1,TOKEN:$token,CREATED_AT:$created,EXPIRES_AT:$expires,MODE:"managed",BLOCKERS:$blockers,AFFECTED_OWNERS:$owners,RETAINED_DATA:["provider database","OCI artifacts","owner mappings","encrypted backups"]}')"
    source="$(/usr/bin/mktemp "$root/operations/.disable-plan.XXXXXX")" || return 1
    printf '%s\n' "$plan" >"$source" && vx_harbor_json_write_atomic "$root/operations/provider-disable.json" "$source" || { /usr/bin/rm -f "$source"; return 1; }
    /usr/bin/rm -f "$source"; /usr/bin/jq -cS . "$root/operations/provider-disable.json"
}

vx_harbor_disable_plan() { local result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_disable_plan_locked)"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }

_vx_harbor_disable_ingress_remove() { local target; target="$(vx_harbor_ingress_target)"; /usr/bin/rm -f -- "$target"; "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t && "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service; }

vx_harbor_disable_locked() {
    local token="$1" root plan now owners owner_file publisher runtime provider_source ingress backup_ingress was_active=no phase=credentials
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive && "$token" =~ ^[a-f0-9]{32}$ ]] || return 1
    root="$(vx_harbor_root)"; plan="$root/operations/provider-disable.json"; vx_harbor_secure_regular_file "$plan" 0600 || return 1
    now="$(/usr/bin/date -u +%s)"
    /usr/bin/jq -e --arg token "$token" --argjson now "$now" '.SCHEMA==1 and .TOKEN==$token and .MODE=="managed" and .EXPIRES_AT >= $now and (.BLOCKERS|length)==0' "$plan" >/dev/null || return 1
    vx_harbor_provider_enabled || return 1
    # Revalidate owner set immediately before external mutation.
    owners='[]'; if /usr/bin/find "$root/owners" -maxdepth 1 -type f -name '*.json' -print -quit | /usr/bin/grep -q .; then owners="$(/usr/bin/jq -s '[.[]|{OWNER,NAMESPACE,STATE}]|sort_by(.OWNER)' "$root"/owners/*.json)" || return 1; fi
    /usr/bin/jq -e --argjson owners "$owners" '.AFFECTED_OWNERS==$owners' "$plan" >/dev/null || return 1
    for owner_file in "$root"/owners/*.json; do
        [[ -f "$owner_file" ]] || continue; vx_harbor_owner_state_validate "$owner_file" || return 1
        publisher="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID // empty' "$owner_file")"
        [[ -z "$publisher" ]] || vx_harbor_api_robot_disable "$publisher" >/dev/null || return 75
    done
    for owner_file in "$root"/owners/*.json; do
        [[ -f "$owner_file" ]] || continue
        runtime="$(/usr/bin/jq -r '.RUNTIME_ROBOT_ID // empty' "$owner_file")"
        [[ -z "$runtime" ]] || vx_harbor_api_robot_disable "$runtime" >/dev/null || return 75
    done
    ingress="$(vx_harbor_ingress_target)"; backup_ingress="$(/usr/bin/mktemp "$root/.disable-ingress.XXXXXX")" || return 1
    if [[ -f "$ingress" && ! -L "$ingress" ]]; then /usr/bin/cp -p "$ingress" "$backup_ingress" || return 1; else : >"$backup_ingress"; fi
    _vx_harbor_service_is_active && was_active=yes || :
    if ! _vx_harbor_disable_ingress_remove; then /usr/bin/rm -f "$backup_ingress"; return 1; fi
    phase=service
    if [[ "$was_active" == yes ]] && ! _vx_harbor_service_stop; then /usr/bin/install -o 0 -g 0 -m 0600 "$backup_ingress" "$ingress"; "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service || :; /usr/bin/rm -f "$backup_ingress"; return 1; fi
    provider_source="$(/usr/bin/mktemp "$root/.provider-disable.XXXXXX")" || return 1
    /usr/bin/jq '.MODE="disabled"|.RUNNING_VERSION=null|.LAST_HEALTH_AT=null' "$root/provider.json" >"$provider_source"
    if ! vx_harbor_json_write_atomic "$root/provider.json" "$provider_source"; then
        [[ "$was_active" == yes ]] && _vx_harbor_service_start || :
        /usr/bin/install -o 0 -g 0 -m 0600 "$backup_ingress" "$ingress"; "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service || :
        /usr/bin/rm -f "$provider_source" "$backup_ingress"; return 1
    fi
    /usr/bin/rm -f "$provider_source" "$backup_ingress" "$plan"; _vx_harbor_fsync "$root/operations"
    vx_harbor_audit system provider-disable success retained || return 1
    printf 'disabled\n'
}

vx_harbor_disable() { local token="$1" result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_disable_locked "$token")"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }
