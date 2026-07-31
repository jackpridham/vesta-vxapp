#!/usr/bin/env bash

vx_compose_revision_root() {
    printf '%s/revisions/%06d\n' \
        "$(vx_compose_project_root "$1" "$2")" "$3"
}

vx_compose_revision_compare_json() {
    local actor="$1" owner="$2" project="$3" from_revision="$4"
    local to_revision="$5" root from_root to_root routes='{}'
    local from_manifest to_manifest

    [[ "$from_revision" =~ ^[1-9][0-9]*$
        && "$to_revision" =~ ^[1-9][0-9]*$ ]] || return 1
    vx_compose_authorize "$actor" "$owner" "$project" view || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    from_root="$(vx_compose_revision_root "$owner" "$project" "$from_revision")"
    to_root="$(vx_compose_revision_root "$owner" "$project" "$to_revision")"
    vx_compose_revision_manifest_verify "$from_root" \
        && vx_compose_revision_manifest_verify "$to_root" || return 1
    from_manifest="$(sha256sum "$from_root/manifest.sha256" | awk '{print $1}')" \
        || return 1
    to_manifest="$(sha256sum "$to_root/manifest.sha256" | awk '{print $1}')" \
        || return 1
    [[ ! -f "$root/routes.conf" ]] || routes="$(jq -c . "$root/routes.conf")" \
        || return 1
    jq -n -S \
        --arg owner "$owner" --arg project "$project" \
        --arg from_manifest "$from_manifest" --arg to_manifest "$to_manifest" \
        --argjson from_revision "$from_revision" \
        --argjson to_revision "$to_revision" \
        --slurpfile before "$from_root/canonical.json" \
        --slurpfile after "$to_root/canonical.json" \
        --argjson routes "$routes" '
        def names($v): (($v//{})|keys);
        def diff($a;$b): {
            ADDED:(names($b)-names($a)),
            REMOVED:(names($a)-names($b)),
            CHANGED:[names($a)[] as $n |
                select(($b|has($n)) and $a[$n]!=$b[$n]) | $n],
            UNCHANGED:[names($a)[] as $n |
                select(($b|has($n)) and $a[$n]==$b[$n]) | $n]
        };
        def svc_facts($s): {
            IMAGE:($s.image//""),
            ENDPOINTS:([($s.ports//[])[] |
                if type=="string" then .
                else ((.host_ip//"0.0.0.0")+":"
                    +((.published//"")|tostring)+":"
                    +((.target//"")|tostring)+"/"+(.protocol//"tcp"))
                end]|sort),
            RESOURCES:{
                CPUS:($s.cpus//null),
                MEMORY:($s.mem_limit//null),
                PIDS:($s.pids_limit//null),
                DEPLOY:($s.deploy.resources//{}),
                LOGGING:($s.logging//{})
            },
            SECURITY:{
                PRIVILEGED:($s.privileged//false),
                CAP_ADD:(($s.cap_add//[])|sort),
                NETWORK_MODE:($s.network_mode//""),
                PID_MODE:($s.pid//""),
                IPC_MODE:($s.ipc//""),
                DEVICES:(($s.devices//[])|sort)
            }
        };
        ($before[0]) as $a | ($after[0]) as $b
        | {
            OWNER:$owner,PROJECT:$project,
            FROM_REVISION:$from_revision,TO_REVISION:$to_revision,
            FROM_MANIFEST_SHA256:$from_manifest,
            TO_MANIFEST_SHA256:$to_manifest,
            SERVICES:diff($a.services;$b.services),
            NETWORKS:diff($a.networks;$b.networks),
            VOLUMES:diff($a.volumes;$b.volumes),
            SECRETS:diff($a.secrets;$b.secrets),
            SERVICE_CHANGES:[
                (($a.services|keys)+($b.services|keys)|unique[]) as $name
                | {
                    SERVICE:$name,
                    BEFORE:(if $a.services[$name] == null then null
                        else svc_facts($a.services[$name]) end),
                    AFTER:(if $b.services[$name] == null then null
                        else svc_facts($b.services[$name]) end)
                }
                | select(.BEFORE != .AFTER)
            ],
            ROUTE_EFFECTS:[
                $routes|to_entries[] |
                .value.SERVICE as $service |
                {DOMAIN:.key,SERVICE:$service,
                 EFFECT:(if $b.services[$service]==null then "invalidated"
                    elif $a.services[$service]==$b.services[$service]
                    then "unchanged" else "revalidate" end)}
            ],
            DEFINITION_FACTS:{
                SERVICE_COUNT_BEFORE:($a.services|length),
                SERVICE_COUNT_AFTER:($b.services|length),
                NETWORK_COUNT_BEFORE:($a.networks//{}|length),
                NETWORK_COUNT_AFTER:($b.networks//{}|length),
                VOLUME_COUNT_BEFORE:($a.volumes//{}|length),
                VOLUME_COUNT_AFTER:($b.volumes//{}|length),
                SECRET_NAMES_BEFORE:($a.secrets//{}|keys),
                SECRET_NAMES_AFTER:($b.secrets//{}|keys)
            }
        }'
}

vx_compose_rollback_preview_json() {
    local actor="$1" owner="$2" project="$3" target_revision="$4"
    local root current comparison

    vx_compose_authorize "$actor" "$owner" "$project" rollback || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    current="$(vx_compose_meta_get "$root/project.conf" REVISION)" || return 1
    [[ "$target_revision" =~ ^[1-9][0-9]*$
        && "$target_revision" != "$current" ]] || return 1
    comparison="$(vx_compose_revision_compare_json \
        "$actor" "$owner" "$project" "$current" "$target_revision")" \
        || return 1
    jq -S '. + {
        ACTION:"rollback",MUTATES_RUNTIME:true,
        BOUND_CURRENT_REVISION:.FROM_REVISION,
        BOUND_TARGET_REVISION:.TO_REVISION,
        DEFINITION_IMPACT:"target revision becomes desired",
        DATA_IMPACT:"retained",BACKUP_IMPACT:"retained",
        ROUTE_IMPACT:"revalidated",
        SECRET_IMPACT:"values retained; references follow target revision"
    }' <<<"$comparison"
}

vx_compose_rollback_bound() {
    local actor="$1" owner="$2" project="$3" target_revision="$4"
    local expected_current="$5" expected_from_manifest="$6"
    local expected_to_manifest="$7" root preview operation_id result=1

    [[ "$expected_current" =~ ^[1-9][0-9]*$
        && "$expected_from_manifest" =~ ^[a-f0-9]{64}$
        && "$expected_to_manifest" =~ ^[a-f0-9]{64}$ ]] || return 1
    vx_compose_authorize "$actor" "$owner" "$project" rollback || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    preview="$(vx_compose_rollback_preview_json \
        "$actor" "$owner" "$project" "$target_revision")" || preview=
    if [[ -z "$preview"
        || "$(jq -r '.BOUND_CURRENT_REVISION' <<<"$preview")" \
            != "$expected_current"
        || "$(jq -r '.FROM_MANIFEST_SHA256' <<<"$preview")" \
            != "$expected_from_manifest"
        || "$(jq -r '.TO_MANIFEST_SHA256' <<<"$preview")" \
            != "$expected_to_manifest" ]]; then
        vx_compose_lock_release
        vx_compose_error 'Compose rollback preview is stale'
        return 1
    fi
    root="$(vx_compose_project_root "$owner" "$project")"
    operation_id="$(vx_compose_operation_begin \
        "$root" "$actor" rollback "$target_revision")" || {
        vx_compose_lock_release
        return 1
    }
    printf 'OPERATION_ID=%s\n' "$operation_id"
    vx_compose_operation_update "$root" "$operation_id" converging 50 \
        'applying manifest-bound rollback' || :
    printf '%s\n' 'PHASE=converging PERCENT=50 RESULT=running'
    vx_compose_rollback "$owner" "$project" "$target_revision" && result=0
    if [[ "$result" -eq 0 ]]; then
        vx_compose_operation_finish "$root" "$operation_id" succeeded \
            'rollback completed' || result=1
        [[ "$result" -ne 0 ]] \
            || printf '%s\n' 'PHASE=complete PERCENT=100 RESULT=succeeded'
    else
        vx_compose_operation_finish "$root" "$operation_id" failed \
            'rollback failed' || :
        printf '%s\n' 'PHASE=failed PERCENT=100 RESULT=failed'
    fi
    vx_compose_lock_release
    return "$result"
}
