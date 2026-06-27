<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$selected_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;
$selected_container_name = !empty($_POST['dataset']['container_name']) ? trim((string) $_POST['dataset']['container_name']) : '';

if (!empty($_POST['docker_install'])) {
    if ($myvesta_logged_user !== 'admin') {
        echo __('Docker engine installation is only available to admin.');
        exit;
    }

    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/install.php");
    exit;
}

if (!empty($_POST['docker_logs']) || !empty($_POST['docker_inspect']) || !empty($_POST['docker_remove'])) {
    $selected_container = vx_docker_resolve_accessible_container(
        $selected_owner,
        $selected_container_name,
        $myvesta_logged_user
    );

    if (empty($selected_container)) {
        echo __('You do not have access to this Docker container.');
        exit;
    }
}

if (!empty($_POST['docker_logs'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/logs.php");
    exit;
}

if (!empty($_POST['docker_inspect'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/inspect.php");
    exit;
}

if (!empty($_POST['docker_remove'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/remove.php");
    exit;
}

echo 'No action selected';
exit;
