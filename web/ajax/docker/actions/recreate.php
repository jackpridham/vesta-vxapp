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

$services = vx_compose_service_names($project);
$service = isset($_POST['service']) && !is_array($_POST['service'])
    ? trim((string) $_POST['service'])
    : '';
if ($service === '') {
    if (empty($services)) {
        echo __('No canonical service is available for recreation.');
        exit;
    }
    $options = array();
    foreach ($services as $available_service) {
        $options[$available_service] = $available_service;
    }
    echo myvesta_open_form('/ajax/docker/router.php');
    echo myvesta_get_hidden_fields(array('docker_recreate' => '1'));
    echo myvesta_get_element(
        'listbox',
        __('Service'),
        'service',
        $options
    );
    echo myvesta_get_element('button', '', 'Select', __('Continue'));
    echo myvesta_close_form();
    exit;
}
if (!in_array($service, $services, true)) {
    echo __('The selected Compose service is not available.');
    exit;
}

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo __(
        'Recreate service %s in project %s?',
        $service,
        $project_name
    ).'<br /><br />';
    echo myvesta_get_hidden_fields(array(
        'docker_recreate' => '1',
        'service' => $service,
    ));
    echo myvesta_get_element(
        'buttons_confirm',
        '',
        'Yes/No',
        __('Yes').'/'.__('No')
    );
    echo myvesta_close_form();
    exit;
}
if (isset($_POST['No'])) {
    myvesta_hide_floating_div();
    exit;
}

$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-recreate-docker-project "
    .escapeshellarg($owner)." "
    .escapeshellarg($project_name)." "
    .escapeshellarg($service);
$hash = trim((string) shell_exec($cmd));

echo '<b>'.__('Compose service recreate output').':</b><br /><br />';
echo myvesta_get_disabled_textarea(
    '',
    '',
    true,
    true,
    true,
    $myvesta_logged_user,
    $hash
);
exit;
