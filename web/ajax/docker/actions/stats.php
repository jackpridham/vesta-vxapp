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
$period = !empty($_POST['period']) ? trim((string) $_POST['period']) : '5m';

if (empty(vx_compose_resolve_accessible_project($owner, $name, $myvesta_logged_user))) {
    echo json_encode(array('LATEST' => null, 'SAMPLES' => array()));
    exit;
}

echo json_encode(vx_compose_stats_payload($owner, $name, $period));
exit;
