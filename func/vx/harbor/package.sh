#!/usr/bin/env bash

VX_HARBOR_PACKAGE_MAX_ATTEMPTS=3

vx_harbor_registry_usage_set() {
    local owner="$1" used_mb="$2"
    [[ "$used_mb" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    update_user_value "$owner" '$U_DOCKER_REGISTRY_MB' "$used_mb"
}

vx_harbor_operation_path() {
    local owner="$1"
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    printf '%s/operations/%s.json\n' "$(vx_harbor_root)" "$owner"
}

vx_harbor_package_operation_validate() {
    local path="$1"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -e '
      type == "object" and (keys == [
        "ATTEMPTS","CREATED_AT","DESIRED_PACKAGE","DESIRED_REGISTRY_MB",
        "LAST_ERROR","OPERATION_ID","OWNER","SCHEMA","STATE","UPDATED_AT"
      ]) and .SCHEMA == 1
      and (.OPERATION_ID | type == "string" and test("^[a-f0-9]{32}$"))
      and (.OWNER | type == "string" and test("^[a-z0-9][a-z0-9_-]{0,31}$"))
      and (.DESIRED_PACKAGE | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and ((.DESIRED_REGISTRY_MB == "unlimited") or
           (.DESIRED_REGISTRY_MB | type == "number" and floor == . and . >= 0))
      and (.STATE == "pending" or .STATE == "converged" or .STATE == "failed")
      and (.ATTEMPTS | type == "number" and floor == . and . >= 0)
      and (.LAST_ERROR == null or
           (.LAST_ERROR | type == "string" and length >= 1 and length <= 160))
      and (.CREATED_AT | type == "number" and floor == . and . >= 0)
      and (.CREATED_AT as $created |
           (.UPDATED_AT | type == "number" and floor == . and . >= $created))
    ' "$path" >/dev/null 2>&1
}

_vx_harbor_observation_json() {
    local owner="$1" path now
    path="$(vx_harbor_root)/observations/$owner.json"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    now="$(/usr/bin/date -u +%s)" || return 1
    /usr/bin/python3 - "$path" "$now" <<'PY'
import datetime, json, re, sys
path, now = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as stream:
    value = json.load(stream)
if set(value) != {"USED_MB", "OBSERVED_AT", "GENERATION"}:
    raise SystemExit(1)
if isinstance(value["USED_MB"], bool) or not isinstance(value["USED_MB"], int) or value["USED_MB"] < 0:
    raise SystemExit(1)
if not isinstance(value["GENERATION"], str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", value["GENERATION"]):
    raise SystemExit(1)
try:
    observed = int(datetime.datetime.strptime(value["OBSERVED_AT"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp())
except (TypeError, ValueError):
    raise SystemExit(1)
if now - observed > 300 or observed - now > 30:
    raise SystemExit(1)
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

vx_harbor_package_transition_check() {
    local owner="$1" package="$2" quota="$3" path state existing_package existing_quota mode observation used
    [[ "$package" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    [[ "$quota" == unlimited || "$quota" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    path="$(vx_harbor_operation_path "$owner")" || return 1
    if [[ -e "$path" || -L "$path" ]]; then
        vx_harbor_package_operation_validate "$path" || return 1
        state="$(/usr/bin/jq -r '.STATE' "$path")"
        existing_package="$(/usr/bin/jq -r '.DESIRED_PACKAGE' "$path")"
        existing_quota="$(/usr/bin/jq -r '.DESIRED_REGISTRY_MB' "$path")"
        if [[ "$state" != converged ]]; then
            [[ "$package" == "$existing_package" && "$quota" == "$existing_quota" ]] || return 1
        fi
    fi
    mode="$(vx_harbor_provider_mode)" || return 1
    if [[ "$mode" == managed && "$quota" != unlimited ]]; then
        observation="$(_vx_harbor_observation_json "$owner")" || return 1
        used="$(/usr/bin/jq -r '.USED_MB' <<<"$observation")" || return 1
        (( 10#$quota >= used )) || return 1
    fi
}

vx_harbor_package_transition_publish() {
    local owner="$1" package="$2" quota="$3" path source now operation_id existing_state existing_package existing_quota result
    vx_harbor_package_transition_check "$owner" "$package" "$quota" || return 1
    path="$(vx_harbor_operation_path "$owner")" || return 1
    now="$(/usr/bin/date -u +%s)" || return 1
    if [[ -e "$path" ]]; then
        existing_state="$(/usr/bin/jq -r '.STATE' "$path")"
        existing_package="$(/usr/bin/jq -r '.DESIRED_PACKAGE' "$path")"
        existing_quota="$(/usr/bin/jq -r '.DESIRED_REGISTRY_MB' "$path")"
        if [[ "$existing_state" != converged && "$package" == "$existing_package" && "$quota" == "$existing_quota" ]]; then
            if [[ "$existing_state" == failed ]]; then
                source="$(/usr/bin/mktemp "$(vx_harbor_root)/operations/.operation.XXXXXX")" || return 1
                if ! /usr/bin/jq --argjson now "$now" \
                    '.STATE="pending" | .ATTEMPTS=0 | .LAST_ERROR=null | .UPDATED_AT=$now' \
                    "$path" >"$source" || ! vx_harbor_json_write_atomic "$path" "$source"; then
                    /usr/bin/rm -f -- "$source"
                    return 1
                fi
                /usr/bin/rm -f -- "$source"
            fi
            /usr/bin/jq -r '.OPERATION_ID' "$path"
            return
        fi
    fi
    operation_id="$(/usr/bin/od -An -N16 -tx1 /dev/urandom | /usr/bin/tr -d ' \n')" || return 1
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/operations/.operation.XXXXXX")" || return 1
    /usr/bin/jq -n --arg id "$operation_id" --arg owner "$owner" --arg package "$package" \
        --arg quota "$quota" --argjson now "$now" '
        {SCHEMA:1,OPERATION_ID:$id,OWNER:$owner,DESIRED_PACKAGE:$package,
         DESIRED_REGISTRY_MB:(if $quota == "unlimited" then $quota else ($quota|tonumber) end),
         STATE:"pending",ATTEMPTS:0,LAST_ERROR:null,CREATED_AT:$now,UPDATED_AT:$now}' >"$source" \
        && vx_harbor_json_write_atomic "$path" "$source"
    result=$?
    /usr/bin/rm -f -- "$source"
    (( result == 0 )) || return "$result"
    printf '%s\n' "$operation_id"
}

_vx_harbor_package_operation_update() {
    local path="$1" state="$2" error="$3" increment="$4" source now
    now="$(/usr/bin/date -u +%s)" || return 1
    source="$(/usr/bin/mktemp "$(vx_harbor_root)/operations/.operation.XXXXXX")" || return 1
    /usr/bin/jq --arg state "$state" --arg error "$error" --argjson now "$now" --argjson increment "$increment" '
      .STATE=$state | .UPDATED_AT=$now | .ATTEMPTS += $increment |
      .LAST_ERROR=(if $error == "" then null else $error end)' "$path" >"$source" \
      && vx_harbor_json_write_atomic "$path" "$source"
    local result=$?
    /usr/bin/rm -f -- "$source"
    return "$result"
}

vx_harbor_package_transition_recover() {
    local owner="$1" path state attempts package quota mode observation generation observed_at error
    path="$(vx_harbor_operation_path "$owner")" || return 1
    [[ -e "$path" ]] || return 0
    vx_harbor_package_operation_validate "$path" || return 1
    state="$(/usr/bin/jq -r '.STATE' "$path")"
    [[ "$state" != converged ]] || return 0
    package="$(/usr/bin/jq -r '.DESIRED_PACKAGE' "$path")"
    quota="$(/usr/bin/jq -r '.DESIRED_REGISTRY_MB' "$path")"
    attempts="$(/usr/bin/jq -r '.ATTEMPTS' "$path")"
    mode="$(vx_harbor_provider_mode)" || return 1
    if [[ "$mode" == managed ]]; then
        if (( attempts >= VX_HARBOR_PACKAGE_MAX_ATTEMPTS )); then
            [[ "$state" == failed ]] || _vx_harbor_package_operation_update "$path" failed 'retry-limit' 0
            return 1
        fi
        observation="$(_vx_harbor_observation_json "$owner")" || {
            _vx_harbor_package_operation_update "$path" pending 'provider-unavailable' 1
            return 1
        }
        generation="$(/usr/bin/jq -r '.GENERATION' <<<"$observation")"
        observed_at="$(/usr/bin/jq -r '.OBSERVED_AT' <<<"$observation")"
        if ! declare -F vx_harbor_owner_quota_set >/dev/null \
            || ! vx_harbor_owner_quota_set "$owner" "$quota" "$generation" "$observed_at" \
                "$(/usr/bin/jq -r '.OPERATION_ID' "$path")" forward; then
            attempts=$((attempts + 1))
            error=provider-unavailable
            state=pending
            (( attempts >= VX_HARBOR_PACKAGE_MAX_ATTEMPTS )) && state=failed error=retry-limit
            _vx_harbor_package_operation_update "$path" "$state" "$error" 1
            return 1
        fi
    fi
    if ! vx_compose_shell_access_transition_complete "$owner"; then
        attempts=$((attempts + 1))
        state=pending
        error=shell-access
        (( attempts >= VX_HARBOR_PACKAGE_MAX_ATTEMPTS )) && state=failed error=retry-limit
        _vx_harbor_package_operation_update "$path" "$state" "$error" 1
        return 1
    fi
    _vx_harbor_package_operation_update "$path" converged '' 0
}
