<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$container_name = !empty($_POST['dataset']['container_name']) ? trim((string) $_POST['dataset']['container_name']) : '';
$container_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

if ($container_name !== '' && !vx_docker_assert_actor_can_access_owner($container_owner, $myvesta_logged_user)) {
    echo __('You do not have access to this Docker container.');
    exit;
}

echo myvesta_open_form('/ajax/docker/router.php');
echo myvesta_get_hidden_fields();

if ($container_name === '') {
    if ($myvesta_logged_user === 'admin') {
        echo myvesta_get_element('button_gray', '', 'docker_install', __('Install Docker'), null, 'width: 300px;', 'add');
    } else {
        echo __('Docker engine installation is only available to admin.');
    }
} else {
    echo myvesta_get_element('button_gray', '', 'docker_logs', __('View Docker Logs'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_inspect', __('Inspect Docker Container'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_remove', __('Remove Docker Container'), null, 'width: 300px;', 'add');
}

echo myvesta_close_form();

exit;
