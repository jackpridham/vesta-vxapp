<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

$container_name = $_POST['dataset']['container_name'];

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
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-delete-docker-container "
    .escapeshellarg($container_name);

$hash = trim(shell_exec($cmd));

echo '<b>'.__('Docker remove output').':</b><br /><br />';
echo myvesta_get_disabled_textarea('', '', true, true, true, $myvesta_logged_user, $hash);
exit;
