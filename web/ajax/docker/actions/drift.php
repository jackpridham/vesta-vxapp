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
$drift = vx_compose_command_json(
    'v-list-docker-project-drift',
    array($myvesta_logged_user, $owner, $project, 'json'),
    array()
);
if (empty($drift) || !isset($drift['DRIFT_DIGEST'], $drift['MATCH'])) {
    echo __('Runtime drift could not be observed safely.');
    exit;
}
echo '<b>'.__('Desired/runtime drift').':</b><br /><br />';
echo '<p>'.htmlspecialchars(
    $drift['MATCH']
        ? __('Runtime matches the validated desired revision.')
        : __('Runtime differs. Reconcile is never automatic.'),
    ENT_QUOTES
).'</p>';
echo '<details><summary>'.__('Advanced JSON').'</summary><pre>'
    .htmlspecialchars(vx_compose_pretty_json($drift), ENT_QUOTES)
    .'</pre></details>';
exit;
