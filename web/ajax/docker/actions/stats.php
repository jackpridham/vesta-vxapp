<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['owner'] = true;
$authentication_check_required_param['name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

header('Content-Type: application/json');

$owner = trim((string) $_POST['owner']);
$name = trim((string) $_POST['name']);
$period = !empty($_POST['period']) ? trim((string) $_POST['period']) : '5m';

if (!vx_docker_assert_actor_can_access_owner($owner, $myvesta_logged_user)) {
    echo json_encode(vx_docker_stats_payload($owner, $name, $period));
    exit;
}

echo json_encode(vx_docker_stats_payload($owner, $name, $period));
exit;
