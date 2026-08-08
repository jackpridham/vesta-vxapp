#!/usr/bin/env bash

VX_HARBOR_DISABLE_TOKEN_TTL=300

_vx_harbor_disable_operations_json() {
    local root file value result='[]'
    root="$(vx_harbor_root)"
    for file in "$root"/operations/*.json; do
        [[ -f "$file" ]] || continue
        [[ "${file##*/}" == provider-disable.json ]] && continue
        vx_harbor_package_operation_validate "$file" || return 1
        value="$(/usr/bin/jq -c --arg file "${file##*/}" '{FILE:$file,OWNER,OPERATION_ID,STATE,UPDATED_AT}' "$file")" || return 1
        result="$(/usr/bin/jq -c --argjson value "$value" '. + [$value] | sort_by(.FILE)' <<<"$result")" || return 1
    done
    printf '%s\n' "$result"
}

vx_harbor_disable_plan_locked() {
    local root now expires owners operations blockers token plan source
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    root="$(vx_harbor_root)"; vx_harbor_provider_enabled || return 1
    now="$(/usr/bin/date -u +%s)"; expires=$((now + VX_HARBOR_DISABLE_TOKEN_TTL))
    owners='[]'
    if /usr/bin/find "$root/owners" -maxdepth 1 -type f -name '*.json' -print -quit | /usr/bin/grep -q .; then owners="$(/usr/bin/jq -s '[.[]|{OWNER,NAMESPACE,STATE}]|sort_by(.OWNER)' "$root"/owners/*.json)" || return 1; fi
    operations="$(_vx_harbor_disable_operations_json)" || return 1
    blockers="$(/usr/bin/jq '[.[]|select(.STATE=="pending" or .STATE=="failed")|{OWNER,OPERATION_ID,STATE}]' <<<"$operations")" || return 1
    token="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')"
    plan="$(/usr/bin/jq -cn --arg token "$token" --argjson created "$now" --argjson expires "$expires" --argjson owners "$owners" --argjson operations "$operations" --argjson blockers "$blockers" '{SCHEMA:1,TOKEN:$token,CREATED_AT:$created,EXPIRES_AT:$expires,MODE:"managed",OPERATIONS:$operations,BLOCKERS:$blockers,AFFECTED_OWNERS:$owners,RETAINED_DATA:["provider database","OCI artifacts","owner mappings","encrypted backups"]}')"
    source="$(/usr/bin/mktemp "$root/operations/.disable-plan.XXXXXX")" || return 1
    printf '%s\n' "$plan" >"$source" && vx_harbor_json_write_atomic "$root/operations/provider-disable.json" "$source" || { /usr/bin/rm -f "$source"; return 1; }
    /usr/bin/rm -f "$source"; /usr/bin/jq -cS . "$root/operations/provider-disable.json"
}

vx_harbor_disable_plan() { local result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_disable_plan_locked)"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }

_vx_harbor_disable_ingress_remove() {
    local target main candidate
    target="$(vx_harbor_ingress_target)"; main="$(vx_harbor_nginx_main)"
    [[ -f "$main" && ! -L "$main" ]] || return 1
    candidate="$(/usr/bin/mktemp "$(dirname "$main")/.harbor-disable.XXXXXX")" || return 1
    /usr/bin/python3 - "$main" "$candidate" "$target" <<'PY' || { /usr/bin/rm -f "$candidate"; return 1; }
import pathlib, sys
src, dst, target = map(pathlib.Path, sys.argv[1:])
needle = 'include '+str(target)+';'
lines = src.read_text().splitlines(keepends=True)
matches = [i for i, line in enumerate(lines) if line.strip() == needle]
if len(matches) != 1: raise SystemExit(1)
del lines[matches[0]]
dst.write_text(''.join(lines))
PY
    "${VX_HARBOR_NGINX:-/usr/sbin/nginx}" -t -c "$candidate" || { /usr/bin/rm -f "$candidate"; return 1; }
    /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$candidate" "$main" || { /usr/bin/rm -f "$candidate"; return 1; }
    /usr/bin/rm -f -- "$candidate" || return 1
    /usr/bin/rm -f -- "$target" || return 1
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service
}

_vx_harbor_disable_restore() {
    local ingress="$1" main="$2" backup_ingress="$3" backup_main="$4" ingress_existed="$5" was_active="$6"
    /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$backup_main" "$main" || return 1
    if [[ "$ingress_existed" == yes ]]; then
        /usr/bin/install -o "$(_vx_harbor_authority_uid)" -g "$(_vx_harbor_authority_gid)" -m 0600 "$backup_ingress" "$ingress" || return 1
    else
        /usr/bin/rm -f -- "$ingress" || return 1
    fi
    [[ "$was_active" == no ]] || _vx_harbor_service_start || return 1
    "${VX_HARBOR_SYSTEMCTL:-/usr/bin/systemctl}" reload nginx.service
}

vx_harbor_disable_locked() {
    local token="$1" root plan now owners operations blockers owner_file publisher runtime provider_source ingress main backup_ingress backup_main was_active=no ingress_existed=no
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive && "$token" =~ ^[a-f0-9]{32}$ ]] || return 1
    root="$(vx_harbor_root)"; plan="$root/operations/provider-disable.json"; vx_harbor_secure_regular_file "$plan" 0600 || return 1
    now="$(/usr/bin/date -u +%s)"
    /usr/bin/jq -e --arg token "$token" --argjson now "$now" 'keys==["AFFECTED_OWNERS","BLOCKERS","CREATED_AT","EXPIRES_AT","MODE","OPERATIONS","RETAINED_DATA","SCHEMA","TOKEN"] and .SCHEMA==1 and .TOKEN==$token and .MODE=="managed" and .EXPIRES_AT >= $now and (.BLOCKERS|length)==0' "$plan" >/dev/null || return 1
    vx_harbor_provider_enabled || return 1
    # Revalidate owner set immediately before external mutation.
    owners='[]'; if /usr/bin/find "$root/owners" -maxdepth 1 -type f -name '*.json' -print -quit | /usr/bin/grep -q .; then owners="$(/usr/bin/jq -s '[.[]|{OWNER,NAMESPACE,STATE}]|sort_by(.OWNER)' "$root"/owners/*.json)" || return 1; fi
    operations="$(_vx_harbor_disable_operations_json)" || return 1
    blockers="$(/usr/bin/jq '[.[]|select(.STATE=="pending" or .STATE=="failed")|{OWNER,OPERATION_ID,STATE}]' <<<"$operations")" || return 1
    /usr/bin/jq -e --argjson owners "$owners" --argjson operations "$operations" --argjson blockers "$blockers" '.AFFECTED_OWNERS==$owners and .OPERATIONS==$operations and .BLOCKERS==$blockers and ($blockers|length)==0' "$plan" >/dev/null || return 1
    now="$(/usr/bin/date -u +%s)"; vx_harbor_provider_enabled || return 1
    /usr/bin/jq -e --arg token "$token" --argjson now "$now" '.TOKEN==$token and .EXPIRES_AT >= $now and .MODE=="managed"' "$plan" >/dev/null || return 1
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
    ingress="$(vx_harbor_ingress_target)"; main="$(vx_harbor_nginx_main)"; backup_ingress="$(/usr/bin/mktemp "$root/.disable-ingress.XXXXXX")" || return 1; backup_main="$(/usr/bin/mktemp "$root/.disable-main.XXXXXX")" || { /usr/bin/rm -f "$backup_ingress"; return 1; }
    if [[ -f "$ingress" && ! -L "$ingress" ]]; then ingress_existed=yes; /usr/bin/cp -p "$ingress" "$backup_ingress" || return 1; else : >"$backup_ingress"; fi
    [[ -f "$main" && ! -L "$main" ]] && /usr/bin/cp -p "$main" "$backup_main" || { /usr/bin/rm -f "$backup_ingress" "$backup_main"; return 1; }
    _vx_harbor_service_is_active && was_active=yes || :
    if ! _vx_harbor_disable_ingress_remove; then _vx_harbor_disable_restore "$ingress" "$main" "$backup_ingress" "$backup_main" "$ingress_existed" no || :; /usr/bin/rm -f "$backup_ingress" "$backup_main"; return 1; fi
    if [[ "$was_active" == yes ]] && ! _vx_harbor_service_stop; then _vx_harbor_disable_restore "$ingress" "$main" "$backup_ingress" "$backup_main" "$ingress_existed" no || :; /usr/bin/rm -f "$backup_ingress" "$backup_main"; return 1; fi
    provider_source="$(/usr/bin/mktemp "$root/.provider-disable.XXXXXX")" || { _vx_harbor_disable_restore "$ingress" "$main" "$backup_ingress" "$backup_main" "$ingress_existed" "$was_active" || :; /usr/bin/rm -f "$backup_ingress" "$backup_main"; return 1; }
    /usr/bin/jq '.MODE="disabled"|.RUNNING_VERSION=null|.LAST_HEALTH_AT=null' "$root/provider.json" >"$provider_source"
    if ! vx_harbor_json_write_atomic "$root/provider.json" "$provider_source"; then
        _vx_harbor_disable_restore "$ingress" "$main" "$backup_ingress" "$backup_main" "$ingress_existed" "$was_active" || :
        /usr/bin/rm -f "$provider_source" "$backup_ingress" "$backup_main"; return 1
    fi
    /usr/bin/rm -f "$provider_source" "$backup_ingress" "$backup_main" "$plan"; _vx_harbor_fsync "$root/operations"
    vx_harbor_audit system provider-disable success retained || return 1
    printf 'disabled\n'
}

vx_harbor_disable() { local token="$1" result status; vx_harbor_provider_lock_acquire exclusive || return 1; result="$(vx_harbor_disable_locked "$token")"; status=$?; vx_harbor_provider_lock_release || return 1; ((status==0)) && printf '%s\n' "$result"; return "$status"; }
