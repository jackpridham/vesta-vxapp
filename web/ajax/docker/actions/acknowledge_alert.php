<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['owner'] = true;
$authentication_check_required_param['aid'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

header('Content-Type: application/json');

$owner = trim((string) $_POST['owner']);
$aid = trim((string) $_POST['aid']);

if (!vx_docker_assert_actor_can_access_owner($owner, $myvesta_logged_user)) {
    echo json_encode(array('OK' => false));
    exit;
}

$ok = vx_docker_acknowledge_alert_record($owner, $aid);
echo json_encode(array(
    'OK' => $ok,
    'OWNER' => $owner,
    'AID' => $aid,
));
exit;
