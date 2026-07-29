<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$docker_owner_users = vx_docker_is_admin_actor() ? vx_docker_list_users() : array();
$docker_form_owner = vx_docker_resolve_owner_from_request($user);
$docker_owner_requested = vx_docker_is_admin_actor() && isset($_REQUEST['user']) && !is_array($_REQUEST['user']);
if (vx_docker_is_admin_actor() && !$docker_owner_requested) {
    $_SESSION['error_msg'] = __('Select an owner scope to add a Docker container.');
    header('Location: /list/docker/');
    exit;
}
if ($docker_owner_requested && !vx_docker_user_exists($docker_form_owner, $docker_owner_users)) {
    $_SESSION['error_msg'] = __('Docker owner scope does not exist.');
    header('Location: /list/docker/');
    exit;
}
$docker_route_domains = vx_docker_route_domain_options($docker_form_owner);
$docker_form_values = vx_docker_form_defaults();
$docker_page_mode = 'add';
$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);
$docker_quota = vx_compose_quota_state($docker_form_owner);
$docker_spawn_hash = '';

if (!empty($_POST['ok'])) {
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }
    if (!$docker_available) {
        $_SESSION['error_msg'] = __(
            'Docker orchestration prerequisites are unavailable.'
        );
    }

    foreach ($docker_form_values as $field => $default_value) {
        $docker_form_values[$field] = isset($_POST[$field]) && !is_array($_POST[$field]) ? trim((string) $_POST[$field]) : $default_value;
    }
    $docker_form_values['v_container_name'] = vx_docker_post_value('v_container_name');
    $docker_form_values['v_auto_start'] = isset($_POST['v_auto_start']) ? 'yes' : 'no';
    $docker_form_values['v_alert_email'] = isset($_POST['v_alert_email']) ? 'yes' : 'no';

    $docker_form_errors = vx_docker_collect_form_errors($docker_form_owner);
    if (!empty($docker_form_errors)) {
        $_SESSION['error_msg'] = implode(' ', $docker_form_errors);
    }

    if (empty($_SESSION['error_msg'])) {
        $spec_payload = vx_docker_spec_from_post();
        $spec_file = vx_compose_web_source_create(
            $spec_payload,
            'simple.spec'
        );
        if ($spec_file === '') {
            $_SESSION['error_msg'] = __('Unable to prepare protected Docker spec file.');
        } else {
            $cmd = VESTA_CMD."v-spawn-ajax-process "
                .escapeshellarg($user)
                ." /usr/local/vesta/bin/v-web-add-docker-container "
                .escapeshellarg($docker_form_owner)." "
                .escapeshellarg($spec_file);
            $docker_spawn_hash = trim((string) shell_exec($cmd));
            if ($docker_spawn_hash === '') {
                vx_compose_web_source_discard($spec_file);
                $_SESSION['error_msg'] = __('Unable to start simple Compose project creation.');
            }
        }
    }

}

render_page($user, $TAB, 'add_docker');
