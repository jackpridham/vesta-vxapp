#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
grep -Fq 'vx_compose_shell_require_standard_project' "$repo_root/bin/v-run-user-docker-command" \
    || { echo 'FAIL: shell broker omits standard-project enforcement' >&2; exit 1; }
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(vx_compose_profile_version standard)" == 2 ]] \
    || fail "standard profile version is unavailable"
vx_compose_profile_is_available standard \
    || fail "standard profile is not enabled"
vx_compose_profile_is_available admin-approved \
    || fail "admin-approved profile definition is unavailable"
[[ "$(vx_compose_profile_version admin-approved)" == 3 ]] \
    || fail "admin-approved bridge-only profile version is unavailable"
if vx_compose_profile_require_authorized \
    alice app admin-approved 2>/dev/null; then
    fail "admin-approved profile was usable without an assignment"
fi
vx_compose_profile_is_available restricted-compatibility \
    || fail "restricted-compatibility profile is not enabled"
[[ "$(vx_compose_profile_version restricted-compatibility)" == 2 ]] \
    || fail "restricted-compatibility profile version is unavailable"
jq -e '
    .enabled == true
    and .admin_only == true
    and .allow_bind_mounts == false
    and .allow_public_ports == false
    and .allow_host_namespaces == false
    and .allowed_cap_add
        == ["CHOWN", "DAC_OVERRIDE", "KILL", "SETGID", "SETUID"]
' "$repo_root/func/vx/compose/profiles/restricted-compatibility.json" >/dev/null \
    || fail "restricted-compatibility profile data exceeds its narrow contract"

base_service='{
    "image": "alpine:3.20",
    "init": true,
    "cap_drop": ["ALL"],
    "security_opt": ["no-new-privileges:true"],
    "cpus": 0.25,
    "mem_limit": "67108864",
    "pids_limit": 32,
    "logging": {
        "driver": "json-file",
        "options": {"max-size": "10m", "max-file": "3"}
    }
}'

compatibility_model="$test_root/compatibility-profile.json"
jq -n --argjson service "$base_service" '
    {
        services: {
            app: ($service + {
                cap_add: ["CHOWN", "DAC_OVERRIDE", "KILL", "SETGID", "SETUID"]
            })
        }
    }
' >"$compatibility_model"
vx_compose_policy_evaluate "$compatibility_model" restricted-compatibility \
    || fail "restricted-compatibility profile rejected its exact capabilities"
for rejected_capability in MKNOD NET_ADMIN SYS_ADMIN; do
    jq --arg capability "$rejected_capability" \
        '.services.app.cap_add += [$capability]' \
        "$compatibility_model" >"$test_root/compatibility-$rejected_capability.json"
    if vx_compose_policy_evaluate \
        "$test_root/compatibility-$rejected_capability.json" restricted-compatibility \
        2>"$test_root/compatibility-$rejected_capability.error"; then
        fail "restricted-compatibility profile accepted $rejected_capability"
    fi
    grep -Fq 'Compose policy rejection [CAP_ADD]' \
        "$test_root/compatibility-$rejected_capability.error" \
        || fail "restricted-compatibility $rejected_capability returned wrong diagnostic"
done

expect_rejection() {
    local name="$1"
    local code="$2"
    local filter="$3"
    local fixture="$test_root/$name.json"
    local error_file="$test_root/$name.error"

    jq -n --argjson service "$base_service" \
        '{name: "vx-alice-test", services: {app: $service}}' \
        | jq "$filter" >"$fixture"
    if vx_compose_policy_evaluate "$fixture" standard 2>"$error_file"; then
        fail "$name input was accepted"
    fi
    grep -Fq "Compose policy rejection [$code]" "$error_file" \
        || fail "$name returned the wrong diagnostic"
    if grep -Fq 'must-not-leak' "$error_file"; then
        fail "$name diagnostic leaked an input value"
    fi
}

expect_rejection privileged PRIVILEGED \
    '.services.app.privileged = true'
expect_rejection build BUILD \
    '.services.app.build = {"context": "/tmp/must-not-leak"}'
expect_rejection host_network HOST_NETWORK \
    '.services.app.network_mode = "host"'
expect_rejection host_pid HOST_PID \
    '.services.app.pid = "host"'
expect_rejection host_ipc HOST_IPC \
    '.services.app.ipc = "host"'
expect_rejection device DEVICE \
    '.services.app.devices = ["/dev/must-not-leak:/dev/x"]'
expect_rejection gpu_reservation DEVICE \
    '.services.app.deploy.resources.reservations.devices = [{
        capabilities: ["gpu"],
        count: -1
    }]'
expect_rejection device_request DEVICE \
    '.services.app.gpus = "all"'
expect_rejection compose_api_socket API_SOCKET \
    '.services.app.use_api_socket = true'
expect_rejection cap_add CAP_ADD \
    '.services.app.cap_add = ["NET_ADMIN"]'
expect_rejection docker_socket MOUNT \
    '.services.app.volumes = [{type: "bind", source: "/var/run/docker.sock", target: "/run/x"}]'
expect_rejection root_mount MOUNT \
    '.services.app.volumes = [{type: "bind", source: "/", target: "/host"}]'
expect_rejection tmpfs TMPFS \
    '.services.app.tmpfs = ["/run"]'
expect_rejection external_network EXTERNAL_NETWORK \
    '.networks.shared.external = true | .services.app.networks.shared = null'
expect_rejection unsafe_security SECURITY_OPT \
    '.services.app.security_opt += ["apparmor:unconfined"]'
expect_rejection missing_init INIT \
    'del(.services.app.init)'
expect_rejection missing_caps CAP_DROP \
    'del(.services.app.cap_drop)'
expect_rejection missing_cpu CPU_LIMIT \
    'del(.services.app.cpus)'
expect_rejection missing_memory MEMORY_LIMIT \
    'del(.services.app.mem_limit)'
expect_rejection missing_pids PIDS_LIMIT \
    'del(.services.app.pids_limit)'
expect_rejection public_port PUBLIC_PORT \
    '.services.app.ports = [{host_ip: "0.0.0.0", published: "12345", target: 80}]'
expect_rejection environment SENSITIVE_VALUE \
    '.services.app.environment = {SECRET: "must-not-leak"}'
safe_environment="$test_root/safe-environment.json"
jq -n \
    --arg value 'production-us-east-1' \
    --argjson service "$base_service" \
    '{services: {app: ($service + {environment: {APP_MODE: $value}})}}' \
    >"$safe_environment"
vx_compose_policy_evaluate "$safe_environment" standard \
    || fail "literal non-secret environment data was rejected"
expect_rejection command_secret SENSITIVE_VALUE \
    '.services.app.command = ["password=must-not-leak"]'
expect_rejection command_secret_flag SENSITIVE_VALUE \
    '.services.app.command = ["run", "--token", "must-not-leak"]'
expect_rejection entrypoint_secret_flag SENSITIVE_VALUE \
    '.services.app.entrypoint = ["entry", "--api-key", "must-not-leak"]'
expect_rejection health_secret_flag SENSITIVE_VALUE \
    '.services.app.healthcheck.test = [
        "CMD", "check", "--password", "must-not-leak"
    ]'
expect_rejection label_secret_key SENSITIVE_VALUE \
    '.services.app.labels = {"API_TOKEN": "must-not-leak"}'
expect_rejection user_namespace USER_NAMESPACE \
    '.services.app.userns_mode = "host"'
expect_rejection scale SCALE \
    '.services.app.deploy.replicas = 2'
expect_rejection sysctl SYSCTL \
    '.services.app.sysctls = {"net.ipv4.ip_forward": "1"}'
expect_rejection secret SECRET \
    '.secrets.token.file = "/tmp/must-not-leak"
     | .services.app.secrets = [{source: "token"}]'
managed_root="$VESTA/data/users/alice/docker-projects/runtime-policy"
mkdir -p "$managed_root/secrets"
chmod 0700 "$managed_root/secrets"
printf 'value\n' >"$managed_root/secrets/token"
chmod 0600 "$managed_root/secrets/token"
runtime_secret_model="$test_root/runtime-secret-model.json"
jq -n --arg source "$managed_root/runtime/workload-secrets/current/token" '{
  secrets:{token:{file:$source}},
  services:{app:{secrets:[{source:"token",target:"/run/secrets/token"}]}}
}' >"$runtime_secret_model"
if vx_compose_policy_check_managed_secrets \
    "$runtime_secret_model" alice runtime-policy 2>/dev/null; then
    fail 'generic project policy accepted a workload runtime secret path'
fi
vx_compose_policy_check_managed_secrets \
    "$runtime_secret_model" alice runtime-policy '' yes \
    || fail 'validated workload authority could not use its runtime secret path'
expect_rejection config CONFIG \
    '.configs.app.file = "/tmp/must-not-leak" | .services.app.configs = ["app"]'
expect_rejection unbounded_logging LOGGING \
    '.services.app.logging = {"driver": "json-file"}'
expect_rejection excessive_log_size LOGGING \
    '.services.app.logging.options["max-size"] = "101m"'
expect_rejection excessive_log_files LOGGING \
    '.services.app.logging.options["max-file"] = "11"'
expect_rejection excessive_stop_grace RUNTIME_BOUND \
    '.services.app.stop_grace_period = "301s"'
expect_rejection unsupported_ulimit RUNTIME_BOUND \
    '.services.app.ulimits.core = {"soft": 1, "hard": 1}'
expect_rejection unbounded_nofile RUNTIME_BOUND \
    '.services.app.ulimits.nofile = {"soft": -1, "hard": -1}'
expect_rejection unsupported_service_key UNSUPPORTED_KEY \
    '.services.app.provider = {"type": "must-not-leak"}'
expect_rejection unsupported_service_hook UNSUPPORTED_KEY \
    '.services.app.post_start = [{"command": ["true"]}]'
expect_rejection unsupported_root_key UNSUPPORTED_KEY \
    '.models.must_not_leak = {"model": "example"}'

expect_candidate_rejection() {
    local name="$1"
    local code="$2"
    local overlay="$3"
    local rendered="$test_root/$name.compose.yaml"
    local output_root="$test_root/$name-candidate"
    local error_file="$test_root/$name-candidate.error"
    local render_error="$test_root/$name-render.error"

    if ! docker compose \
        --project-name "vx-policy-$name" \
        --file "$repo_root/test/compose/fixtures/basic-http.compose.yaml" \
        --file "$overlay" \
        config >"$rendered" 2>"$render_error"; then
        if [[ "$code" == API_SOCKET ]] \
            && grep -Fq 'use_api_socket' "$render_error"; then
            return
        fi
        cat "$render_error" >&2
        fail "$name malicious fixture did not reach a fail-closed parser boundary"
    fi
    docker compose --file "$rendered" config --format json >/dev/null \
        || fail "$name malicious fixture did not render"
    if vx_compose_prepare_candidate \
        alice "$name" "$rendered" "$output_root" 2>"$error_file"; then
        fail "$name malicious fixture reached accepted candidate state"
    fi
    grep -Fq "Compose policy rejection [$code]" "$error_file" \
        || fail "$name malicious fixture returned the wrong diagnostic"
    if grep -Fq 'must-not-leak' "$error_file"; then
        fail "$name malicious fixture leaked an input value"
    fi
}

expect_candidate_rejection api-socket API_SOCKET \
    "$repo_root/test/compose/fixtures/malicious/compose-api-socket.yaml"
expect_candidate_rejection gpu-request DEVICE \
    "$repo_root/test/compose/fixtures/malicious/gpu-reservation.yaml"
expect_candidate_rejection unbounded-runtime RUNTIME_BOUND \
    "$repo_root/test/compose/fixtures/malicious/unbounded-runtime.yaml"

expect_candidate_yaml_rejection() {
    local name="$1"
    local code="$2"
    local overlay="$test_root/$name.overlay.yaml"

    command cat >"$overlay"
    expect_candidate_rejection "$name" "$code" "$overlay"
}

expect_candidate_yaml_rejection service-authorization SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      authorization: must-not-leak
EOF
expect_candidate_yaml_rejection service-bearer SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      bearer: must-not-leak
EOF
expect_candidate_yaml_rejection service-private-key SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      privateKey: must-not-leak
EOF
expect_candidate_yaml_rejection service-access-token SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      accessToken: must-not-leak
EOF
expect_candidate_yaml_rejection service-client-key SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      client-key: must-not-leak
EOF
expect_candidate_yaml_rejection service-concatenated SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      clientsecret: must-not-leak
EOF
expect_candidate_yaml_rejection service-url-userinfo SENSITIVE_VALUE <<'EOF'
services:
  web:
    labels:
      endpoint: https://must-not-leak@example.invalid/api
EOF
expect_candidate_yaml_rejection environment-auth-camel SENSITIVE_VALUE <<'EOF'
services:
  web:
    environment:
      authHeader: must-not-leak
EOF
expect_candidate_yaml_rejection environment-access-concatenated SENSITIVE_VALUE <<'EOF'
services:
  web:
    environment:
      ACCESSTOKEN: must-not-leak
EOF
expect_candidate_yaml_rejection command-bearer SENSITIVE_VALUE <<'EOF'
services:
  web:
    command:
      - run
      - --authorization
      - Bearer must-not-leak
EOF
expect_candidate_yaml_rejection command-url-userinfo SENSITIVE_VALUE <<'EOF'
services:
  web:
    command:
      - fetch
      - https://must-not-leak@example.invalid/archive
EOF
expect_candidate_yaml_rejection network-authorization SENSITIVE_VALUE <<'EOF'
services:
  web:
    networks:
      - internal
networks:
  internal:
    labels:
      authorization: must-not-leak
EOF
expect_candidate_yaml_rejection volume-client-key SENSITIVE_VALUE <<'EOF'
services:
  web:
    volumes:
      - state:/srv/state
volumes:
  state:
    labels:
      clientKey: must-not-leak
EOF

expect_candidate_yaml_rejection service-compose-label OWNERSHIP_LABEL <<'EOF'
services:
  web:
    labels:
      com.docker.compose.project: must-not-leak
EOF
expect_candidate_yaml_rejection service-vx-label OWNERSHIP_LABEL <<'EOF'
services:
  web:
    labels:
      vx.custom: must-not-leak
EOF
expect_candidate_yaml_rejection network-compose-label NETWORK_OWNERSHIP <<'EOF'
services:
  web:
    networks:
      - internal
networks:
  internal:
    labels:
      com.docker.compose.network: must-not-leak
EOF
expect_candidate_yaml_rejection network-vx-label NETWORK_OWNERSHIP <<'EOF'
services:
  web:
    networks:
      - internal
networks:
  internal:
    labels:
      vx.user: must-not-leak
EOF
expect_candidate_yaml_rejection volume-compose-label VOLUME_OWNERSHIP <<'EOF'
services:
  web:
    volumes:
      - state:/srv/state
volumes:
  state:
    labels:
      com.docker.compose.volume: must-not-leak
EOF
expect_candidate_yaml_rejection volume-vx-label VOLUME_OWNERSHIP <<'EOF'
services:
  web:
    volumes:
      - state:/srv/state
volumes:
  state:
    labels:
      vx.volume: must-not-leak
EOF

trusted_candidate="$test_root/trusted-ownership-candidate"
vx_compose_prepare_candidate \
    alice access-token \
    "$repo_root/test/compose/fixtures/no-port.compose.yaml" \
    "$trusted_candidate" \
    || fail "exact injected ownership labels were treated as credentials"
jq -e '
    .services.app.labels["vx.managed"] == "yes"
    and .services.app.labels["vx.user"] == "alice"
    and .services.app.labels["vx.project"] == "access-token"
' "$trusted_candidate/canonical.json" >/dev/null \
    || fail "candidate did not preserve exact trusted ownership labels"

trusted_resources_overlay="$test_root/trusted-resources.overlay.yaml"
trusted_resources_input="$test_root/trusted-resources.compose.yaml"
trusted_resources_candidate="$test_root/trusted-resources-candidate"
command cat >"$trusted_resources_overlay" <<'EOF'
services:
  web:
    networks:
      - access-token
    volumes:
      - client_key:/srv/state
networks:
  access-token: {}
volumes:
  client_key: {}
EOF
docker compose \
    --project-name vx-policy-trusted-resources \
    --file "$repo_root/test/compose/fixtures/basic-http.compose.yaml" \
    --file "$trusted_resources_overlay" \
    config >"$trusted_resources_input"
vx_compose_prepare_candidate \
    alice trusted-resources \
    "$trusted_resources_input" \
    "$trusted_resources_candidate" \
    || fail "exact injected network or volume labels were treated as credentials"
jq -e '
    .networks["access-token"].labels["vx.network"] == "access-token"
    and .volumes.client_key.labels["vx.volume"] == "client_key"
' "$trusted_resources_candidate/canonical.json" >/dev/null \
    || fail "candidate did not preserve exact trusted resource labels"

for valid_fixture in \
    basic-http.compose.yaml \
    host-network.compose.yaml \
    no-port.compose.yaml \
    persistent-stack.compose.yaml \
    port-range.compose.yaml \
    public-http.compose.yaml \
    tcp-udp.compose.yaml
do
    docker compose \
        --project-name vx-policy-valid \
        --file "$repo_root/test/compose/fixtures/$valid_fixture" \
        config --format json >"$test_root/$valid_fixture.json"
    vx_compose_policy_check_supported_keys \
        "$test_root/$valid_fixture.json" \
        || fail "$valid_fixture exceeds the closed rendered-key model"
done

valid="$test_root/valid.json"
jq -n --argjson service "$base_service" \
    '{name: "vx-alice-test", services: {app: $service}}' >"$valid"
vx_compose_policy_evaluate "$valid" standard
vx_compose_write_policy_facts "$valid" standard "$test_root/policy.conf"

grep -Fq "PROFILE_VERSION='2'" "$test_root/policy.conf" \
    || fail "profile version was not recorded"
grep -Fq "VALIDATOR_VERSION='2'" "$test_root/policy.conf" \
    || fail "validator version was not recorded"
grep -Fq "SERVICES='1'" "$test_root/policy.conf" \
    || fail "service usage was not recorded"
grep -Fq "CPUS_MILLI='250'" "$test_root/policy.conf" \
    || fail "CPU usage was not normalized"
grep -Fq "MEMORY_MB='64'" "$test_root/policy.conf" \
    || fail "memory usage was not normalized"
grep -Fq "PIDS='32'" "$test_root/policy.conf" \
    || fail "PID usage was not recorded"

reserved="$test_root/reserved.json"
jq -n --argjson service "$base_service" \
    '{services: {app: ($service + {labels: {"vx.user": "must-not-leak"}})}}' \
    >"$reserved"
if vx_compose_policy_check_reserved_labels "$reserved" 2>"$test_root/reserved.error"; then
    fail "reserved ownership label override was accepted"
fi
grep -Fq 'Compose policy rejection [OWNERSHIP_LABEL]' "$test_root/reserved.error" \
    || fail "ownership label override returned the wrong diagnostic"

echo "Compose policy tests passed."
