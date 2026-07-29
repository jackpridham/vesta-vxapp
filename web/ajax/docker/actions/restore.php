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
if (empty(vx_compose_resolve_mutable_project(
    $owner,
    $project_name,
    $myvesta_logged_user
))) {
    echo __('You do not have access to this Compose project.');
    exit;
}

$backups = vx_compose_backups_payload($owner, $project_name);
$allowed_archives = array();
foreach ($backups as $backup) {
    if (is_array($backup)
        && !empty($backup['ARCHIVE'])
        && basename((string) $backup['ARCHIVE']) === (string) $backup['ARCHIVE']) {
        $archive_name = (string) $backup['ARCHIVE'];
        $label = $archive_name;
        if (!empty($backup['CREATED'])) {
            $label .= ' — '.$backup['CREATED'];
        }
        $allowed_archives[$archive_name] = $label;
    }
}
$archive = isset($_POST['archive']) && !is_array($_POST['archive'])
    ? trim((string) $_POST['archive'])
    : '';

if ($archive === '') {
    if (empty($allowed_archives)) {
        echo __('No managed backup is available for this project.');
        exit;
    }
    echo myvesta_open_form('/ajax/docker/router.php');
    echo myvesta_get_hidden_fields(array('docker_restore' => '1'));
    echo myvesta_get_element(
        'listbox',
        __('Managed backup'),
        'archive',
        $allowed_archives
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

if (!isset($allowed_archives[$archive])) {
    echo __('The selected managed backup is not available.');
    exit;
}

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __(
        'Validate and apply backup %s to project %s?',
        $archive,
        $project_name
    ).'<br /><br />';
    echo myvesta_get_hidden_fields(array(
        'docker_restore' => '1',
        'archive' => $archive,
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
    ." /usr/local/vesta/bin/v-restore-docker-project "
    .escapeshellarg($owner)." "
    .escapeshellarg($project_name)." "
    .escapeshellarg('managed:'.$archive)." "
    .escapeshellarg('apply');
$hash = trim(shell_exec($cmd));

echo '<b>'.__('Compose restore output').':</b><br /><br />';
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
