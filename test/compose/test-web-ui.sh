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

expect_pattern web/list/docker/index.php 'inc/vx_compose\.php' \
    'Compose list adapter is loaded'
expect_pattern web/list/docker/index.php 'vx_compose_list_projects_for_actor' \
    'Compose projects are the list source'
expect_pattern web/edit/docker/index.php 'vx_compose_resolve_accessible_project' \
    'simple edit resolves a Compose project'
expect_pattern web/edit/docker/index.php "SIMPLE.*GENERATED|SIMPLE'\\]\\['GENERATED" \
    'advanced projects do not enter the simple editor'
expect_pattern web/templates/docker_list_shared.php 'SERVICE_COUNT' \
    'project cards expose service counts'
expect_pattern web/templates/docker_list_shared.php 'REVISION' \
    'project cards expose revisions'

expect_pattern web/add/docker/project/index.php "myvesta_logged_user|\\\$user" \
    'advanced page is tied to the authenticated actor'
expect_pattern web/add/docker/project/index.php 'inc/main\.php' \
    'add loads the production authenticated panel bootstrap'
expect_pattern web/edit/docker/project/index.php 'inc/main\.php' \
    'edit loads the production authenticated panel bootstrap'
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
expect_pattern web/ajax/docker/actions/recreate.php 'v-recreate-docker-project' \
    'service recreation uses the constrained command'
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
    'v-acknowledge-docker-project-alert' \
    'alert acknowledgement is project-scoped'
expect_pattern web/ajax/docker/actions/audit.php 'vx_compose_audit_payload' \
    'audit output uses the redacted CLI'
expect_pattern web/ajax/docker/actions/routes.php 'vx_compose_routes_payload' \
    'route output uses managed route state'
expect_pattern web/ajax/docker/actions/secrets.php 'vx_compose_secrets_payload' \
    'secret output is metadata-only'

if [ "$failures" -ne 0 ]; then
    exit 1
fi

printf 'Compose web UI static tests passed.\n'
