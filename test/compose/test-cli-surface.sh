#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

commands=(
    v-add-docker-project
    v-validate-docker-project
    v-deploy-docker-project
    v-list-docker-project
    v-list-docker-projects
    v-start-docker-project
    v-stop-docker-project
    v-restart-docker-project
    v-recreate-docker-project
    v-change-docker-project
    v-delete-docker-project
    v-backup-docker-project
    v-add-docker-project-backup-policy
    v-list-docker-project-backup-policy
    v-run-docker-project-backup-policy
    v-list-docker-project-backups
    v-restore-docker-project
    v-approve-docker-project-profile
    v-delete-docker-project-profile
    v-add-docker-project-route
    v-delete-docker-project-route
    v-list-docker-project-routes
    v-list-docker-project-ingress-consumers
    v-add-docker-project-role
    v-delete-docker-project-role
    v-list-docker-project-roles
    v-check-docker-project-capability
    v-compare-docker-project-revisions
    v-preview-docker-project-rollback
    v-apply-docker-project-rollback
    v-list-docker-project-drift
    v-preview-docker-project-reconcile
    v-reconcile-docker-project
    v-list-docker-project-operation
    v-run-docker-project-action
    v-add-docker-project-notification-route
    v-list-docker-project-notification-routes
    v-list-docker-compose-quota
    v-list-docker-project-health
    v-list-docker-project-logs
    v-list-docker-project-stats
    v-list-docker-project-alerts
    v-acknowledge-docker-project-alert
    v-list-docker-project-audit
    v-update-docker-project-monitoring
    v-adopt-docker-project
    v-rollback-docker-project
    v-migrate-docker-containers
    v-plan-docker-project-source
    v-list-docker-project-definition
    v-stage-docker-project-preview
    v-apply-docker-project-preview
    v-validate-docker-project-source
    v-web-add-docker-project
    v-web-change-docker-project
    v-web-add-docker-container
    v-web-change-docker-container
    v-verify-docker-image-trust
    v-list-docker-image-update-candidate
    v-approve-docker-image
    v-delete-docker-image-approval
    v-plan-docker-workload-bundle
    v-import-docker-workload-bundle
    v-run-docker-project-probe
)

for command_name in "${commands[@]}"; do
    command_path="$repo_root/bin/$command_name"
    [[ -x "$command_path" ]] || fail "missing executable command: $command_name"
    grep -Fq '# info:' "$command_path" || fail "missing info header: $command_name"
    grep -Fq '# options:' "$command_path" || fail "missing options header: $command_name"
    grep -Fq 'func/vx/compose/main.sh' "$command_path" \
        || fail "command does not use vx Compose helpers: $command_name"
done

grep -Fq '# options: USER PROJECT SOURCE [dry-run|apply] [PROFILE]' \
    "$repo_root/bin/v-adopt-docker-project" \
    || fail "adopt command does not expose the validated profile selector"
grep -Fq 'managed:' "$repo_root/bin/v-restore-docker-project" \
    || fail "restore command does not support confined managed backups"
grep -Fq "basename -- \"\$backup_file\"" \
    "$repo_root/bin/v-backup-docker-project" \
    || fail "managed backup command exposes its protected control-root path"
grep -Fq '# options: USER PROJECT FORMAT' \
    "$repo_root/bin/v-list-docker-project-definition" \
    || fail "definition export command options are incorrect"
grep -Fq 'format=${3-json}' \
    "$repo_root/bin/v-list-docker-project-definition" \
    || fail "definition export command does not default to JSON"
grep -Fq '# options: ACTOR OWNER PROJECT SOURCE PROFILE MODE' \
    "$repo_root/bin/v-stage-docker-project-preview" \
    || fail "preview staging command options are incorrect"
grep -Fq 'user=$owner' "$repo_root/bin/v-stage-docker-project-preview" \
    || fail "preview staging does not initialize owner-scoped Vesta state"
grep -Fq '# options: ACTOR OWNER PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 EXPECTED_CURRENT_REVISION' \
    "$repo_root/bin/v-apply-docker-project-preview" \
    || fail "preview apply command options are incorrect"
grep -Fq '# options: USER PROJECT [FORMAT] [ACTOR]' \
    "$repo_root/bin/v-list-docker-project-ingress-consumers" \
    || fail "ingress consumer command does not expose explicit actor binding"
grep -Fq '# options: USER IMAGE PROFILE [FORMAT]' \
    "$repo_root/bin/v-verify-docker-image-trust" \
    || fail "image trust verifier options are incorrect"
grep -Fq 'vx_compose_verify_image_trust' \
    "$repo_root/bin/v-verify-docker-image-trust" \
    || fail "image trust command is not a thin helper adapter"
grep -Fq '# options: USER IMAGE [FORMAT]' \
    "$repo_root/bin/v-list-docker-image-update-candidate" \
    || fail "image update candidate options are incorrect"
grep -Fq 'vx_compose_image_update_candidate' \
    "$repo_root/bin/v-list-docker-image-update-candidate" \
    || fail "image update command is not a thin helper adapter"
grep -Fq '# options: ACTOR USER IMAGE_REFERENCE IMAGE_ID OS ARCHITECTURE PROFILE PROFILE_VERSION EXPIRES' \
    "$repo_root/bin/v-approve-docker-image" \
    || fail 'local image approval options are incorrect'
grep -Fq '# options: ACTOR USER PROJECT ARCHIVE CHECKSUM MODE [FORMAT]' \
    "$repo_root/bin/v-plan-docker-workload-bundle" \
    || fail 'workload bundle plan options are incorrect'
grep -Fq '# options: ACTOR USER PROJECT ARCHIVE CHECKSUM MODE EXPECTED_CURRENT_REVISION [SECRETS_DIRECTORY]' \
    "$repo_root/bin/v-import-docker-workload-bundle" \
    || fail 'workload bundle import options are incorrect'
grep -Fq '# options: ACTOR USER PROJECT PROBE [FORMAT]' \
    "$repo_root/bin/v-run-docker-project-probe" \
    || fail 'project probe options are incorrect'

fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/func/vx/compose"
cat >"$fixture/func/main.sh" <<'EOF'
E_INVALID=2
check_args() { :; }
is_format_valid() { :; }
is_object_valid() { :; }
check_result() { return "$1"; }
EOF
cat >"$fixture/func/vx/compose/main.sh" <<'EOF'
vx_compose_authorize() { return 0; }
EOF
capability_output="$(
    VESTA="$fixture" bash "$repo_root/bin/v-check-docker-project-capability" \
        admin alice app lifecycle
)" || fail "capability adapter did not emit authorized JSON"
jq -e '
    .AUTHORIZED == true
    and .ACTOR == "admin"
    and .OWNER == "alice"
    and .PROJECT == "app"
    and .CAPABILITY == "lifecycle"
' <<<"$capability_output" >/dev/null \
    || fail "capability adapter JSON does not preserve the authorized actor"

for public_command in \
    v-start-docker-project v-deploy-docker-project \
    v-recreate-docker-project v-restart-docker-project \
    v-rollback-docker-project v-restore-docker-project; do
    if ! VESTA="$fixture" \
        VX_COMPOSE_WORKLOAD_OVERRIDE=/tmp/bypass-workload \
        VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE=/tmp/bypass-canonical \
        VX_COMPOSE_INVOKE_IMAGES_OVERRIDE=/tmp/bypass-images \
        VX_COMPOSE_INVOKE_REVISION_OVERRIDE=999 \
        VX_COMPOSE_INVOKE_ENV_OVERRIDE=/tmp/bypass-env \
        VX_COMPOSE_POLICY_OVERRIDE=/tmp/bypass-policy \
        VX_COMPOSE_PROBE_TEST_ENGINE_HELPER=/tmp/bypass-helper \
        VX_COMPOSE_TEST_MODE=yes \
        bash -c '
          source "$1"
          [[ -z "${VX_COMPOSE_WORKLOAD_OVERRIDE:-}"
            && -z "${VX_COMPOSE_INVOKE_CANONICAL_OVERRIDE:-}"
            && -z "${VX_COMPOSE_INVOKE_IMAGES_OVERRIDE:-}"
            && -z "${VX_COMPOSE_INVOKE_REVISION_OVERRIDE:-}"
            && -z "${VX_COMPOSE_INVOKE_ENV_OVERRIDE:-}"
            && -z "${VX_COMPOSE_POLICY_OVERRIDE:-}"
            && -z "${VX_COMPOSE_PROBE_TEST_ENGINE_HELPER:-}"
            && -z "${VX_COMPOSE_TEST_MODE:-}" ]]
        ' "$public_command" "$repo_root/func/vx/compose/main.sh"; then
        fail "public override environment survived $public_command"
    fi
done

echo "Compose CLI surface tests passed."
