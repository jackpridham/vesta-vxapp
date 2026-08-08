#!/usr/bin/env bash

_vx_harbor_random_secret() { /usr/bin/od -An -N32 -tx1 /dev/urandom | /usr/bin/tr -d ' \n'; }

vx_harbor_runtime_credential_switch() {
    local owner="$1" origin="$2" username="$3" secret="$4" root config metadata temporary now auth host auth_file
    [[ "$origin" =~ ^https://([^/]+)$ && "$username" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ && ${#secret} -ge 16 ]] || return 1
    host="${origin#https://}"
    root="$(vx_compose_registry_root "$owner")"; vx_compose_registry_prepare "$owner" || return 1
    config="$root/config.json"; metadata="$root/registries.json"; now="$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    auth="$(printf '%s:%s' "$username" "$secret" | /usr/bin/base64 -w0)" || return 1
    auth_file="$(/usr/bin/mktemp "$root/.managed-auth.XXXXXX")" || return 1
    printf %s "$auth" >"$auth_file"; unset auth secret
    /usr/bin/chown 0:0 "$auth_file" && /usr/bin/chmod 0600 "$auth_file" || { /usr/bin/rm -f "$auth_file"; return 1; }
    temporary="$(/usr/bin/mktemp "$root/.config.XXXXXX")" || return 1
    /usr/bin/jq --arg host "$host" --rawfile auth "$auth_file" '.auths[$host]={auth:$auth}' "$config" >"$temporary" \
      && /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$config" || { /usr/bin/rm -f "$temporary" "$auth_file"; return 1; }
    /usr/bin/rm -f "$auth_file"
    temporary="$(/usr/bin/mktemp "$root/.registries.XXXXXX")" || return 1
    /usr/bin/jq -S --arg host "$host" --arg username "$username" --arg now "$now" \
      '.[$host]={REGISTRY:$host,USERNAME:$username,CREATED:(.[$host].CREATED//$now),ROTATED:$now,LAST_VALIDATION:"succeeded",MANAGED_BY:"harbor"}' "$metadata" >"$temporary" \
      && /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" \
      && /usr/bin/mv -fT "$temporary" "$metadata" || { /usr/bin/rm -f "$temporary"; return 1; }
}

vx_harbor_runtime_rotate() {
    local owner="$1" namespace="$2" origin="$3" old_id="$4" generation="$5" secret username response id
    secret="$(_vx_harbor_random_secret)" || return 1; username="$namespace-runtime-$generation"
    response="$(printf %s "$secret" | vx_harbor_api_robot_create "$namespace" "$username" pull)" || return 1
    id="$(/usr/bin/jq -er '.id' <<<"$response")" || return 1
    vx_harbor_api_robot_get "$id" >/dev/null || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    vx_harbor_runtime_credential_switch "$owner" "$origin" "$username" "$secret" || { vx_harbor_api_robot_delete "$id" >/dev/null 2>&1 || :; return 1; }
    [[ "$old_id" == null || -z "$old_id" ]] || vx_harbor_api_robot_delete "$old_id" >/dev/null || return 1
    printf '%s\t%s\n' "$id" "$username"
}

vx_harbor_runtime_revoke() {
    local owner="$1" origin="$2" id="$3" root host temporary
    [[ "$id" == null || -z "$id" ]] || vx_harbor_api_robot_disable "$id" >/dev/null || return 1
    root="$(vx_compose_registry_root "$owner")"; host="${origin#https://}"
    [[ -d "$root" ]] || return 0
    for file in config.json registries.json; do
        [[ -f "$root/$file" ]] || continue
        temporary="$(/usr/bin/mktemp "$root/.$file.XXXXXX")" || return 1
        if [[ "$file" == config.json ]]; then /usr/bin/jq --arg h "$host" 'del(.auths[$h])' "$root/$file" >"$temporary"; else /usr/bin/jq --arg h "$host" 'del(.[$h])' "$root/$file" >"$temporary"; fi
        /usr/bin/chown 0:0 "$temporary" && /usr/bin/chmod 0600 "$temporary" && /usr/bin/mv -fT "$temporary" "$root/$file" || return 1
    done
}
