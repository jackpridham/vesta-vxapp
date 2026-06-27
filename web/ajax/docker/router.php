<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$selected_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

if (!empty($_POST['docker_install'])) {
    if ($myvesta_logged_user !== 'admin') {
        echo __('Docker engine installation is only available to admin.');
        exit;
    }

    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/install.php");
    exit;
}

if (!empty($_POST['docker_logs']) || !empty($_POST['docker_inspect']) || !empty($_POST['docker_remove'])) {
    if (!vx_docker_assert_actor_can_access_owner($selected_owner, $myvesta_logged_user)) {
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
