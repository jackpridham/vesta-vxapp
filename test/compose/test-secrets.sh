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
    printf "VALIDATOR_VERSION='2'\n"
    printf "PROFILE='standard'\n"
    printf "PROFILE_VERSION='2'\n"
    printf "SERVICES='1'\n"
    printf "CPUS_MILLI='250'\n"
    printf "MEMORY_MB='64'\n"
    printf "PIDS='32'\n"
    printf "STORAGE_MB='0'\n"
    printf "PORTS='0'\n"
    printf "SECRETS='0'\n"
    printf "VOLUMES='0'\n"
} >"$candidate/policy.conf"
printf '{}\n' >"$candidate/images.json"
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
jq -e '
    .api_key.NAME == "api_key"
    and (.api_key | keys | sort) == [
        "CREATED", "NAME", "ROTATED", "STATUS", "TARGET", "VERSION"
    ]
    and (.api_key.VERSION | test("^[a-f0-9]{32}$"))
    and .api_key.STATUS == "available"
    and .api_key.ROTATED == ""
    and (.. | objects | has("SHA256") | not)
' "$test_root/list.json" >/dev/null || fail "public secret metadata is unsafe"
first_version="$(jq -r '.api_key.VERSION' "$test_root/list.json")"
integrity_metadata="$(vx_compose_secret_integrity_path alice app)"
[[ -f "$integrity_metadata"
    && "$(stat -c '%a' "$integrity_metadata")" == 600 ]] \
    || fail "private secret integrity metadata is not protected"
if [[ "$EUID" -eq 0 && "$(stat -c '%u:%g' "$integrity_metadata")" != 0:0 ]]; then
    fail "private secret integrity metadata is not root-owned"
fi
jq -e '.api_key.SHA256 | test("^[a-f0-9]{64}$")' \
    "$integrity_metadata" >/dev/null \
    || fail "private secret integrity metadata is incomplete"
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
cp "$managed_model" "$(vx_compose_project_root alice app)/runtime/canonical.json"
: >"$test_root/recreate.calls"
vx_compose_recreate() {
    printf '%s\n' "$3" >>"$test_root/recreate.calls"
}
vx_compose_secret_change alice app api_key "$value_file"
[[ "$(cat "$secret_file")" == rotated-canary-must-not-leak ]] \
    || fail "secret rotation failed"
[[ "$(cat "$test_root/recreate.calls")" == app ]] \
    || fail "secret rotation did not recreate only the affected service"
vx_compose_secret_list_json alice app >"$test_root/rotated-list.json"
jq -e --arg prior "$first_version" '
    .api_key.VERSION != $prior
    and (.api_key.VERSION | test("^[a-f0-9]{32}$"))
    and .api_key.ROTATED != ""
' "$test_root/rotated-list.json" >/dev/null \
    || fail "secret rotation did not issue a new opaque version"

# A collision retries without changing the public encoding or exposing a hash.
printf '0\n' >"$test_root/collision.calls"
vx_compose_secret_version_candidate() {
    local calls
    calls="$(cat "$test_root/collision.calls")"
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$test_root/collision.calls"
    if [[ "$calls" -eq 1 ]]; then
        VX_COMPOSE_SECRET_VERSION_CANDIDATE="$(jq -r '.api_key.VERSION' \
            "$(vx_compose_secret_metadata_path alice app)")"
    else
        VX_COMPOSE_SECRET_VERSION_CANDIDATE="$(printf '%032x' 42)"
    fi
}
collision_value="$test_root/collision-rotation"
printf 'rotated-canary-must-not-leak\n' >"$collision_value"
chmod 0600 "$collision_value"
vx_compose_secret_change alice app api_key "$collision_value"
[[ "$(cat "$test_root/collision.calls")" -eq 2
    && "$(jq -r '.api_key.VERSION' \
        "$(vx_compose_secret_metadata_path alice app)")" \
        == 0000000000000000000000000000002a ]] \
    || fail "opaque secret version collision was not retried"
prior_metadata="$(cat "$(vx_compose_secret_metadata_path alice app)")"
collision_failure="$test_root/collision-failure"
printf 'collision failure canary\n' >"$collision_failure"
chmod 0600 "$collision_failure"
vx_compose_secret_version_candidate() {
    VX_COMPOSE_SECRET_VERSION_CANDIDATE="$(jq -r '.api_key.VERSION' \
        "$(vx_compose_secret_metadata_path alice app)")"
}
if vx_compose_secret_change alice app api_key "$collision_failure" \
    2>"$test_root/collision-failure.stderr"; then
    fail "exhausted opaque version collisions were accepted"
fi
[[ -f "$collision_failure"
    && "$(cat "$(vx_compose_secret_metadata_path alice app)")" \
        == "$prior_metadata" ]] \
    || fail "version collision failure mutated secret metadata or input"
grep -Fq 'unable to allocate a unique Compose secret version' \
    "$test_root/collision-failure.stderr" \
    || fail "version collision exhaustion returned the wrong diagnostic"
unset -f vx_compose_secret_version_candidate
# Restore the production generator after the collision seam override.
# shellcheck source=func/vx/compose/secrets.sh
source "$repo_root/func/vx/compose/secrets.sh"

# Legacy SHA metadata is projected in memory without rewrite or digest exposure.
legacy_metadata="$test_root/legacy-secrets.json"
cp "$(vx_compose_secret_metadata_path alice app)" "$legacy_metadata"
jq '.api_key |= del(.VERSION, .STATUS) |
    .api_key.SHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$legacy_metadata" >"$legacy_metadata.new"
mv "$legacy_metadata.new" "$(vx_compose_secret_metadata_path alice app)"
legacy_before="$(sha256sum "$(vx_compose_secret_metadata_path alice app)")"
vx_compose_secret_list_json alice app >"$test_root/legacy-list.json"
legacy_after="$(sha256sum "$(vx_compose_secret_metadata_path alice app)")"
[[ "$legacy_before" == "$legacy_after" ]] \
    || fail "legacy read rewrote secret metadata"
jq -e '
    (.api_key | keys | sort) == [
        "CREATED", "NAME", "ROTATED", "STATUS", "TARGET", "VERSION"
    ]
    and (.api_key.VERSION | test("^[a-f0-9]{32}$"))
    and (tostring | contains("aaaaaaaaaaaaaaaa") | not)
' "$test_root/legacy-list.json" >/dev/null \
    || fail "legacy secret read exposed an integrity digest"
cp "$legacy_metadata" "$(vx_compose_secret_metadata_path alice app)"

# A failed new-inode bind restores value+metadata, rebinds the old inode, keeps
# caller input for retry, and redacts both generations.
prior_metadata="$(cat "$(vx_compose_secret_metadata_path alice app)")"
failed_value="$test_root/failed-rotation"
printf 'failed-new-canary-must-not-leak\n' >"$failed_value"
chmod 0600 "$failed_value"
recreate_attempt=0
vx_compose_recreate() {
    recreate_attempt=$((recreate_attempt + 1))
    [[ "$recreate_attempt" -gt 1 ]]
}
if vx_compose_secret_change alice app api_key "$failed_value" \
    2>"$test_root/change-failed.stderr"; then
    fail "failed secret runtime rebind reported success"
fi
[[ -f "$failed_value"
    && "$(cat "$secret_file")" == rotated-canary-must-not-leak
    && "$(cat "$(vx_compose_secret_metadata_path alice app)")" \
        == "$prior_metadata"
    && "$recreate_attempt" -eq 2 ]] \
    || fail "failed secret rotation did not restore value/metadata/runtime"
if grep -Fq -e 'rotated-canary-must-not-leak' \
    -e 'failed-new-canary-must-not-leak' \
    "$(vx_compose_project_root alice app)/audit.log" \
    "$(vx_compose_project_root alice app)/runtime/last-operation.json" \
    "$test_root/change-failed.stderr"; then
    fail "secret rotation failure leaked old or new values"
fi

copy_fail_value="$test_root/copy-fail-rotation"
printf 'copy-fail-new-canary\n' >"$copy_fail_value"
chmod 0600 "$copy_fail_value"
prior_metadata="$(cat "$(vx_compose_secret_metadata_path alice app)")"
if VX_COMPOSE_TEST_SECRET_COPY_FAIL=old \
    vx_compose_secret_change alice app api_key "$copy_fail_value" \
    2>"$test_root/copy-fail.stderr"; then
    fail "failed secret rollback-copy setup reported success"
fi
[[ -f "$copy_fail_value"
    && "$(cat "$secret_file")" == rotated-canary-must-not-leak
    && "$(cat "$(vx_compose_secret_metadata_path alice app)")" \
        == "$prior_metadata" ]] \
    || fail "setup-copy failure altered secret, metadata, or caller input"
if grep -Fq copy-fail-new-canary \
    "$(vx_compose_project_root alice app)/audit.log" \
    "$(vx_compose_project_root alice app)/runtime/last-operation.json" \
    "$test_root/copy-fail.stderr"; then
    fail "setup-copy failure leaked the new secret"
fi
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
