#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"
record="NAME='site' CTN_NAME='vx-alice-site' OWNER='alice' IMAGE='nginx:alpine' COMMAND='' ENV='' MOUNTS='' HOST_PORT='18080' CONTAINER_PORT='80' DOMAIN='' ROUTE_PATH='' AUTO_START='yes' RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='none'"
vx_compose_migration_render alice "$record" "$test_root/compose.yaml"
grep -Fq '127.0.0.1:18080:80' "$test_root/compose.yaml"
grep -Fq 'cap_drop:' "$test_root/compose.yaml"
grep -Fq 'no-new-privileges:true' "$test_root/compose.yaml"

bad="${record/ENV=\'\'/ENV=\'PASSWORD=canary\'}"
if vx_compose_migration_render alice "$bad" "$test_root/bad.yaml" 2>/dev/null; then
    echo 'FAIL: secret-like legacy environment was accepted' >&2
    exit 1
fi

if (( EUID == 0 )); then
    migration_owner=
    while IFS=: read -r candidate _ candidate_uid _ _ _ _; do
        (( candidate_uid >= 1000 )) || continue
        if [[ "$(id -gn "$candidate" 2>/dev/null)" == "$candidate" ]]; then
            migration_owner="$candidate"
            break
        fi
    done < <(getent passwd)
else
    migration_owner="$(id -un)"
fi
if [[ -n "$migration_owner" ]]; then
    mkdir -p \
        "$VESTA/data/users/$migration_owner" \
        "$HOMEDIR/$migration_owner/docker/site/data"
    if (( EUID == 0 )); then
        chown "$migration_owner:$migration_owner" "$HOMEDIR/$migration_owner"
        chown -R "$migration_owner:$migration_owner" \
            "$HOMEDIR/$migration_owner/docker"
    fi
    migration_record="NAME='site' CTN_NAME='vx-$migration_owner-site' OWNER='$migration_owner' IMAGE='nginx:alpine' COMMAND='' ENV='' MOUNTS='data:/data' HOST_PORT='18081' CONTAINER_PORT='80' DOMAIN='' ROUTE_PATH='' AUTO_START='yes' RESTART_POLICY='unless-stopped' HEALTHCHECK_TYPE='none'"
    printf '%s\n' "$migration_record" \
        >"$VESTA/data/users/$migration_owner/docker.conf"
    fake_docker="$test_root/fake-docker"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$*" == *vx.managed* ]]; then' \
        "    printf '%s\\n' 'yes|$migration_owner|site'" \
        'elif [[ "$*" == *State.Running* ]]; then' \
        "    printf '%s\\n' false" \
        'fi' >"$fake_docker"
    chmod 0755 "$fake_docker"
    vx_compose_docker_bin() { printf '%s\n' "$fake_docker"; }
    vx_compose_prepare_candidate() {
        mkdir -p "$4"
        printf '{}\n' >"$4/canonical.json"
    }
    vx_compose_store_new() {
        mkdir -p "$(vx_compose_project_root "$1" "$2")"
    }
    vx_compose_deploy() { :; }
    vx_compose_audit() { :; }

    migration_report="$(
        vx_compose_migrate_owner "$migration_owner" apply
    )"
    jq -e '.[0] == {PROJECT:"site",STATUS:"migrated"}' \
        <<<"$migration_report" >/dev/null \
        || {
            echo 'FAIL: real owner-owned legacy migration did not complete' >&2
            exit 1
        }
    [[ -d "$HOMEDIR/$migration_owner/docker/site/binds/data"
        && "$(stat -c %u "$HOMEDIR/$migration_owner/docker")" == "$EUID"
        && "$(stat -c %u "$HOMEDIR/$migration_owner/docker/site")" == "$EUID"
        && "$(stat -c %u "$HOMEDIR/$migration_owner/docker/site/binds/data")" \
            == "$(id -u "$migration_owner")"
        && "$(cat "$VESTA/data/users/$migration_owner/docker-projects/.legacy-data-authority/site.conf")" \
            == "STATE='complete'" ]] \
        || {
            echo 'FAIL: legacy migration ownership transition was incorrect' >&2
            exit 1
        }
fi

echo "Compose migration tests passed."
