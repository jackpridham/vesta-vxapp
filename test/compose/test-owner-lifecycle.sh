#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

for command in v-sync-docker-shell-access v-sync-docker-shell-access-all; do
    grep -Fq 'vesta-compose-users' "$repo_root/bin/$command" \
        || { echo "FAIL: $command omits dedicated group" >&2; exit 1; }
    if grep -Eqi '(groupadd|usermod|gpasswd)[^#]*[[:space:]]docker([[:space:]]|$)' "$repo_root/bin/$command"; then
        echo "FAIL: $command references docker group" >&2
        exit 1
    fi
done

for owner_command in v-suspend-user v-unsuspend-user v-change-user-package v-change-user-shell v-delete-user; do
    grep -Fq 'vx_compose_shell_access_lock_acquire "$user"' "$repo_root/bin/$owner_command" \
        || { echo "FAIL: $owner_command omits Compose owner access lock" >&2; exit 1; }
done
for enable_command in v-unsuspend-user v-change-user-package v-change-user-shell; do
    grep -Fq 'vx_compose_shell_access_deny_establish "$user"' "$repo_root/bin/$enable_command" \
        || { echo "FAIL: $enable_command omits fail-closed deny marker" >&2; exit 1; }
    grep -Fq 'vx_compose_shell_access_transition_complete "$user"' "$repo_root/bin/$enable_command" \
        || { echo "FAIL: $enable_command clears denial before terminal success" >&2; exit 1; }
done
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice" "$HOMEDIR/alice"
{
    printf "DOCKER_PROJECTS='4'\n"
    printf "DOCKER_SERVICES='8'\n"
    printf "DOCKER_CPUS='4.000'\n"
    printf "DOCKER_MEMORY_MB='4096'\n"
    printf "DOCKER_PIDS='512'\n"
    printf "DOCKER_STORAGE_MB='128'\n"
    printf "DOCKER_PORTS='8'\n"
    printf "DOCKER_SECRETS='0'\n"
    printf "DOCKER_VOLUMES='0'\n"
} >"$VESTA/data/users/alice/user.conf"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

fake_docker="$test_root/fake-docker"
docker_log="$test_root/docker.log"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf '%s\n' 'state_file="$(dirname -- "$0")/web-runtime-present"'
    # The generated helper must expand these values when it runs.
    # shellcheck disable=SC2016
    printf '%s\n' 'printf "%s\n" "$*" >>"$(dirname -- "$0")/docker.log"'
    printf '%s\n' 'if [[ " $* " == *" compose "*" up "* ]]; then'
    printf '%s\n' '  : >"$state_file"'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ " $* " == *" compose "*" stop "* || " $* " == *" compose "*" down "* ]]; then'
    printf '%s\n' '  rm -f -- "$state_file"'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ " $* " == *" ps -aq "*"label=com.docker.compose.project=vx-alice-web"* && -f "$state_file" ]]; then'
    printf '%s\n' '  printf "%064d\n" 1'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ "$1" == inspect && "${2:-}" =~ ^[a-f0-9]{12,64}$ ]]; then'
    printf '%s\n' \
        '  printf "%s\n" '"'"'[{"Config":{"Labels":{"com.docker.compose.project":"vx-alice-web","com.docker.compose.service":"app","vx.managed":"yes","vx.user":"alice","vx.project":"web","vx.revision":"1","vx.image-id":"sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"}},"Image":"sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"}]'"'"
    printf '%s\n' 'fi'
    printf '%s\n' 'if [[ " $* " == *" image inspect "* ]]; then'
    printf '%s\n' \
        '  printf "%s\n" '"'"'{"Id":"sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface","RepoTags":["alpine:3.20"],"RepoDigests":["alpine@sha256:feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"],"Architecture":"amd64","Os":"linux"}'"'"
    printf '%s\n' 'fi'
} >"$fake_docker"
chmod 0755 "$fake_docker"
export VX_COMPOSE_DOCKER_BIN="$fake_docker"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

# Derived membership ignores current group trust and follows authoritative
# quota, suspension, shell, and passwd identity.
cat >>"$VESTA/data/users/alice/user.conf" <<'EOF'
SUSPENDED='no'
SHELL='bash'
EOF
chmod 0600 "$VESTA/data/users/alice/user.conf"
vx_compose_authority_uid() { id -u; }
vx_compose_shell_actor_uid() { printf '%s\n' 1001; }
vx_compose_shell_actor_gids() { printf '%s\n' 1001; }
vx_compose_shell_passwd_by_name() { printf 'alice:x:1001:1001::%s/alice:/bin/bash\n' "$HOMEDIR"; }
vx_compose_shell_should_be_group_member alice || fail 'eligible Bash user was denied derived membership'
sed -i "s/DOCKER_PROJECTS='4'/DOCKER_PROJECTS='0'/" "$VESTA/data/users/alice/user.conf"
if vx_compose_shell_should_be_group_member alice; then fail 'zero quota retained derived membership'; fi
sed -i "s/DOCKER_PROJECTS='0'/DOCKER_PROJECTS='unlimited'/" "$VESTA/data/users/alice/user.conf"
vx_compose_shell_should_be_group_member alice || fail 'unlimited quota did not restore derived membership'
sed -i "s/SHELL='bash'/SHELL='nologin'/" "$VESTA/data/users/alice/user.conf"
if vx_compose_shell_should_be_group_member alice; then fail 'nologin retained derived membership'; fi
sed -i "s/SHELL='nologin'/SHELL='bash'/" "$VESTA/data/users/alice/user.conf"
sed -i "s/SUSPENDED='no'/SUSPENDED='yes'/" "$VESTA/data/users/alice/user.conf"
if vx_compose_shell_should_be_group_member alice; then fail 'suspended user retained derived membership'; fi
sed -i "s/SUSPENDED='yes'/SUSPENDED='no'/" "$VESTA/data/users/alice/user.conf"
grep -Fq '"$uid" == "$SUDO_UID"' "$repo_root/func/vx/compose/shell-access.sh" \
    || fail 'broker identity does not reject a stale UID for the same username'
sed -i "s/DOCKER_PROJECTS='unlimited'/DOCKER_PROJECTS='4'/" "$VESTA/data/users/alice/user.conf"

make_project() {
    local project="$1"
    local state="$2"
    local candidate="$test_root/$project-candidate"

    mkdir -p "$candidate"
    printf 'services: {app: {image: alpine:3.20}}\n' >"$candidate/compose.yaml"
    jq -n --arg name "vx-alice-$project" '{
        name: $name,
        services: {
            app: {
                image: "alpine:3.20",
                init: true,
                cap_drop: ["ALL"],
                security_opt: ["no-new-privileges:true"],
                cpus: 0.25,
                mem_limit: "67108864",
                pids_limit: 32,
                labels: {
                    "vx.managed": "yes",
                    "vx.user": "alice",
                    "vx.project": ($name | sub("^vx-alice-"; ""))
                },
                logging: {
                    driver: "json-file",
                    options: {"max-size": "10m", "max-file": "3"}
                }
            }
        }
    }' >"$candidate/canonical.json"
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
    vx_compose_store_new alice "$project" standard "$candidate"
    vx_compose_update_state alice "$project" "$state"
}

make_project web running
make_project worker stopped

vx_compose_suspend_owner alice
[[ "$(vx_compose_meta_get "$(vx_compose_project_root alice web)/project.conf" STATE)" == stopped ]] \
    || fail "suspend did not stop the running project"
[[ "$(vx_compose_meta_get "$(vx_compose_project_root alice worker)/project.conf" STATE)" == stopped ]] \
    || fail "suspend changed the stopped project incorrectly"
grep -Fxq web "$(vx_compose_projects_root alice)/.suspended-running" \
    || fail "suspend did not record desired running state"

vx_compose_unsuspend_owner alice
[[ "$(vx_compose_meta_get "$(vx_compose_project_root alice web)/project.conf" STATE)" == running ]] \
    || fail "unsuspend did not restore the running project"
[[ "$(vx_compose_meta_get "$(vx_compose_project_root alice worker)/project.conf" STATE)" == stopped ]] \
    || fail "unsuspend started a previously stopped project"
[[ ! -e "$(vx_compose_projects_root alice)/.suspended-running" ]] \
    || fail "unsuspend marker was retained"

calls_before="$(wc -l <"$docker_log")"
vx_compose_rebuild_owner alice
calls_after="$(wc -l <"$docker_log")"
(( calls_after > calls_before )) \
    || fail "rebuild did not converge the running project"

vx_compose_remove_owner_runtime alice
grep -Fq 'vx-alice-web' "$docker_log" \
    || fail "owner runtime cleanup omitted the running project"
grep -Fq 'vx-alice-worker' "$docker_log" \
    || fail "owner runtime cleanup omitted the stopped project"
if grep -Eqi 'system prune|volume prune|--volumes' "$docker_log"; then
    fail "owner lifecycle used a global or data-destructive Docker option"
fi
[[ -d "$(vx_compose_project_root alice web)" ]] \
    || fail "runtime cleanup deleted project control data"

echo "Compose owner lifecycle tests passed."
