<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

$compose_project_name = isset($_GET['project']) && !is_array($_GET['project'])
    ? trim((string) $_GET['project'])
    : '';
$compose_project_owner = $user === 'admin'
    ? vx_docker_resolve_owner_from_request('')
    : $user;
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
$compose_project_profile = isset($compose_project['PROFILE'])
    ? (string) $compose_project['PROFILE']
    : '';
$compose_standard_workflow = $compose_project_profile === 'standard';
if (!$compose_standard_workflow && $user !== 'admin') {
    $_SESSION['error_msg'] = __('This Compose profile is admin-only.');
    header('Location: /list/docker/');
    exit;
}
if ($compose_standard_workflow
    && !vx_compose_actor_can_manage_profile(
        $user,
        $compose_project_owner,
        $compose_project_profile
    )) {
    $_SESSION['error_msg'] = __('Compose project is not accessible.');
    header('Location: /list/docker/');
    exit;
}

$compose_update_definition = '';
$compose_validation_preview = array();
$compose_preview_key = '';
$compose_spawn_hash = '';
if ($_SERVER['REQUEST_METHOD'] === 'GET') {
    vx_compose_preview_forget_actor_mode($user, 'change');
    if ($compose_standard_workflow) {
        $definition_payload = vx_compose_command_json(
            'v-list-docker-project-definition',
            array($compose_project_owner, $compose_project_name, 'json'),
            array()
        );
        if (empty($definition_payload)
            || !isset(
                $definition_payload['OWNER'],
                $definition_payload['PROJECT'],
                $definition_payload['PROFILE'],
                $definition_payload['REVISION'],
                $definition_payload['DEFINITION']
            )
            || $definition_payload['OWNER'] !== $compose_project_owner
            || $definition_payload['PROJECT'] !== $compose_project_name
            || $definition_payload['PROFILE'] !== 'standard'
            || (int) $definition_payload['REVISION']
                !== (int) $compose_project['REVISION']
            || !is_string($definition_payload['DEFINITION'])
            || trim($definition_payload['DEFINITION']) === '') {
            $_SESSION['error_msg'] = __(
                'The stored Compose definition could not be safely loaded.'
            );
            header('Location: /list/docker/project/?project='
                .urlencode($compose_project_name).'&user='
                .urlencode($compose_project_owner));
            exit;
        }
        $compose_update_definition = $definition_payload['DEFINITION'];
    }
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
    vx_compose_preview_forget($compose_preview_key);
    header('Location: /edit/docker/project/?project='
        .urlencode($compose_project_name).'&user='
        .urlencode($compose_project_owner));
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
        } elseif ($compose_standard_workflow) {
            // v-stage-docker-project-preview owns the immutable candidate.
            $payload = vx_compose_stage_preview(
                $user,
                $compose_project_owner,
                $compose_project_name,
                $source,
                'standard',
                'change'
            );
            vx_compose_web_source_discard($source);
            $record = vx_compose_preview_record($payload, $user);
            if (empty($record)
                || $record['owner'] !== $compose_project_owner
                || $record['project'] !== $compose_project_name
                || $record['profile'] !== 'standard'
                || $record['mode'] !== 'change'
                || $record['expected_revision']
                    !== (int) $compose_project['REVISION']) {
                $_SESSION['error_msg'] = __('Compose project validation failed.');
            } else {
                $compose_validation_preview = $payload;
                $compose_preview_key = vx_compose_preview_store($record);
                $preview = $record;
            }
        } else {
            $payload = vx_compose_command_json(
                'v-validate-docker-project-source',
                array(
                    $compose_project_owner,
                    $compose_project_name,
                    $source,
                    $compose_project_profile,
                ),
                array()
            );
            $source_sha = hash_file('sha256', $source);
            vx_compose_web_source_discard($source);
            try {
                $admin_preview_id = bin2hex(random_bytes(16));
            } catch (Exception $exception) {
                $admin_preview_id = '';
            }
            if (!empty($payload) && $admin_preview_id !== '') {
                $payload['OWNER'] = $compose_project_owner;
                $payload['PROJECT'] = $compose_project_name;
                $payload['PROFILE'] = $compose_project_profile;
                $payload['MODE'] = 'change';
                $payload['PREVIEW_ID'] = $admin_preview_id;
                $payload['SOURCE_SHA256'] = $source_sha;
                $payload['CANDIDATE_SHA256'] = isset(
                    $payload['CANDIDATE_SHA256']
                ) ? $payload['CANDIDATE_SHA256'] : $source_sha;
                $payload['EXPECTED_CURRENT_REVISION'] =
                    (int) $compose_project['REVISION'];
                $payload['EXPIRES_AT'] = gmdate(
                    'Y-m-d\TH:i:s\Z',
                    time() + 900
                );
            }
            $record = vx_compose_preview_record($payload, $user);
            if (empty($record)) {
                $_SESSION['error_msg'] = __('Compose project validation failed.');
            } else {
                $compose_validation_preview = $payload;
                $compose_preview_key = vx_compose_preview_store($record);
                $preview = $record;
            }
        }
        if (empty($_SESSION['error_msg']) && $compose_preview_key === '') {
            $_SESSION['error_msg'] = __(
                'Unable to retain the validated Compose update.'
            );
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
        || !vx_compose_preview_post_matches($preview, $_POST)
        || $preview['owner'] !== $compose_project_owner
        || $preview['project'] !== $compose_project_name
        || $preview['profile'] !== $compose_project_profile
        || $preview['expected_revision'] !== (int) $compose_project['REVISION']) {
        $_SESSION['error_msg'] = __(
            'The validated Compose update expired or changed. Validate it again.'
        );
    } elseif ($compose_standard_workflow
        && vx_compose_actor_can_manage_profile(
            $user,
            $preview['owner'],
            $preview['profile']
        )) {
        $cmd = VESTA_CMD."v-spawn-ajax-process "
            .escapeshellarg($user)
            ." /usr/local/vesta/bin/v-apply-docker-project-preview "
            .escapeshellarg($user)." "
            .escapeshellarg($preview['owner'])." "
            .escapeshellarg($preview['project'])." "
            .escapeshellarg($preview['preview_id'])." "
            .escapeshellarg($preview['source_sha'])." "
            .escapeshellarg($preview['candidate_sha'])." "
            .escapeshellarg((string) $preview['expected_revision']);
        $compose_spawn_hash = trim((string) shell_exec($cmd));
    } elseif ($user === 'admin') {
        $definition = isset($_POST['definition'])
            && !is_array($_POST['definition'])
            ? (string) $_POST['definition']
            : '';
        if (!hash_equals($preview['source_sha'], hash('sha256', $definition))) {
            $_SESSION['error_msg'] = __('The Compose preview was altered.');
        } else {
            $source = vx_compose_web_source_create($definition, 'compose.yaml');
            if ($source !== '') {
                $cmd = VESTA_CMD."v-spawn-ajax-process "
                    .escapeshellarg($user)
                    ." /usr/local/vesta/bin/v-web-change-docker-project "
                    .escapeshellarg($preview['owner'])." "
                    .escapeshellarg($preview['project'])." "
                    .escapeshellarg($source);
                $compose_spawn_hash = trim((string) shell_exec($cmd));
                if ($compose_spawn_hash === '') {
                    vx_compose_web_source_discard($source);
                }
            }
        }
    }
    if (empty($_SESSION['error_msg']) && $compose_spawn_hash === '') {
        $_SESSION['error_msg'] = __('Unable to start Compose project update.');
    }
    if ($compose_spawn_hash !== '') {
        vx_compose_preview_forget($compose_preview_key);
    }
}
if (!empty($_POST)
    && !empty($_SESSION['error_msg'])
    && empty($compose_validation_preview)
    && $compose_spawn_hash === '') {
    $compose_update_definition = '';
}

render_page($user, $TAB, 'edit_docker_project');
