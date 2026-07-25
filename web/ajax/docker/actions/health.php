<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['owner'] = true;
$authentication_check_required_param['name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

header('Content-Type: application/json');

$owner = trim((string) $_POST['owner']);
$name = trim((string) $_POST['name']);

if (empty(vx_compose_resolve_accessible_project($owner, $name, $myvesta_logged_user))) {
    echo json_encode(array('HEALTH_STATUS' => 'unknown', 'SERVICES' => array()));
    exit;
}

$output = array();
$return_var = 0;
exec(
    VESTA_CMD."v-update-docker-project-monitoring "
    .escapeshellarg($owner)." "
    .escapeshellarg($name),
    $output,
    $return_var
);

echo json_encode(vx_compose_health_payload($owner, $name));
exit;
