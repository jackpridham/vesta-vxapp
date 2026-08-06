#!/usr/bin/env bash

vx_compose_policy_reject() {
    local code="$1"
    local reason="$2"

    vx_compose_error "Compose policy rejection [$code]: $reason"
}

vx_compose_policy_check_reserved_labels() {
    local canonical_json="$1"

    jq -e '
        all(.services[];
            ((.labels // {}) | type == "object")
            and (
                (.labels // {})
                | with_entries(
                    select(
                        (.key | startswith("vx."))
                        or (.key | startswith("com.docker.compose."))
                    )
                )
                | length == 0
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            OWNERSHIP_LABEL \
            'service definitions may not set reserved ownership labels'
}

vx_compose_policy_check_existing_labels() {
    local canonical_json="$1"
    local owner="$2"
    local project="$3"

    jq -e --arg owner "$owner" --arg project "$project" '
        all(.services[];
            (.labels["vx.managed"] // "") == "yes"
            and (.labels["vx.user"] // "") == $owner
            and (.labels["vx.project"] // "") == $project
            and all((.labels // {}) | to_entries[];
                if (.key | startswith("vx.")) then
                    (.key == "vx.managed" and .value == "yes")
                    or (.key == "vx.user" and .value == $owner)
                    or (.key == "vx.project" and .value == $project)
                else
                    (.key | startswith("com.docker.compose.") | not)
                end
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            OWNERSHIP_LABEL \
            'stored ownership labels do not match project metadata'
}

vx_compose_policy_require() {
    local canonical_json="$1"
    local code="$2"
    local reason="$3"
    local expression="$4"

    jq -e "$expression" "$canonical_json" >/dev/null \
        || vx_compose_policy_reject "$code" "$reason"
}

vx_compose_policy_check_supported_keys() {
    local canonical_json="$1"

    jq -e '
        def supported($allowed):
            type == "object"
            and ((keys - $allowed) | length) == 0;
        def label_map:
            type == "object"
            and all(to_entries[];
                (.key | type == "string")
                and (.value | type == "string")
            );

        supported([
            "configs", "name", "networks", "secrets", "services", "volumes"
        ])
        and (.services | type == "object" and length > 0)
        and all(.services[];
            supported([
                "build", "cap_add", "cap_drop", "command", "configs", "cpus",
                "deploy", "device_cgroup_rules", "devices", "entrypoint",
                "environment", "gpus", "healthcheck", "image", "init", "ipc",
                "labels", "logging", "mem_limit", "network_mode", "networks",
                "pids_limit", "pid", "ports", "privileged", "read_only",
                "restart", "secrets", "security_opt", "stop_grace_period",
                "sysctls", "tmpfs", "ulimits", "use_api_socket", "user",
                "userns_mode", "volumes"
            ])
            and ((.labels // {}) | label_map)
            and ((.healthcheck // {}) | supported([
                "interval", "retries", "start_period", "test", "timeout"
            ]))
            and ((.logging // {}) | supported(["driver", "options"]))
            and ((.logging.options // {}) | supported([
                "max-file", "max-size"
            ]))
            and all((.ports // [])[];
                supported([
                    "host_ip", "mode", "protocol", "published", "target"
                ])
            )
            and (
                (.networks // {}) | supported(keys)
                and all(to_entries[];
                    .value == null
                    or (.value | supported([]))
                )
            )
            and all((.volumes // [])[];
                supported([
                    "bind", "read_only", "source", "target", "type", "volume"
                ])
                and ((.bind // {}) | supported(["create_host_path"]))
                and (((.bind // {}).create_host_path // false) == false)
                and ((.volume // {}) | supported([]))
            )
            and all((.secrets // [])[];
                supported(["mode", "source", "target"])
            )
            and (
                (.deploy // {}) | supported([
                    "placement", "replicas", "resources"
                ])
            )
            and (((.deploy // {}).placement // {}) | supported([]))
            and (((.deploy // {}).resources // {}) | supported(["limits"]))
            and (
                (((.deploy // {}).resources // {}).limits // {})
                | supported(["cpus", "memory", "pids"])
            )
            and ((.ulimits // {}) | supported(["nofile"]))
        )
        and (
            (.networks // {}) | type == "object"
            and all(to_entries[];
                (.value | supported([
                    "attachable", "driver", "external", "ipam", "labels",
                    "name"
                ]))
                and ((.value.labels // {}) | label_map)
                and ((.value.ipam // {}) | supported([]))
            )
        )
        and (
            (.volumes // {}) | type == "object"
            and all(to_entries[];
                (.value | supported(["external", "labels", "name"]))
                and ((.value.labels // {}) | label_map)
            )
        )
        and (
            (.secrets // {}) | type == "object"
            and all(to_entries[];
                (.value | supported(["external", "file", "name"]))
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            UNSUPPORTED_KEY \
            'rendered Compose contains an unsupported field or nested option'
}

vx_compose_policy_check_sensitive_values() {
    local canonical_json="$1"
    local owner="${2:-}"
    local project="${3:-}"

    jq -e --arg owner "$owner" --arg project "$project" '
        def normalized:
            tostring
            | ascii_downcase
            | gsub("[^a-z0-9]"; "");
        def credential_key:
            normalized
            | test(
                "password|passwd|secret|token|credential|authorization|authentication|bearer|apikey|auth$|auth(header|key|token|secret|credential)|private($|key|secret|credential)|access($|key|token|secret|credential)|client(key|token|secret|credential)"
            );
        def credential_value:
            tostring as $value
            | (
                ($value | credential_key)
                or (
                    $value
                    | test(
                        "(?i)(^|[^a-z0-9])(password|passwd|secret|token|credential|authorization|authentication|auth|bearer|private[._ -]?key|access[._ -]?(key|token|secret|credential)|client[._ -]?(key|token|secret|credential)|api[._ -]?key)([^a-z0-9]|$)"
                    )
                )
                or (
                    $value
                    | test(
                        "(?i)[a-z][a-z0-9+.-]*://[^/@[:space:]]+@"
                    )
                )
            );
        def trusted_service_label($entry):
            ($entry.key == "vx.managed" and $entry.value == "yes")
            or ($entry.key == "vx.user" and $entry.value == $owner)
            or ($entry.key == "vx.project" and $entry.value == $project);
        def trusted_network_label($entry; $network):
            trusted_service_label($entry)
            or ($entry.key == "vx.network" and $entry.value == $network);
        def trusted_volume_label($entry; $volume):
            trusted_service_label($entry)
            or ($entry.key == "vx.volume" and $entry.value == $volume);
        def safe_label($entry):
            ($entry.key | credential_key | not)
            and ($entry.value | credential_value | not);
        (
            all(.services[];
                all((.labels // {}) | to_entries[];
                    trusted_service_label(.)
                    or safe_label(.)
                )
                and all((.environment // {}) | to_entries[];
                    (.key | credential_key | not)
                    and (.value | credential_value | not)
                )
                and (
                    [
                        (.command // empty),
                        (.entrypoint // empty),
                        ((.healthcheck // {}).test // empty)
                    ]
                    | [
                        .. | scalars
                        | select(credential_value)
                    ]
                    | length == 0
                )
            )
            and all((.networks // {}) | to_entries[];
                .key as $network
                | all((.value.labels // {}) | to_entries[];
                    trusted_network_label(.; $network)
                    or safe_label(.)
                )
            )
            and all((.volumes // {}) | to_entries[];
                .key as $volume
                | all((.value.labels // {}) | to_entries[];
                    trusted_volume_label(.; $volume)
                    or safe_label(.)
                )
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            SENSITIVE_VALUE \
            'credential-like keys, flags, or values are not permitted in service metadata or commands'
}

vx_compose_policy_check_runtime_bounds() {
    local canonical_json="$1"

    jq -e '
        def bounded_nofile:
            if type == "number" then
                (floor == . and . >= 1 and . <= 1048576)
            elif type == "object" then
                ((keys - ["hard", "soft"]) | length) == 0
                and (.soft | type == "number" and floor == .
                    and . >= 1 and . <= 1048576)
                and (.hard | type == "number" and floor == .
                    and . >= 1 and . <= 1048576)
                and .soft <= .hard
            else
                false
            end;
        all(.services[];
            (
                (.stop_grace_period // null) == null
                or (
                    (.stop_grace_period | type) == "string"
                    and (.stop_grace_period | test("^[1-9][0-9]{0,2}s$"))
                    and (
                        .stop_grace_period
                        | sub("s$"; "")
                        | tonumber
                    ) <= 300
                )
            )
            and (
                ((.ulimits // {}) | length) == 0
                or (
                    ((.ulimits | keys) == ["nofile"])
                    and (.ulimits.nofile | bounded_nofile)
                )
            )
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            RUNTIME_BOUND \
            'stop grace and nofile limits must remain within the bounded runtime contract'
}

vx_compose_policy_check_cap_add() {
    local canonical_json="$1"
    local profile="$2"
    local profile_path allowed

    profile_path="$(vx_compose_profile_path "$profile")" || return 1
    allowed="$(jq -c '.allowed_cap_add // []' "$profile_path")" || return 1
    jq -e --argjson allowed "$allowed" '
        ($allowed | map(ascii_upcase)) as $approved
        | all(.services[];
            ((.cap_add // []) | map(ascii_upcase)) as $requested
            | ($requested | index("ALL") == null)
            and all($requested[]; . as $cap | $approved | index($cap) != null)
        )
    ' "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            CAP_ADD \
            'added Linux capabilities exceed the selected profile'
}

vx_compose_policy_check_managed_secrets() {
    local canonical_json="$1"
    local owner="${2:-}"
    local project="${3:-}"
    local validation_secret_root="${4:-}"
    local allow_runtime_secret_path="${5:-no}"
    local secret_name configured_path expected_path runtime_path validation_path

    if jq -e '
        ((.secrets // {}) | length == 0)
        and all(.services[]; ((.secrets // []) | length == 0))
    ' "$canonical_json" >/dev/null; then
        return 0
    fi
    [[ -n "$owner" && -n "$project" ]] \
        || {
            vx_compose_policy_reject \
                SECRET \
                'secrets must resolve through an existing managed project'
            return 1
        }
    jq -e '
        ((.secrets // {}) | type == "object" and length > 0)
        and all((.secrets // {}) | to_entries[];
            (.key | test("^[a-z][a-z0-9_-]{0,62}$"))
            and (.value.file | type == "string" and length > 0)
            and ((.value.external // false) == false)
        )
        and (. as $root | all(.services[];
            all((.secrets // [])[];
                (.source | type == "string")
                and $root.secrets[.source] != null
                and ((.target // ("/run/secrets/" + .source))
                    | test("^/run/secrets/[a-z][a-z0-9_.-]{0,62}$"))
                and (
                    ((.mode // "0444") | tostring) == "0444"
                    or (.mode // 292) == 292
                )
            )
        ))
    ' "$canonical_json" >/dev/null \
        || {
            vx_compose_policy_reject \
                SECRET \
                'secret declarations exceed the managed read-only contract'
            return 1
        }
    while IFS= read -r secret_name; do
        configured_path="$(jq -r --arg name "$secret_name" \
            '.secrets[$name].file' "$canonical_json")"
        expected_path="$(vx_compose_secret_path "$owner" "$project" "$secret_name")"
        runtime_path="$(vx_compose_runtime_secret_path \
            "$owner" "$project" "$secret_name")"
        validation_path="$expected_path"
        if [[ -n "$validation_secret_root" ]]; then
            validation_path="$validation_secret_root/$secret_name"
        fi
        [[ ( "$configured_path" == "$expected_path"
                || ( "$allow_runtime_secret_path" == yes
                    && "$configured_path" == "$runtime_path" ) )
            && -f "$validation_path"
            && ! -L "$validation_path"
            && "$(stat -c '%a' "$validation_path")" == 600 ]] \
            || {
                vx_compose_policy_reject \
                    SECRET \
                    'secret source is not a protected managed file'
                return 1
            }
    done < <(jq -r '(.secrets // {}) | keys[]' "$canonical_json")
}

vx_compose_policy_evaluate() {
    local canonical_json="$1"
    local profile="${2:-$VX_COMPOSE_DEFAULT_PROFILE}"
    local owner="${3:-}"
    local project="${4:-}"
    local validation_bind_root="${5:-}"
    local validation_secret_root="${6:-}"
    local allow_runtime_secret_path="${7:-no}"

    vx_compose_profile_is_available "$profile" \
        || {
            vx_compose_error "Compose profile is not available: $profile"
            return 1
        }
    jq -e '.services | type == "object" and length > 0' \
        "$canonical_json" >/dev/null \
        || vx_compose_policy_reject \
            SERVICES \
            'at least one service is required'

    vx_compose_policy_require "$canonical_json" IMAGE \
        'every service must use an explicit image' \
        'all(.services[]; (.image | type == "string" and length > 0))' \
        || return 1
    vx_compose_policy_require "$canonical_json" BUILD \
        'image builds are not permitted by this profile' \
        'all(.services[]; (.build // null) == null)' || return 1
    vx_compose_policy_require "$canonical_json" PRIVILEGED \
        'privileged services are not permitted' \
        'all(.services[]; (.privileged // false) == false)' || return 1
    vx_compose_policy_require "$canonical_json" API_SOCKET \
        'Compose daemon API socket access is not permitted' \
        'all(.services[]; (.use_api_socket // false) == false)' || return 1
    vx_compose_policy_check_host_network "$canonical_json" "$profile" || return 1
    vx_compose_policy_require "$canonical_json" HOST_PID \
        'explicit PID namespace modes are not permitted' \
        'all(.services[]; ((.pid // "") == ""))' || return 1
    vx_compose_policy_require "$canonical_json" HOST_IPC \
        'explicit IPC namespace modes are not permitted' \
        'all(.services[]; ((.ipc // "") == ""))' || return 1
    vx_compose_policy_require "$canonical_json" DEVICE \
        'device mappings and requests are not permitted' \
        'all(.services[];
            ((.devices // []) | length == 0)
            and ((.gpus // []) | length == 0)
            and ((.device_cgroup_rules // []) | length == 0)
            and (
                ((((.deploy // {}).resources // {}).reservations // {}).devices // [])
                | length == 0
            )
        )' || return 1
    vx_compose_policy_check_sensitive_values \
        "$canonical_json" "$owner" "$project" || return 1
    vx_compose_policy_check_runtime_bounds "$canonical_json" || return 1
    vx_compose_policy_check_supported_keys "$canonical_json" || return 1
    vx_compose_policy_check_cap_add "$canonical_json" "$profile" || return 1
    vx_compose_policy_check_storage \
        "$canonical_json" "$owner" "$project" "$validation_bind_root" || return 1
    vx_compose_policy_require "$canonical_json" TMPFS \
        'tmpfs mounts are not permitted by this profile' \
        'all(.services[]; ((.tmpfs // []) | length == 0))' || return 1
    vx_compose_policy_check_managed_secrets \
        "$canonical_json" "$owner" "$project" "$validation_secret_root" \
        "$allow_runtime_secret_path" \
        || return 1
    vx_compose_policy_require "$canonical_json" CONFIG \
        'Compose configs are not enabled in this checkpoint' \
        '((.configs // {}) | length == 0)
         and all(.services[]; ((.configs // []) | length == 0))' || return 1
    vx_compose_policy_check_networks \
        "$canonical_json" "$owner" "$project" "$profile" || return 1
    vx_compose_policy_require "$canonical_json" SYSCTL \
        'service sysctls are not permitted' \
        'all(.services[]; ((.sysctls // {}) | length == 0))' || return 1
    vx_compose_policy_require "$canonical_json" ENVIRONMENT \
        'environment keys and values must be non-secret literal data' \
        'all(.services[];
            ((.environment // {}) | type == "object")
            and all(
                (.environment // {}) | to_entries[];
                (.key | test("^[A-Z_][A-Z0-9_]{0,127}$"))
                and (.value | type == "string")
                and (.value | length <= 1024)
                and (.value | test("^[A-Za-z0-9 ._:/@,+-]*$"))
            )
        )' || return 1
    vx_compose_policy_require "$canonical_json" USER_NAMESPACE \
        'custom user namespace modes are not permitted' \
        'all(.services[]; ((.userns_mode // "") == ""))' || return 1
    vx_compose_policy_require "$canonical_json" SCALE \
        'service scaling is not permitted on the managed single host' \
        'all(.services[]; (((.deploy // {}).replicas // 1) | tonumber) == 1)' \
        || return 1
    vx_compose_policy_require "$canonical_json" CAP_DROP \
        'all Linux capabilities must be dropped' \
        'all(.services[];
            ((.cap_drop // []) | map(ascii_upcase) | index("ALL") != null)
        )' || return 1
    vx_compose_policy_require "$canonical_json" SECURITY_OPT \
        'no-new-privileges must be the only security option' \
        'all(.services[];
            ((.security_opt // []) == ["no-new-privileges:true"])
        )' || return 1
    vx_compose_policy_require "$canonical_json" INIT \
        'an init process is required for every service' \
        'all(.services[]; (.init // false) == true)' || return 1
    vx_compose_policy_require "$canonical_json" CPU_LIMIT \
        'a positive CPU limit is required for every service' \
        'all(.services[]; ((.cpus // 0) | tonumber) > 0)' || return 1
    vx_compose_policy_require "$canonical_json" MEMORY_LIMIT \
        'a positive memory limit is required for every service' \
        'all(.services[]; ((.mem_limit // 0) | tonumber) > 0)' || return 1
    vx_compose_policy_require "$canonical_json" PIDS_LIMIT \
        'a positive PID limit is required for every service' \
        'all(.services[]; ((.pids_limit // 0) | tonumber) > 0)' || return 1
    vx_compose_policy_check_ports "$canonical_json" "$profile" || return 1
    vx_compose_policy_require "$canonical_json" LOGGING \
        'bounded json-file logging is required for every service' \
        'all(.services[];
            (.logging.driver // "") == "json-file"
            and ((.logging.options // {})["max-size"] | type == "string")
            and ((.logging.options // {})["max-size"] | test("^[1-9][0-9]*[kKmMgG]$"))
            and (
                ((.logging.options // {})["max-size"]
                    | capture("^(?<amount>[1-9][0-9]*)(?<unit>[kKmMgG])$"))
                | (.amount | tonumber)
                    * (if (.unit | ascii_downcase) == "k" then 1024
                       elif (.unit | ascii_downcase) == "m" then 1048576
                       else 1073741824
                       end)
                | . <= 104857600
            )
            and (
                ((.logging.options // {})["max-file"] | tostring)
                | test("^[1-9][0-9]*$")
            )
            and ((.logging.options // {})["max-file"] | tonumber) <= 10
        )' || return 1
}

vx_compose_write_policy_facts() {
    local canonical_json="$1"
    local profile="$2"
    local output_file="$3"
    local profile_version facts

    profile_version="$(vx_compose_profile_version "$profile")" || return 1
    facts="$(jq -r '
        [
            (.services | length),
            ([.services[].cpus | tonumber * 1000 | round] | add // 0),
            ([.services[].mem_limit | tonumber / 1048576 | ceil] | add // 0),
            ([.services[].pids_limit | tonumber] | add // 0),
            ([.services[] | (.ports // []) | length] | add // 0),
            ((.secrets // {}) | length),
            ((.volumes // {}) | length)
        ] | @tsv
    ' "$canonical_json")" || return 1

    IFS=$'\t' read -r services cpus_milli memory_mb pids ports secrets volumes \
        <<<"$facts"
    {
        printf "POLICY_SCHEMA='%s'\n" "$VX_COMPOSE_POLICY_SCHEMA_VERSION"
        printf "VALIDATOR_VERSION='%s'\n" "$VX_COMPOSE_POLICY_VALIDATOR_VERSION"
        printf "PROFILE='%s'\n" "$profile"
        printf "PROFILE_VERSION='%s'\n" "$profile_version"
        printf "SERVICES='%s'\n" "$services"
        printf "CPUS_MILLI='%s'\n" "$cpus_milli"
        printf "MEMORY_MB='%s'\n" "$memory_mb"
        printf "PIDS='%s'\n" "$pids"
        printf "STORAGE_MB='0'\n"
        printf "PORTS='%s'\n" "$ports"
        printf "SECRETS='%s'\n" "$secrets"
        printf "VOLUMES='%s'\n" "$volumes"
    } >"$output_file"
    chmod 0640 "$output_file"
}
