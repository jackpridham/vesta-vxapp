<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if ($user !== 'admin') {
    $_SESSION['error_msg'] = __('Advanced Compose updates are admin-only.');
    header('Location: /list/docker/');
    exit;
}

$compose_project_name = isset($_GET['project']) && !is_array($_GET['project'])
    ? trim((string) $_GET['project'])
    : '';
$compose_project_owner = vx_docker_resolve_owner_from_request('');
$compose_project = vx_compose_resolve_accessible_project(
    $compose_project_owner,
    $compose_project_name,
    $user
);
if (empty($compose_project)) {
    $_SESSION['error_msg'] = __('Compose project does not exist or is not accessible.');
    header('Location: /list/docker/');
    exit;
}

$compose_update_definition = '';
$compose_validation_preview = array();
$compose_preview_key = '';
$compose_spawn_hash = '';
if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    vx_compose_preview_forget_actor_mode($user, 'change');
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
    $preview = vx_compose_preview_get($compose_preview_key, $user, 'change');
    if (!empty($preview)) {
        vx_compose_preview_forget($compose_preview_key, true);
    }
    header(
        'Location: /edit/docker/project/?project='
        .urlencode($compose_project_name)
        .'&user='.urlencode($compose_project_owner)
    );
    exit;
}

if (!empty($_POST['validate_preview'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    $compose_update_definition = isset($_POST['definition'])
        && !is_array($_POST['definition'])
        ? (string) $_POST['definition']
        : '';
    if (trim($compose_update_definition) === ''
        || strlen($compose_update_definition) > 262144) {
        $_SESSION['error_msg'] = __(
            'Compose definition must be between 1 and 262144 bytes.'
        );
    }
    if (empty($_SESSION['error_msg'])) {
        vx_compose_preview_forget_actor_mode($user, 'change');
        $source = vx_compose_web_source_create(
            $compose_update_definition,
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
                    $compose_project_owner,
                    $compose_project_name,
                    $source,
                    $compose_project['PROFILE'],
                ),
                array()
            );
            if (empty($compose_validation_preview)) {
                vx_compose_web_source_discard($source);
                $_SESSION['error_msg'] = __('Compose project validation failed.');
            } else {
                $compose_preview_key = vx_compose_preview_store(array(
                    'actor' => $user,
                    'mode' => 'change',
                    'source' => $source,
                    'owner' => $compose_project_owner,
                    'project' => $compose_project_name,
                    'profile' => $compose_project['PROFILE'],
                    'preview' => $compose_validation_preview,
                ));
                if ($compose_preview_key === '') {
                    $_SESSION['error_msg'] = __(
                        'Unable to retain the validated Compose update.'
                    );
                }
            }
        }
    }
}

if (!empty($_POST['confirm_update'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    $compose_preview_key = isset($_POST['preview_token'])
        && !is_array($_POST['preview_token'])
        ? (string) $_POST['preview_token']
        : '';
    $preview = vx_compose_preview_get($compose_preview_key, $user, 'change');
    if (empty($preview)
        || $preview['owner'] !== $compose_project_owner
        || $preview['project'] !== $compose_project_name) {
        $_SESSION['error_msg'] = __(
            'The validated Compose update expired. Validate it again.'
        );
    } else {
        $cmd = VESTA_CMD."v-spawn-ajax-process "
            .escapeshellarg($user)
            ." /usr/local/vesta/bin/v-web-change-docker-project "
            .escapeshellarg($preview['owner'])." "
            .escapeshellarg($preview['project'])." "
            .escapeshellarg($preview['source']);
        $compose_spawn_hash = trim((string) shell_exec($cmd));
        if ($compose_spawn_hash === '') {
            vx_compose_preview_forget($compose_preview_key, true);
            $_SESSION['error_msg'] = __(
                'Unable to start Compose project update.'
            );
        } else {
            vx_compose_preview_forget($compose_preview_key, false);
        }
    }
}
if (!empty($_POST)
    && !empty($_SESSION['error_msg'])
    && empty($compose_validation_preview)
    && $compose_spawn_hash === '') {
    $compose_update_definition = '';
}

render_page($user, $TAB, 'edit_docker_project');
