#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

test -f "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'Compose shell-access contract is missing'
grep -Fq 'vesta-compose-users' \
    "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'shell-access contract omits the derived group'
grep -Fq 'v-run-user-docker-command' \
    "$repo_root/.docs/contracts/compose-shell-access.md" \
    || fail 'shell-access contract omits the privileged broker'

required_docs=(
    ".docs/contracts/compose-storage.md"
    ".docs/contracts/compose-policy.md"
    ".docs/contracts/compose-lifecycle.md"
    ".docs/contracts/compose-security.md"
    ".docs/contracts/compose-secrets.md"
    ".docs/contracts/compose-images.md"
    ".docs/contracts/compose-networking.md"
    ".docs/contracts/compose-backup-restore.md"
    ".docs/contracts/compose-interfaces.md"
    ".docs/contracts/compose-self-service-deployment.md"
    ".docs/README.md"
    ".docs/user-guides/docker-compose-projects.md"
    "docs/container-orchestration.md"
    "SECURITY.md"
    ".agents/skills/runtime-layout/SKILL.md"
    ".agents/skills/runtime-layout/references/path-mapping.md"
    ".agents/skills/bash-cli/SKILL.md"
    ".agents/skills/web-ui/SKILL.md"
    ".agents/skills/web-ui/references/modal-ajax.md"
)

for relative_path in "${required_docs[@]}"; do
    [[ -s "$repo_root/$relative_path" ]] \
        || fail "missing required document: $relative_path"
done

mapfile -t link_docs < <(
    {
        printf '%s\n' README.md AGENTS.md
        while IFS= read -r path; do
            printf '.docs/%s\n' "$path"
        done < <(
            find "$repo_root/.docs" -type f -name '*.md' \
                ! -path "$repo_root/.docs/audits/*" -printf '%P\n'
        )
        while IFS= read -r path; do
            printf 'docs/%s\n' "$path"
        done < <(
            find "$repo_root/docs" -type f -name '*.md' -printf '%P\n'
        )
        while IFS= read -r path; do
            printf '.agents/skills/%s\n' "$path"
        done < <(
            find "$repo_root/.agents/skills" -type f -name '*.md' -printf '%P\n'
        )
    } | sort -u
)

# Audit files are immutable point-in-time evidence and may link to files later
# removed by their recorded follow-up commits. All mutable requested surfaces
# must retain a valid local link graph.
for relative_path in "${link_docs[@]}"; do
    source_path="$repo_root/$relative_path"
    source_dir="$(dirname -- "$source_path")"
    while IFS= read -r markdown_link; do
        target="${markdown_link#']('}"
        target="${target%')'}"
        target="${target#<}"
        target="${target%>}"
        case "$target" in
            ''|'#'*|http://*|https://*|mailto:*) continue ;;
        esac
        target="${target%%#*}"
        target="${target%%\?*}"
        [[ -n "$target" ]] || continue
        if [[ "$target" == /* ]]; then
            resolved="$target"
        else
            resolved="$(realpath -m -- "$source_dir/$target")"
        fi
        [[ -e "$resolved" ]] \
            || fail "broken internal link in $relative_path: $target"
    done < <(grep -oE '\]\([^)]+\)' "$source_path" || true)
done

for legacy_path in \
    .docs/contracts/docker-container-schema.md \
    .docs/contracts/docker-monitoring-schema.md \
    .docs/contracts/docker-alerts-schema.md \
    .docs/contracts/docker-ui-states.md \
    .docs/plans/2026-06-27-docker-panel-management.md \
    .docs/user-guides/docker-containers.md \
    .docs/validation/sydlocal-docker-e2e-closeout.md
do
    grep -Eqi 'historical|legacy|superseded' "$repo_root/$legacy_path" \
        || fail "legacy document lacks supersession notice: $legacy_path"
done

for command_name in \
    v-add-docker-project \
    v-validate-docker-project \
    v-deploy-docker-project \
    v-start-docker-project \
    v-stop-docker-project \
    v-restart-docker-project \
    v-recreate-docker-project \
    v-change-docker-project \
    v-delete-docker-project \
    v-adopt-docker-project \
    v-backup-docker-project \
    v-restore-docker-project \
    v-approve-docker-project-profile \
    v-add-docker-project-route \
    v-delete-docker-project-route \
    v-list-docker-project-routes \
    v-rollback-docker-project \
    v-migrate-docker-containers \
    v-plan-docker-project-source \
    v-list-docker-project-definition \
    v-stage-docker-project-preview \
    v-apply-docker-project-preview
do
    grep -Fq "$command_name" \
        "$repo_root/.docs/contracts/compose-interfaces.md" \
        || fail "interface contract omits command: $command_name"
done

for profile_name in standard admin-approved slave-vxapp; do
    grep -Fq "$profile_name" "$repo_root/.docs/contracts/compose-policy.md" \
        || fail "policy contract omits profile: $profile_name"
done

grep -Fq 'implementation is production ready' "$repo_root/README.md" \
    || fail "README does not state current implementation readiness"
if grep -Fqi 'not yet production ready' "$repo_root/README.md"; then
    fail "README retains the superseded production-readiness claim"
fi
if rg -n -i 'not (yet )?production[- ]ready' \
    "$repo_root/README.md" \
    "$repo_root/.docs/README.md" \
    "$repo_root/.docs/contracts" \
    "$repo_root/.docs/user-guides/docker-compose-projects.md" \
    "$repo_root/docs" \
    "$repo_root/.agents"; then
    fail "active guidance retains a superseded readiness claim"
fi
grep -Fq 'Compose owns workload desired state' \
    "$repo_root/docs/container-orchestration.md" \
    || fail "operator guide omits the Compose authority boundary"
grep -Fq 'Host mode is rejected for every profile' \
    "$repo_root/.docs/contracts/compose-networking.md" \
    || fail "networking contract does not reject host mode"
grep -Fq 'docker-compose-projects.md' "$repo_root/README.md" \
    || fail "README omits the current Compose user guide"
grep -Fq '.docs/contracts/compose-self-service-deployment.md' \
    "$repo_root/AGENTS.md" \
    || fail "AGENTS.md omits self-service contract routing"
grep -Fq 'test/compose/run-production-readiness.sh' \
    "$repo_root/AGENTS.md" \
    || fail "AGENTS.md omits the release gate"
grep -Fq 'deny-first' "$repo_root/SECURITY.md" \
    || fail "security policy omits Compose deny-first enforcement"
grep -Fq 'Ordinary users act only on their own `standard` projects' \
    "$repo_root/AGENTS.md" \
    || fail "AGENTS.md omits current owner/profile authority"
for skill_path in \
    .agents/skills/runtime-layout/SKILL.md \
    .agents/skills/bash-cli/SKILL.md \
    .agents/skills/web-ui/SKILL.md
do
    grep -Fq 'compose-self-service-deployment.md' "$repo_root/$skill_path" \
        || fail "local skill omits self-service contract: $skill_path"
done
grep -Fq '| `admin-approved` | Admin per project | Bridge;' \
    "$repo_root/.docs/contracts/compose-policy.md" \
    || fail "policy contract does not preserve bridge-only admin profile"
jq -e '
    .name == "admin-approved"
    and .version == 3
    and .allow_host_namespaces == false
' "$repo_root/func/vx/compose/profiles/admin-approved.json" >/dev/null \
    || fail "admin profile implementation no longer matches the documented boundary"
grep -Fq 'Host networking is rejected for every profile' \
    "$repo_root/.docs/contracts/compose-security.md" \
    || fail "security contract does not constrain general host networking"
if rg -n -i \
    'Bridge or explicitly approved host mode|selected public or host-mode behavior' \
    "$repo_root/README.md" \
    "$repo_root/AGENTS.md" \
    "$repo_root/.docs/contracts" \
    "$repo_root/.docs/user-guides/docker-compose-projects.md" \
    "$repo_root/docs" \
    "$repo_root/.agents"; then
    fail "active guidance permits obsolete general administrator host mode"
fi
if rg -n -i \
    'advanced compose (definitions|updates|add/update).*(admin-only|administrator-only)' \
    "$repo_root/README.md" \
    "$repo_root/AGENTS.md" \
    "$repo_root/SECURITY.md" \
    "$repo_root/docs" \
    "$repo_root/.agents"; then
    fail "active guidance contains obsolete advanced-Compose authority"
fi

(( $(wc -l <"$repo_root/AGENTS.md") <= 60 )) \
    || fail "AGENTS.md exceeds the repository's concise guidance target"

echo "Compose documentation consistency checks passed."
