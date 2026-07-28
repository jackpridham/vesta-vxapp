#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
mkdir -p "$VESTA/data/users/alice/docker-projects/shop/runtime" \
    "$VESTA/data/users/alice/docker-secrets/shop" \
    "$VESTA/data/users/alice/docker-registries"
root="$VESTA/data/users/alice/docker-projects/shop"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cases=(
    add_all_services
    no_change
    add_remove_change_service
    resource_delta
    port_change
    route_unchanged
    route_service_removed
    route_target_removed
    secret_names_only
    mutable_image_warning
)

policy() {
    local path="$1"
    local services="$2"
    local memory="$3"

    {
        printf "CPUS_MILLI='500'\n"
        printf "MEMORY_MB='%s'\n" "$memory"
        printf "PIDS='64'\n"
        printf "STORAGE_MB='256'\n"
        printf "SERVICES='%s'\n" "$services"
    } >"$path"
}

candidate() {
    local name="$1"
    local json="$2"
    local services="${3:-1}"
    local memory="${4:-256}"
    local path="$test_root/$name"

    mkdir -p "$path"
    printf '%s\n' "$json" | jq -S . >"$path/canonical.json"
    sha256sum "$path/canonical.json" >"$path/canonical.sha256"
    policy "$path/policy.conf" "$services" "$memory"
    printf '%s\n' "$path"
}

plan_candidate() {
    local path="$1"
    local mode="$2"

    vx_compose_candidate_deployment_plan_json \
        alice shop standard "$path" "$mode" \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}

current_json='{
  "services": {
    "web": {
      "image": "example/web:latest",
      "ports": [{
        "host_ip": "127.0.0.1",
        "published": "18081",
        "target": 8080,
        "protocol": "tcp"
      }],
      "deploy": {"resources": {"limits": {"memory": "256M"}}}
    },
    "worker": {"image": "example/worker@sha256:old"}
  },
  "networks": {"default": {}, "present_null": null},
  "volumes": {"cache": {}, "present_null": null},
  "secrets": {
    "api_key": {"file": "/managed/api_key"},
    "present_null": null
  }
}'
printf '%s\n' "$current_json" | jq -S . >"$root/runtime/canonical.json"
printf "OWNER='alice'\nPROJECT='shop'\nPROFILE='standard'\nREVISION='3'\n" \
    >"$root/project.conf"
printf 'services: {}\n' >"$root/compose.yaml"
policy "$root/policy.conf" 2 384
cat >"$root/routes.conf" <<'EOF'
{
  "shop.example.test": {
    "SERVICE": "web",
    "CONTAINER_PORT": 8080,
    "HOST_PORT": 18081,
    "SCHEME": "http",
    "PATH": "/"
  }
}
EOF
cat >"$root/images.json" <<'EOF'
{
  "web": {
    "REFERENCE": "example/web:latest",
    "IMAGE_ID": "sha256:immutable-current"
  }
}
EOF

canary='VX_PLAN_SECRET_9ce1188e'
printf '%s\n' "$canary" >"$VESTA/data/users/alice/docker-secrets/shop/api_key"
printf '{"PASSWORD":"%s"}\n' "$canary" \
    >"$VESTA/data/users/alice/docker-registries/private.json"

# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

[[ "$(vx_compose_preview_root)" == "$VESTA/data/tmp/compose-previews" ]] \
    || fail 'preview root is incorrect'

for case_name in "${cases[@]}"; do
    case "$case_name" in
        add_all_services)
            path="$(candidate "$case_name" \
                '{"services":{"api":{"image":"example/api@sha256:new"},"web":{"image":"example/web@sha256:new"}}}' \
                2 256)"
            plan="$(plan_candidate "$path" add)"
            jq -e '
                .CURRENT_REVISION == 0
                and .SERVICES.ADDED == ["api", "web"]
                and .RECREATE_SERVICES == ["api", "web"]
            ' <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        no_change)
            path="$(candidate "$case_name" "$current_json" 2 384)"
            plan="$(plan_candidate "$path" change)"
            jq -e '
                .SERVICES.UNCHANGED == ["web", "worker"]
                and .SERVICES.ADDED == []
                and .SERVICES.REMOVED == []
                and .SERVICES.CHANGED == []
                and .NETWORKS.UNCHANGED == ["default", "present_null"]
                and .VOLUMES.UNCHANGED == ["cache", "present_null"]
                and .SECRETS.UNCHANGED == ["api_key", "present_null"]
            ' <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        add_remove_change_service)
            path="$(candidate "$case_name" \
                '{"services":{"cron":{"image":"example/cron@sha256:new"},"web":{"image":"example/web:latest","command":["serve"]}}}' \
                2 256)"
            plan="$(plan_candidate "$path" change)"
            jq -e '
                .SERVICES.ADDED == ["cron"]
                and .SERVICES.REMOVED == ["worker"]
                and .SERVICES.CHANGED == ["web"]
            ' <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        resource_delta)
            path="$(candidate "$case_name" "$current_json" 2 256)"
            plan="$(plan_candidate "$path" change)"
            jq -e '.RESOURCES.DELTA.MEMORY_MB == -128' \
                <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        port_change)
            changed_port="${current_json//18081/18082}"
            path="$(candidate "$case_name" "$changed_port" 2 384)"
            plan="$(plan_candidate "$path" change)"
            jq -e '.ROUTES.RETARGET_REQUIRED == ["shop.example.test"]' \
                <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        route_unchanged)
            path="$(candidate "$case_name" "$current_json" 2 384)"
            plan="$(plan_candidate "$path" change)"
            jq -e '.ROUTES.UNCHANGED == ["shop.example.test"]' \
                <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        route_service_removed)
            path="$(candidate "$case_name" \
                '{"services":{"worker":{"image":"example/worker@sha256:old"}}}' \
                1 128)"
            plan="$(plan_candidate "$path" change)"
            jq -e '.ROUTES.INVALIDATED == ["shop.example.test"]' \
                <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        route_target_removed)
            path="$(candidate "$case_name" \
                '{"services":{"web":{"image":"example/web@sha256:new","ports":[{"host_ip":"127.0.0.1","published":"18081","target":9090,"protocol":"tcp"}]}}}' \
                1 128)"
            plan="$(plan_candidate "$path" change)"
            jq -e '.ROUTES.INVALIDATED == ["shop.example.test"]' \
                <<<"$plan" >/dev/null || fail "$case_name"
            ;;
        secret_names_only)
            path="$(candidate "$case_name" \
                '{"services":{"web":{"image":"example/web@sha256:new","secrets":[{"source":"api_key"}]}},"secrets":{"api_key":{"file":"/managed/api_key"},"new_key":{"file":"/managed/new_key"}}}' \
                1 128)"
            diagnostics="$test_root/$case_name.err"
            plan="$(plan_candidate "$path" change 2>"$diagnostics")"
            jq -e '
                .SECRETS.ADDED == ["new_key"]
                and .SECRETS.UNCHANGED == ["api_key"]
                and .SECRETS.REMOVED == ["present_null"]
            ' <<<"$plan" >/dev/null || fail "$case_name"
            if grep -Fq "$canary" <<<"$plan" \
                || grep -Fq "$canary" "$diagnostics"; then
                fail 'managed secret or registry canary leaked'
            fi
            ;;
        mutable_image_warning)
            path="$(candidate "$case_name" \
                '{"services":{"web":{"image":"example/web:latest"}}}' 1 128)"
            plan="$(plan_candidate "$path" change)"
            jq -e '
                .WARNINGS | index(
                    "Image tags are resolved again at apply time; equal mutable tags do not guarantee equal image identities."
                ) != null
            ' <<<"$plan" >/dev/null || fail "$case_name"
            ;;
    esac
done

combined='{
  "services": {
    "cron": {"image": "example/cron@sha256:new"},
    "web": {"image": "example/web:latest", "command": ["serve"]}
  },
  "networks": {"default": {}, "present_null": null},
  "volumes": {"cache": {}, "present_null": null},
  "secrets": {
    "api_key": {"file": "/managed/api_key"},
    "present_null": null
  }
}'
path="$(candidate combined "$combined" 2 256)"
diagnostics="$test_root/combined.err"
plan="$(plan_candidate "$path" change 2>"$diagnostics")"
jq -e '
  .VALID == true
  and .CURRENT_REVISION == 3
  and .SERVICES.ADDED == ["cron"]
  and .SERVICES.REMOVED == ["worker"]
  and .SERVICES.CHANGED == ["web"]
  and .RECREATE_SERVICES == ["cron", "web"]
  and .REMOVE_SERVICES == ["worker"]
  and .ROUTES.INVALIDATED == ["shop.example.test"]
  and .RESOURCES.DELTA.MEMORY_MB == -128
  and .DATA_ROLLBACK == false
  and (.WARNINGS | index(
    "Image tags are resolved again at apply time; equal mutable tags do not guarantee equal image identities."
  ) != null)
' <<<"$plan" >/dev/null || fail 'update impact plan is incorrect'
jq -e '
    .IMAGES.CURRENT_IDENTITIES.web.IMAGE_ID
        == "sha256:immutable-current"
' <<<"$plan" >/dev/null || fail 'current immutable image evidence is absent'
if grep -Fq "$canary" <<<"$plan" || grep -Fq "$canary" "$diagnostics"; then
    fail 'plan or diagnostics leaked a protected canary'
fi

echo "Compose deployment plan tests passed."
