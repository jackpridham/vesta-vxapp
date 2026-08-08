#!/usr/bin/env bash

vx_harbor_quota_bytes() {
    [[ "$1" == unlimited ]] && { printf '%s\n' -1; return; }
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ && ${#1} -le 13 ]] || return 1
    (( ${#1} < 13 || 10#$1 <= 8796093022207 )) || return 1
    printf '%s\n' "$((10#$1 * 1024 * 1024))"
}

vx_harbor_quota_observe() {
    local owner="$1" quota_id="$2" quota used bytes now generation source path
    quota="$(vx_harbor_api_quota_get "$quota_id")" || return 1
    bytes="$(/usr/bin/jq -er '.used.storage | select(type=="number" and floor==. and .>=0)' <<<"$quota")" || return 1
    used=$(((bytes + 1048575) / 1048576))
    now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    generation="$(/usr/bin/sha256sum <<<"$owner:$quota_id:$bytes:$now" | /usr/bin/awk '{print $1}')"
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/observations/.owner.XXXXXX")" || return 1
    path="$(vx_harbor_root)/observations/$owner.json"
    /usr/bin/jq -n --argjson used "$used" --arg at "$now" --arg generation "$generation" \
      '{USED_MB:$used,OBSERVED_AT:$at,GENERATION:$generation}' >"$source" \
      && vx_harbor_json_write_atomic "$path" "$source"
    local result=$?; /usr/bin/rm -f "$source"; (( result == 0 )) || return "$result"
    vx_harbor_registry_usage_set "$owner" "$used"
}
