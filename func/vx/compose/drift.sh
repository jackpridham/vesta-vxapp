#!/usr/bin/env bash

vx_compose_drift_observe_json() {
    local owner="$1" project="$2"
    local root runtime docker_bin revision desired_state raw='[]'
    local container_id evidence digest ps_output revision_root workload_current workload_revision workload_match
    local workload_evidence_current workload_evidence_revision
    local workload_manifest_current workload_manifest_revision
    local -a container_ids=()

    vx_compose_require_project "$owner" "$project" || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    runtime="$(vx_compose_runtime_name "$owner" "$project")"
    revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" || return 1
    desired_state="$(vx_compose_meta_get "$root/project.conf" STATE)" || return 1
    printf -v revision_root '%s/revisions/%06d' "$root" "$revision"
    workload_current=''
    workload_revision=''
    if [[ -f "$root/workload.json" && ! -L "$root/workload.json" ]]; then
        workload_current="$(sha256sum "$root/workload.json" | awk '{print $1}')" || return 1
    fi
    if [[ -f "$revision_root/workload.json"
        && ! -L "$revision_root/workload.json" ]]; then
        workload_revision="$(sha256sum "$revision_root/workload.json" | awk '{print $1}')" || return 1
    fi
    workload_match=false
    [[ "$workload_current" == "$workload_revision" ]] && workload_match=true
    workload_evidence_current=''
    workload_evidence_revision=''
    [[ ! -f "$root/workload-evidence.json" ]] \
        || workload_evidence_current="$(sha256sum "$root/workload-evidence.json" | awk '{print $1}')" \
        || return 1
    [[ ! -f "$revision_root/workload-evidence.json" ]] \
        || workload_evidence_revision="$(sha256sum "$revision_root/workload-evidence.json" | awk '{print $1}')" \
        || return 1
    [[ "$workload_evidence_current" == "$workload_evidence_revision" ]] \
        || workload_match=false
    workload_manifest_current=''; workload_manifest_revision=''
    [[ ! -f "$root/workload-manifest.sha256" ]] \
        || workload_manifest_current="$(sha256sum "$root/workload-manifest.sha256" | awk '{print $1}')" || return 1
    [[ ! -f "$revision_root/workload-manifest.sha256" ]] \
        || workload_manifest_revision="$(sha256sum "$revision_root/workload-manifest.sha256" | awk '{print $1}')" || return 1
    [[ "$workload_manifest_current" == "$workload_manifest_revision" ]] || workload_match=false
    docker_bin="$(vx_compose_docker_bin)" || return 1
    ps_output="$(
        env -i PATH="$VX_COMPOSE_SAFE_PATH" \
            HOME="$root/runtime/home" \
            DOCKER_CONFIG="$root/runtime/docker-config" \
            "$docker_bin" ps -aq \
            --filter "label=com.docker.compose.project=$runtime"
    )" || return 1
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] || return 1
        container_ids+=("$container_id")
    done <<<"$ps_output"
    if ((${#container_ids[@]} > 0)); then
        raw="$(
            env -i PATH="$VX_COMPOSE_SAFE_PATH" \
                HOME="$root/runtime/home" \
                DOCKER_CONFIG="$root/runtime/docker-config" \
                "$docker_bin" inspect "${container_ids[@]}"
        )" || return 1
    fi
    jq -e 'type=="array"' <<<"$raw" >/dev/null || return 1
    evidence="$(jq -S -n \
        --arg owner "$owner" --arg project "$project" \
        --arg runtime "$runtime" --arg desired_state "$desired_state" \
        --arg workload_current "$workload_current" \
        --arg workload_revision "$workload_revision" \
        --arg workload_evidence_current "$workload_evidence_current" \
        --arg workload_evidence_revision "$workload_evidence_revision" \
        --arg workload_manifest_current "$workload_manifest_current" \
        --arg workload_manifest_revision "$workload_manifest_revision" \
        --argjson workload_match "$workload_match" \
        --argjson revision "$revision" \
        --slurpfile canonical "$root/runtime/canonical.json" \
        --slurpfile images "$root/images.json" \
        --argjson observed "$raw" '
        def netkeys($service):
            if ($service.networks // null) == null then ["default"]
            elif ($service.networks|type)=="array" then $service.networks
            else ($service.networks|keys)
            end | sort;
        def mounts($root;$service):
            ([($service.volumes // [])[] |
                if type=="string" then
                    (split(":")) as $p
                    | {SOURCE:($p[0]//""),TARGET:($p[1]//""),
                       READ_ONLY:(($p[2]//"")|contains("ro"))}
                else {SOURCE:(.source//""),TARGET:(.target//""),
                      READ_ONLY:(.read_only//false)}
                end]
            + [($service.secrets // [])[] |
                if type=="string" then
                    {SOURCE:($root.secrets[.].file//""),
                     TARGET:("/run/secrets/"+.),READ_ONLY:true}
                else
                    {SOURCE:($root.secrets[.source].file//""),
                     TARGET:(.target//("/run/secrets/"+.source)),READ_ONLY:true}
                end]) | sort_by(.TARGET,.SOURCE);
        def ports($service):
            [($service.ports // [])[] |
                if type=="string" then .
                else ((.host_ip//"0.0.0.0")+":"
                    +((.published//"")|tostring)+":"
                    +((.target//"")|tostring)+"/"+(.protocol//"tcp"))
                end] | sort;
        def security($service):
            {PRIVILEGED:($service.privileged//false),
             CAP_ADD:(($service.cap_add//[])|sort),
             NETWORK_MODE:($service.network_mode//"default"),
             PID_MODE:($service.pid//""),
             IPC_MODE:($service.ipc//""),
             DEVICES:(($service.devices//[])|sort)};
        def actualnetworks:
            [(.NetworkSettings.Networks // {} | keys[]) |
                if . == ($runtime+"_default") then "default"
                elif startswith($runtime+"_") then ltrimstr($runtime+"_")
                else . end] | sort;
        def actualmounts:
            [(.Mounts // [])[] | {
                SOURCE:(
                    (.Name // .Source // "") as $source
                    | if ($source|startswith($runtime+"_"))
                      then ($source|ltrimstr($runtime+"_"))
                      else $source end
                ),
                TARGET:(.Destination // ""),
                READ_ONLY:(if has("RW") and (.RW|type)=="boolean"
                    then (.RW|not) else false end)
            }] | sort_by(.TARGET,.SOURCE);
        def actualports:
            [(.NetworkSettings.Ports // {} | to_entries[]) as $entry |
                ($entry.key|split("/")) as $target |
                if ($entry.value|type)=="array" then
                    $entry.value[] |
                    ((.HostIp//"0.0.0.0")+":"+(.HostPort//"")+":"
                        +$target[0]+"/"+($target[1]//"tcp"))
                else empty end] | sort;
        def actualsecurity:
            {PRIVILEGED:(.HostConfig.Privileged//false),
             CAP_ADD:((.HostConfig.CapAdd//[])|sort),
             NETWORK_MODE:(
                (.HostConfig.NetworkMode//"") as $mode
                | if $mode==($runtime+"_default") then "default"
                  elif ($mode|startswith($runtime+"_"))
                  then ($mode|ltrimstr($runtime+"_"))
                  else $mode end
             ),
             PID_MODE:(.HostConfig.PidMode//""),
             IPC_MODE:(
                (.HostConfig.IpcMode//"") as $mode
                | if $mode=="private" then "" else $mode end
             ),
             DEVICES:([(.HostConfig.Devices//[])[] |
                (.PathOnHost//"")+":"+(.PathInContainer//"")]
                | sort)};
        ($canonical[0].services | to_entries | map({
            SERVICE:.key,
            IMAGE:($images[0][.key].IMAGE_ID // .value.image // ""),
            NETWORKS:netkeys(.value),
            MOUNTS:mounts($canonical[0];.value),
            PORTS:ports(.value),
            SECURITY:security(.value)
        }) | sort_by(.SERVICE)) as $desired
        | ($observed | map({
            SERVICE:(.Config.Labels["com.docker.compose.service"]//""),
            OWNER:(.Config.Labels["vx.user"]//""),
            PROJECT:(.Config.Labels["vx.project"]//""),
            MANAGED:(.Config.Labels["vx.managed"]//""),
            REVISION:(.Config.Labels["vx.revision"]//""),
            IMAGE_LABEL:(.Config.Labels["vx.image-id"]//""),
            IMAGE:(.Image//""),
            STATE:(.State.Status//"unknown"),
            NETWORKS:actualnetworks,
            MOUNTS:actualmounts,
            PORTS:actualports,
            SECURITY:actualsecurity
        }) | sort_by(.SERVICE)) as $actual
        | {
            SCHEMA:1, OWNER:$owner, PROJECT:$project,
            CURRENT_REVISION:$revision, DESIRED_STATE:$desired_state,
            WORKLOAD:{MATCH:$workload_match,CURRENT_SHA256:$workload_current,
                REVISION_SHA256:$workload_revision,
                CURRENT_EVIDENCE_SHA256:$workload_evidence_current,
                REVISION_EVIDENCE_SHA256:$workload_evidence_revision,
                CURRENT_MANIFEST_SHA256:$workload_manifest_current,
                REVISION_MANIFEST_SHA256:$workload_manifest_revision},
            DESIRED:$desired, OBSERVED:$actual,
            EXCLUDED_VOLATILE_FIELDS:[
                "container id","container name","created/started timestamps",
                "health output","restart count","runtime IP/MAC addresses",
                "network endpoint ids","resource counters","log paths"
            ],
            MISSING_SERVICES:(
                ($desired|map(.SERVICE))
                - ($actual|map(.SERVICE)|map(select(length>0)))
            ),
            EXTRA_SERVICES:(
                ($actual|map(.SERVICE)|map(select(length>0)))
                - ($desired|map(.SERVICE))
            ),
            CHANGED_SERVICES:[
                $desired[] as $want
                | ($actual|map(select(.SERVICE==$want.SERVICE))|first) as $got
                | select($got != null)
                | [
                    (if $got.OWNER!=$owner or $got.PROJECT!=$project
                        or $got.MANAGED!="yes" then "ownership" else empty end),
                    (if $got.REVISION!=($revision|tostring)
                        then "revision" else empty end),
                    (if $got.IMAGE!=$want.IMAGE
                        or $got.IMAGE_LABEL!=$want.IMAGE
                        then "image" else empty end),
                    (if $got.NETWORKS!=$want.NETWORKS
                        then "network" else empty end),
                    (if $got.MOUNTS!=$want.MOUNTS
                        then "mount" else empty end),
                    (if $got.PORTS!=$want.PORTS
                        then "port" else empty end),
                    (if $got.SECURITY!=$want.SECURITY
                        then "security" else empty end),
                    (if $desired_state=="running" and $got.STATE!="running"
                        then "state" else empty end)
                  ] as $changes
                | select($changes|length>0)
                | {SERVICE:$want.SERVICE,CHANGES:$changes}
            ]
        }
        | .MATCH = (
            (.MISSING_SERVICES|length)==0
            and (.EXTRA_SERVICES|length)==0
            and (.CHANGED_SERVICES|length)==0
            and .WORKLOAD.MATCH
        )
    ')" || return 1
    digest="$(jq -cS 'del(.DRIFT_DIGEST)' <<<"$evidence" \
        | sha256sum | awk '{print $1}')" || return 1
    jq -S --arg digest "$digest" '. + {DRIFT_DIGEST:$digest}' <<<"$evidence"
}

vx_compose_reconcile_preview_json() {
    local actor="$1" owner="$2" project="$3" evidence

    vx_compose_authorize "$actor" "$owner" "$project" reconcile || return 1
    evidence="$(vx_compose_drift_observe_json "$owner" "$project")" || return 1
    jq -S '. + {ACTION:"reconcile",MUTATES_RUNTIME:true,
        DEFINITION_IMPACT:"retained",DATA_IMPACT:"retained",
        ROUTE_IMPACT:"revalidated",BACKUP_IMPACT:"retained",
        SECRET_IMPACT:"references retained"}' <<<"$evidence"
}

vx_compose_reconcile() {
    local actor="$1" owner="$2" project="$3" expected_digest="$4"
    local expected_revision="$5" root observed actual_digest actual_revision
    local operation_id result=1

    [[ "$expected_digest" =~ ^[a-f0-9]{64}$
        && "$expected_revision" =~ ^[1-9][0-9]*$ ]] || return 1
    vx_compose_lock_authorize "$actor" "$owner" "$project" reconcile \
        || return 1
    root="$(vx_compose_project_root "$owner" "$project")"
    actual_revision="$(vx_compose_meta_get "$root/project.conf" REVISION)" \
        || actual_revision=
    observed="$(vx_compose_drift_observe_json "$owner" "$project")" \
        || observed=
    actual_digest="$(jq -r '.DRIFT_DIGEST // ""' <<<"$observed" 2>/dev/null)" \
        || actual_digest=
    if [[ "$actual_revision" != "$expected_revision"
        || "$actual_digest" != "$expected_digest" ]]; then
        vx_compose_lock_release
        vx_compose_error 'Compose drift observation is stale'
        return 1
    fi
    operation_id="$(vx_compose_operation_begin \
        "$root" "$actor" reconcile "$expected_revision")" || {
        vx_compose_lock_release
        return 1
    }
    printf 'OPERATION_ID=%s\n' "$operation_id"
    vx_compose_operation_update "$root" "$operation_id" converging 50 \
        'reconciling validated desired state' || :
    printf '%s\n' 'PHASE=converging PERCENT=50 RESULT=running'
    if jq -e '.MATCH==true' <<<"$observed" >/dev/null; then
        result=0
    elif vx_compose_deploy "$owner" "$project"; then
        result=0
    fi
    if [[ "$result" -eq 0 ]]; then
        vx_compose_operation_finish "$root" "$operation_id" succeeded \
            'runtime reconciled' || result=1
        [[ "$result" -ne 0 ]] \
            || printf '%s\n' 'PHASE=complete PERCENT=100 RESULT=succeeded'
    else
        vx_compose_operation_finish "$root" "$operation_id" failed \
            'runtime reconciliation failed' || :
        printf '%s\n' 'PHASE=failed PERCENT=100 RESULT=failed'
    fi
    vx_compose_lock_release
    return "$result"
}
