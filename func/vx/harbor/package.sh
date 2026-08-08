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
    _vx_harbor_authority_schema_validate package-operation "$path" "$(basename "$path" .json)"
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
         DESIRED_REGISTRY_MB:$quota,
         STATE:"pending",ATTEMPTS:0,LAST_ERROR:null,CREATED_AT:$now,UPDATED_AT:$now}' >"$source" \
        && vx_harbor_json_write_atomic "$path" "$source"
    result=$?
    /usr/bin/rm -f -- "$source"
    (( result == 0 )) || return "$result"
    printf '%s\n' "$operation_id"
}

_vx_harbor_package_quota_from_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    /usr/bin/awk -F"'" '
      $1 == "PACKAGE=" && NF == 3 { package=$2; packages++ }
      $1 == "DOCKER_REGISTRY_MB=" && NF == 3 { quota=$2; quotas++ }
      END {
        if (packages != 1 || quotas != 1 ||
            package !~ /^[A-Za-z0-9._-]+$/ ||
            quota !~ /^(0|[1-9][0-9]*|unlimited)$/) exit 1
        print package "\t" quota
      }
    ' "$path"
}

_vx_harbor_user_desired_package_quota() {
    local owner="$1"
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || return 1
    _vx_harbor_package_quota_from_file "$VESTA/data/users/$owner/user.conf"
}

_vx_harbor_package_transition_checkpoint() {
    :
}

vx_harbor_package_transition_install_desired() {
    local owner="$1" package="$2" quota="$3" staged="$4" destination="$5"
    local operation_id directory
    [[ "$destination" == "$VESTA/data/users/$owner/user.conf" \
        && -f "$destination" && ! -L "$destination" \
        && -f "$staged" && ! -L "$staged" \
        && "$(dirname -- "$staged")" == "$(dirname -- "$destination")" ]] || return 1
    [[ "$(_vx_harbor_package_quota_from_file "$staged")" \
        == "$package"$'\t'"$quota" ]] || return 1
    _vx_harbor_fsync "$staged" || return 1
    operation_id="$(vx_harbor_package_transition_publish "$owner" "$package" "$quota")" \
        || return 1
    _vx_harbor_package_transition_checkpoint operation-published || return 1
    /usr/bin/mv -fT -- "$staged" "$destination" || return 1
    _vx_harbor_fsync "$destination" || return 1
    directory="$(dirname -- "$destination")" || return 1
    _vx_harbor_fsync "$directory" || return 1
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

vx_harbor_owner_quota_set() {
    local owner="$1" quota="$2" generation="$3" observed_at="$4"
    local operation_id="$5" intent="$6" operation owner_state quota_id
    local observation storage
    [[ "$owner" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ \
        && "$quota" =~ ^(0|[1-9][0-9]*|unlimited)$ \
        && "$generation" =~ ^[A-Za-z0-9._:-]{1,128}$ \
        && "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ \
        && "$operation_id" =~ ^[a-f0-9]{32}$ && "$intent" == forward ]] || return 1
    operation="$(vx_harbor_operation_path "$owner")" || return 1
    vx_harbor_package_operation_validate "$operation" || return 1
    /usr/bin/jq -e --arg owner "$owner" --arg quota "$quota" \
      --arg generation "$generation" --arg operation_id "$operation_id" '
      .OWNER==$owner and .DESIRED_REGISTRY_MB==$quota and
      .OPERATION_ID==$operation_id and .STATE=="pending"' \
      "$operation" >/dev/null || return 1
    observation="$(_vx_harbor_observation_json "$owner")" || return 1
    /usr/bin/jq -e --arg generation "$generation" --arg observed_at "$observed_at" \
      '.GENERATION==$generation and .OBSERVED_AT==$observed_at' \
      <<<"$observation" >/dev/null || return 1
    owner_state="$(vx_harbor_owner_state_path "$owner")" || return 1
    vx_harbor_owner_state_validate "$owner_state" || return 1
    quota_id="$(/usr/bin/jq -er --arg owner "$owner" '
      select(.SCHEMA==1 and .OWNER==$owner) |
      .QUOTA_ID | select(type=="number" and floor==. and .>=1)' \
      "$owner_state" 2>/dev/null)" || return 1
    if [[ "$quota" == unlimited ]]; then
        storage=-1
    else
        if (( ${#quota} > 13 )) \
            || (( ${#quota} == 13 && 10#$quota > 8796093022207 )); then
            return 1
        fi
        storage=$((10#$quota * 1024 * 1024))
        (( storage >= 0 )) || return 1
    fi
    vx_harbor_api_quota_set_bytes "$quota_id" "$storage"
}

vx_harbor_package_transition_recover() {
    local owner="$1" path state attempts package quota mode observation generation observed_at error desired
    path="$(vx_harbor_operation_path "$owner")" || return 1
    [[ -e "$path" ]] || return 0
    vx_harbor_package_operation_validate "$path" || return 1
    state="$(/usr/bin/jq -r '.STATE' "$path")"
    [[ "$state" != converged ]] || return 0
    package="$(/usr/bin/jq -r '.DESIRED_PACKAGE' "$path")"
    quota="$(/usr/bin/jq -r '.DESIRED_REGISTRY_MB' "$path")"
    attempts="$(/usr/bin/jq -r '.ATTEMPTS' "$path")"
    desired="$(_vx_harbor_user_desired_package_quota "$owner" 2>/dev/null || :)"
    if [[ "$desired" != "$package"$'\t'"$quota" ]]; then
        _vx_harbor_package_operation_update "$path" failed 'desired-state-mismatch' 0
        return 1
    fi
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
