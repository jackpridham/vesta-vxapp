<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_match_user = 'admin';
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");

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

if (!empty($_POST['docker_install'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/install.php");
    exit;
}

echo 'No action selected';
exit;
