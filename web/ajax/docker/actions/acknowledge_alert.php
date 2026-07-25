<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['owner'] = true;
$authentication_check_required_param['name'] = true;
$authentication_check_required_param['aid'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

header('Content-Type: application/json');

$owner = trim((string) $_POST['owner']);
$name = trim((string) $_POST['name']);
$aid = trim((string) $_POST['aid']);

if (empty(vx_compose_resolve_accessible_project(
    $owner,
    $name,
    $myvesta_logged_user
))) {
    echo json_encode(array('OK' => false));
    exit;
}

$output = array();
$return_var = 0;
exec(
    VESTA_CMD."v-acknowledge-docker-project-alert "
    .escapeshellarg($owner)." "
    .escapeshellarg($name)." "
    .escapeshellarg($aid),
    $output,
    $return_var
);
$ok = ($return_var === 0);
echo json_encode(array(
    'OK' => $ok,
    'OWNER' => $owner,
    'PROJECT' => $name,
    'AID' => $aid,
));
exit;
