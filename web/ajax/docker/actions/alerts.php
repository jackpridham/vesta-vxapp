<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

header('Content-Type: application/json');

$owner = !empty($_POST['owner']) ? trim((string) $_POST['owner']) : '';
$name = !empty($_POST['name']) ? trim((string) $_POST['name']) : '';

if ($owner !== '' && !vx_compose_actor_can_access_owner($owner, $myvesta_logged_user)) {
    echo json_encode(array('ALERTS' => array()));
    exit;
}

if ($owner === '' && $myvesta_logged_user !== 'admin') {
    $owner = $myvesta_logged_user;
}

$alerts = array();
$projects = $name !== '' && $owner !== ''
    ? array(vx_compose_get_project($owner, $name))
    : vx_compose_list_projects_for_actor($myvesta_logged_user, $owner);
foreach ($projects as $project) {
    if (empty($project['OWNER']) || empty($project['PROJECT'])) {
        continue;
    }
    $payload = vx_compose_alerts_payload(
        $project['OWNER'],
        $project['PROJECT']
    );
    if (!empty($payload['ALERTS']) && is_array($payload['ALERTS'])) {
        $alerts = array_merge($alerts, $payload['ALERTS']);
    }
}

echo json_encode(array(
    'OWNER' => $owner,
    'NAME' => $name,
    'ALERTS' => $alerts,
));
exit;
