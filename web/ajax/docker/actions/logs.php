<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$container_name = trim((string) $_POST['dataset']['container_name']);
$container_owner = !empty($_POST['dataset']['owner']) ? trim((string) $_POST['dataset']['owner']) : $myvesta_logged_user;

$project = vx_compose_resolve_accessible_project(
    $container_owner,
    $container_name,
    $myvesta_logged_user
);
if (empty($project)) {
    echo __('You do not have access to this Compose project.');
    exit;
}

$services = vx_compose_service_names($project);
$service = isset($_POST['service']) && !is_array($_POST['service'])
    ? trim((string) $_POST['service'])
    : '';
if ($service === '') {
    if (empty($services)) {
        echo __('No canonical service is available for log collection.');
        exit;
    }
    $options = array();
    foreach ($services as $available_service) {
        $options[$available_service] = $available_service;
    }
    echo myvesta_open_form('/ajax/docker/router.php');
    echo myvesta_get_hidden_fields(array('docker_logs' => '1'));
    echo myvesta_get_element(
        'listbox',
        __('Service'),
        'service',
        $options
    );
    echo myvesta_get_element('button', '', 'Select', __('View logs'));
    echo myvesta_close_form();
    exit;
}
if (!in_array($service, $services, true)) {
    echo __('The selected Compose service is not available.');
    exit;
}

$output = shell_exec(
    VESTA_CMD."v-list-docker-project-logs "
    .escapeshellarg($container_owner)
    ." "
    .escapeshellarg($container_name)." "
    .escapeshellarg($service)." "
    .escapeshellarg('200')
    ." 2>&1"
);

echo '<b>'.__('Compose project logs').':</b><br /><br />';
echo myvesta_get_disabled_textarea(
    htmlspecialchars((string) $output, ENT_QUOTES),
    '',
    true,
    true,
    false,
    '',
    '',
    420
);
exit;
