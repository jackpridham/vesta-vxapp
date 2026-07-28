#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
export VESTA="$test_root/vesta"
export HOMEDIR="$test_root/home"
export TMPDIR="$test_root/tmp"
mkdir -p "$TMPDIR"
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
chmod 0640 "$root/compose.yaml"
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

vx_compose_definition_export_expected_uid() {
    printf '%s\n' "$EUID"
}
# shellcheck source=func/vx/compose/main.sh
source "$repo_root/func/vx/compose/main.sh"

VX_COMPOSE_DEFINITION_EXPORT_EXPECTED_UID="$EUID"
export VX_COMPOSE_DEFINITION_EXPORT_EXPECTED_UID
[[ "$(vx_compose_definition_export_expected_uid)" == 0 ]] \
    || fail 'definition export production owner is not root'
unset VX_COMPOSE_DEFINITION_EXPORT_EXPECTED_UID
real_lock_acquire="$(declare -f vx_compose_lock_acquire)"
definition_lock_attempted=no
vx_compose_lock_acquire() {
    definition_lock_attempted=yes
    return 1
}
if vx_compose_definition_export_json '../alice' shop >/dev/null 2>&1 \
    || vx_compose_definition_export_json alice '../shop' >/dev/null 2>&1; then
    fail 'definition export accepted a malicious lock-path identifier'
fi
[[ "$definition_lock_attempted" == no ]] \
    || fail 'definition export constructed a lock path from an invalid identifier'
eval "$real_lock_acquire"

vx_compose_definition_export_expected_uid() {
    printf '%s\n' "$EUID"
}
[[ "$(vx_compose_definition_export_expected_uid)" == "$EUID" ]] \
    || fail 'definition export test owner seam is not active'

real_prepare_candidate="$(declare -f vx_compose_prepare_candidate)"
vx_compose_prepare_candidate() {
    local input_file="$3"
    local output_root="$4"
    local expected_uid

    expected_uid="$(vx_compose_definition_export_expected_uid)"

    grep -Fq 'policy-stale: true' "$input_file" && return 1
    [[ "$(stat -c '%a' "$input_file")" == 600 ]] \
        || fail 'definition export temporary copy is not mode 0600'
    [[ "$(stat -c '%u' "$input_file")" == "$expected_uid" ]] \
        || fail 'definition export temporary copy has the wrong owner'
    mkdir -p "$output_root"
    printf '{}\n' >"$output_root/canonical.json"
}

mkdir -p "$root/secrets"
printf '%s' 'VX_EXPORT_SECRET_ONE_LINE' >"$root/secrets/one-line"
printf '%s\n\n%s\n' 'VX_EXPORT_SECRET_LINE_ONE' 'VX_EXPORT_SECRET_LINE_TWO' \
    >"$root/secrets/multi-line"

export_sizes=(4096 262144)
trailing_newlines=(0 1 2)
for export_size in "${export_sizes[@]}"; do
    for trailing_newline in "${trailing_newlines[@]}"; do
        export_source="$test_root/export-$export_size-$trailing_newline.yaml"
        export_decoded="$test_root/export-$export_size-$trailing_newline.decoded"
        printf '%s' $'services: {}\n#' >"$export_source"
        export_prefix_size="$(stat -c '%s' "$export_source")"
        export_fill_size="$((export_size - export_prefix_size - trailing_newline))"
        head -c "$export_fill_size" /dev/zero | tr '\0' x \
            >>"$export_source"
        for ((newline=0; newline<trailing_newline; newline++)); do
            printf '\n' >>"$export_source"
        done
        [[ "$(stat -c '%s' "$export_source")" -eq "$export_size" ]] \
            || fail "definition export fixture is not exactly $export_size bytes"
        cp "$export_source" "$root/compose.yaml"
        chmod 0640 "$root/compose.yaml"
        export_json="$(vx_compose_definition_export_json alice shop)"
        jq -rj '.DEFINITION' <<<"$export_json" >"$export_decoded"
        cmp "$export_source" "$export_decoded" \
            || fail "definition export changed $export_size-byte source with $trailing_newline trailing newlines"
        jq -e --arg sha "$(sha256sum "$export_source" | awk '{print $1}')" '
            .OWNER == "alice"
            and .PROJECT == "shop"
            and .PROFILE == "standard"
            and .REVISION == 3
            and .SOURCE_SHA256 == $sha
        ' <<<"$export_json" >/dev/null || fail 'definition export metadata is invalid'
    done
done

export_diagnostics="$test_root/export.err"
rm -f "$root/compose.yaml"
ln -s "$export_source" "$root/compose.yaml"
if vx_compose_definition_export_json alice shop \
    >"$test_root/export.out" 2>"$export_diagnostics"; then
    fail 'definition export accepted a symlink'
fi

rm -f "$root/compose.yaml"
printf '%s\n' 'services: {}' 'policy-stale: true' >"$root/compose.yaml"
chmod 0640 "$root/compose.yaml"
if vx_compose_definition_export_json alice shop \
    >"$test_root/export.out" 2>"$export_diagnostics"; then
    fail 'definition export accepted policy-stale source'
fi

printf 'services: {}\n' >"$root/compose.yaml"
chmod 0640 "$root/compose.yaml"
real_snapshot_source_file="$(declare -f vx_compose_snapshot_source_file)"
vx_compose_snapshot_source_file() {
    command cp --no-dereference -- "$1" "$2"
    printf '# changed\n' >>"$1"
    chmod 0600 "$2"
}
if vx_compose_definition_export_json alice shop \
    >"$test_root/export.out" 2>"$export_diagnostics"; then
    fail 'definition export accepted source changed during export'
fi
eval "$real_snapshot_source_file"

for export_canary in \
    VX_EXPORT_SECRET_ONE_LINE VX_EXPORT_SECRET_LINE_ONE VX_EXPORT_SECRET_LINE_TWO; do
    printf 'services:\n  web:\n    command: ["%s"]\n' "$export_canary" \
        >"$root/compose.yaml"
    chmod 0640 "$root/compose.yaml"
    if vx_compose_definition_export_json alice shop \
        >"$test_root/export.out" 2>"$export_diagnostics"; then
        fail "definition export accepted managed secret canary"
    fi
    if grep -Fq "$export_canary" "$test_root/export.out" \
        || grep -Fq "$export_canary" "$export_diagnostics"; then
        fail 'managed secret canary leaked during refused export'
    fi
done
eval "$real_prepare_candidate"

[[ "$(vx_compose_preview_root)" == "$VESTA/data/tmp/compose-previews" ]] \
    || fail 'preview root is incorrect'

safe_source="$test_root/source.compose.yaml"
attacker_source="$test_root/attacker.compose.yaml"
source_snapshot="$test_root/source.snapshot.yaml"
printf 'services: {}\n' >"$safe_source"
printf '%s\n' "$canary" >"$attacker_source"
[[ -f "$safe_source" && ! -L "$safe_source" ]] \
    || fail 'source-swap fixture did not begin as a regular file'
rm -f -- "$safe_source"
ln -s "$attacker_source" "$safe_source"
if vx_compose_snapshot_source_file "$safe_source" "$source_snapshot"; then
    fail 'source snapshot followed a swapped symlink'
fi
[[ ! -e "$source_snapshot" ]] \
    || fail 'rejected source snapshot was not cleaned up'

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

coherent_current='{
  "services": {
    "web": {
      "image": "example/web:revision4",
      "ports": [{
        "host_ip": "127.0.0.1",
        "published": "18082",
        "target": 8080,
        "protocol": "tcp"
      }]
    }
  }
}'
coherent_path="$(candidate coherent "$coherent_current" 1 512)"
vx_compose_lock_acquire() {
    printf "OWNER='alice'\nPROJECT='shop'\nPROFILE='standard'\nREVISION='4'\n" \
        >"$root/project.conf"
    printf '%s\n' "$coherent_current" | jq -S . \
        >"$root/runtime/canonical.json"
    policy "$root/policy.conf" 1 512
    jq '.["shop.example.test"].HOST_PORT = 18082' \
        "$root/routes.conf" >"$root/routes.next"
    mv "$root/routes.next" "$root/routes.conf"
    printf '{"web":{"IMAGE_ID":"sha256:revision4"}}\n' >"$root/images.json"
}
vx_compose_lock_release() {
    :
}
plan="$(plan_candidate "$coherent_path" change)"
jq -e '
    .CURRENT_REVISION == 4
    and .SERVICES.UNCHANGED == ["web"]
    and .ROUTES.UNCHANGED == ["shop.example.test"]
    and .RESOURCES.CURRENT.MEMORY_MB == 512
    and .IMAGES.CURRENT_IDENTITIES.web.IMAGE_ID == "sha256:revision4"
' <<<"$plan" >/dev/null || fail 'current-state snapshot was not coherent'
if compgen -G "$TMPDIR/vx-compose-plan-current.*" >/dev/null; then
    fail 'successful current-state snapshot was not cleaned up'
fi

# Restore the real lock helpers and prove parse failures also clean snapshots.
# shellcheck source=func/vx/compose/storage.sh
source "$repo_root/func/vx/compose/storage.sh"
printf "CPUS_MILLI='invalid'\n" >"$root/policy.conf"
if plan_candidate "$coherent_path" change >/dev/null 2>&1; then
    fail 'malformed current policy unexpectedly produced a plan'
fi
if compgen -G "$TMPDIR/vx-compose-plan-current.*" >/dev/null; then
    fail 'failed current-state snapshot was not cleaned up'
fi

echo "Compose deployment plan tests passed."
