<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$project = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
if (empty(vx_compose_resolve_capable_project(
    $owner,
    $project,
    $myvesta_logged_user,
    'view'
))) {
    echo __('You do not have access to this Compose project.');
    exit;
}
$roles = vx_compose_command_json(
    'v-list-docker-project-roles',
    array($myvesta_logged_user, $owner, $project, 'json'),
    array()
);
echo '<b>'.__('Project role assignments').':</b><br /><br />';
echo '<p>'.__('Only the owner or administrator can change assignments. Revocation is immediate.').'</p>';
echo '<details><summary>'.__('Advanced JSON').'</summary><pre>'
    .htmlspecialchars(vx_compose_pretty_json($roles), ENT_QUOTES)
    .'</pre></details>';
exit;
