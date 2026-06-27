<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_match_user = 'admin';
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");

$container_name = '';
if (!empty($_POST['dataset']['container_name'])) {
    $container_name = $_POST['dataset']['container_name'];
}

echo myvesta_open_form('/ajax/docker/router.php');
echo myvesta_get_hidden_fields();

if ($container_name === '') {
    echo myvesta_get_element('button_gray', '', 'docker_install', __('Install Docker'), null, 'width: 300px;', 'add');
} else {
    echo myvesta_get_element('button_gray', '', 'docker_logs', __('View Docker Logs'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_inspect', __('Inspect Docker Container'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_remove', __('Remove Docker Container'), null, 'width: 300px;', 'add');
}

echo myvesta_close_form();

exit;
