#!/usr/bin/env bash

vx_compose_bundle_input_is_secure() {
    local path="$1" parent
    vx_compose_control_file_is_secure "$path" 600 || return 1
    parent="$(dirname -- "$path")"
    vx_compose_bundle_staging_dir_is_secure "$parent"
}

vx_compose_bundle_staging_dir_is_secure() {
    local parent="$1" allowed resolved
    local -a allowed_roots=()
    [[ ! -L "$parent"
        && "$(stat -c '%u:%g:%a:%F' "$parent" 2>/dev/null)" == \
            "$(vx_compose_authority_uid):$(vx_compose_authority_gid):700:directory" ]] \
        || return 1
    resolved="$(readlink -f -- "$parent")" || return 1
    if [[ "$resolved" =~ ^/(tmp|var/tmp)/vx-compose-bundle\.[A-Za-z0-9_-]{6,64}$ ]]; then
        return 0
    fi
    IFS=: read -ra allowed_roots \
        <<<"${VX_COMPOSE_PROTECTED_STAGING_ROOTS:-}"
    for allowed in "${allowed_roots[@]}"; do
        [[ -n "$allowed" && "$resolved" == "$(readlink -f -- "$allowed" 2>/dev/null)" ]] \
            && return 0
    done
    return 1
}

vx_compose_bundle_secrets_dir_is_secure() {
    local directory="$1"
    [[ ! -L "$directory"
        && "$(stat -c '%u:%g:%a:%F' "$directory" 2>/dev/null)" == \
            "$(vx_compose_authority_uid):$(vx_compose_authority_gid):700:directory" ]] \
        && vx_compose_bundle_staging_dir_is_secure "$(dirname -- "$directory")"
}

vx_compose_bundle_extract() {
    local archive="$1" checksum="$2" output="$3"
    vx_compose_bundle_input_is_secure "$archive" \
        && vx_compose_bundle_input_is_secure "$checksum" || {
        vx_compose_error 'bundle inputs must be protected authority files'
        return 1
    }
    [[ "$(dirname -- "$archive")" == "$(dirname -- "$checksum")" \
        && ! -e "$output" ]] || {
        vx_compose_error 'bundle input or extraction path is invalid'
        return 1
    }
    env -i PATH="$VX_COMPOSE_SAFE_PATH" \
        /usr/bin/python3 "$VX_COMPOSE_LIB_DIR/bundle-validator.py" \
        "$archive" "$checksum" "$output"
}

vx_compose_bundle_manifest_check_compose() {
    local workload="$1" canonical="$2" policy="$3" profile="$4"
    local profile_version
    profile_version="$(vx_compose_profile_version "$profile")" || return 1
    jq -e --arg profile "$profile" --argjson profile_version "$profile_version" \
        --slurpfile compose "$canonical" --rawfile policy "$policy" '
        def fact($name): ($policy | capture("(?m)^"+$name+"=\\x27(?<v>[^\\x27]*)\\x27$").v);
        def endpoints($value):
          ($value|tostring) as $v
          | if ($v|contains("-")) then ($v|split("-")|map(tonumber)) as $r
            | [range($r[0];$r[1]+1)] else [($v|tonumber)] end;
        def ports:
          [.services | to_entries[] as $s | $s.value.ports[]?
           | if type == "string" then empty else
             endpoints(.published) as $published | endpoints(.target) as $targets
             | range(0;$published|length) as $i
             | {service:$s.key,host_ip:(.host_ip // "0.0.0.0"),host_port:$published[$i],
                container_port:($targets[$i] // $targets[0]),protocol:(.protocol // "tcp")}
             end] | sort_by(.service,.host_ip,.host_port,.container_port,.protocol);
        .profile.name == $profile and .profile.version == $profile_version
        and ([.services[].name] == ($compose[0].services|keys))
        and all(.services[]; .image == .image)
        and (.resources.memory_mib == (fact("MEMORY_MB")|tonumber))
        and (.resources.pids == (fact("PIDS")|tonumber))
        and (((.resources.cpus|tonumber)*1000|floor) == (fact("CPUS_MILLI")|tonumber))
        and (.ports == ($compose[0] | ports))
        and ([.secrets[].name] == (($compose[0].secrets // {})|keys))
        and ([.volumes[].name] == (($compose[0].volumes // {})|keys))
        and all(.services[] as $declared; $compose[0].services[$declared.name].image == $declared.image)
        and all(.secrets[] as $declared;
          any($compose[0].services[]?.secrets[]?;
            ((if type=="string" then . else .source end) == $declared.name)
            and ((if type=="string" then "/run/secrets/"+. else (.target // "/run/secrets/"+.source) end) == $declared.target)))
        and all(.volumes[] as $declared;
          any($compose[0].services[$declared.service].volumes[]?;
            .type == "volume" and .source == $declared.name and .target == $declared.target))
    ' "$workload" >/dev/null || {
        vx_compose_error 'workload manifest does not match rendered Compose facts'
        return 1
    }
}

vx_compose_bundle_candidate_prepare() {
    local owner="$1" project="$2" extracted="$3" candidate="$4"
    local profile image_id reference resolved_id validation_secrets secret_name
    profile="$(jq -r '.profile.name' "$extracted/workload.json")" || return 1
    image_id="$(jq -r '.image.id' "$extracted/workload.json")" || return 1
    reference="$(jq -r '.image.reference' "$extracted/workload.json")" || return 1
    validation_secrets="$(vx_compose_project_root "$owner" "$project")/secrets"
    if [[ ! -d "$validation_secrets" ]]; then
        validation_secrets="$extracted/validation-secrets"
        install -d -m 0700 "$validation_secrets" || return 1
        while IFS= read -r secret_name; do
            printf x >"$validation_secrets/$secret_name" \
                && chmod 0600 "$validation_secrets/$secret_name" || return 1
        done < <(jq -r '.secrets[].name' "$extracted/workload.json")
    fi
    vx_compose_prepare_candidate "$owner" "$project" \
        "$extracted/compose.yaml" "$candidate" "$profile" no '' \
        "$validation_secrets" || return 1
    vx_compose_bundle_manifest_check_compose \
        "$extracted/workload.json" "$candidate/canonical.json" \
        "$candidate/policy.conf" "$profile" || return 1
    resolved_id="$(vx_compose_image_approval_require \
        "$owner" "$reference" "$image_id" \
        "$(jq -r '.image.os' "$extracted/workload.json")" \
        "$(jq -r '.image.architecture' "$extracted/workload.json")" \
        "$profile" "$(jq -r '.profile.version' "$extracted/workload.json")")" \
        || return 1
    [[ "$resolved_id" == "$image_id" ]] || return 1
    jq -S --arg id "$image_id" '.services |= with_entries(.value.image=$id)' \
        "$candidate/canonical.json" >"$candidate/.canonical.json" || return 1
    mv -f -- "$candidate/.canonical.json" "$candidate/canonical.json"
    cp -- "$candidate/canonical.json" "$candidate/compose.yaml"
    (cd "$candidate" && sha256sum canonical.json >canonical.sha256) || return 1
    install -m 0600 "$extracted/workload.json" "$candidate/workload.json"
    install -m 0600 "$extracted/manifest.sha256" \
        "$candidate/workload-manifest.sha256"
    jq -S --arg canonical "$(vx_compose_candidate_sha "$candidate")" \
        '. + {CANONICAL_SHA256:$canonical}' \
        "$extracted/workload-evidence.json" >"$candidate/workload-evidence.json"
    chmod 0600 "$candidate/workload-evidence.json"
    vx_compose_bundle_image_evidence_to_file "$owner" "$reference" "$image_id" \
        "$profile" "$candidate/canonical.json" "$candidate/images.json"
}

vx_compose_bundle_image_evidence_to_file() {
    local owner="$1" reference="$2" image_id="$3" profile="$4" canonical="$5" output="$6"
    local inspection immutable digest labels trust evidence service
    inspection="$(vx_compose_image_inspect "$owner" "$reference")" || return 1
    [[ "$(jq -r '.Id' <<<"$inspection")" == "$image_id" ]] || return 1
    immutable="$(vx_compose_image_immutable_reference "$inspection" "$reference")" || return 1
    digest="${immutable##*@}"; [[ -n "$immutable" ]] || digest=''
    labels="$(vx_compose_image_oci_labels "$inspection")" || return 1
    trust="$(vx_compose_verify_image_trust "$profile" "$immutable" "$image_id" "$labels")" \
        || return 1
    evidence='{}'
    while IFS= read -r service; do
        evidence="$(jq -c --argjson schema "$VX_COMPOSE_IMAGE_EVIDENCE_SCHEMA_VERSION" \
            --arg service "$service" --arg reference "$reference" \
            --arg immutable "$immutable" --arg digest "$digest" \
            --argjson image "$inspection" --argjson labels "$labels" --argjson trust "$trust" \
            '.[$service]={SCHEMA:$schema,REFERENCE:$reference,IMMUTABLE_REFERENCE:$immutable,
              REGISTRY_DIGEST:$digest,IMAGE_ID:$image.Id,
              REPO_DIGESTS:(($image.RepoDigests//[])|unique|sort),OCI_LABELS:$labels,
              TRUST:$trust,OS:$image.Os,ARCHITECTURE:$image.Architecture}' \
            <<<"$evidence")" || return 1
    done < <(jq -r '.services|keys[]' "$canonical")
    jq -S . <<<"$evidence" >"$output" && chmod 0640 "$output" \
        && vx_compose_image_evidence_current_validate "$output"
}

vx_compose_bundle_plan() {
    local actor="$1" owner="$2" project="$3" archive="$4" checksum="$5" mode="$6"
    local extracted candidate expected=0 profile payload
    [[ "$actor" == admin && "$mode" =~ ^(add|change)$ ]] || {
        vx_compose_error 'bundle planning requires administrator authorization and a valid mode'
        return 1
    }
    vx_compose_require_owner "$owner" || return 1
    vx_compose_require_project_key "$project" || return 1
    vx_compose_lock_acquire "$owner" "$project" || return 1
    if [[ "$mode" == add ]]; then
        [[ ! -e "$(vx_compose_project_root "$owner" "$project")" ]] \
            || { vx_compose_lock_release; return 1; }
    else
        vx_compose_require_project "$owner" "$project" \
            || { vx_compose_lock_release; return 1; }
        expected="$(vx_compose_meta_get "$(vx_compose_project_root "$owner" "$project")/project.conf" REVISION)" \
            || { vx_compose_lock_release; return 1; }
    fi
    extracted="$(mktemp -u "$(dirname -- "$archive")/.bundle.extract.XXXXXX")"
    candidate="$(mktemp -u "$(dirname -- "$archive")/.bundle.candidate.XXXXXX")"
    trap 'rm -rf -- "${extracted:-}" "${candidate:-}"; vx_compose_lock_release' RETURN
    vx_compose_bundle_extract "$archive" "$checksum" "$extracted" || return 1
    vx_compose_bundle_candidate_prepare "$owner" "$project" "$extracted" "$candidate" || return 1
    profile="$(jq -r '.profile.name' "$extracted/workload.json")"
    payload="$(jq -n -S --arg owner "$owner" --arg project "$project" --arg mode "$mode" \
        --arg profile "$profile" --argjson expected "$expected" \
        --arg canonical "$(vx_compose_candidate_sha "$candidate")" \
        --slurpfile workload "$extracted/workload.json" \
        --slurpfile evidence "$candidate/workload-evidence.json" \
        '{SCHEMA:1,OWNER:$owner,PROJECT:$project,MODE:$mode,PROFILE:$profile,
          EXPECTED_CURRENT_REVISION:$expected,CANONICAL_SHA256:$canonical,
          WORKLOAD:{ID:$workload[0].workload.id,RELEASE:$workload[0].workload.release,
            SHA256:$evidence[0].WORKLOAD_SHA256},IMAGE_ID:$workload[0].image.id,
          SERVICES:[$workload[0].services[].name],PROBES:($workload[0].probes|keys),MUTATED:false}')" || return 1
    ((${#payload} <= 32768)) || return 1
    printf '%s\n' "$payload"
    rm -rf -- "$extracted" "$candidate"; vx_compose_lock_release; trap - RETURN
}

vx_compose_bundle_import() {
    local actor="$1" owner="$2" project="$3" archive="$4" checksum="$5" mode="$6"
    local expected="$7" secrets_dir="${8:-}" extracted candidate profile root result=1
    [[ "$actor" == admin && "$mode" =~ ^(add|change)$ ]] || return 1
    [[ "$expected" =~ ^[0-9]+$ ]] || return 1
    extracted="$(mktemp -u "$(dirname -- "$archive")/.bundle.extract.XXXXXX")"
    candidate="$(mktemp -u "$(dirname -- "$archive")/.bundle.candidate.XXXXXX")"
    vx_compose_lock_acquire "$owner" "$project" || return 1
    trap 'rm -rf -- "${extracted:-}" "${candidate:-}"; vx_compose_lock_release' RETURN
    vx_compose_bundle_extract "$archive" "$checksum" "$extracted" \
        && vx_compose_bundle_candidate_prepare "$owner" "$project" "$extracted" "$candidate" || {
        return 1
    }
    profile="$(jq -r '.profile.name' "$extracted/workload.json")"
    if [[ "$mode" == add && "$expected" == 0 ]]; then
        if [[ ! -e "$(vx_compose_project_root "$owner" "$project")" ]] \
            && vx_compose_bundle_stage_secrets "$extracted/workload.json" "$secrets_dir" "$candidate" \
            && vx_compose_store_new "$owner" "$project" "$profile" "$candidate"; then
            if vx_compose_deploy "$owner" "$project"; then
                result=0
            else
                root="$(vx_compose_project_root "$owner" "$project")"
                if vx_compose_invoke "$owner" "$project" down --remove-orphans; then
                    vx_compose_remove_control_root "$owner" "$project" || :
                    rmdir -- "$(vx_compose_bind_root "$owner" "$project")" 2>/dev/null || :
                    rmdir -- "$(vx_compose_project_data_root "$owner" "$project")" 2>/dev/null || :
                else
                    vx_compose_update_state "$owner" "$project" restore-required || :
                fi
            fi
        fi
    elif [[ "$mode" == change && -z "$secrets_dir" ]]; then
        root="$(vx_compose_project_root "$owner" "$project")"
        [[ "$(vx_compose_meta_get "$root/project.conf" REVISION 2>/dev/null)" == "$expected" ]] \
            && [[ "$(vx_compose_meta_get "$root/project.conf" PROFILE 2>/dev/null)" == "$profile" ]] \
            && vx_compose_transaction_update "$owner" "$project" "$candidate" "$expected" running \
            && result=0
    fi
    vx_compose_lock_release
    rm -rf -- "$extracted" "$candidate"; trap - RETURN
    return "$result"
}

vx_compose_bundle_stage_secrets() {
    local workload="$1" source_dir="$2" candidate="$3" count name path total=0
    local directory_identity file_identity
    local -A identities=()
    count="$(jq '.secrets|length' "$workload")" || return 1
    if (( count == 0 )); then [[ -z "$source_dir" ]]; return; fi
    [[ -n "$source_dir" ]] \
        && vx_compose_bundle_secrets_dir_is_secure "$source_dir" || return 1
    [[ "$(find "$source_dir" -mindepth 1 -maxdepth 1 | wc -l)" -eq "$count" ]] || return 1
    directory_identity="$(stat -Lc '%d:%i:%u:%g:%a:%F' "$source_dir")" || return 1
    install -d -m 0700 "$candidate/secrets"
    while IFS= read -r name; do
        path="$source_dir/$name"
        vx_compose_secret_name_is_valid "$name" && vx_compose_control_file_is_secure "$path" 600 \
            && vx_compose_secret_input_validate "$path" || return 1
        file_identity="$(stat -Lc '%d:%i:%u:%g:%a:%s:%F' "$path")" || return 1
        [[ -z "${identities[$file_identity]:-}" ]] || return 1
        identities[$file_identity]=yes
        total=$((total + $(stat -c '%s' "$path"))); (( total <= 8388608 )) || return 1
        install -m 0600 "$path" "$candidate/secrets/$name" || return 1
        [[ "$(stat -Lc '%d:%i:%u:%g:%a:%s:%F' "$path")" == "$file_identity" ]] \
            || return 1
    done < <(jq -r '.secrets[].name' "$workload")
    [[ "$(stat -Lc '%d:%i:%u:%g:%a:%F' "$source_dir")" == "$directory_identity" ]]
}
