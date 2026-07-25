#!/usr/bin/env bash

vx_compose_legacy_field() {
    local record="$1"
    local key="$2"

    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    if [[ "$record" =~ (^|[[:space:]])${key}=\'([^\']*)\' ]]; then
        printf '%s\n' "${BASH_REMATCH[2]}"
        return
    fi
    return 1
}

vx_compose_migration_render() {
    local owner="$1"
    local record="$2"
    local output_file="$3"
    local name image command environment mounts host_port container_port
    local restart health_type item source target
    local health_target health_interval

    name="$(vx_compose_legacy_field "$record" NAME)" || return 1
    image="$(vx_compose_legacy_field "$record" IMAGE)" || return 1
    command="$(vx_compose_legacy_field "$record" COMMAND 2>/dev/null)" \
        || command=''
    environment="$(vx_compose_legacy_field "$record" ENV 2>/dev/null)" \
        || environment=''
    mounts="$(vx_compose_legacy_field "$record" MOUNTS 2>/dev/null)" || mounts=''
    host_port="$(vx_compose_legacy_field "$record" HOST_PORT)" || return 1
    container_port="$(vx_compose_legacy_field "$record" CONTAINER_PORT)" \
        || return 1
    restart="$(vx_compose_legacy_field "$record" RESTART_POLICY 2>/dev/null)" \
        || restart=unless-stopped
    health_type="$(vx_compose_legacy_field "$record" HEALTHCHECK_TYPE 2>/dev/null)" \
        || health_type=none
    health_target="$(vx_compose_legacy_field "$record" HEALTHCHECK_TARGET 2>/dev/null)" \
        || health_target=''
    health_interval="$(vx_compose_legacy_field "$record" HEALTHCHECK_INTERVAL 2>/dev/null)" \
        || health_interval=60
    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$name" || return 1
    vx_compose_image_reference_is_valid "$image" || return 1
    [[ "$host_port" =~ ^[1-9][0-9]{0,4}$
        && "$container_port" =~ ^[1-9][0-9]{0,4}$
        && "$host_port" -le 65535
        && "$container_port" -le 65535 ]] || return 1
    if [[ "$environment" =~ (^|\|\|)([^=]*(PASSWORD|PASS|SECRET|TOKEN|KEY)[^=]*)= ]]; then
        vx_compose_error 'legacy environment contains a secret-like key'
        return 1
    fi
    {
        printf '%s\n' 'services:' "  $name:"
        printf '    image: %s\n' "$(jq -Rn --arg value "$image" '$value')"
        [[ -z "$command" ]] \
            || printf '    command: ["sh","-c",%s]\n' \
                "$(jq -Rn --arg value "$command" '$value')"
        printf '%s\n' \
            '    cap_drop: [ALL]' \
            '    security_opt: [no-new-privileges:true]' \
            '    init: true'
        printf '    restart: %s\n' "$restart"
        printf '%s\n' \
            '    cpus: "0.50"' \
            '    mem_limit: 128M' \
            '    pids_limit: 64' \
            '    deploy:' \
            '      resources:' \
            '        limits:' \
            '          cpus: "0.50"' \
            '          memory: 128M' \
            '          pids: 64' \
            '    logging:' \
            '      driver: json-file' \
            '      options:' \
            '        max-size: 10m' \
            '        max-file: "3"'
        printf '    ports: ["127.0.0.1:%s:%s"]\n' \
            "$host_port" "$container_port"
        if [[ -n "$environment" ]]; then
            printf '%s\n' '    environment:'
            while IFS= read -r item; do
                printf '      - %s\n' "$(jq -Rn --arg value "$item" '$value')"
            done < <(tr '||' '\n' <<<"$environment" | sed '/^$/d')
        fi
        if [[ -n "$mounts" ]]; then
            printf '%s\n' '    volumes:'
            while IFS= read -r item; do
                source="${item%%:*}"
                target="${item#*:}"
                [[ "$source" =~ ^[a-z0-9][a-z0-9_-]{0,63}$
                    && "$target" == /* ]] || return 1
                printf '      - %s\n' \
                    "$(jq -Rn \
                        --arg value "$HOMEDIR/$owner/docker/$name/binds/$source:$target" \
                        '$value')"
            done < <(tr '||' '\n' <<<"$mounts" | sed '/^$/d')
        fi
        case "$health_type" in
            http)
                health_target="${health_target//$host_port/$container_port}"
                printf '%s\n' \
                    '    healthcheck:'
                printf '      test: ["CMD-SHELL", %s]\n' \
                    "$(jq -Rn \
                        --arg value "wget -q -O /dev/null $health_target" \
                        '$value')"
                printf '%s\n' \
                    "      interval: ${health_interval}s" \
                    '      timeout: 5s' \
                    '      retries: 3'
                ;;
            none|docker) ;;
            *)
                vx_compose_error 'legacy healthcheck type is not representable'
                return 1
                ;;
        esac
    } >"$output_file"
    chmod 0600 "$output_file"
}

vx_compose_migrate_owner() {
    local owner="$1"
    local mode="$2"
    local conf record name temp_root compose_file candidate status='validated'
    local reports='[]' was_running=no container labels mounts item source
    local moved_sources='' auto_start domain route_path migrated_ok
    local host_port container_port validation_bind

    [[ "$mode" == dry-run || "$mode" == apply ]] || return 1
    vx_compose_require_owner "$owner" || return 1
    conf="$VESTA/data/users/$owner/docker.conf"
    [[ -f "$conf" ]] || {
        printf '[]\n'
        return
    }
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        name="$(vx_compose_legacy_field "$record" NAME)" || return 1
        temp_root="$(mktemp -d)"
        compose_file="$temp_root/compose.yaml"
        vx_compose_migration_render "$owner" "$record" "$compose_file" || {
            rm -rf -- "$temp_root"
            return 1
        }
        mounts="$(vx_compose_legacy_field "$record" MOUNTS 2>/dev/null)" \
            || mounts=''
        host_port="$(vx_compose_legacy_field "$record" HOST_PORT)" || return 1
        container_port="$(vx_compose_legacy_field "$record" CONTAINER_PORT)" \
            || return 1
        validation_bind="$temp_root/validation-binds"
        install -d -m 0750 "$validation_bind"
        if [[ -n "$mounts" ]]; then
            while IFS= read -r item; do
                source="${item%%:*}"
                install -d -m 0750 "$validation_bind/$source"
            done < <(tr '||' '\n' <<<"$mounts" | sed '/^$/d')
        fi
        candidate="$temp_root/candidate"
        VX_COMPOSE_ALLOWED_LIVE_PORT_KEY="tcp:$host_port" \
            vx_compose_prepare_candidate \
                "$owner" "$name" "$compose_file" "$candidate" standard \
                no "$validation_bind" || {
                    rm -rf -- "$temp_root"
                    return 1
                }
        if [[ "$mode" == apply ]]; then
            container="$(vx_compose_legacy_field "$record" CTN_NAME)" || return 1
            labels="$("$(vx_compose_docker_bin)" inspect "$container" --format \
                '{{index .Config.Labels "vx.managed"}}|{{index .Config.Labels "vx.user"}}|{{index .Config.Labels "vx.name"}}' \
                2>/dev/null)" || return 1
            [[ "$labels" == "yes|$owner|$name" ]] \
                || {
                    vx_compose_error 'legacy container ownership labels mismatch'
                    return 1
                }
            if "$(vx_compose_docker_bin)" inspect "$container" \
                --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
                was_running=yes
                "$(vx_compose_docker_bin)" stop "$container" >/dev/null || return 1
            else
                was_running=no
            fi
            moved_sources=''
            if [[ -n "$mounts" ]]; then
                install -d -m 0750 "$HOMEDIR/$owner/docker/$name/binds"
                while IFS= read -r item; do
                    source="${item%%:*}"
                    if [[ -d "$HOMEDIR/$owner/docker/$name/$source"
                        && ! -e "$HOMEDIR/$owner/docker/$name/binds/$source" ]]; then
                        mv -- \
                            "$HOMEDIR/$owner/docker/$name/$source" \
                            "$HOMEDIR/$owner/docker/$name/binds/$source"
                        moved_sources+="$source "
                    fi
                done < <(tr '||' '\n' <<<"$mounts" | sed '/^$/d')
            fi
            auto_start="$(vx_compose_legacy_field "$record" AUTO_START 2>/dev/null)" \
                || auto_start=yes
            domain="$(vx_compose_legacy_field "$record" DOMAIN 2>/dev/null)" \
                || domain=''
            route_path="$(vx_compose_legacy_field "$record" ROUTE_PATH 2>/dev/null)" \
                || route_path=''
            migrated_ok=no
            if vx_compose_store_new \
                "$owner" "$name" standard "$candidate"; then
                if [[ "$auto_start" == yes ]]; then
                    vx_compose_deploy "$owner" "$name" && migrated_ok=yes
                else
                    vx_compose_update_state "$owner" "$name" stopped \
                        && migrated_ok=yes
                fi
                if [[ "$migrated_ok" == yes && -n "$domain" ]]; then
                    vx_compose_route_add \
                        "$owner" "$name" "$domain" "$name" \
                        "$container_port" http "${route_path:-/}" \
                        || migrated_ok=no
                fi
            fi
            if [[ "$migrated_ok" == yes ]]; then
                "$(vx_compose_docker_bin)" rm "$container" >/dev/null || {
                    vx_compose_error 'legacy container removal failed'
                    migrated_ok=no
                }
            fi
            if [[ "$migrated_ok" == yes ]]; then
                printf '%s MIGRATED_PROJECT=%q MIGRATED_AT=%q\n' \
                    "$record" "$name" "$(vx_compose_now)" \
                    >>"$VESTA/data/users/$owner/docker-migrated.conf"
                chmod 0600 "$VESTA/data/users/$owner/docker-migrated.conf"
                awk -v exact="$record" '$0 != exact' "$conf" >"$conf.tmp"
                mv -f -- "$conf.tmp" "$conf"
                vx_compose_audit \
                    "$(vx_compose_project_root "$owner" "$name")" \
                    migrate succeeded 'legacy record archived'
                status=migrated
            else
                if [[ -d "$(vx_compose_project_root "$owner" "$name")" ]]; then
                    vx_compose_audit \
                        "$(vx_compose_project_root "$owner" "$name")" \
                        migrate failed 'legacy runtime restored' || true
                else
                    vx_compose_owner_audit \
                        "$owner" migrate failed "project=$name" || true
                fi
                [[ ! -d "$(vx_compose_project_root "$owner" "$name")" ]] \
                    || vx_compose_remove "$owner" "$name" >/dev/null 2>&1 || true
                for source in $moved_sources; do
                    [[ ! -d "$HOMEDIR/$owner/docker/$name/binds/$source" ]] \
                        || mv -- \
                            "$HOMEDIR/$owner/docker/$name/binds/$source" \
                            "$HOMEDIR/$owner/docker/$name/$source"
                done
                [[ "$was_running" != yes ]] \
                    || "$(vx_compose_docker_bin)" start "$container" >/dev/null \
                    || true
                if [[ -n "$domain"
                    && -x "$VESTA/bin/v-sync-docker-container-route" ]]; then
                    "$VESTA/bin/v-sync-docker-container-route" \
                        "$owner" "$name" >/dev/null 2>&1 || true
                fi
                status=failed
            fi
        fi
        reports="$(jq -c \
            --arg name "$name" \
            --arg status "$status" \
            '. + [{PROJECT: $name, STATUS: $status}]' <<<"$reports")"
        rm -rf -- "$temp_root"
        [[ "$status" != failed ]] || return 1
    done <"$conf"
    printf '%s\n' "$reports"
}
