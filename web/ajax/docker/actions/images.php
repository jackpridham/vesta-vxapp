<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$project_name = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
$project = vx_compose_resolve_accessible_project(
    $owner,
    $project_name,
    $myvesta_logged_user
);
if (empty($project)) {
    echo __('You do not have access to this Compose project.');
    exit;
}

$images = isset($project['IMAGE_IDENTITIES'])
    && is_array($project['IMAGE_IDENTITIES'])
    ? $project['IMAGE_IDENTITIES']
    : array('REFERENCES' => isset($project['IMAGES']) ? $project['IMAGES'] : array());
echo '<b>'.__('Redacted image identities').':</b><br /><br />';
echo myvesta_get_disabled_textarea(
    htmlspecialchars(vx_compose_pretty_json($images), ENT_QUOTES),
    '',
    true,
    true,
    false,
    '',
    '',
    420
);
exit;
