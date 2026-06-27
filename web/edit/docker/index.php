<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

if (empty($_GET['container'])) {
    header('Location: /list/docker/');
    exit;
}

$docker_owner_users = vx_docker_is_admin_actor() ? vx_docker_list_users() : array();
$docker_form_owner = vx_docker_resolve_owner_from_request($user);
$docker_owner_requested = vx_docker_is_admin_actor() && isset($_REQUEST['user']) && !is_array($_REQUEST['user']);
if ($docker_owner_requested && !vx_docker_user_exists($docker_form_owner, $docker_owner_users)) {
    $_SESSION['error_msg'] = __('Docker owner scope does not exist.');
    header('Location: /list/docker/');
    exit;
}
$docker_container_name = trim((string) $_GET['container']);
$docker_details_container = vx_docker_get_container($docker_form_owner, $docker_container_name);

if (empty($docker_details_container)) {
    $_SESSION['error_msg'] = __('Docker container does not exist.');
    header('Location: /list/docker/');
    exit;
}

$docker_route_domains = vx_docker_route_domain_options($docker_form_owner);
$docker_form_values = vx_docker_form_defaults($docker_details_container);
$docker_page_mode = 'edit';
$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);

if (!empty($_POST['save'])) {
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }

    foreach ($docker_form_values as $field => $default_value) {
        $docker_form_values[$field] = isset($_POST[$field]) && !is_array($_POST[$field]) ? trim((string) $_POST[$field]) : $default_value;
    }
    $docker_form_values['v_container_name'] = vx_docker_post_value('v_container_name');
    $docker_form_values['v_auto_start'] = isset($_POST['v_auto_start']) ? 'yes' : 'no';
    $docker_form_values['v_alert_email'] = isset($_POST['v_alert_email']) ? 'yes' : 'no';

    if ($docker_form_values['v_container_name'] !== $docker_container_name) {
        $_SESSION['error_msg'] = __('Docker container name can not be changed.');
    } else {
        $docker_form_errors = vx_docker_collect_form_errors($docker_form_owner);
        if (!empty($docker_form_errors)) {
            $_SESSION['error_msg'] = implode(' ', $docker_form_errors);
        }
    }

    if (empty($_SESSION['error_msg'])) {
        exec('mktemp -d', $output, $return_var);
        $tmpdir = isset($output[0]) ? trim($output[0]) : '';
        unset($output);

        if ($return_var !== 0 || $tmpdir === '') {
            $_SESSION['error_msg'] = __('Unable to prepare Docker spec file.');
        } else {
            $spec_file = vx_docker_write_spec_file($tmpdir, vx_docker_spec_from_post());
            exec(
                VESTA_CMD."v-change-docker-container "
                .escapeshellarg($docker_form_owner)
                ." "
                .escapeshellarg($docker_container_name)
                ." "
                .escapeshellarg($spec_file),
                $output,
                $return_var
            );
            check_return_code($return_var, $output);
            unset($output);
            @unlink($spec_file);
            @rmdir($tmpdir);
        }
    }

    if (empty($_SESSION['error_msg'])) {
        $redirect = '/list/docker/';
        if (vx_docker_is_admin_actor() && $docker_form_owner !== 'admin') {
            $redirect .= '?user='.urlencode($docker_form_owner);
        }
        header('Location: '.$redirect);
        exit;
    }
}

render_page($user, $TAB, 'edit_docker');
