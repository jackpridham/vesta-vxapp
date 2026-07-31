<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if (!vx_docker_is_orchestration_ready()) {
    echo __('Docker orchestration prerequisites are unavailable.');
    exit;
}

$project_name = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
$project = vx_compose_resolve_capable_project(
    $owner,
    $project_name,
    $myvesta_logged_user,
    'rollback'
);
if (empty($project)) {
    echo __('You do not have access to this Compose project.');
    exit;
}

$allowed_revisions = vx_compose_revision_options($project);
$revision = isset($_POST['revision']) && !is_array($_POST['revision'])
    ? (int) $_POST['revision']
    : 0;

if ($revision === 0) {
    $options = array();
    foreach ($allowed_revisions as $available_revision) {
        if ($available_revision !== (int) $project['REVISION']) {
            $options[$available_revision] = __(
                'Revision %s',
                $available_revision
            );
        }
    }
    if (empty($options)) {
        echo __('No prior revision is available for rollback.');
        exit;
    }
    echo myvesta_open_form('/ajax/docker/router.php');
    echo myvesta_get_hidden_fields(array('docker_rollback' => '1'));
    echo myvesta_get_element(
        'listbox',
        __('Revision'),
        'revision',
        $options
    );
    echo myvesta_get_element(
        'button',
        '',
        'Select',
        __('Continue')
    );
    echo myvesta_close_form();
    exit;
}

if (!in_array($revision, $allowed_revisions, true)) {
    echo __('The selected revision is not available.');
    exit;
}

$rollback_preview = vx_compose_command_json(
    'v-preview-docker-project-rollback',
    array($myvesta_logged_user, $owner, $project_name, (string) $revision),
    array()
);
if (empty($rollback_preview)
    || empty($rollback_preview['FROM_MANIFEST_SHA256'])
    || empty($rollback_preview['TO_MANIFEST_SHA256'])
    || empty($rollback_preview['BOUND_CURRENT_REVISION'])
    || (int) $rollback_preview['BOUND_TARGET_REVISION'] !== $revision) {
    echo __('The rollback preview could not be bound safely.');
    exit;
}
$posted_current = isset($_POST['current_revision'])
    && !is_array($_POST['current_revision'])
    ? (int) $_POST['current_revision']
    : 0;
$posted_from_manifest = isset($_POST['from_manifest'])
    && !is_array($_POST['from_manifest'])
    ? (string) $_POST['from_manifest']
    : '';
$posted_to_manifest = isset($_POST['to_manifest'])
    && !is_array($_POST['to_manifest'])
    ? (string) $_POST['to_manifest']
    : '';

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __(
        'Roll back project %s to revision %s? The current definition is retained as revision history.',
        $project_name,
        $revision
    ).'<br /><br />';
    echo '<details><summary>'.__('Advanced JSON').'</summary><pre>'
        .htmlspecialchars(
            vx_compose_pretty_json($rollback_preview),
            ENT_QUOTES
        )
        .'</pre></details>';
    echo myvesta_get_hidden_fields(array(
        'docker_rollback' => '1',
        'revision' => (string) $revision,
        'current_revision' => (string) $rollback_preview['BOUND_CURRENT_REVISION'],
        'from_manifest' => (string) $rollback_preview['FROM_MANIFEST_SHA256'],
        'to_manifest' => (string) $rollback_preview['TO_MANIFEST_SHA256'],
    ));
    echo myvesta_get_element(
        'buttons_confirm',
        '',
        'Yes/No',
        __('Yes').'/'.__('No')
    );
    echo myvesta_close_form();
    exit;
}

if (isset($_POST['No'])) {
    myvesta_hide_floating_div();
    exit;
}
if ((int) $rollback_preview['BOUND_CURRENT_REVISION'] !== $posted_current
    || !hash_equals(
        (string) $rollback_preview['FROM_MANIFEST_SHA256'],
        $posted_from_manifest
    )
    || !hash_equals(
        (string) $rollback_preview['TO_MANIFEST_SHA256'],
        $posted_to_manifest
    )) {
    echo __('The rollback preview changed. Review a fresh preview.');
    exit;
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-apply-docker-project-rollback "
    .escapeshellarg($myvesta_logged_user)." "
    .escapeshellarg($owner)." "
    .escapeshellarg($project_name)." "
    .escapeshellarg((string) $revision)." "
    .escapeshellarg((string) $posted_current)." "
    .escapeshellarg($posted_from_manifest)." "
    .escapeshellarg($posted_to_manifest);
$hash = trim(shell_exec($cmd));

echo '<b>'.__('Compose rollback output').':</b><br /><br />';
echo myvesta_get_disabled_textarea(
    '',
    '',
    true,
    true,
    true,
    $myvesta_logged_user,
    $hash
);
exit;
