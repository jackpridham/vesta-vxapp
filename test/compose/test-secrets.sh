#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$VESTA/data/users/bob" "$HOMEDIR/alice" "$HOMEDIR/bob"
for owner in alice bob; do
    {
        printf "DOCKER_PROJECTS='2'\n"
        printf "DOCKER_SERVICES='2'\n"
        printf "DOCKER_CPUS='1.000'\n"
        printf "DOCKER_MEMORY_MB='512'\n"
        printf "DOCKER_PIDS='128'\n"
        printf "DOCKER_STORAGE_MB='64'\n"
        printf "DOCKER_PORTS='2'\n"
        printf "DOCKER_SECRETS='1'\n"
        printf "DOCKER_VOLUMES='0'\n"
    } >"$VESTA/data/users/$owner/user.conf"
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

candidate="$test_root/candidate"
mkdir -p "$candidate"
printf 'services: {app: {image: alpine:3.20}}\n' >"$candidate/compose.yaml"
printf '{"name":"vx-alice-app","services":{"app":{"image":"alpine:3.20"}}}\n' \
    >"$candidate/canonical.json"
(
    cd "$candidate"
    sha256sum canonical.json >canonical.sha256
)
{
    printf "POLICY_SCHEMA='1'\n"
    printf "VALIDATOR_VERSION='1'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='1'\n"
    printf "SERVICES='1'\n"
    printf "CPUS_MILLI='250'\n"
    printf "MEMORY_MB='64'\n"
    printf "PIDS='32'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"
vx_compose_store_new alice app standard "$candidate"

value_file="$test_root/value"
printf 'secret-canary-must-not-leak\n' >"$value_file"
chmod 0600 "$value_file"
vx_compose_secret_add alice app api_key "$value_file" \
    >"$test_root/add.stdout" 2>"$test_root/add.stderr"
secret_file="$(vx_compose_secret_path alice app api_key)"
[[ ! -e "$value_file" ]] || fail "consumed secret input was not removed"
[[ "$(stat -c '%a' "$secret_file")" == 600 ]] || fail "secret mode is wrong"
[[ "$(cat "$secret_file")" == secret-canary-must-not-leak ]] \
    || fail "secret value was not installed"

managed_model="$test_root/managed-secret.json"
jq -n --arg secret_file "$secret_file" '{
    name: "vx-alice-app",
    secrets: {api_key: {file: $secret_file}},
    services: {
        app: {
            image: "alpine:3.20",
            init: true,
            cap_drop: ["ALL"],
            security_opt: ["no-new-privileges:true"],
            cpus: 0.25,
            mem_limit: "67108864",
            pids_limit: 32,
            secrets: [{
                source: "api_key",
                target: "/run/secrets/api_key",
                mode: 292
            }],
            logging: {
                driver: "json-file",
                options: {"max-size": "10m", "max-file": "3"}
            }
        }
    }
}' >"$managed_model"
vx_compose_policy_evaluate "$managed_model" standard alice app \
    || fail "managed read-only secret model was rejected"
vx_compose_write_policy_facts "$managed_model" standard "$test_root/managed-policy.conf"
grep -Fq "SECRETS='1'" "$test_root/managed-policy.conf" \
    || fail "managed secret usage was not counted"

secret_compose="$test_root/secret.compose.yaml"
{
    printf '%s\n' 'services:'
    printf '%s\n' '  app:'
    printf '%s\n' '    image: alpine:3.20'
    printf '%s\n' '    init: true'
    printf '%s\n' '    cap_drop: [ALL]'
    printf '%s\n' '    security_opt: [no-new-privileges:true]'
    printf '%s\n' '    cpus: 0.25'
    printf '%s\n' '    mem_limit: 64m'
    printf '%s\n' '    pids_limit: 32'
    printf '%s\n' '    secrets:'
    printf '%s\n' '      - source: api_key'
    printf '%s\n' '        target: /run/secrets/api_key'
    printf '%s\n' '        mode: 0444'
    printf '%s\n' '    logging:'
    printf '%s\n' '      driver: json-file'
    printf '%s\n' '      options:'
    printf '%s\n' '        max-size: 10m'
    printf '%s\n' '        max-file: "3"'
    printf '%s\n' 'secrets:'
    printf '%s\n' '  api_key:'
    printf '    file: %s\n' "$secret_file"
} >"$secret_compose"
vx_compose_prepare_candidate \
    alice app "$secret_compose" "$test_root/secret-candidate"
jq -e '
    .secrets.api_key.file != null
    and .services.app.secrets[0].target == "/run/secrets/api_key"
' "$test_root/secret-candidate/canonical.json" >/dev/null \
    || fail "managed secret was not canonicalized"

vx_compose_secret_list_json alice app >"$test_root/list.json"
jq -e '.api_key.NAME == "api_key" and .api_key.SHA256 != ""' \
    "$test_root/list.json" >/dev/null || fail "secret metadata is incomplete"
if grep -F 'secret-canary-must-not-leak' \
    "$test_root/list.json" \
    "$test_root/add.stdout" \
    "$test_root/add.stderr" \
    "$(vx_compose_project_root alice app)/audit.log" \
    "$(vx_compose_project_root alice app)/secrets.json"; then
    fail "secret value leaked into metadata or audit"
fi
if vx_compose_secret_list_json bob app 2>/dev/null; then
    fail "cross-owner secret listing succeeded"
fi

second="$test_root/second"
printf 'second secret\n' >"$second"
chmod 0600 "$second"
if vx_compose_secret_add alice app second "$second" 2>"$test_root/quota.error"; then
    fail "secret quota overage was accepted"
fi
grep -Fq 'Compose quota exceeded [DOCKER_SECRETS]' "$test_root/quota.error" \
    || fail "secret quota returned the wrong diagnostic"

printf 'rotated-canary-must-not-leak\n' >"$value_file"
chmod 0600 "$value_file"
vx_compose_secret_change alice app api_key "$value_file"
[[ "$(cat "$secret_file")" == rotated-canary-must-not-leak ]] \
    || fail "secret rotation failed"
cp "$managed_model" "$(vx_compose_project_root alice app)/runtime/canonical.json"
if vx_compose_secret_delete alice app api_key 2>"$test_root/referenced.error"; then
    fail "referenced secret deletion was accepted"
fi
grep -Fq 'referenced by the current revision' "$test_root/referenced.error" \
    || fail "referenced secret returned the wrong diagnostic"
jq 'del(.secrets) | .services.app |= del(.secrets)' "$managed_model" \
    >"$(vx_compose_project_root alice app)/runtime/canonical.json"
vx_compose_secret_delete alice app api_key
[[ ! -e "$secret_file" ]] || fail "secret deletion retained the value"

printf 'encryption canary\n' >"$test_root/plaintext"
if vx_compose_age_encrypt "$test_root/plaintext" "$test_root/payload.age" \
    2>"$test_root/age.error"; then
    fail "secret encryption succeeded without configured age support"
fi
grep -Eq 'age encryption (is not installed|recipient is not configured)' \
    "$test_root/age.error" || fail "age fail-closed diagnostic is wrong"

echo "Compose secret tests passed."
