<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

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
$docker_details_container = ($user === 'admin' || $user === $docker_form_owner)
    ? vx_compose_resolve_accessible_project(
        $docker_form_owner,
        $docker_container_name,
        $user
    )
    : array();

if (empty($docker_details_container)) {
    $_SESSION['error_msg'] = __('Compose project does not exist.');
    header('Location: /list/docker/');
    exit;
}
if (empty($docker_details_container['SIMPLE'])
    || !is_array($docker_details_container['SIMPLE'])
    || empty($docker_details_container['SIMPLE']['GENERATED'])) {
    $details_url = '/list/docker/project/?project='
        .urlencode($docker_container_name);
    if (vx_docker_is_admin_actor()) {
        $details_url .= '&user='.urlencode($docker_form_owner);
    }
    $_SESSION['error_msg'] = __(
        'Multi-service projects are managed from the Compose project view.'
    );
    header('Location: '.$details_url);
    exit;
}

$docker_route_domains = vx_docker_route_domain_options($docker_form_owner);
$docker_form_values = vx_docker_form_defaults($docker_details_container);
$docker_page_mode = 'edit';
$docker_state = vx_docker_get_engine_state();
$docker_available = vx_docker_is_engine_available($docker_state);
$docker_spawn_hash = '';

if (!empty($_POST['save'])) {
    if ((!isset($_POST['token'])) || ($_SESSION['token'] != $_POST['token'])) {
        header('location: /login/');
        exit();
    }
    if (!$docker_available) {
        $_SESSION['error_msg'] = __(
            'Docker orchestration prerequisites are unavailable.'
        );
    }
    if (($user !== 'admin' && $user !== $docker_form_owner)
        || empty(vx_compose_resolve_accessible_project(
            $docker_form_owner,
            $docker_container_name,
            $user
        ))) {
        $_SESSION['error_msg'] = __(
            'You are not authorized to update this Compose project.'
        );
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
                ." /usr/local/vesta/bin/v-web-change-docker-container "
                .escapeshellarg($docker_form_owner)." "
                .escapeshellarg($docker_container_name)." "
                .escapeshellarg($spec_file);
            $docker_spawn_hash = trim((string) shell_exec($cmd));
            if ($docker_spawn_hash === '') {
                vx_compose_web_source_discard($spec_file);
                $_SESSION['error_msg'] = __('Unable to start simple Compose project update.');
            }
        }
    }
}

render_page($user, $TAB, 'edit_docker');
