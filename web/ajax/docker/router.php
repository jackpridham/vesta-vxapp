<?php

$authentication_check_this_is_nested_script = false;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$selected_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;
$selected_container_name = !empty($_POST['dataset']['project'])
    ? trim((string) $_POST['dataset']['project'])
    : (!empty($_POST['dataset']['container_name'])
        ? trim((string) $_POST['dataset']['container_name'])
        : '');

if (!empty($_POST['docker_install'])) {
    if ($myvesta_logged_user !== 'admin') {
        echo __('Docker engine installation is only available to admin.');
        exit;
    }

    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/install.php");
    exit;
}

if (!empty($_POST['docker_logs'])
    || !empty($_POST['docker_inspect'])
    || !empty($_POST['docker_audit'])
    || !empty($_POST['docker_routes'])
    || !empty($_POST['docker_ingress_consumers'])
    || !empty($_POST['docker_secrets'])
    || !empty($_POST['docker_images'])
    || !empty($_POST['docker_drift'])
    || !empty($_POST['docker_roles'])
    || !empty($_POST['docker_reconcile'])
    || !empty($_POST['docker_recreate'])
    || !empty($_POST['docker_deploy'])
    || !empty($_POST['docker_rollback'])
    || !empty($_POST['docker_backup'])
    || !empty($_POST['docker_restore'])
    || !empty($_POST['docker_remove'])) {
    $selected_container = vx_compose_resolve_accessible_project(
        $selected_owner,
        $selected_container_name,
        $myvesta_logged_user
    );

    if (empty($selected_container)) {
        echo __('You do not have access to this Compose project.');
        exit;
    }
}

if (!empty($_POST['docker_logs'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/logs.php");
    exit;
}

if (!empty($_POST['docker_inspect'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/inspect.php");
    exit;
}

foreach (array(
    'audit',
    'routes',
    'ingress_consumers',
    'secrets',
    'images',
    'drift',
    'roles',
    'reconcile',
    'recreate',
    'deploy',
    'rollback',
    'backup',
    'restore',
) as $docker_action) {
    if (!empty($_POST['docker_'.$docker_action])) {
        include(
            $_SERVER['DOCUMENT_ROOT']
            .'/ajax/docker/actions/'.$docker_action.'.php'
        );
        exit;
    }
}

if (!empty($_POST['docker_remove'])) {
    include($_SERVER['DOCUMENT_ROOT']."/ajax/docker/actions/remove.php");
    exit;
}

echo 'No action selected';
exit;
