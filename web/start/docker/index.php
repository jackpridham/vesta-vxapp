<?php
error_reporting(NULL);
ob_start();
session_start();
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if ((!isset($_GET['token'])) || ($_SESSION['token'] != $_GET['token'])) {
    header('location: /login/');
    exit();
}

if (!vx_docker_is_orchestration_ready()) {
    $_SESSION['error_msg'] = __(
        'Docker orchestration prerequisites are unavailable.'
    );
    header('Location: /list/docker/');
    exit;
}

$docker_owner = vx_docker_resolve_owner_from_request($user);

if (!empty($_GET['container'])
    && !empty(vx_compose_resolve_mutable_project(
        $docker_owner,
        trim((string) $_GET['container']),
        $user
    ))) {
    exec(
        VESTA_CMD."v-run-docker-project-action "
        .escapeshellarg($user)
        ." "
        .escapeshellarg($docker_owner)
        ." "
        .escapeshellarg($_GET['container'])
        ." "
        .escapeshellarg('start'),
        $output,
        $return_var
    );
    check_return_code($return_var, $output);
    unset($output);
}

$back = $_SESSION['back'];
if (!empty($back)) {
    header("Location: ".$back);
    exit;
}

$redirect = "/list/docker/";
if (vx_docker_is_admin_actor() && $docker_owner !== 'admin') {
    $redirect .= '?user='.urlencode($docker_owner);
}

header("Location: ".$redirect);
exit;
