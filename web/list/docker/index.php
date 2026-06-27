<?php
error_reporting(NULL);
ob_start();
$TAB = 'SERVER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);
$docker_owner = vx_docker_is_admin_actor() ? vx_docker_resolve_owner_from_request('') : $user;
$docker_scope = ($docker_owner !== '') ? $docker_owner : 'admin';
$docker_owner_filter_options = vx_docker_is_admin_actor() ? vx_docker_list_users() : array();
$docker_user_panel = ($docker_owner !== '') ? vx_docker_get_user_panel($docker_owner) : array();
$docker_quota = ($docker_owner !== '') ? vx_docker_get_quota_state($docker_owner, $docker_user_panel) : array(
    'limit' => null,
    'used' => 0,
    'reached' => false,
);

$data = array();
if ($docker_available) {
    $data = vx_docker_list_containers($docker_scope);
}

render_page($user, $TAB, 'list_docker');

$_SESSION['back'] = $_SERVER['REQUEST_URI'];
