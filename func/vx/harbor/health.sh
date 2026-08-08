#!/usr/bin/env bash

VX_HARBOR_OBSERVATION_MAX_BYTES=1048576

_vx_harbor_certificate_observe() {
    local certificate="${VX_HARBOR_CERTIFICATE:-$VESTA/ssl/certificate.crt}" hostname expiry names now
    vx_harbor_secure_regular_file "$certificate" 0600 || return 1
    expiry="$(/usr/bin/openssl x509 -in "$certificate" -noout -enddate 2>/dev/null | /usr/bin/cut -d= -f2-)" || return 1
    names="$(/usr/bin/openssl x509 -in "$certificate" -noout -ext subjectAltName 2>/dev/null)" || return 1
    hostname="$(_vx_harbor_authoritative_hostname)" || return 1
    now="$(/usr/bin/date -u +%s)"
    /usr/bin/jq -cn --arg host "$hostname" --arg expiry "$expiry" --arg names "$names" --argjson now "$now" '
      ($expiry|strptime("%b %e %H:%M:%S %Y %Z")|mktime) as $end |
      {STATE:(if $end <= $now then "expired" elif ($end-$now)<2592000 then "expiring" else "valid" end),
       EXPIRES_AT:($end|strftime("%Y-%m-%dT%H:%M:%SZ")),HOSTNAME_VALID:($names|contains("DNS:"+$host))}'
}

vx_harbor_health_observe_locked() {
    local root now provider_health volume cert operations pending failed owner_file owner owner_json owners source owner_source quota_id quota_json used_bytes runtime_id publisher_id runtime_ready publisher_ready
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == shared || "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    root="$(vx_harbor_root)"; vx_harbor_provider_enabled || return 1
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    provider_health="$(vx_harbor_api_health 2>/dev/null)" && provider_health=healthy || provider_health=unavailable
    volume="$(vx_harbor_api_volume 2>/dev/null || printf '{}')"
    cert="$(_vx_harbor_certificate_observe 2>/dev/null || printf '{"STATE":"unavailable","EXPIRES_AT":null,"HOSTNAME_VALID":false}')"
    pending=0; failed=0
    if /usr/bin/find "$root/operations" -maxdepth 1 -type f -name '*.json' -print -quit 2>/dev/null | /usr/bin/grep -q .; then
        operations="$(/usr/bin/jq -s '[.[]|select(type=="object")]|map({STATE,UPDATED_AT})' "$root"/operations/*.json 2>/dev/null || printf '[]')"
        pending="$(/usr/bin/jq '[.[]|select(.STATE=="pending")]|length' <<<"$operations")"
        failed="$(/usr/bin/jq '[.[]|select(.STATE=="failed")]|length' <<<"$operations")"
    fi
    owners='[]'
    for owner_file in "$root"/owners/*.json; do
        [[ -f "$owner_file" ]] || continue
        vx_harbor_owner_state_validate "$owner_file" || return 1
        owner="$(/usr/bin/jq -r .OWNER "$owner_file")"; quota_id="$(/usr/bin/jq -r .QUOTA_ID "$owner_file")"
        quota_json="$(vx_harbor_api_quota_get "$quota_id" 2>/dev/null || printf '{}')"; used_bytes="$(/usr/bin/jq -r '.used.storage // .used_storage // 0' <<<"$quota_json")"
        [[ "$used_bytes" =~ ^[0-9]+$ ]] || used_bytes=0
        runtime_id="$(/usr/bin/jq -r '.RUNTIME_ROBOT_ID // empty' "$owner_file")"; publisher_id="$(/usr/bin/jq -r '.PUBLISHER_ROBOT_ID // empty' "$owner_file")"
        runtime_ready=false; publisher_ready=false
        [[ -n "$runtime_id" ]] && vx_harbor_api_robot_get "$runtime_id" >/dev/null 2>&1 && runtime_ready=true
        [[ -n "$publisher_id" && "$(/usr/bin/jq -r .PUBLISHER_ENABLED "$owner_file")" == true ]] && vx_harbor_api_robot_get "$publisher_id" >/dev/null 2>&1 && publisher_ready=true
        owner_json="$(/usr/bin/jq -c --argjson used "$(((used_bytes + 1048575) / 1048576))" --argjson runtime "$runtime_ready" --argjson publisher "$publisher_ready" '{OWNER,QUOTA_MB,STATE,USED_MB:$used,CREDENTIAL_READY:$runtime,PUBLISHER_READY:$publisher}' "$owner_file")"
        owners="$(/usr/bin/jq -c --argjson item "$owner_json" '.+[$item]' <<<"$owners")"
        owner_source="$(/usr/bin/mktemp "$root/observations/.owner.XXXXXX")" || return 1
        /usr/bin/jq -n --arg at "$now" --argjson value "$owner_json" '{SCHEMA:1,OBSERVED_AT:$at}+$value' >"$owner_source" \
          && vx_harbor_json_write_atomic "$root/observations/$owner.json" "$owner_source" || { /usr/bin/rm -f "$owner_source"; return 1; }
        /usr/bin/rm -f "$owner_source"
    done
    source="$(/usr/bin/mktemp "$root/observations/.provider.XXXXXX")" || return 1
    /usr/bin/jq -n --arg at "$now" --arg health "$provider_health" --argjson cert "$cert" --argjson volume "$volume" --argjson owners "$owners" --argjson pending "$pending" --argjson failed "$failed" \
      '{SCHEMA:1,OBSERVED_AT:$at,HEALTH:$health,CERTIFICATE:$cert,STORAGE:{USED_BYTES:($volume.storage.used // 0),TOTAL_BYTES:($volume.storage.total // 0)},OPERATIONS:{PENDING:$pending,FAILED:$failed},OWNERS:$owners}' >"$source" || { /usr/bin/rm -f "$source"; return 1; }
    (( $(/usr/bin/stat -c %s "$source") <= VX_HARBOR_OBSERVATION_MAX_BYTES )) || { /usr/bin/rm -f "$source"; return 1; }
    vx_harbor_json_write_atomic "$root/observations/provider.json" "$source" || { /usr/bin/rm -f "$source"; return 1; }
    /usr/bin/rm -f "$source"
    /usr/bin/jq -cS . "$root/observations/provider.json"
}

vx_harbor_health_observe() {
    local result
    vx_harbor_provider_lock_acquire shared || return 1
    result="$(vx_harbor_health_observe_locked)"; local status=$?
    vx_harbor_provider_lock_release || return 1
    (( status == 0 )) && printf '%s\n' "$result"
    return "$status"
}
