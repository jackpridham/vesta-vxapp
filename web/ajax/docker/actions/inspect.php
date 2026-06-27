<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

$container_name = $_POST['dataset']['container_name'];
$output = shell_exec(
    VESTA_CMD."v-list-docker-container-inspect "
    .escapeshellarg($container_name)
    ." 2>&1"
);

echo '<b>'.__('Docker container inspect').':</b><br /><br />';
echo myvesta_get_disabled_textarea($output, '', true, true, false, '', '', 420);
exit;
