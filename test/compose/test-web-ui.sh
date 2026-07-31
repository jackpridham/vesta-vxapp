#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failures=0

expect_file() {
    if [ ! -f "$ROOT/$1" ]; then
        printf 'FAIL: missing %s\n' "$1" >&2
        failures=$((failures + 1))
    fi
}

expect_pattern() {
    local file=$1
    local pattern=$2
    local description=$3
    if ! grep -Eq "$pattern" "$ROOT/$file"; then
        printf 'FAIL: %s (%s)\n' "$description" "$file" >&2
        failures=$((failures + 1))
    fi
}

expect_absent() {
    local file=$1
    local pattern=$2
    local description=$3
    if grep -Eq "$pattern" "$ROOT/$file"; then
        printf 'FAIL: %s (%s)\n' "$description" "$file" >&2
        failures=$((failures + 1))
    fi
}

expect_file web/inc/vx_compose.php
expect_file web/list/docker/project/index.php
expect_file web/templates/docker_project_shared.php
expect_file web/add/docker/project/index.php
expect_file web/templates/docker_project_add_shared.php
expect_file web/edit/docker/project/index.php
expect_file web/templates/docker_project_edit_shared.php
expect_file web/ajax/docker/actions/deploy.php
expect_file web/ajax/docker/actions/rollback.php
expect_file web/ajax/docker/actions/backup.php
expect_file web/ajax/docker/actions/restore.php
expect_file web/ajax/docker/actions/recreate.php
expect_file web/ajax/docker/actions/drift.php
expect_file web/ajax/docker/actions/reconcile.php
expect_file web/ajax/docker/actions/roles.php

expect_pattern web/list/docker/index.php 'inc/vx_compose\.php' \
    'Compose list adapter is loaded'
expect_pattern web/list/docker/index.php 'vx_compose_list_projects_for_actor' \
    'Compose projects are the list source'
expect_pattern web/edit/docker/index.php \
    'vx_compose_resolve_accessible_project' \
    'owner/admin simple edit resolves an accessible Compose project'
expect_pattern web/add/docker/index.php \
    'if \(!\$docker_available\)' \
    'simple add rejects POST when orchestration is unavailable'
expect_pattern web/edit/docker/index.php \
    'if \(!\$docker_available\)' \
    'simple edit rejects POST when orchestration is unavailable'
expect_pattern web/edit/docker/index.php "SIMPLE.*GENERATED|SIMPLE'\\]\\['GENERATED" \
    'advanced projects do not enter the simple editor'
expect_pattern web/templates/docker_list_shared.php 'SERVICE_COUNT' \
    'project cards expose service counts'
expect_pattern web/templates/docker_list_shared.php 'REVISION' \
    'project cards expose revisions'
expect_pattern web/templates/docker_list_shared.php \
    'vx_compose_actor_can_mutate_project' \
    'project cards derive mutation controls from project profile authority'
expect_pattern web/templates/docker_project_shared.php \
    'vx_compose_actor_can_mutate_project' \
    'project details derive mutation controls from project profile authority'
for helper in \
    services endpoints routes ingress health resources revisions backups \
    alerts operations events; do
    expect_pattern web/inc/vx_compose.php \
        "function vx_compose_view_${helper}" \
        "$helper has an escaped Compose view-model helper"
done
expect_pattern web/inc/vx_compose.php \
    "htmlspecialchars.*ENT_QUOTES.*UTF-8" \
    'Compose view-model scalars are escaped centrally'
expect_pattern web/templates/docker_project_shared.php \
    'docker-data-table' \
    'project detail payloads use semantic data tables'
expect_pattern web/templates/docker_project_shared.php \
    '<details class="docker-advanced-json">' \
    'raw project payloads are opt-in Advanced JSON'
expect_pattern web/templates/docker_project_shared.php \
    'docker-button--danger.*Impact:|Impact:.*docker-button--danger' \
    'interrupting project actions have a distinct impact treatment'
expect_pattern web/templates/docker_project_shared.php \
    'docker-impact-note' \
    'project mutation impact is visible before opening actions'
expect_pattern web/css/docker.css \
    'docker-console-bg: #1f1633' \
    'project console uses the local warm-purple dashboard token'
expect_pattern web/css/docker.css \
    'docker-data-table--stack' \
    'project tables collapse for mobile screens'
expect_absent web/templates/docker_project_shared.php \
    'fonts.googleapis.com|sentry' \
    'project console does not import remote fonts or product branding'
expect_pattern web/templates/docker_list_shared.php \
    "docker_available.*docker_quota.*docker_can_add_from_scope|docker_available.*reached.*docker_can_add_from_scope" \
    'advanced add follows Docker readiness, quota, and explicit owner scope'
expect_pattern web/templates/docker_list_shared.php \
    'docker_quota_used.*docker_quota_limit' \
    'project quota uses its authoritative usage counter'
expect_pattern web/templates/docker_list_shared.php \
    "foreach.*docker_quota\\['dimensions'\\]" \
    'all Compose quota dimensions are rendered'
expect_pattern web/templates/docker_project_shared.php 'Advanced update' \
    'standard owners can discover advanced update'
expect_pattern web/js/pages/list_docker.js \
    '\$\.when\(statsRequest, healthRequest\)' \
    'dashboard settles fresh health and metrics together'
expect_pattern web/js/pages/list_docker.js \
    'generation !== pollGeneration' \
    'dashboard rejects responses from an older poll'
expect_pattern web/js/pages/list_docker.js \
    'beforeunload pagehide' \
    'dashboard cancels polling during navigation'
expect_pattern web/js/pages/list_docker.js \
    'formatCapacityMiB|MiB.*GiB' \
    'dashboard shares binary capacity formatting'
expect_pattern web/templates/docker_list_shared.php \
    'data-freshness.*aria-label|aria-label.*data-freshness' \
    'dashboard exposes health freshness to assistive technology'

expect_pattern web/add/docker/project/index.php "myvesta_logged_user|\\\$user" \
    'advanced page is tied to the authenticated actor'
expect_pattern web/add/docker/project/index.php 'inc/main\.php' \
    'add loads the production authenticated panel bootstrap'
expect_pattern web/edit/docker/project/index.php 'inc/main\.php' \
    'edit loads the production authenticated panel bootstrap'
expect_pattern web/add/docker/project/index.php \
    'vx_docker_is_orchestration_ready' \
    'advanced add checks orchestration readiness server-side'
expect_pattern web/edit/docker/project/index.php \
    'vx_docker_is_orchestration_ready' \
    'advanced edit checks orchestration readiness server-side'
expect_pattern web/add/docker/project/index.php \
    "\\\$user === 'admin'.*|\\? vx_docker_resolve_owner_from_request" \
    'add derives owner scope from the authenticated panel actor'
expect_pattern web/edit/docker/project/index.php \
    "\\\$user === 'admin'.*|\\? vx_docker_resolve_owner_from_request" \
    'edit derives owner scope from the authenticated panel actor'
expect_pattern web/add/docker/project/index.php "SESSION\\['token'\\]" \
    'project editor validates CSRF'
expect_pattern web/add/docker/project/index.php 'v-stage-docker-project-preview' \
    'add uses root-owned preview staging'
expect_pattern web/edit/docker/project/index.php 'v-stage-docker-project-preview' \
    'edit uses root-owned preview staging'
expect_pattern web/add/docker/project/index.php 'v-apply-docker-project-preview' \
    'add consumes an immutable preview'
expect_pattern web/edit/docker/project/index.php 'v-apply-docker-project-preview' \
    'edit consumes an immutable preview'
expect_pattern web/edit/docker/project/index.php 'v-list-docker-project-definition' \
    'edit loads revalidated desired state'
expect_pattern web/add/docker/project/index.php 'vx_compose_get_project' \
    'advanced add refuses an existing project before staging'
expect_pattern web/add/docker/project/index.php 'v-spawn-ajax-process' \
    'advanced deployment is spawned'
expect_absent web/add/docker/project/index.php \
    'v-(approve|delete)-docker-project-profile' \
    'profile authority is owned atomically by the backend wrapper'
expect_pattern web/add/docker/project/index.php 'vx_compose_profile_expiry_is_valid' \
    'admin-approved expiry is validated'
expect_pattern web/templates/docker_project_add_shared.php 'name="expires"' \
    'advanced form exposes profile expiry'
expect_pattern web/templates/docker_project_add_shared.php 'compose-validation-preview' \
    'canonical validation preview is rendered before deployment'
expect_pattern web/templates/docker_project_add_shared.php 'confirm_deploy' \
    'advanced deployment requires explicit confirmation'
expect_pattern web/add/docker/project/index.php 'vx_compose_actor_can_manage_profile' \
    'add confirmation rechecks profile authority'
expect_pattern web/edit/docker/project/index.php 'vx_compose_actor_can_manage_profile' \
    'edit checks stored profile authority'
expect_pattern web/templates/docker_project_edit_shared.php \
    'compose-update-validation-preview' \
    'advanced updates render canonical preview'
expect_pattern web/templates/docker_project_edit_shared.php 'confirm_update' \
    'advanced updates require explicit confirmation'
expect_pattern web/templates/docker_project_add_shared.php \
    "DOMContentLoaded.*|DOMContentLoaded" \
    'advanced deployment defers its watcher until shared scripts are loaded'
expect_pattern web/templates/docker_project_edit_shared.php \
    "DOMContentLoaded.*|DOMContentLoaded" \
    'advanced update defers its watcher until shared scripts are loaded'
expect_pattern web/templates/docker_project_add_shared.php \
    "startWatchingSpawnedAjaxProcess[[:space:]]*\\(|compose-spawn-output-textarea" \
    'advanced deployment targets its page output instead of the hidden modal'
expect_pattern web/templates/docker_project_edit_shared.php \
    "startWatchingSpawnedAjaxProcess[[:space:]]*\\(|compose-spawn-output-textarea" \
    'advanced update targets its page output instead of the hidden modal'
expect_pattern web/templates/docker_add_shared.php \
    'DOMContentLoaded' \
    'simple deployment waits for shared scripts'
expect_pattern web/templates/docker_add_shared.php \
    'docker-simple-spawn-output-textarea' \
    'simple deployment targets its visible output'
expect_pattern web/templates/docker_edit_shared.php \
    'DOMContentLoaded' \
    'simple update waits for shared scripts'
expect_pattern web/templates/docker_edit_shared.php \
    'docker-simple-spawn-output-textarea' \
    'simple update targets its visible output'
expect_pattern web/js/floating-div.js \
    'parseSpawnedAjaxProcessResponse' \
    'spawn watcher validates JSON responses before rendering'
expect_pattern web/js/floating-div.js \
    'Unable to read spawned process output' \
    'spawn watcher reports a fixed safe malformed-response error'

expect_pattern web/inc/vx_compose.php 'random_bytes\(16\)' \
    'web sources use cryptographic directory names'
expect_pattern web/inc/vx_compose.php "mkdir\\(\\\$directory, 0700\\)" \
    'web source directories are mode 0700'
expect_pattern web/inc/vx_compose.php "chmod\\(\\\$source, 0600\\)" \
    'web source files are mode 0600'
expect_pattern web/inc/vx_compose.php \
    "defined\\('VX_COMPOSE_CONTROLLER_TEST'\\)" \
    'controller test hook requires a fixed code-defined constant'
expect_pattern web/inc/vx_compose.php \
    "function_exists\\('vx_compose_test_(command_json|spawn_command)'\\)" \
    'controller test hook requires an explicit callback'
expect_absent web/inc/vx_compose.php \
    "\\\$_(GET|POST|REQUEST)|getenv\\(" \
    'controller test hook is not request or environment controlled'
expect_absent web/add/docker/project/index.php \
    "preview.*\\['source'\\]" 'PHP add session does not retain a source path'
expect_absent web/edit/docker/project/index.php \
    "preview.*\\['source'\\]" 'PHP edit session does not retain a source path'
expect_pattern web/add/docker/index.php 'v-web-add-docker-container' \
    'simple create uses the consuming web wrapper'
expect_absent web/add/docker/index.php 'vx_docker_build_spec_payload' \
    'simple create must not encode its generated spec twice'
expect_pattern web/edit/docker/index.php 'v-web-change-docker-container' \
    'simple update uses the consuming web wrapper'
expect_absent web/edit/docker/index.php 'vx_docker_build_spec_payload' \
    'simple update must not encode its generated spec twice'
expect_pattern web/add/docker/index.php 'v-spawn-ajax-process' \
    'simple create streams a spawned operation'
expect_pattern web/edit/docker/index.php 'v-spawn-ajax-process' \
    'simple update streams a spawned operation'

for file in web/ajax/docker/index.php web/ajax/docker/router.php web/ajax/docker/actions/*.php; do
    relative=${file#"$ROOT/"}
    expect_pattern "$relative" 'include_authentication_check\.php' \
        'AJAX endpoint performs authentication'
done

for action in deploy rollback backup restore remove recreate; do
    file="web/ajax/docker/actions/${action}.php"
    expect_pattern "$file" 'v-spawn-ajax-process' \
        "$action uses the spawned process workflow"
    expect_pattern "$file" 'escapeshellarg' \
        "$action escapes command arguments"
    expect_pattern "$file" 'myvesta_logged_user' \
        "$action uses the authenticated actor"
done

for page in start stop restart; do
    expect_pattern "web/${page}/docker/index.php" \
        'vx_compose_resolve_mutable_project' \
        "$page requires project mutation authority"
    expect_pattern "web/${page}/docker/index.php" \
        'v-run-docker-project-action' \
        "$page rechecks actor capability in the mutation adapter"
done

for action in acknowledge_alert backup deploy recreate restore rollback; do
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        'vx_compose_resolve_capable_project' \
        "$action requires capability-specific project authority"
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        'vx_docker_is_orchestration_ready' \
        "$action rejects mutation while orchestration is unavailable"
done
expect_pattern web/ajax/docker/actions/remove.php \
    'vx_compose_resolve_accessible_project' \
    'remove requires owner/admin authority over an accessible project'

for action in logs inspect audit routes ingress_consumers secrets images; do
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        'vx_compose_resolve_accessible_project' \
        "$action remains available through read-only project access"
done

for page in start stop restart; do
    expect_pattern "web/${page}/docker/index.php" \
        'vx_docker_is_orchestration_ready' \
        "$page rejects mutation while orchestration is unavailable"
done

for action in logs inspect audit routes ingress_consumers secrets images health stats alerts; do
    expect_absent "web/ajax/docker/actions/${action}.php" \
        'vx_docker_is_orchestration_ready' \
        "$action remains readable while orchestration is unavailable"
done

expect_pattern web/ajax/docker/actions/ingress_consumers.php \
    'vx_compose_ingress_consumers_payload.*myvesta_logged_user|myvesta_logged_user' \
    'native ingress panel call binds the authenticated actor'
expect_pattern web/ajax/docker/index.php \
    "docker_ingress_consumers" \
    'project action modal exposes native ingress consumers'
expect_pattern web/ajax/docker/router.php \
    "'ingress_consumers'|docker_ingress_consumers" \
    'project action router dispatches native ingress consumers'
expect_pattern bin/v-list-docker-project-ingress-consumers \
    'vx_compose_ingress_actor_can_view_metadata' \
    'native ingress adapter uses explicit capability authorization'
expect_absent bin/v-list-docker-project-ingress-consumers \
    'id[[:space:]]+-un|whoami|SUDO_USER' \
    'native ingress adapter does not infer panel authority from OS identity'

for action in acknowledge_alert backup deploy recreate remove restore rollback; do
    if command -v php >/dev/null 2>&1; then
        response="$(php -n "$ROOT/test/test_compose_php_helpers.php" \
            mutation-readiness "$action")"
    else
        response="$(docker run --rm \
            -v "$ROOT:/workspace:ro" -w /workspace \
            php:8.2-cli php -n test/test_compose_php_helpers.php \
            mutation-readiness "$action")"
    fi
    jq -e '
        .output | contains(
            "Docker orchestration prerequisites are unavailable."
        )
    ' <<<"$response" >/dev/null \
        || {
            printf 'FAIL: %s dynamically accepted unavailable orchestration\n' \
                "$action" >&2
            failures=$((failures + 1))
        }
done

expect_pattern web/ajax/docker/index.php \
    'vx_compose_actor_can_mutate_project' \
    'project action modal hides mutation controls without hiding read views'

expect_pattern web/ajax/docker/actions/remove.php "isset\\(\\\$_POST\\['Yes'\\]\\)" \
    'destructive removal asks for confirmation'
expect_pattern web/ajax/docker/actions/rollback.php "isset\\(\\\$_POST\\['Yes'\\]\\)" \
    'rollback asks for confirmation'
expect_pattern web/ajax/docker/actions/restore.php "isset\\(\\\$_POST\\['Yes'\\]\\)" \
    'restore apply asks for confirmation'
expect_pattern web/ajax/docker/actions/backup.php "isset\\(\\\$_POST\\['Yes'\\]\\)" \
    'backup asks for confirmation'
expect_pattern web/ajax/docker/actions/recreate.php "isset\\(\\\$_POST\\['Yes'\\]\\)" \
    'service recreation asks for confirmation'
expect_pattern web/ajax/docker/actions/logs.php 'v-list-docker-project-logs' \
    'logs use bounded Compose log output'
expect_pattern web/ajax/docker/actions/logs.php "name|service|in_array\\(\\\$service" \
    'logs validate a selected canonical service'
expect_pattern web/ajax/docker/actions/recreate.php 'v-run-docker-project-action' \
    'service recreation uses the actor-authorized constrained command'
expect_pattern web/ajax/docker/actions/recreate.php "in_array\\(\\\$service" \
    'service recreation validates canonical membership'
expect_pattern web/ajax/docker/actions/inspect.php 'vx_compose_resolve_accessible_project' \
    'inspect uses the redacted project summary'
expect_pattern web/ajax/docker/actions/health.php 'vx_compose_health_payload' \
    'health is project-scoped'
expect_pattern web/ajax/docker/actions/stats.php 'vx_compose_stats_payload' \
    'metrics are project-scoped'
expect_pattern web/ajax/docker/actions/alerts.php 'vx_compose_alerts_payload' \
    'alerts are project-scoped'
expect_pattern web/ajax/docker/actions/acknowledge_alert.php \
    'v-run-docker-project-action' \
    'alert acknowledgement is actor-authorized and project-scoped'
for capability_action in \
    'deploy:deploy' 'rollback:rollback' 'backup:backup' 'restore:restore' \
    'recreate:lifecycle' 'reconcile:reconcile'; do
    action="${capability_action%%:*}"
    capability="${capability_action#*:}"
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        "vx_compose_resolve_capable_project|${capability}" \
        "$action uses a capability-specific resolver"
done
expect_pattern web/ajax/docker/actions/rollback.php \
    'v-apply-docker-project-rollback' \
    'rollback consumes the manifest-bound preview adapter'
expect_pattern web/ajax/docker/actions/rollback.php 'from_manifest' \
    'rollback confirmation preserves the current manifest binding'
expect_pattern web/ajax/docker/actions/rollback.php 'to_manifest' \
    'rollback confirmation preserves the target manifest binding'
expect_pattern web/ajax/docker/actions/reconcile.php 'drift_digest' \
    'reconcile confirmation preserves the drift digest binding'
expect_pattern web/ajax/docker/actions/reconcile.php 'current_revision' \
    'reconcile confirmation preserves the revision binding'
for action in drift reconcile roles; do
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        'include_authentication_check\.php' \
        "$action includes the nested authentication check"
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        '\$myvesta_logged_user' \
        "$action derives actor authority from the logged-in user"
    expect_pattern "web/ajax/docker/actions/${action}.php" \
        'exit;' \
        "$action terminates after emitting bounded output"
done
expect_pattern web/ajax/docker/actions/reconcile.php \
    'escapeshellarg.*myvesta_logged_user' \
    'reconcile escapes the actor shell argument'
expect_pattern web/ajax/docker/actions/reconcile.php \
    'escapeshellarg.*owner' \
    'reconcile escapes the owner shell argument'
expect_pattern web/ajax/docker/actions/audit.php 'vx_compose_audit_payload' \
    'audit output uses the redacted CLI'
expect_pattern web/ajax/docker/actions/routes.php 'vx_compose_routes_payload' \
    'route output uses managed route state'
expect_pattern web/ajax/docker/actions/secrets.php 'vx_compose_secrets_payload' \
    'secret output is metadata-only'

if command -v php >/dev/null 2>&1; then
    php -r '
        define("VESTA_CMD", "/usr/local/vesta/bin/");
        require $argv[1];
        $attack = "<script>alert(\"x\")</script>";
        $project = array(
            "SERVICE_SUMMARY" => array($attack => array(
                "IMAGE" => $attack,
                "PORTS" => array($attack),
                "HAS_HEALTHCHECK" => true,
            )),
            "PUBLISHED_ENDPOINTS" => array(array(
                "SERVICE" => $attack,
                "DISPLAY" => $attack,
                "PROTOCOL" => "tcp",
            )),
            "RESOURCES" => array("CPUS_MILLI" => $attack),
        );
        $views = array(
            vx_compose_view_services($project),
            vx_compose_view_endpoints($project),
            vx_compose_view_routes(array($attack => array(
                "DOMAIN" => $attack,
                "SERVICE" => $attack,
            ))),
            vx_compose_view_ingress(array(
                "COUNT" => 1,
                "CONSUMERS" => array(array("CONSUMER" => $attack)),
            )),
            vx_compose_view_health(array(
                "STATUS" => $attack,
                "SERVICES" => array(array("SERVICE" => $attack)),
            )),
            vx_compose_view_resources($project, array()),
            vx_compose_view_revisions(array(2, 1), 2),
            vx_compose_view_backups(array(array("ARCHIVE" => $attack))),
            vx_compose_view_alerts(array(
                "ALERTS" => array(array("TYPE" => $attack)),
            )),
            vx_compose_view_operations(array(array("ACTION" => $attack))),
            vx_compose_view_events(array(array("DETAILS" => $attack))),
        );
        $encoded = json_encode($views);
        if (strpos($encoded, "<script>") !== false
            || strpos($encoded, "&lt;script&gt;") === false) {
            fwrite(STDERR, "FAIL: Compose view model emitted an unsafe scalar\n");
            exit(1);
        }
    ' "$ROOT/web/inc/vx_compose.php" || failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    exit 1
fi

printf 'Compose web UI static tests passed.\n'
