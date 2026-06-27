<?php
error_reporting(NULL);
ob_start();
session_start();
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

if ((!isset($_GET['token'])) || ($_SESSION['token'] != $_GET['token'])) {
    header('location: /login/');
    exit();
}

if ($_SESSION['user'] == 'admin' && !empty($_GET['container'])) {
    $container = escapeshellarg($_GET['container']);
    exec(VESTA_CMD."v-start-docker-container ".$container, $output, $return_var);
    check_return_code($return_var, $output);
    unset($output);
}

$back = $_SESSION['back'];
if (!empty($back)) {
    header("Location: ".$back);
    exit;
}

header("Location: /list/docker/");
exit;
