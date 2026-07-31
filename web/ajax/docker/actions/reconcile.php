<?php

$authentication_check_this_is_nested_script = true;
$authentication_check_required_param['dataset']['container_name'] = true;
include($_SERVER['DOCUMENT_ROOT']."/ajax/include_authentication_check.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include_once($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if (!vx_docker_is_orchestration_ready()) {
    echo __('Docker orchestration prerequisites are unavailable.');
    exit;
}
$project = trim((string) $_POST['dataset']['container_name']);
$owner = !empty($_POST['dataset']['owner'])
    ? trim((string) $_POST['dataset']['owner'])
    : $myvesta_logged_user;
if (empty(vx_compose_resolve_capable_project(
    $owner,
    $project,
    $myvesta_logged_user,
    'reconcile'
))) {
    echo __('You do not have access to this Compose project.');
    exit;
}
$preview = vx_compose_command_json(
    'v-preview-docker-project-reconcile',
    array($myvesta_logged_user, $owner, $project),
    array()
);
if (empty($preview)
    || empty($preview['DRIFT_DIGEST'])
    || empty($preview['CURRENT_REVISION'])) {
    echo __('Reconcile preview could not be created safely.');
    exit;
}
$posted_digest = isset($_POST['drift_digest'])
    && !is_array($_POST['drift_digest'])
    ? (string) $_POST['drift_digest']
    : '';
$posted_revision = isset($_POST['current_revision'])
    && !is_array($_POST['current_revision'])
    ? (int) $_POST['current_revision']
    : 0;

if (!isset($_POST['Yes']) && !isset($_POST['No'])) {
    echo myvesta_open_form('/ajax/docker/router.php');
    echo '<p>'.__(
        'Reconcile runtime to revision %s? Definition and data are retained; services and routes may be restarted.',
        (int) $preview['CURRENT_REVISION']
    ).'</p>';
    echo '<details><summary>'.__('Advanced JSON').'</summary><pre>'
        .htmlspecialchars(vx_compose_pretty_json($preview), ENT_QUOTES)
        .'</pre></details>';
    echo myvesta_get_hidden_fields(array(
        'docker_reconcile' => '1',
        'drift_digest' => (string) $preview['DRIFT_DIGEST'],
        'current_revision' => (string) $preview['CURRENT_REVISION'],
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
if (!hash_equals((string) $preview['DRIFT_DIGEST'], $posted_digest)
    || (int) $preview['CURRENT_REVISION'] !== $posted_revision) {
    echo __('Runtime drift changed. Review a fresh reconcile preview.');
    exit;
}
$cmd = VESTA_CMD."v-spawn-ajax-process "
    .escapeshellarg($myvesta_logged_user)
    ." /usr/local/vesta/bin/v-reconcile-docker-project "
    .escapeshellarg($myvesta_logged_user)." "
    .escapeshellarg($owner)." "
    .escapeshellarg($project)." "
    .escapeshellarg($posted_digest)." "
    .escapeshellarg((string) $posted_revision);
$hash = trim((string) shell_exec($cmd));
echo '<b>'.__('Compose reconcile output').':</b><br /><br />';
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
