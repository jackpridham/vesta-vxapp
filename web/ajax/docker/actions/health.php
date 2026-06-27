<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['owner'] = true;
$authentication_check_required_param['name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

header('Content-Type: application/json');

$owner = trim((string) $_POST['owner']);
$name = trim((string) $_POST['name']);

if (!vx_docker_assert_actor_can_access_owner($owner, $myvesta_logged_user)) {
    echo json_encode(vx_docker_health_payload(array(
        'OWNER' => $owner,
        'NAME' => $name,
        'STATUS' => '',
        'HEALTH_STATUS' => 'unknown',
        'LAST_HEALTH_AT' => '',
    )));
    exit;
}

$container = vx_docker_get_container($owner, $name);
if (empty($container)) {
    $container = array(
        'OWNER' => $owner,
        'NAME' => $name,
        'STATUS' => '',
        'HEALTH_STATUS' => 'unknown',
        'LAST_HEALTH_AT' => '',
    );
}

echo json_encode(vx_docker_health_payload($container));
exit;
