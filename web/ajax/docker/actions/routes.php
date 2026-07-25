<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$project = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
if (empty(vx_compose_resolve_accessible_project(
    $owner,
    $project,
    $myvesta_logged_user
))) {
    echo __('You do not have access to this Compose project.');
    exit;
}

echo '<b>'.__('Vesta-managed routes').':</b><br /><br />';
echo myvesta_get_disabled_textarea(
    htmlspecialchars(
        vx_compose_pretty_json(vx_compose_routes_payload($owner, $project)),
        ENT_QUOTES
    ),
    '',
    true,
    true,
    false,
    '',
    '',
    420
);
exit;
