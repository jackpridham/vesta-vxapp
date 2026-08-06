<?php

$authentication_check_this_is_nested_script = false;
$authentication_check_required_param['dataset'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");

include($_SERVER['DOCUMENT_ROOT']."/inc/form-elements.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$container_name = !empty($_POST['dataset']['project'])
    ? trim((string) $_POST['dataset']['project'])
    : (!empty($_POST['dataset']['container_name'])
        ? trim((string) $_POST['dataset']['container_name'])
        : '');
$container_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

$selected_project = array();
$can_mutate_project = false;
$can_deploy_project = false;
$can_rollback_project = false;
$can_backup_project = false;
$can_restore_project = false;
$can_reconcile_project = false;
$can_remove_project = false;
if ($container_name !== '') {
    $selected_project = vx_compose_resolve_accessible_project(
        $container_owner,
        $container_name,
        $myvesta_logged_user
    );
    if (empty($selected_project)) {
        echo __('You do not have access to this Compose project.');
        exit;
    }
    $can_mutate_project = vx_compose_actor_can_mutate_project(
        $selected_project,
        $myvesta_logged_user,
        $container_owner
    );
    $can_deploy_project = vx_compose_actor_has_capability(
        $myvesta_logged_user,
        $container_owner,
        $container_name,
        'deploy'
    );
    $can_rollback_project = vx_compose_actor_has_capability(
        $myvesta_logged_user,
        $container_owner,
        $container_name,
        'rollback'
    );
    $can_backup_project = vx_compose_actor_has_capability(
        $myvesta_logged_user,
        $container_owner,
        $container_name,
        'backup'
    );
    $can_restore_project = vx_compose_actor_has_capability(
        $myvesta_logged_user,
        $container_owner,
        $container_name,
        'restore'
    );
    $can_reconcile_project = vx_compose_actor_has_capability(
        $myvesta_logged_user,
        $container_owner,
        $container_name,
        'reconcile'
    );
    $can_remove_project = $myvesta_logged_user === 'admin'
        || $myvesta_logged_user === $container_owner;
}

echo myvesta_open_form('/ajax/docker/router.php');
echo myvesta_get_hidden_fields();

if ($container_name === '') {
    if ($myvesta_logged_user === 'admin') {
        echo myvesta_get_element('button_gray', '', 'docker_install', __('Install Docker'), null, 'width: 300px;', 'add');
    } else {
        echo __('Docker engine installation is only available to admin.');
    }
} else {
    echo myvesta_get_element('button_gray', '', 'docker_logs', __('View project logs'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_inspect', __('Project summary'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_audit', __('Audit trail'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_routes', __('Managed routes'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_ingress_consumers', __('Native ingress consumers'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_secrets', __('Secret metadata'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_images', __('Image identities'), null, 'width: 300px;', 'add');
    echo myvesta_get_element('button_gray', '', 'docker_drift', __('Desired/runtime drift'), null, 'width: 300px;', 'add');
    if (!empty($selected_project['WORKLOAD']['PROBES'])) {
        echo myvesta_get_element('button_gray', '', 'docker_probe', __('Run project probe'), null, 'width: 300px;', 'add');
    }
    echo myvesta_get_element('button_gray', '', 'docker_roles', __('Project roles'), null, 'width: 300px;', 'add');
    if ($can_mutate_project) {
        echo myvesta_get_element('button_gray', '', 'docker_recreate', __('Recreate service'), null, 'width: 300px;', 'add');
    }
    if ($can_deploy_project) {
        echo myvesta_get_element('button_gray', '', 'docker_deploy', __('Deploy validated revision'), null, 'width: 300px;', 'add');
    }
    if ($can_rollback_project) {
        echo myvesta_get_element('button_gray', '', 'docker_rollback', __('Rollback revision'), null, 'width: 300px;', 'add');
    }
    if ($can_backup_project) {
        echo myvesta_get_element('button_gray', '', 'docker_backup', __('Create backup'), null, 'width: 300px;', 'add');
    }
    if ($can_restore_project) {
        echo myvesta_get_element('button_gray', '', 'docker_restore', __('Restore backup'), null, 'width: 300px;', 'add');
    }
    if ($can_reconcile_project) {
        echo myvesta_get_element('button_gray', '', 'docker_reconcile', __('Reconcile observed drift'), null, 'width: 300px;', 'add');
    }
    if ($can_remove_project) {
        echo myvesta_get_element('button_gray', '', 'docker_remove', __('Remove project (keep data)'), null, 'width: 300px;', 'add');
    }
}

echo myvesta_close_form();

exit;
