<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$container_name = trim((string) $_POST['dataset']['container_name']);
$container_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

if (empty(vx_docker_resolve_accessible_container($container_owner, $container_name, $myvesta_logged_user))) {
    echo __('You do not have access to this Docker container.');
    exit;
}

$output = shell_exec(
    VESTA_CMD."v-list-docker-container-logs "
    .escapeshellarg($container_owner)
    ." "
    .escapeshellarg($container_name)
    ." 200 2>&1"
);

echo '<b>'.__('Docker container logs').':</b><br /><br />';
echo myvesta_get_disabled_textarea($output, '', true, true, false, '', '', 420);
exit;
