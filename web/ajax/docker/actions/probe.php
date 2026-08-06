<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$project = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
$selected = vx_compose_resolve_accessible_project(
    $owner,
    $project,
    $myvesta_logged_user
);
if (empty($selected) || empty($selected['WORKLOAD']['PROBES'])) {
    echo __('No managed project probes are available.');
    exit;
}
$probe = isset($_POST['probe']) && !is_array($_POST['probe'])
    ? trim((string) $_POST['probe'])
    : '';
if ($probe === '') {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo '<p>'.__('Select a bounded probe from the current accepted workload.').'</p>';
    foreach ($selected['WORKLOAD']['PROBES'] as $probe_name) {
        echo myvesta_get_element(
            'button_gray',
            '',
            'probe',
            htmlspecialchars((string) $probe_name, ENT_QUOTES),
            (string) $probe_name,
            'width: 300px;',
            'add'
        );
    }
    echo myvesta_get_hidden_fields(array('docker_probe' => '1'));
    echo myvesta_close_form();
    exit;
}
if (!in_array($probe, $selected['WORKLOAD']['PROBES'], true)) {
    echo __('The selected probe is not declared by the current workload.');
    exit;
}
$payload = vx_compose_command_json(
    'v-run-docker-project-probe',
    array($myvesta_logged_user, $owner, $project, $probe, 'json'),
    array()
);
if (empty($payload)) {
    echo __('The project probe did not return a safe result.');
    exit;
}
echo '<h3>'.htmlspecialchars((string) $probe, ENT_QUOTES).'</h3>';
echo '<p>'.htmlspecialchars((string) $payload['STATE'], ENT_QUOTES).': '
    .htmlspecialchars((string) $payload['SUMMARY'], ENT_QUOTES).'</p>';
echo '<details><summary>'.__('Advanced JSON').'</summary><pre>'
    .htmlspecialchars(vx_compose_pretty_json($payload), ENT_QUOTES)
    .'</pre></details>';
exit;
