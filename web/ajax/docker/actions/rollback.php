<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$project_name = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
$project = vx_compose_resolve_accessible_project(
    $owner,
    $project_name,
    $myvesta_logged_user
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

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __(
        'Roll back project %s to revision %s? The current definition is retained as revision history.',
        $project_name,
        $revision
    ).'<br /><br />';
    echo myvesta_get_hidden_fields(array(
        'docker_rollback' => '1',
        'revision' => (string) $revision,
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

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-rollback-docker-project "
    .escapeshellarg($owner)." "
    .escapeshellarg($project_name)." "
    .escapeshellarg((string) $revision);
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
