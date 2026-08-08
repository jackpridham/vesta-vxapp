#!/usr/bin/env bash

vx_harbor_registry_usage_set() {
    local owner="$1" used_mb="$2"
    [[ "$used_mb" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    update_user_value "$owner" '$U_DOCKER_REGISTRY_MB' "$used_mb"
}

_vx_harbor_transition_key() {
    local root key secrets
    root="$(vx_harbor_root)" || return 1
    secrets="$root/secrets"
    key="$secrets/package-transition.key"
    _vx_harbor_secure_directory "$secrets" || return 1
    /usr/bin/python3 - "$key" "$secrets" <<'PY'
import os
import sys

path, directory = sys.argv[1:]
try:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit(0)
try:
    os.write(descriptor, os.urandom(32).hex().encode("ascii") + b"\n")
    os.fsync(descriptor)
finally:
    os.close(descriptor)
directory_descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
PY
    vx_harbor_secure_regular_file "$key" 0600 || return 1
    [[ "$(/usr/bin/wc -l <"$key")" == 1 ]] || return 1
    /usr/bin/grep -Eq '^[0-9a-f]{64}$' "$key" || return 1
    printf '%s\n' "$key"
}

_vx_harbor_transition_sign() {
    local payload="$1" key
    key="$(_vx_harbor_transition_key)" || return 1
    /usr/bin/python3 - "$key" "$payload" <<'PY'
import hashlib
import hmac
import sys

with open(sys.argv[1], "rb") as key_file:
    key = key_file.read().strip()
payload = sys.argv[2].encode("ascii")
sys.stdout.write(hmac.new(key, payload, hashlib.sha256).hexdigest() + "\n")
PY
}

_vx_harbor_transition_token_create() {
    local owner="$1" mode="$2" old_quota="$3" new_quota="$4"
    local payload signature
    payload="$({ /usr/bin/printf '%s|%s|%s|%s|%s' \
        "$owner" "$mode" "$old_quota" "$new_quota" "$$"; } \
        | /usr/bin/base64 -w0)" || return 1
    signature="$(_vx_harbor_transition_sign "$payload")" || return 1
    printf '%s.%s\n' "$payload" "$signature"
}

_vx_harbor_transition_token_read() {
    local owner="$1" token="$2" payload signature expected decoded
    payload="${token%%.*}"
    signature="${token#*.}"
    [[ -n "$payload" && "$signature" != "$token" ]] || return 1
    expected="$(_vx_harbor_transition_sign "$payload")" || return 1
    [[ "$signature" == "$expected" ]] || return 1
    decoded="$(/usr/bin/base64 -d <<<"$payload")" || return 1
    IFS='|' read -r VX_HARBOR_TRANSITION_OWNER \
        VX_HARBOR_TRANSITION_MODE VX_HARBOR_TRANSITION_OLD_QUOTA \
        VX_HARBOR_TRANSITION_NEW_QUOTA VX_HARBOR_TRANSITION_PID <<<"$decoded"
    [[ "$VX_HARBOR_TRANSITION_OWNER" == "$owner" \
        && "$VX_HARBOR_TRANSITION_PID" == "$$" ]]
}

_vx_harbor_observed_owner_quota() {
    local owner="$1" path
    path="$(vx_harbor_root)/observations/$owner.json"
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -er '.USED_MB | select(type == "number" and floor == . and . >= 0)' \
        "$path" 2>/dev/null
}

_vx_harbor_current_owner_quota() {
    local owner="$1" path
    path="$(vx_harbor_owner_state_path "$owner")" || return 1
    vx_harbor_secure_regular_file "$path" 0600 || return 1
    /usr/bin/jq -er '.QUOTA_MB | select(. == "unlimited" or
        (type == "number" and floor == . and . >= 0))' "$path" 2>/dev/null
}

_vx_harbor_transition_quota_apply() {
    declare -F vx_harbor_owner_quota_set >/dev/null || return 1
    vx_harbor_owner_quota_set "$1" "$2"
}

vx_harbor_package_transition_prepare() {
    local owner="$1" new_quota="$2" mode used old_quota token
    [[ "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == shared \
        || "${VX_HARBOR_PROVIDER_LOCK_MODE:-}" == exclusive ]] || return 1
    [[ "$new_quota" == unlimited \
        || "$new_quota" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    mode="$(vx_harbor_provider_mode)" || return 1
    if [[ "$mode" == managed ]]; then
        old_quota="$(_vx_harbor_current_owner_quota "$owner")" || return 1
        used="$(_vx_harbor_observed_owner_quota "$owner")" || return 1
        if [[ "$new_quota" != unlimited ]] && (( 10#$new_quota < 10#$used )); then
            return 1
        fi
    else
        old_quota=0
    fi
    token="$(_vx_harbor_transition_token_create \
        "$owner" "$mode" "$old_quota" "$new_quota")" || return 1
    if [[ "$mode" == managed ]] \
        && ! _vx_harbor_transition_quota_apply "$owner" "$new_quota"; then
        _vx_harbor_transition_quota_apply "$owner" "$old_quota" || :
        return 1
    fi
    printf '%s\n' "$token"
}

vx_harbor_package_transition_commit() {
    local owner="$1" token="$2"
    _vx_harbor_transition_token_read "$owner" "$token" || return 1
    [[ "$VX_HARBOR_TRANSITION_MODE" == disabled ]] && return 0
    [[ "$VX_HARBOR_TRANSITION_MODE" == managed ]] || return 1
}

vx_harbor_package_transition_rollback() {
    local owner="$1" token="$2"
    _vx_harbor_transition_token_read "$owner" "$token" || return 1
    [[ "$VX_HARBOR_TRANSITION_MODE" == disabled ]] && return 0
    [[ "$VX_HARBOR_TRANSITION_MODE" == managed ]] || return 1
    _vx_harbor_transition_quota_apply \
        "$owner" "$VX_HARBOR_TRANSITION_OLD_QUOTA"
}
