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

$project = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
if (empty(vx_compose_resolve_capable_project(
    $owner,
    $project,
    $myvesta_logged_user,
    'backup'
))) {
    echo __('You do not have access to this Compose project.');
    exit;
}

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __(
        'Create a protected managed backup of Compose project %s?',
        $project
    ).'<br /><br />';
    echo myvesta_get_hidden_fields(array('docker_backup' => '1'));
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
    ." /usr/local/vesta/bin/v-run-docker-project-action "
    .escapeshellarg($myvesta_logged_user)." "
    .escapeshellarg($owner)." "
    .escapeshellarg($project)." "
    .escapeshellarg('backup');
$hash = trim(shell_exec($cmd));

echo '<b>'.__('Compose backup output').':</b><br /><br />';
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
