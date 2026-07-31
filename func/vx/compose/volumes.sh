#!/usr/bin/env bash

VX_COMPOSE_VOLUME_HELPER_IMAGE="${VX_COMPOSE_VOLUME_HELPER_IMAGE:-alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}"

vx_compose_bind_root() {
    printf '%s/binds\n' "$(vx_compose_project_data_root "$1" "$2")"
}

vx_compose_bind_root_secure() {
    local owner="$1"
    local project="$2"
    local bind_root

    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    if id -u "$owner" >/dev/null 2>&1; then
        vx_compose_prepare_project_data_roots "$owner" "$project" || return 1
    else
        [[ -d "$bind_root" && ! -L "$bind_root" ]] || return 1
        chmod 0750 "$bind_root"
    fi
}

vx_compose_managed_binds_verify() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"
    local bind_root resolved_root source resolved_source traversal mode uid
    local relative_source
    local authority_uid=0

    (( EUID == 0 )) || authority_uid="$EUID"

    [[ -f "$canonical_json" && ! -L "$canonical_json" ]] || return 1
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    [[ -d "$bind_root" && ! -L "$bind_root" ]] || {
        vx_compose_error 'managed bind root is unavailable'
        return 1
    }
    resolved_root="$(realpath -e -- "$bind_root")" || return 1
    [[ "$resolved_root" == "$bind_root" ]] || {
        vx_compose_error 'managed bind traversal contains a symlink'
        return 1
    }
    for traversal in \
        "$(vx_compose_project_data_root "$owner" "$project")" "$bind_root"; do
        [[ -d "$traversal" && ! -L "$traversal" ]] || return 1
        uid="$(stat -c '%u' "$traversal")" || return 1
        mode="$(stat -c '%a' "$traversal")" || return 1
        [[ "$uid" -eq "$authority_uid" && $((8#$mode & 0022)) -eq 0 ]] || {
            vx_compose_error \
                'managed bind traversal must be root-owned and non-renamable'
            return 1
        }
    done
    while IFS= read -r source; do
        case "$source" in
            "$bind_root"/*) ;;
            *)
                vx_compose_error 'managed bind source is outside its root'
                return 1
                ;;
        esac
        relative_source="${source#"$bind_root"/}"
        [[ "$relative_source" != */* ]] || {
            vx_compose_error \
                'managed bind sources must be direct children of the authority-owned bind root'
            return 1
        }
        [[ -e "$source" && ! -L "$source" ]] || {
            vx_compose_error 'managed bind source changed after validation'
            return 1
        }
        resolved_source="$(realpath -e -- "$source")" || return 1
        case "$resolved_source" in
            "$resolved_root"/*) ;;
            *)
                vx_compose_error 'managed bind source escaped after validation'
                return 1
                ;;
        esac
    done < <(jq -r '
        .services[]
        | (.volumes // [])[]
        | select(.type == "bind")
        | .source
    ' "$canonical_json")
}

vx_compose_simple_bind_leaves_normalize() {
    local owner="$1"
    local project="$2"
    local canonical_json="$3"
    local bind_root source relative_source

    (( EUID == 0 )) || return 0
    id -u "$owner" >/dev/null 2>&1 || return 0
    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    while IFS= read -r source; do
        relative_source="${source#"$bind_root"/}"
        [[ "$source" == "$bind_root"/* && "$relative_source" != */*
            && -e "$source" && ! -L "$source" ]] || return 1
        if [[ -d "$source" ]]; then
            vx_compose_managed_directory_prepare \
                "$owner" "$source" tenant 0750 || return 1
        else
            chown "$owner:$owner" "$source" || return 1
            chmod 0640 "$source" || return 1
        fi
    done < <(jq -r '
        .services[]
        | (.volumes // [])[]
        | select(.type == "bind")
        | .source
    ' "$canonical_json")
}

vx_compose_volume_runtime_name() {
    local owner="$1"
    local project="$2"
    local volume="$3"

    [[ "$volume" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || return 1
    printf 'vx_%s_%s_%s\n' "$owner" "$project" "$volume"
}

vx_compose_policy_check_reserved_volume_labels() {
    local canonical_json="$1"

    jq -e '
        all((.volumes // {})[];
            ((.labels // {}) | type == "object")
            and (
                (.labels // {})
                | with_entries(select(
                    (.key | startswith("vx."))
                    or (.key | startswith("com.docker.compose."))
                ))
                | length == 0
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            VOLUME_OWNERSHIP \
            'volume definitions may not set managed identity fields'
}

vx_compose_policy_check_existing_volume_labels() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"
    local volume expected_name

    while IFS= read -r volume; do
        expected_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")" \
            || return 1
        jq -e \
            --arg volume "$volume" \
            --arg expected "$expected_name" \
            --arg owner "$owner" \
            --arg project "$project" '
                .volumes[$volume].name == $expected
                and .volumes[$volume].labels["vx.managed"] == "yes"
                and .volumes[$volume].labels["vx.user"] == $owner
                and .volumes[$volume].labels["vx.project"] == $project
                and .volumes[$volume].labels["vx.volume"] == $volume
                and ((.volumes[$volume].external // false) == false)
                and all(
                    (.volumes[$volume].labels // {}) | to_entries[];
                    if (.key | startswith("vx.")) then
                        (.key == "vx.managed" and .value == "yes")
                        or (.key == "vx.user" and .value == $owner)
                        or (.key == "vx.project" and .value == $project)
                        or (.key == "vx.volume" and .value == $volume)
                    else
                        (.key | startswith("com.docker.compose.") | not)
                    end
                )
            ' "$canonical_json" >/dev/null \
            || {
                vx_compose_policy_reject \
                    VOLUME_OWNERSHIP \
                    'stored volume ownership does not match project metadata'
                return 1
            }
    done < <(jq -r '(.volumes // {}) | keys[]' "$canonical_json")
}

vx_compose_storage_target_is_safe() {
    local target="$1"

    [[ "$target" == /* && "$target" != *$'\n'* ]] || return 1
    case "$target" in
        /|/bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/proc|/proc/*|\
        /run|/run/*|/sbin|/sbin/*|/sys|/sys/*|/usr|/usr/*|/var/run/docker.sock)
            return 1
            ;;
    esac
}

vx_compose_policy_check_storage() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"
    local validation_bind_root="${4:-}"
    local volume expected_name bind_root resolved_root
    local source_path validation_source resolved_source target relative_source

    jq -e '
        ((.volumes // {}) | type == "object")
        and all(.services[];
            all((.volumes // [])[];
                (.type == "volume" or .type == "bind")
                and (.source | type == "string" and length > 0)
                and (.target | type == "string" and length > 0)
            )
        )
    ' "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                MOUNT \
                'anonymous or unsupported mounts are not permitted'
            return 1
        }

    while IFS= read -r volume; do
        [[ "$volume" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] \
            || {
                vx_compose_policy_reject VOLUME 'invalid managed volume name'
                return 1
            }
        expected_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")"
        jq -e \
            --arg volume "$volume" \
            --arg expected "$expected_name" \
            --arg owner "$owner" \
            --arg project "$project" '
                .volumes[$volume].name == $expected
                and .volumes[$volume].labels["vx.managed"] == "yes"
                and .volumes[$volume].labels["vx.user"] == $owner
                and .volumes[$volume].labels["vx.project"] == $project
                and .volumes[$volume].labels["vx.volume"] == $volume
                and ((.volumes[$volume].external // false) == false)
            ' "$canonical_json" >/dev/null \
            || {
                vx_compose_policy_reject \
                    VOLUME \
                    'managed volume identity or ownership labels are invalid'
                return 1
            }
    done < <(jq -r '(.volumes // {}) | keys[]' "$canonical_json")

    bind_root="$(vx_compose_bind_root "$owner" "$project")"
    if [[ -n "$validation_bind_root" ]]; then
        [[ -d "$validation_bind_root" && ! -L "$validation_bind_root" ]] \
            || {
                vx_compose_policy_reject BIND 'restore bind staging is unavailable'
                return 1
            }
        resolved_root="$(realpath -e -- "$validation_bind_root")" || return 1
    fi
    while IFS=$'\t' read -r source_path target; do
        case "$source_path" in
            "$bind_root"/*) ;;
            *)
                vx_compose_policy_reject \
                    MOUNT \
                    'host paths outside the managed bind root are not permitted'
                return 1
                ;;
        esac
        validation_source="$source_path"
        relative_source="${source_path#"$bind_root"/}"
        [[ "$relative_source" != */* ]] \
            || {
                vx_compose_policy_reject \
                    BIND \
                    'managed bind sources must be direct children of their root'
                return 1
            }
        if [[ -n "$validation_bind_root" ]]; then
            validation_source="$validation_bind_root/$relative_source"
        else
            [[ -d "$bind_root" && ! -L "$bind_root" ]] \
                || {
                    vx_compose_policy_reject BIND 'managed bind root is unavailable'
                    return 1
                }
            resolved_root="$(realpath -e -- "$bind_root")" || return 1
        fi
        [[ -e "$validation_source" && ! -L "$validation_source" ]] \
            || {
                vx_compose_policy_reject BIND 'managed bind source is unavailable'
                return 1
            }
        resolved_source="$(realpath -e -- "$validation_source")" || return 1
        case "$resolved_source" in
            "$resolved_root"/*) ;;
            *)
                vx_compose_policy_reject \
                    BIND \
                    'managed bind resolves outside the project bind root'
                return 1
                ;;
        esac
        vx_compose_storage_target_is_safe "$target" \
            || {
                vx_compose_policy_reject \
                    MOUNT_TARGET \
                    'mount target overlaps a protected container path'
                return 1
            }
    done < <(jq -r '
        .services[]
        | (.volumes // [])[]
        | select(.type == "bind")
        | [.source, .target]
        | @tsv
    ' "$canonical_json")

    while IFS=$'\t' read -r volume target; do
        jq -e --arg volume "$volume" '.volumes[$volume] != null' \
            "$canonical_json" >/dev/null \
            || {
                vx_compose_policy_reject \
                    VOLUME \
                    'service references an unmanaged named volume'
                return 1
            }
        vx_compose_storage_target_is_safe "$target" \
            || {
                vx_compose_policy_reject \
                    MOUNT_TARGET \
                    'mount target overlaps a protected container path'
                return 1
            }
    done < <(jq -r '
        .services[]
        | (.volumes // [])[]
        | select(.type == "volume")
        | [.source, .target]
        | @tsv
    ' "$canonical_json")
}

vx_compose_volume_inspect() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local canonical="${4:-}"
    local root runtime_name docker_bin inspection

    vx_compose_require_project "$owner" "$project" || return 1
    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")" \
        || {
            vx_compose_error 'invalid managed volume name'
            return 1
        }
    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -n "$canonical" ]] \
        || canonical="${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-$root/runtime/canonical.json}"
    jq -e --arg volume "$volume" '.volumes[$volume] != null' \
        "$canonical" >/dev/null \
        || {
            vx_compose_error 'volume is not declared by the managed project'
            return 1
        }
    docker_bin="$(vx_compose_docker_bin)" || return 1
    inspection="$("$docker_bin" volume inspect "$runtime_name")" \
        || {
            vx_compose_error 'managed volume does not exist'
            return 1
        }
    jq -e \
        --arg runtime "$runtime_name" \
        --arg compose_project "$(vx_compose_runtime_name "$owner" "$project")" \
        --arg owner "$owner" \
        --arg project "$project" \
        --arg volume "$volume" '
            .[0].Name == $runtime
            and .[0].Labels["com.docker.compose.project"] == $compose_project
            and .[0].Labels["com.docker.compose.volume"] == $volume
            and .[0].Labels["vx.managed"] == "yes"
            and .[0].Labels["vx.user"] == $owner
            and .[0].Labels["vx.project"] == $project
            and .[0].Labels["vx.volume"] == $volume
        ' <<<"$inspection" >/dev/null \
        || {
            vx_compose_error 'managed volume ownership labels do not match'
            return 1
        }
    printf '%s\n' "$inspection"
}

vx_compose_volume_verify_runtime() {
    local owner="$1"
    local project="$2"
    local canonical="${3:-}"
    local require_present="${4:-yes}"
    local root docker_bin volume runtime_name

    root="$(vx_compose_project_root "$owner" "$project")"
    [[ -n "$canonical" ]] || canonical="$root/runtime/canonical.json"
    [[ -f "$canonical" && ! -L "$canonical"
        && ( "$require_present" == yes || "$require_present" == no ) ]] \
        || return 1
    docker_bin="$(vx_compose_docker_bin)" || return 1
    while IFS= read -r volume; do
        runtime_name="$(vx_compose_volume_runtime_name \
            "$owner" "$project" "$volume")" || return 1
        if ! "$docker_bin" volume inspect "$runtime_name" >/dev/null 2>&1; then
            if [[ "$require_present" == yes ]]; then
                vx_compose_error 'managed project volume does not exist'
                return 1
            fi
            continue
        fi
        vx_compose_volume_inspect \
            "$owner" "$project" "$volume" "$canonical" >/dev/null \
            || return 1
    done < <(jq -r '(.volumes // {}) | keys[]' "$canonical")
}

vx_compose_volume_export() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local output_file="$4"
    local runtime_name docker_bin output_parent temp_root

    vx_compose_volume_inspect "$owner" "$project" "$volume" >/dev/null \
        || return 1
    [[ ! -e "$output_file" && "$(basename -- "$output_file")" =~ ^[a-z][a-z0-9_-]{0,62}[.]tar[.]gz$ ]] \
        || {
            vx_compose_error 'invalid managed volume export path'
            return 1
        }
    output_parent="$(realpath -e -- "$(dirname -- "$output_file")")" || return 1
    [[ -d "$output_parent" && ! -L "$(dirname -- "$output_file")" ]] || return 1
    temp_root="$(mktemp -d "$output_parent/.volume-export.XXXXXX")" || return 1
    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")"
    docker_bin="$(vx_compose_docker_bin)" || {
        rm -rf -- "$temp_root"
        return 1
    }
    if "$docker_bin" run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --mount "type=volume,src=$runtime_name,dst=/source,readonly" \
        --mount "type=bind,src=$temp_root,dst=/backup" \
        "$VX_COMPOSE_VOLUME_HELPER_IMAGE" \
        tar --numeric-owner -czf "/backup/$(basename -- "$output_file")" \
        -C /source . >/dev/null; then
        chmod 0600 "$temp_root/$(basename -- "$output_file")"
        mv -- "$temp_root/$(basename -- "$output_file")" "$output_file"
        rmdir "$temp_root"
    else
        rm -rf -- "$temp_root"
        vx_compose_error 'managed volume export failed'
        return 1
    fi
}

vx_compose_volume_create() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local runtime_name docker_bin

    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")" \
        || return 1
    docker_bin="$(vx_compose_docker_bin)" || return 1
    if "$docker_bin" volume inspect "$runtime_name" >/dev/null 2>&1; then
        vx_compose_volume_inspect "$owner" "$project" "$volume" >/dev/null
        return
    fi
    "$docker_bin" volume create \
        --label "com.docker.compose.project=$(vx_compose_runtime_name "$owner" "$project")" \
        --label com.docker.compose.volume="$volume" \
        --label vx.managed=yes \
        --label vx.user="$owner" \
        --label vx.project="$project" \
        --label vx.volume="$volume" \
        "$runtime_name" >/dev/null \
        || {
            vx_compose_error 'managed volume creation failed'
            return 1
        }
}

vx_compose_volume_import() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local input_file="$4"
    local runtime_name docker_bin input_parent

    [[ -f "$input_file" && ! -L "$input_file" ]] \
        || {
            vx_compose_error 'managed volume import must be a regular archive'
            return 1
        }
    vx_compose_data_archive_validate "$input_file" || return 1
    vx_compose_volume_create "$owner" "$project" "$volume" || return 1
    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    input_parent="$(realpath -e -- "$(dirname -- "$input_file")")" || return 1
    "$docker_bin" run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --mount "type=volume,src=$runtime_name,dst=/target" \
        --mount "type=bind,src=$input_parent,dst=/backup,readonly" \
        "$VX_COMPOSE_VOLUME_HELPER_IMAGE" \
        tar --numeric-owner -xzf "/backup/$(basename -- "$input_file")" \
        -C /target >/dev/null \
        || {
            vx_compose_error 'managed volume import failed'
            return 1
        }
}

vx_compose_volume_clear() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local runtime_name docker_bin

    vx_compose_volume_inspect "$owner" "$project" "$volume" >/dev/null \
        || return 1
    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")"
    docker_bin="$(vx_compose_docker_bin)" || return 1
    "$docker_bin" run --rm \
        --network none \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --mount "type=volume,src=$runtime_name,dst=/target" \
        "$VX_COMPOSE_VOLUME_HELPER_IMAGE" \
        sh -eu -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' \
        >/dev/null \
        || {
            vx_compose_error 'managed volume clear failed'
            return 1
        }
}

vx_compose_volume_remove() {
    local owner="$1"
    local project="$2"
    local volume="$3"
    local canonical="${4:-}"
    local runtime_name docker_bin

    vx_compose_volume_inspect \
        "$owner" "$project" "$volume" "$canonical" >/dev/null || return 1
    runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")" \
        || return 1
    docker_bin="$(vx_compose_docker_bin)" || return 1
    "$docker_bin" volume rm "$runtime_name" >/dev/null
}

vx_compose_project_volume_storage_mb() {
    local owner="$1"
    local project="$2"
    local project_root volume inspection mountpoint size
    local docker_bin runtime_name
    local total=0

    project_root="$(vx_compose_project_root "$owner" "$project")"
    [[ -f "$project_root/project.conf"
        && -f "$project_root/runtime/canonical.json" ]] || {
        printf '0\n'
        return
    }
    docker_bin="$(vx_compose_docker_bin)" || return 1
    while IFS= read -r volume; do
        runtime_name="$(vx_compose_volume_runtime_name "$owner" "$project" "$volume")" \
            || return 1
        "$docker_bin" volume inspect "$runtime_name" >/dev/null 2>&1 || continue
        inspection="$(vx_compose_volume_inspect "$owner" "$project" "$volume")" \
            || return 1
        mountpoint="$(jq -er '.[0].Mountpoint | select(type == "string" and length > 0)' \
            <<<"$inspection")" || return 1
        [[ "$mountpoint" == /var/lib/docker/volumes/*/_data
            && -d "$mountpoint" && ! -L "$mountpoint" ]] \
            || {
                vx_compose_error 'managed volume mountpoint is invalid'
                return 1
            }
        size="$(du -sm -- "$mountpoint" | awk 'NR == 1 { print $1 }')" \
            || return 1
        total=$((total + size))
    done < <(jq -r '(.volumes // {}) | keys[]' \
        "$project_root/runtime/canonical.json")
    printf '%s\n' "$total"
}

vx_compose_volume_storage_mb() {
    local owner="$1"
    local projects_root project_root project size total=0

    projects_root="$(vx_compose_projects_root "$owner")"
    [[ -d "$projects_root" ]] || {
        printf '0\n'
        return
    }
    for project_root in "$projects_root"/*; do
        [[ -f "$project_root/project.conf" ]] || continue
        project="$(basename -- "$project_root")"
        size="$(vx_compose_project_volume_storage_mb "$owner" "$project")" \
            || return 1
        total=$((total + size))
    done
    printf '%s\n' "$total"
}
