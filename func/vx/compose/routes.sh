#!/usr/bin/env bash

vx_compose_routes_path() {
    printf '%s/data/users/%s/docker-projects/%s/routes.conf\n' \
        "$VESTA" "$1" "$2"
}

vx_compose_routes_candidate_path() {
    printf '%s/data/users/%s/docker-projects/%s/runtime/routes.pending.json\n' \
        "$VESTA" "$1" "$2"
}

vx_compose_routes_desired_path() {
    local candidate

    candidate="$(vx_compose_routes_candidate_path "$1" "$2")"
    if [[ -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
    else
        vx_compose_routes_path "$1" "$2"
    fi
}

vx_compose_routes_lock_acquire() {
    local owner="$1"
    local lock_root lock_path

    lock_root="$(vx_compose_projects_root "$owner")/.locks"
    lock_path="$lock_root/.routes.lock"
    install -d -m 0750 "$lock_root"
    exec {VX_COMPOSE_ROUTES_LOCK_FD}>"$lock_path"
    chmod 0640 "$lock_path"
    flock -x "$VX_COMPOSE_ROUTES_LOCK_FD"
}

vx_compose_routes_lock_release() {
    if [[ -n "${VX_COMPOSE_ROUTES_LOCK_FD:-}" ]]; then
        flock -u "$VX_COMPOSE_ROUTES_LOCK_FD"
        exec {VX_COMPOSE_ROUTES_LOCK_FD}>&-
        unset VX_COMPOSE_ROUTES_LOCK_FD
    fi
}

vx_compose_route_domain_is_valid() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}[A-Za-z0-9]$
        && "$1" == *.* && "$1" != *..* ]]
}

vx_compose_route_path_is_valid() {
    [[ "$1" == /*
        && "$1" != *..*
        && "$1" != *'//'*
        && "$1" != *$'\n'*
        && "$1" =~ ^/[A-Za-z0-9._~!%+:,@/-]*$ ]]
}

vx_compose_route_domain_is_owned() {
    local owner="$1"
    local domain="$2"
    local web_conf="$VESTA/data/users/$owner/web.conf"

    [[ -f "$web_conf" && ! -L "$web_conf" ]] || return 1
    grep -Fq "DOMAIN='$domain'" "$web_conf"
}

vx_compose_route_probe_url() {
    local owner="$1"
    local domain="$2"
    local configured="${VX_COMPOSE_ROUTE_PROBE_URL:-}"
    local web_conf="$VESTA/data/users/$owner/web.conf"
    local ip

    if [[ -n "$configured" ]]; then
        printf '%s\n' "$configured"
        return
    fi
    ip="$(awk -v domain="$domain" '
        index($0, "DOMAIN=\047" domain "\047") {
            if (match($0, /IP=\047[0-9A-Fa-f:.]+\047/)) {
                value = substr($0, RSTART + 4, RLENGTH - 5)
                print value
                exit
            }
        }
    ' "$web_conf")"
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] \
        || {
            vx_compose_error 'Compose route domain has no usable local IP'
            return 1
        }
    if [[ "$ip" == *:* ]]; then
        printf 'http://[%s]\n' "$ip"
    else
        printf 'http://%s\n' "$ip"
    fi
}

vx_compose_domain_route_project() {
    local owner="$1"
    local domain="$2"
    local projects_root project_root routes_file

    projects_root="$VESTA/data/users/$owner/docker-projects"
    [[ -d "$projects_root" ]] || return 1
    for project_root in "$projects_root"/*; do
        [[ -d "$project_root" ]] || continue
        routes_file="$project_root/routes.conf"
        [[ -f "$routes_file" ]] || continue
        if jq -e --arg domain "$domain" '.[$domain] != null' \
            "$routes_file" >/dev/null; then
            basename -- "$project_root"
            return
        fi
    done
    return 1
}

vx_compose_domain_desired_route_project() {
    local owner="$1"
    local domain="$2"
    local projects_root project_root routes_file

    projects_root="$VESTA/data/users/$owner/docker-projects"
    [[ -d "$projects_root" ]] || return 1
    for project_root in "$projects_root"/*; do
        [[ -d "$project_root" ]] || continue
        for routes_file in \
            "$project_root/routes.conf" \
            "$project_root/runtime/routes.pending.json"; do
            [[ -f "$routes_file" ]] || continue
            if jq -e --arg domain "$domain" '.[$domain] != null' \
                "$routes_file" >/dev/null; then
                basename -- "$project_root"
                return
            fi
        done
    done
    return 1
}

vx_compose_domain_route_matches_proxy_options() {
    local owner="$1"
    local domain="$2"
    local mode="$3"
    local target="$4"
    local profile="$5"
    local preserve_host="$6"
    local timeout="$7"
    local headers="$8"
    local path="${9:-/}"
    local project routes_file

    project="$(vx_compose_domain_route_project "$owner" "$domain")" || return 1
    routes_file="$(vx_compose_routes_path "$owner" "$project")"
    [[ "$mode" == proxy
        && "$profile" == application
        && "$preserve_host" == yes
        && "$timeout" == 60
        && -z "$headers" ]] || return 1
    jq -e \
        --arg domain "$domain" \
        --arg target "$target" \
        --arg path "$path" '
            .[$domain] as $route
            | ($route.SCHEME + "://127.0.0.1:"
                + ($route.HOST_PORT | tostring)) == $target
            and $route.PATH == $path
        ' "$routes_file" >/dev/null
}

vx_compose_route_resolve_host_port() {
    local canonical_json="$1"
    local service="$2"
    local container_port="$3"

    jq -er \
        --arg service "$service" \
        --argjson target "$container_port" '
            [
                .services[$service].ports[]
                | select(
                    .target == $target
                    and (.protocol // "tcp") == "tcp"
                    and .host_ip == "127.0.0.1"
                )
                | (.published | tonumber)
            ]
            | select(length == 1)
            | .[0]
        ' "$canonical_json"
}

vx_compose_routes_validate_file() {
    local owner="$1"
    local project="$2"
    local canonical_json="$3"
    local routes_file="$4"
    local domain service container_port host_port scheme path resolved_port

    [[ -f "$routes_file" && ! -L "$routes_file" ]] \
        || {
            vx_compose_error 'Compose route metadata is not a regular file'
            return 1
        }
    jq -e \
        --arg owner "$owner" \
        --arg project "$project" '
            type == "object"
            and all(to_entries[];
                .key == .value.DOMAIN
                and .value.OWNER == $owner
                and .value.PROJECT == $project
                and (.value.SERVICE | type == "string")
                and (.value.CONTAINER_PORT | type == "number")
                and (.value.HOST_PORT | type == "number")
                and (.value.SCHEME | type == "string")
                and (.value.PATH | type == "string")
            )
        ' "$routes_file" >/dev/null \
        || {
            vx_compose_error 'Compose route metadata structure is invalid'
            return 1
        }
    while IFS=$'\t' read -r \
        domain service container_port host_port scheme path; do
        if ! vx_compose_route_domain_is_valid "$domain" \
            || ! vx_compose_route_domain_is_owned "$owner" "$domain" \
            || ! [[ "$service" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$
                && "$container_port" =~ ^[0-9]+$
                && "$container_port" -ge 1
                && "$container_port" -le 65535
                && "$host_port" =~ ^[0-9]+$
                && "$host_port" -ge 1
                && "$host_port" -le 65535
                && ( "$scheme" == http || "$scheme" == https ) ]] \
            || ! vx_compose_route_path_is_valid "$path"; then
            vx_compose_error 'Compose route metadata value is invalid'
            return 1
        fi
        resolved_port="$(vx_compose_route_resolve_host_port \
            "$canonical_json" "$service" "$container_port")" \
            || {
                vx_compose_error 'Compose route target is not published locally'
                return 1
            }
        [[ "$resolved_port" == "$host_port" ]] \
            || {
                vx_compose_error 'Compose route host port does not match the project'
                return 1
            }
    done < <(jq -r '
        to_entries[]
        | [
            .key,
            .value.SERVICE,
            (.value.CONTAINER_PORT | tostring),
            (.value.HOST_PORT | tostring),
            .value.SCHEME,
            .value.PATH
        ]
        | @tsv
    ' "$routes_file")
}

vx_compose_route_add() {
    local owner="$1"
    local project="$2"
    local domain="$3"
    local service="$4"
    local container_port="$5"
    local scheme="${6:-http}"
    local route_path="${7:-/}"
    local root canonical routes_file host_port temp_file linked_project

    vx_compose_require_project "$owner" "$project" || return 1
    if ! vx_compose_route_domain_is_valid "$domain" \
        || ! vx_compose_route_domain_is_owned "$owner" "$domain"; then
        vx_compose_error 'Compose route domain is not owned by the project owner'
        return 1
    fi
    [[ "$service" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$
        && "$container_port" =~ ^[0-9]+$
        && "$container_port" -ge 1
        && "$container_port" -le 65535
        && ( "$scheme" == http || "$scheme" == https ) ]] \
        || {
            vx_compose_error 'invalid Compose HTTP route target'
            return 1
        }
    vx_compose_route_path_is_valid "$route_path" \
        || {
            vx_compose_error 'invalid Compose HTTP route path'
            return 1
        }
    vx_compose_lock_acquire "$owner" "$project" || return 1
    vx_compose_routes_lock_acquire "$owner"
    linked_project="$(
        vx_compose_domain_desired_route_project "$owner" "$domain" 2>/dev/null
    )" || true
    if [[ -n "$linked_project" && "$linked_project" != "$project" ]]; then
        vx_compose_routes_lock_release
        vx_compose_lock_release
        vx_compose_error \
            "Compose route domain is already managed by project $linked_project"
        return 1
    fi
    root="$(vx_compose_project_root "$owner" "$project")"
    canonical="$root/runtime/canonical.json"
    host_port="$(vx_compose_route_resolve_host_port \
        "$canonical" "$service" "$container_port")" \
        || {
            vx_compose_routes_lock_release
            vx_compose_lock_release
            vx_compose_error \
                'Compose route requires one localhost published TCP target'
            return 1
        }
    routes_file="$(vx_compose_routes_desired_path "$owner" "$project")"
    [[ -f "$routes_file" ]] || printf '{}\n' >"$routes_file"
    local candidate_file
    candidate_file="$(vx_compose_routes_candidate_path "$owner" "$project")"
    temp_file="$(mktemp "$root/.routes.XXXXXX")"
    jq -S \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg domain "$domain" \
        --arg service "$service" \
        --argjson container_port "$container_port" \
        --argjson host_port "$host_port" \
        --arg scheme "$scheme" \
        --arg path "$route_path" '
            .[$domain] = {
                OWNER: $owner,
                PROJECT: $project,
                DOMAIN: $domain,
                SERVICE: $service,
                CONTAINER_PORT: $container_port,
                HOST_PORT: $host_port,
                SCHEME: $scheme,
                PATH: $path
            }
        ' "$routes_file" >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f -- "$temp_file" "$candidate_file"
    vx_compose_audit "$root" route-add succeeded
    vx_compose_routes_lock_release
    vx_compose_lock_release
}

vx_compose_route_delete() {
    local owner="$1"
    local project="$2"
    local domain="$3"
    local root routes_file temp_file

    vx_compose_require_project "$owner" "$project" || return 1
    vx_compose_route_domain_is_valid "$domain" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    vx_compose_routes_lock_acquire "$owner"
    root="$(vx_compose_project_root "$owner" "$project")"
    routes_file="$(vx_compose_routes_desired_path "$owner" "$project")"
    if [[ ! -f "$routes_file" ]]; then
        vx_compose_routes_lock_release
        vx_compose_lock_release
        return 0
    fi
    local candidate_file
    candidate_file="$(vx_compose_routes_candidate_path "$owner" "$project")"
    temp_file="$(mktemp "$root/.routes.XXXXXX")"
    jq -S --arg domain "$domain" 'del(.[$domain])' \
        "$routes_file" >"$temp_file"
    chmod 0640 "$temp_file"
    mv -f -- "$temp_file" "$candidate_file"
    vx_compose_audit "$root" route-delete succeeded
    vx_compose_routes_lock_release
    vx_compose_lock_release
}

vx_compose_route_list_json() {
    local owner="$1"
    local project="$2"
    local routes_file

    vx_compose_require_project "$owner" "$project" || return 1
    routes_file="$(vx_compose_routes_desired_path "$owner" "$project")"
    [[ -f "$routes_file" ]] || {
        printf '{}\n'
        return
    }
    jq -S . "$routes_file"
}

vx_compose_routes_proxy_configtest() {
    local command="${VX_COMPOSE_ROUTE_CONFIGTEST_COMMAND:-}"
    local service_bin proxy_system="${PROXY_SYSTEM:-nginx}"

    if [[ -n "$command" ]]; then
        [[ -x "$command" ]] && "$command"
        return
    fi
    service_bin="$(command -v service)" || return 1
    "$service_bin" "$proxy_system" configtest
}

vx_compose_routes_proxy_reload() {
    local command="${VX_COMPOSE_ROUTE_RELOAD_COMMAND:-}"
    local service_bin proxy_system="${PROXY_SYSTEM:-nginx}"

    if [[ -n "$command" ]]; then
        [[ -x "$command" ]] && "$command"
        return
    fi
    service_bin="$(command -v service)" || return 1
    "$service_bin" "$proxy_system" reload
}

vx_compose_routes_apply_unlocked() {
    local owner="$1"
    local project="$2"
    local routes_file active_file candidate_file route_command probe_command probe_url
    local domain target path web_conf snapshot_root domain_list
    local conf snapshot_conf result=0

    active_file="$(vx_compose_routes_path "$owner" "$project")"
    candidate_file="$(vx_compose_routes_candidate_path "$owner" "$project")"
    routes_file="$(vx_compose_routes_desired_path "$owner" "$project")"
    [[ -f "$routes_file" ]] || return 0
    vx_compose_routes_validate_file \
        "$owner" "$project" \
        "$(vx_compose_project_root "$owner" "$project")/runtime/canonical.json" \
        "$routes_file" || return 1
    if jq -e 'length == 0' "$routes_file" >/dev/null \
        && {
            [[ ! -f "$active_file" ]] \
                || jq -e 'length == 0' "$active_file" >/dev/null
        }; then
        if [[ -f "$candidate_file" ]]; then
            install -m 0640 "$candidate_file" "$active_file"
            rm -f -- "$candidate_file"
        fi
        return 0
    fi
    route_command="${VX_COMPOSE_ROUTE_COMMAND:-$VESTA/bin/v-change-web-domain-proxy-options}"
    probe_command="${VX_COMPOSE_ROUTE_PROBE_COMMAND:-$(command -v curl)}"
    [[ -x "$route_command" && -x "$probe_command" ]] \
        || {
            vx_compose_error 'Compose route adapter or probe is unavailable'
            return 1
        }
    web_conf="$VESTA/data/users/$owner/web.conf"
    snapshot_root="$(mktemp -d)"
    install -d -m 0700 "$snapshot_root/generated"
    install -m 0600 "$web_conf" "$snapshot_root/web.conf"
    domain_list="$snapshot_root/domains"
    {
        jq -r 'keys[]' "$routes_file"
        [[ -f "$active_file" ]] && jq -r 'keys[]' "$active_file"
    } | sort -u >"$domain_list"
    while IFS= read -r domain; do
        for conf in \
            "$HOMEDIR/$owner/conf/web/$domain.nginx.conf" \
            "$HOMEDIR/$owner/conf/web/$domain.nginx.ssl.conf"; do
            [[ -f "$conf" && ! -L "$conf" ]] || continue
            install -m 0600 "$conf" \
                "$snapshot_root/generated/$(basename -- "$conf")"
        done
    done <"$domain_list"
    if [[ -f "$active_file" ]]; then
        while IFS= read -r domain; do
            if ! jq -e --arg domain "$domain" '.[$domain] != null' \
                "$routes_file" >/dev/null; then
                vx_compose_route_unapply_domain \
                    "$owner" "$project" "$domain" no || {
                        result=1
                        break
                    }
            fi
        done < <(jq -r 'keys[]' "$active_file")
    fi
    while [[ "$result" -eq 0 ]] && IFS=$'\t' read -r domain target path; do
        VX_COMPOSE_SYNC_ROUTE=yes VX_COMPOSE_ROUTE_PATH="$path" "$route_command" \
            "$owner" "$domain" proxy "$target" application yes 60 '' no \
            >/dev/null \
            || {
                result=1
                break
            }
    done < <(jq -r '
        to_entries[]
        | [
            .key,
            (.value.SCHEME + "://127.0.0.1:" + (.value.HOST_PORT | tostring)),
            .value.PATH
        ]
        | @tsv
    ' "$routes_file")
    if [[ "$result" -eq 0 ]] \
        && {
            ! vx_compose_routes_proxy_configtest >/dev/null 2>&1 \
                || ! vx_compose_routes_proxy_reload >/dev/null 2>&1
        }; then
        result=1
    fi
    while [[ "$result" -eq 0 ]] && IFS=$'\t' read -r domain path; do
        probe_url="$(vx_compose_route_probe_url "$owner" "$domain")" \
            || {
                result=1
                break
            }
        "$probe_command" --fail --silent --show-error \
            --retry 5 --retry-delay 1 --retry-all-errors \
            --connect-timeout 3 --max-time 15 \
            --header "Host: $domain" "$probe_url$path" >/dev/null \
            || {
                result=1
                break
            }
    done < <(jq -r '
        to_entries[]
        | [.key, .value.PATH]
        | @tsv
    ' "$routes_file")
    if [[ "$result" -ne 0 ]]; then
        install -m 0640 "$snapshot_root/web.conf" "$web_conf"
        while IFS= read -r domain; do
            for conf in \
                "$HOMEDIR/$owner/conf/web/$domain.nginx.conf" \
                "$HOMEDIR/$owner/conf/web/$domain.nginx.ssl.conf"; do
                snapshot_conf="$snapshot_root/generated/$(basename -- "$conf")"
                if [[ -f "$snapshot_conf" ]]; then
                    install -m 0640 "$snapshot_conf" "$conf"
                else
                    rm -f -- "$conf"
                fi
            done
        done <"$domain_list"
        vx_compose_routes_proxy_configtest >/dev/null 2>&1 || true
        vx_compose_routes_proxy_reload >/dev/null 2>&1 || true
        rm -rf -- "$snapshot_root"
        vx_compose_error 'Compose route rendering, reload, or Host-header probe failed'
        return 1
    fi
    if [[ -f "$candidate_file" ]]; then
        install -m 0640 "$candidate_file" "$active_file"
        rm -f -- "$candidate_file"
    fi
    rm -rf -- "$snapshot_root"
}

vx_compose_routes_apply() {
    local owner="$1"
    local project="$2"
    local result

    vx_compose_routes_lock_acquire "$owner"
    if vx_compose_routes_apply_unlocked "$owner" "$project"; then
        result=0
    else
        result=$?
    fi
    vx_compose_routes_lock_release
    return "$result"
}

vx_compose_route_unapply_domain() {
    local owner="$1"
    local project="$2"
    local domain="$3"
    local restart="${4:-yes}"
    local routes_file web_conf target delete_command line

    routes_file="$(vx_compose_routes_path "$owner" "$project")"
    [[ -f "$routes_file" ]] || return 0
    target="$(jq -er \
        --arg domain "$domain" '
            .[$domain]
            | .SCHEME + "://127.0.0.1:" + (.HOST_PORT | tostring)
        ' "$routes_file" 2>/dev/null)" || return 0
    web_conf="$VESTA/data/users/$owner/web.conf"
    [[ -f "$web_conf" ]] || return 0
    line="$(grep -F "DOMAIN='$domain'" "$web_conf" 2>/dev/null)" || return 0
    [[ "$line" == *"PROXY='vx-proxy'"*
        && "$line" == *"PROXY_TARGET='$target'"* ]] || return 0
    delete_command="${VX_COMPOSE_ROUTE_DELETE_COMMAND:-$VESTA/bin/v-delete-web-domain-proxy}"
    [[ -x "$delete_command" ]] \
        || {
            vx_compose_error 'Compose route delete adapter is unavailable'
            return 1
        }
    VX_COMPOSE_SYNC_ROUTE=yes "$delete_command" \
        "$owner" "$domain" "$restart" >/dev/null \
        || {
            vx_compose_error 'Compose route removal failed'
            return 1
        }
}

vx_compose_routes_clear_unlocked() {
    local owner="$1"
    local project="$2"
    local routes_file domain

    routes_file="$(vx_compose_routes_path "$owner" "$project")"
    [[ -f "$routes_file" ]] || return 0
    while IFS= read -r domain; do
        vx_compose_route_unapply_domain \
            "$owner" "$project" "$domain" || return 1
    done < <(jq -r 'keys[]' "$routes_file")
}

vx_compose_routes_clear() {
    local owner="$1"
    local project="$2"
    local result

    vx_compose_routes_lock_acquire "$owner"
    if vx_compose_routes_clear_unlocked "$owner" "$project"; then
        result=0
    else
        result=$?
    fi
    vx_compose_routes_lock_release
    return "$result"
}
