#!/usr/bin/env bash

vx_compose_ingress_published_endpoints_json() {
    local owner="$1"
    local project="$2"
    local root

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    jq -c '
        def expanded_ports:
            tostring as $value
            | if ($value | test("^[0-9]+$")) then
                [($value | tonumber)]
              elif ($value | test("^[0-9]+-[0-9]+$")) then
                ($value
                    | capture("^(?<first>[0-9]+)-(?<last>[0-9]+)$")
                    | (.first | tonumber) as $first
                    | (.last | tonumber) as $last
                    | if $first >= 1
                        and $last <= 65535
                        and $last >= $first
                        and ($last - $first) <= 1023
                      then [range($first; $last + 1)]
                      else []
                      end)
              else []
              end;
        [
            .services
            | to_entries[]
            | .key as $service
            | .value.ports[]?
            | select(
                type == "object"
                and ((.protocol // "tcp") == "tcp")
                and (.host_ip | type == "string")
            )
            | (.published | expanded_ports[]) as $published
            | select($published >= 1 and $published <= 65535)
            | {
                SERVICE: $service,
                HOST_IP: .host_ip,
                HOST_PORT: $published
            }
        ]
    ' "$root/runtime/canonical.json"
}

vx_compose_ingress_actor_is_valid() {
    local actor="$1"

    [[ "$actor" == admin ]] && return 0
    vx_compose_owner_is_valid "$actor" \
        && [[ -d "$VESTA/data/users/$actor" ]]
}

vx_compose_ingress_actor_can_view_metadata() {
    local actor="$1"
    local owner="$2"
    local project="$3"

    vx_compose_ingress_actor_is_valid "$actor" || return 1
    [[ "$actor" == admin ]] && return 0
    vx_compose_actor_has_project_capability \
        "$actor" "$owner" "$project" view-ingress-consumers
}

vx_compose_ingress_header_names_json() {
    local stored="$1"
    local header name
    local names='[]'

    while IFS= read -r header; do
        [[ -n "$header" ]] || continue
        name="${header%%:*}"
        [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        names="$(jq -c --arg name "$name" '. + [$name] | unique' <<<"$names")"
    done <<<"${stored//||/$'\n'}"
    printf '%s\n' "$names"
}

vx_compose_ingress_render_freshness() {
    local owner="$1"
    local domain="$2"
    local source="$3"
    local rendered

    for rendered in \
        "$HOMEDIR/$owner/conf/web/$domain.nginx.conf" \
        "$HOMEDIR/$owner/conf/web/snginx.$domain.conf"; do
        if [[ -f "$rendered" && ! -L "$rendered"
            && "$(stat -c %Y -- "$rendered" 2>/dev/null)" =~ ^[0-9]+$
            && "$(stat -c %Y -- "$source" 2>/dev/null)" =~ ^[0-9]+$
            && "$(stat -c %Y -- "$rendered")" \
                -ge "$(stat -c %Y -- "$source")" ]]; then
            printf '%s\n' current
            return
        fi
    done
    printf '%s\n' stale
}

vx_compose_ingress_backend_health() {
    local target="$1"
    local curl_bin

    curl_bin="$(command -v curl)" || {
        printf '%s\n' unavailable
        return
    }
    if env -i PATH="$VX_COMPOSE_SAFE_PATH" \
        "$curl_bin" --silent --show-error --output /dev/null \
        --max-time 2 --connect-timeout 1 --fail "$target/" \
        >/dev/null 2>&1; then
        printf '%s\n' healthy
    else
        printf '%s\n' unhealthy
    fi
}

vx_compose_ingress_consumers_json() {
    local owner="$1"
    local project="$2"
    local endpoints user_root consumer_owner web_conf line
    local target_scheme target_host target_port normalized_target path scheme
    local header_names freshness health records='[]'

    endpoints="$(vx_compose_ingress_published_endpoints_json \
        "$owner" "$project")" || return 1

    for user_root in "$VESTA/data/users"/*; do
        [[ -d "$user_root" ]] || continue
        consumer_owner="$(basename -- "$user_root")"
        vx_compose_owner_is_valid "$consumer_owner" || continue
        web_conf="$user_root/web.conf"
        [[ -f "$web_conf" && ! -L "$web_conf" ]] || continue
        while IFS= read -r line; do
            unset DOMAIN PROXY PROXY_MODE PROXY_TARGET PROXY_HEADERS \
                PROXY_PATH SSL
            parse_object_kv_list_non_eval "$line"
            [[ "${PROXY:-}" == vx-proxy
                && "${PROXY_MODE:-proxy}" == proxy
                && "${DOMAIN:-}" =~ ^[A-Za-z0-9.-]+$
                && "${PROXY_TARGET:-}" =~ ^(https?)://(\[[0-9A-Fa-f:]+\]|([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]{1,5})/?$ ]] \
                || continue
            target_scheme="${BASH_REMATCH[1]}"
            target_host="${BASH_REMATCH[2]}"
            target_host="${target_host#[}"
            target_host="${target_host%]}"
            target_port="${BASH_REMATCH[4]}"
            ((10#$target_port >= 1 && 10#$target_port <= 65535)) \
                || continue
            jq -e \
                --arg host "$target_host" \
                --argjson port "$((10#$target_port))" \
                'any(.[]; .HOST_IP == $host and .HOST_PORT == $port)' \
                <<<"$endpoints" >/dev/null || continue

            normalized_target="$target_scheme://"
            [[ "$target_host" != *:* ]] \
                || normalized_target+='['
            normalized_target+="$target_host"
            [[ "$target_host" != *:* ]] \
                || normalized_target+=']'
            normalized_target+=":$((10#$target_port))"
            path="${PROXY_PATH:-/}"
            [[ "$path" =~ ^/[A-Za-z0-9._~!%+:,@/-]*$
                && "$path" != *..* && "$path" != *'//'* ]] \
                || path='/'
            scheme=http
            [[ "${SSL:-no}" == yes ]] && scheme=https
            header_names="$(vx_compose_ingress_header_names_json \
                "${PROXY_HEADERS:-}")"
            unset PROXY_HEADERS
            freshness="$(vx_compose_ingress_render_freshness \
                "$consumer_owner" "$DOMAIN" "$web_conf")"
            health="$(vx_compose_ingress_backend_health "$normalized_target")"
            records="$(jq -c \
                --arg owner "$consumer_owner" \
                --arg domain "$DOMAIN" \
                --arg scheme "$scheme" \
                --arg path "$path" \
                --arg target "$normalized_target" \
                --arg health "$health" \
                --arg freshness "$freshness" \
                --argjson headers "$header_names" '
                    . + [{
                        OWNER: $owner,
                        DOMAIN: $domain,
                        SCHEME: $scheme,
                        PATH: $path,
                        TARGET: $target,
                        HEALTH: $health,
                        CONFIG_FRESHNESS: $freshness,
                        HEADER_NAMES: $headers
                    }]
                ' <<<"$records")"
        done <"$web_conf"
    done
    jq -S 'sort_by(.OWNER, .DOMAIN, .PATH)' <<<"$records"
}
