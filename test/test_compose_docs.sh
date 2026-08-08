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

catalog_tmp="$(mktemp -d)"
trap 'rm -rf -- "$catalog_tmp"' EXIT
contract_catalog="$catalog_tmp/contract.tsv"
expected_catalog="$catalog_tmp/expected.tsv"
broker_operations="$catalog_tmp/broker.operations"
contract_operations="$catalog_tmp/contract.operations"

awk '
    /^```tsv compose-shell-catalog$/ { catalog=1; next }
    catalog && /^```$/ { exit }
    catalog { print }
' "$repo_root/.docs/contracts/compose-shell-access.md" >"$contract_catalog"

cat >"$expected_catalog" <<'EOF'
projects	[json|plain]
show	PROJECT [json|plain]
definition	PROJECT [json|plain]
quota	[json|plain]
validate	PROJECT [json|plain]
health	PROJECT [json|plain]
logs	PROJECT [SERVICE] [LINES]
stats	PROJECT [PERIOD] [json|plain]
alerts	PROJECT [json|plain]
operation	PROJECT [json|plain]
routes	PROJECT [json|plain]
backups	PROJECT [json|plain]
secrets	PROJECT [json|plain]
registries	[json|plain]
registry-info	PROJECT [json|plain]
registry-publisher-change	< publisher-secret
registry-publisher-disable
image-pull	PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION IMAGE@sha256:DIGEST
drift	PROJECT [json|plain]
probe	PROJECT SERVICE [json|plain]
start	PROJECT
stop	PROJECT
restart	PROJECT
recreate	PROJECT [SERVICE]
deploy	PROJECT
preview	PROJECT add|change < compose.yaml
apply	PROJECT PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION
backup	PROJECT
restore	PROJECT BACKUP_ID validate|apply
rollback-preview	PROJECT REVISION
rollback-apply	PROJECT REVISION CURRENT FROM_MANIFEST_SHA TO_MANIFEST_SHA
reconcile-preview	PROJECT
reconcile-apply	PROJECT DRIFT_SHA CURRENT_REVISION
secret-add	PROJECT NAME < secret-value
secret-change	PROJECT NAME < secret-value
secret-delete	PROJECT NAME
registry-add	REGISTRY USERNAME < registry-password
registry-change	REGISTRY USERNAME < registry-password
registry-delete	REGISTRY
route-add	PROJECT DOMAIN SERVICE PORT [SCHEME] [PATH]
route-delete	PROJECT DOMAIN
alert-ack	PROJECT ALERT
remove	PROJECT keep-data
EOF

cmp -s "$expected_catalog" "$contract_catalog" \
    || { diff -u "$expected_catalog" "$contract_catalog" >&2 || :; fail 'shell catalog signature drift'; }

cut -f1 "$contract_catalog" | sort >"$contract_operations"
[[ "$(wc -l <"$contract_operations")" -eq 43 ]] \
    || fail 'shell contract catalog must contain exactly 43 operations'
[[ "$(uniq "$contract_operations" | wc -l)" -eq 43 ]] \
    || fail 'shell contract catalog contains duplicate operations'

awk '
    /^case "\$operation" in$/ { dispatch=1; next }
    dispatch && /^    [a-z0-9][a-z0-9|-]*\)$/ {
        label=$0
        sub(/^    /, "", label)
        sub(/\)$/, "", label)
        count=split(label, operations, "|")
        for (i=1; i<=count; i++) print operations[i]
    }
    dispatch && /^esac$/ { exit }
' "$repo_root/bin/v-run-user-docker-command" | sort >"$broker_operations"

cmp -s "$contract_operations" "$broker_operations" \
    || { diff -u "$contract_operations" "$broker_operations" >&2 || :; fail 'broker and contract operation sets differ'; }

shell_access_docs=(
    "README.md"
    "SECURITY.md"
    "AGENTS.md"
    "docs/container-orchestration.md"
    ".docs/README.md"
    ".docs/contracts/compose-interfaces.md"
    ".docs/contracts/compose-policy.md"
    ".docs/contracts/compose-lifecycle.md"
    ".docs/contracts/compose-shell-access.md"
    ".docs/user-guides/docker-compose-projects.md"
    ".agents/skills/bash-cli/SKILL.md"
    ".agents/skills/runtime-layout/SKILL.md"
)

for required_text in \
    'v-docker' \
    'vesta-compose-users' \
    'v-run-user-docker-command' \
    'DOCKER_PROJECTS' \
    'package-derived' \
    'standard-only' \
    'bounded stdin' \
    'automatic reconciliation'
do
    grep -Fq "$required_text" "${shell_access_docs[@]/#/$repo_root/}" \
        || fail "active shell-access guidance omits: $required_text"
done

for workflow_command in \
    'v-docker quota json' \
    'v-docker projects json' \
    'v-docker show app json' \
    'v-docker health app json' \
    'v-docker logs app app 100' \
    'v-docker preview app change < compose.yaml' \
    'v-docker apply app PREVIEW_ID SOURCE_SHA256 CANDIDATE_SHA256 REVISION' \
    'v-docker restart app'
do
    grep -Fq "$workflow_command" \
        "$repo_root/.docs/user-guides/docker-compose-projects.md" \
        || fail "user guide omits shell workflow command: $workflow_command"
done

for repair_command in \
    '/usr/local/vesta/bin/v-sync-docker-shell-access USER' \
    '/usr/local/vesta/bin/v-sync-docker-shell-access-all' \
    '/usr/local/vesta/bin/v-install-docker-shell-access' \
    '/usr/sbin/visudo -cf /etc/sudoers.d/vesta-compose-users' \
    'getent group vesta-compose-users' \
    'sudo -l -U USER'
do
    grep -Fq "$repair_command" "$repo_root/docs/container-orchestration.md" \
        || fail "operator guide omits shell-access repair command: $repair_command"
done

limited_readiness="$repo_root/test/compose/run-production-readiness-limited.sh"
[[ -x "$limited_readiness" ]] \
    || fail 'resource-limited production readiness launcher is missing'
for required_text in \
    'test/compose/run-production-readiness-limited.sh' \
    'test/compose/run-production-shellcheck.sh' \
    'VX_READINESS_CPU_QUOTA' \
    'VX_READINESS_MEMORY_MAX' \
    'VX_READINESS_ALLOW_UNLIMITED=yes'
do
    grep -Fq "$required_text" "$repo_root/docs/container-orchestration.md" \
        || fail "operator guide omits limited readiness guidance: $required_text"
done

if rg -n \
    '(usermod|gpasswd).*(docker|vesta-compose-users)|chmod.*docker\.sock|setfacl.*docker\.sock|sudo[[:space:]]+(-n[[:space:]]+)?(/usr/local/vesta/bin/)?v-[a-z0-9-]+|^[[:space:]]*(\$[[:space:]]*)?(sudo[[:space:]]+)?docker[[:space:]]+(ps|compose|logs|inspect|restart|start|stop|exec|run)|v-docker.*(ACTOR|OWNER)|manual(ly)? (add|remove|maintain).*(vesta-compose-users|group membership)' \
    "${shell_access_docs[@]/#/$repo_root/}"
then
    fail 'active guidance recommends a forbidden tenant Docker access path'
fi

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
