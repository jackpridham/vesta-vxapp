<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$container_name = trim((string) $_POST['dataset']['container_name']);
$container_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

if (empty(vx_docker_resolve_accessible_container($container_owner, $container_name, $myvesta_logged_user))) {
    echo __('You do not have access to this Docker container.');
    exit;
}

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __('Are you sure you want to remove Docker container %s?', $container_name).'<br /><br />';
    echo myvesta_get_hidden_fields(array(
        'docker_remove' => '1',
    ));
    echo myvesta_get_element('buttons_confirm', '', 'Yes/No', __('Yes').'/'.__('No'));
    echo myvesta_close_form();
    exit;
}

if (isset($_POST['No'])) {
    myvesta_hide_floating_div();
    exit;
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-delete-docker-container "
    .escapeshellarg($container_owner)
    ." "
    .escapeshellarg($container_name);

$hash = trim(shell_exec($cmd));

echo '<b>'.__('Docker remove output').':</b><br /><br />';
echo myvesta_get_disabled_textarea('', '', true, true, true, $myvesta_logged_user, $hash);
exit;
