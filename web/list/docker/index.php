<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);
$docker_daemon_available = vx_docker_is_daemon_available($docker_state);
$docker_actor_is_admin = vx_docker_is_admin_actor();
$docker_owner_filter_options = $docker_actor_is_admin ? vx_docker_list_users() : array();
$docker_owner = $docker_actor_is_admin ? vx_docker_resolve_owner_from_request('') : $user;
if ($docker_actor_is_admin && $docker_owner !== '' && !vx_docker_user_exists($docker_owner, $docker_owner_filter_options)) {
    $_SESSION['error_msg'] = __('Docker owner scope does not exist.');
    header('Location: /list/docker/');
    exit;
}
$docker_user_panel = ($docker_owner !== '') ? vx_docker_get_user_panel($docker_owner) : array();
$docker_quota = ($docker_owner !== '') ? vx_docker_get_quota_state($docker_owner, $docker_user_panel) : array(
    'limit' => null,
    'used' => 0,
    'reached' => false,
);

$data = array();
$docker_grouped_data = array();
if ($docker_available) {
    $data = vx_docker_list_containers($docker_actor_is_admin ? 'admin' : $user);
    if ($docker_actor_is_admin && $docker_owner !== '') {
        $data = vx_docker_filter_containers_by_owner($data, $docker_owner);
    }

    if ($docker_actor_is_admin && $docker_owner === '') {
        foreach ($data as $docker_key => $container) {
            $docker_container_owner = isset($container['OWNER']) && $container['OWNER'] !== '' ? $container['OWNER'] : __('Unknown');
            if (!isset($docker_grouped_data[$docker_container_owner])) {
                $docker_grouped_data[$docker_container_owner] = array();
            }

            $docker_grouped_data[$docker_container_owner][$docker_key] = $container;
        }
    }
}

render_page($user, $TAB, 'list_docker');

$_SESSION['back'] = $_SERVER['REQUEST_URI'];
