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

$docker_owner = vx_docker_resolve_owner_from_request($user);

if (!empty($_GET['container'])
    && !empty(vx_compose_resolve_accessible_project(
        $docker_owner,
        trim((string) $_GET['container']),
        $user
    ))) {
    exec(
        VESTA_CMD."v-stop-docker-project "
        .escapeshellarg($docker_owner)
        ." "
        .escapeshellarg($_GET['container']),
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
