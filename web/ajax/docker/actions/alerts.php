<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

header('Content-Type: application/json');

$owner = !empty($_POST['owner']) ? trim((string) $_POST['owner']) : '';
$name = !empty($_POST['name']) ? trim((string) $_POST['name']) : '';

if ($owner !== '' && !vx_docker_assert_actor_can_access_owner($owner, $myvesta_logged_user)) {
    echo json_encode(array('ALERTS' => array()));
    exit;
}

if ($owner === '' && $myvesta_logged_user !== 'admin') {
    $owner = $myvesta_logged_user;
}

$alerts = vx_docker_list_alerts_for_scope($owner);
if ($name !== '') {
    $alerts = array_values(array_filter($alerts, function($alert) use ($name) {
        return isset($alert['NAME']) && $alert['NAME'] === $name;
    }));
}

echo json_encode(array(
    'OWNER' => $owner,
    'NAME' => $name,
    'ALERTS' => $alerts,
));
exit;
