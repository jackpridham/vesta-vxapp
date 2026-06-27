<?php

$authentication_check_this_is_nested_script = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

if ($myvesta_logged_user !== 'admin') {
    echo __('Docker engine installation is only available to admin.');
    exit;
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-install-docker-service";

$hash = trim(shell_exec($cmd));

echo '<b>'.__('Docker installation output').':</b><br /><br />';
echo myvesta_get_disabled_textarea('', '', true, true, true, $myvesta_logged_user, $hash);
exit;
