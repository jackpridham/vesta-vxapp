<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$docker_project_name = isset($_GET['project']) && !is_array($_GET['project'])
    ? trim((string) $_GET['project'])
    : '';
$docker_project_owner = $user;
if (isset($_GET['user']) && !is_array($_GET['user'])) {
    $requested_owner = trim((string) $_GET['user']);
    if ($requested_owner !== '') {
        $docker_project_owner = $requested_owner;
    }
}
$docker_project = vx_compose_resolve_accessible_project(
    $docker_project_owner,
    $docker_project_name,
    $user
);

if (empty($docker_project)) {
    $_SESSION['error_msg'] = __('Compose project does not exist or is not accessible.');
    header('Location: /list/docker/');
    exit;
}

$docker_project_health = vx_compose_health_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_stats = vx_compose_stats_payload(
    $docker_project_owner,
    $docker_project_name,
    '5m'
);
$docker_project_alerts = vx_compose_alerts_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_audit = vx_compose_audit_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_routes = vx_compose_routes_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_secrets = vx_compose_secrets_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_backups = vx_compose_backups_payload(
    $docker_project_owner,
    $docker_project_name
);
$docker_project_revisions = vx_compose_revision_options($docker_project);
$docker_project_capabilities = vx_compose_project_action_capabilities(
    $user,
    $docker_project_owner,
    $docker_project_name
);

render_page($user, $TAB, 'docker_project');

$_SESSION['back'] = $_SERVER['REQUEST_URI'];
