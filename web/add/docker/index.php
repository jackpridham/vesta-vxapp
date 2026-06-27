<?php
error_reporting(NULL);
ob_start();
$TAB = 'SERVER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");

$docker_form_owner = vx_docker_resolve_owner_from_request($user);
$docker_route_domains = vx_docker_route_domain_options($docker_form_owner);
$docker_owner_users = vx_docker_is_admin_actor() ? vx_docker_list_users() : array();
$docker_form_values = vx_docker_form_defaults();
$docker_page_mode = 'add';
$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);
$docker_quota = vx_docker_get_quota_state($docker_form_owner);

if (!empty($_POST['ok'])) {
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

    if ($docker_form_values['v_container_name'] === '') $errors[] = __('container name');
    if ($docker_form_values['v_container_image'] === '') $errors[] = __('image');
    if ($docker_form_values['v_container_port'] === '') $errors[] = __('container port');

    if (!empty($errors)) {
        $_SESSION['error_msg'] = __('Field "%s" can not be blank.', implode(', ', $errors));
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
                VESTA_CMD."v-add-docker-container "
                .escapeshellarg($docker_form_owner)
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

render_page($user, $TAB, 'add_docker');
