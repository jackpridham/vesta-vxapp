<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if ($user !== 'admin') {
    $_SESSION['error_msg'] = __('Advanced Compose definitions are admin-only.');
    header('Location: /list/docker/');
    exit;
}

$docker_owner_users = vx_docker_list_users();
$docker_form_owner = vx_docker_resolve_owner_from_request('');
if ($docker_form_owner === ''
    || !vx_docker_user_exists($docker_form_owner, $docker_owner_users)) {
    $_SESSION['error_msg'] = __('Select an existing owner scope.');
    header('Location: /list/docker/');
    exit;
}

$compose_form = array(
    'project' => '',
    'profile' => 'standard',
    'expires' => gmdate('Y-m-d\TH:i:s\Z', time() + 86400),
    'definition' => "services:\n  web:\n    image: nginx:stable-alpine\n",
);
$compose_validation_preview = array();
$compose_preview_key = '';
$compose_spawn_hash = '';
if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    vx_compose_preview_forget_actor_mode($user, 'add');
}

if (!empty($_POST['cancel_preview'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    $compose_preview_key = isset($_POST['preview_token'])
        && !is_array($_POST['preview_token'])
        ? (string) $_POST['preview_token']
        : '';
    $preview = vx_compose_preview_get($compose_preview_key, $user, 'add');
    if (!empty($preview)) {
        vx_compose_preview_forget($compose_preview_key, true);
    }
    header(
        'Location: /add/docker/project/?user='.urlencode($docker_form_owner)
    );
    exit;
}

if (!empty($_POST['validate_preview'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    foreach ($compose_form as $field => $default) {
        if (isset($_POST[$field]) && !is_array($_POST[$field])) {
            $compose_form[$field] = (string) $_POST[$field];
        }
    }
    $compose_form['project'] = trim($compose_form['project']);
    $compose_form['profile'] = trim($compose_form['profile']);
    $compose_form['expires'] = trim($compose_form['expires']);

    if (!vx_compose_project_key_is_valid($compose_form['project'])) {
        $_SESSION['error_msg'] = __(
            'Project names use lowercase letters, numbers, and hyphens.'
        );
    } elseif (!in_array(
        $compose_form['profile'],
        array('standard', 'admin-approved'),
        true
    )) {
        $_SESSION['error_msg'] = __('Invalid Compose profile.');
    } elseif ($compose_form['profile'] === 'admin-approved'
        && !vx_compose_profile_expiry_is_valid($compose_form['expires'])) {
        $_SESSION['error_msg'] = __(
            'Admin-approved profile expiry must be a future UTC timestamp within one year.'
        );
    } elseif (trim($compose_form['definition']) === ''
        || strlen($compose_form['definition']) > 262144) {
        $_SESSION['error_msg'] = __(
            'Compose definition must be between 1 and 262144 bytes.'
        );
    }
    if (empty($_SESSION['error_msg'])
        && !empty(vx_compose_get_project(
            $docker_form_owner,
            $compose_form['project']
        ))) {
        $_SESSION['error_msg'] = __(
            'A Compose project with this name already exists.'
        );
    }

    if (empty($_SESSION['error_msg'])) {
        vx_compose_preview_forget_actor_mode($user, 'add');
        $source = vx_compose_web_source_create(
            $compose_form['definition'],
            'compose.yaml'
        );
        if ($source === '') {
            $_SESSION['error_msg'] = __(
                'Unable to prepare protected Compose validation input.'
            );
        } else {
            $compose_validation_preview = vx_compose_command_json(
                'v-validate-docker-project-source',
                array(
                    $docker_form_owner,
                    $compose_form['project'],
                    $source,
                    $compose_form['profile'],
                ),
                array()
            );
            if (empty($compose_validation_preview)) {
                vx_compose_web_source_discard($source);
                $_SESSION['error_msg'] = __(
                    'Compose project validation failed.'
                );
            } else {
                $compose_preview_key = vx_compose_preview_store(array(
                    'actor' => $user,
                    'mode' => 'add',
                    'source' => $source,
                    'owner' => $docker_form_owner,
                    'project' => $compose_form['project'],
                    'profile' => $compose_form['profile'],
                    'expires' => $compose_form['expires'],
                    'preview' => $compose_validation_preview,
                ));
                if ($compose_preview_key === '') {
                    $_SESSION['error_msg'] = __(
                        'Unable to retain the validated Compose candidate.'
                    );
                }
            }
        }
    }
}

if (!empty($_POST['confirm_deploy'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    $compose_preview_key = isset($_POST['preview_token'])
        && !is_array($_POST['preview_token'])
        ? (string) $_POST['preview_token']
        : '';
    $preview = vx_compose_preview_get($compose_preview_key, $user, 'add');
    if (empty($preview)
        || $preview['owner'] !== $docker_form_owner
        || !vx_compose_actor_can_access_owner($preview['owner'], $user)) {
        $_SESSION['error_msg'] = __(
            'The validated Compose preview expired. Validate it again.'
        );
    } else {
        $cmd = VESTA_CMD."v-spawn-ajax-process "
            .escapeshellarg($user)
            ." /usr/local/vesta/bin/v-web-add-docker-project "
            .escapeshellarg($preview['owner'])." "
            .escapeshellarg($preview['project'])." "
            .escapeshellarg($preview['source'])." "
            .escapeshellarg($preview['profile']);
        if ($preview['profile'] === 'admin-approved') {
            $cmd .= " ".escapeshellarg($preview['expires']);
        }
        $compose_spawn_hash = trim((string) shell_exec($cmd));
        if ($compose_spawn_hash === '') {
            vx_compose_preview_forget($compose_preview_key, true);
            $_SESSION['error_msg'] = __(
                'Unable to start Compose project deployment.'
            );
        } else {
            vx_compose_preview_forget($compose_preview_key, false);
            $compose_form['project'] = $preview['project'];
        }
    }
}
if (!empty($_POST)
    && !empty($_SESSION['error_msg'])
    && empty($compose_validation_preview)
    && $compose_spawn_hash === '') {
    $compose_form['definition'] = '';
}

render_page($user, $TAB, 'add_docker_project');
