<?php
error_reporting(NULL);
ob_start();
$TAB = 'DOCKER';

include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_docker.php");
include($_SERVER['DOCUMENT_ROOT']."/inc/vx_compose.php");

if ($user !== 'admin'
    && isset($_REQUEST['user'])
    && (is_array($_REQUEST['user'])
        || (string) $_REQUEST['user'] !== (string) $user)) {
    $_SESSION['error_msg'] = __('Compose owner scope is not accessible.');
    header('Location: /list/docker/');
    exit;
}
$docker_owner_users = vx_docker_list_users();
$docker_form_owner = $user === 'admin'
    ? vx_docker_resolve_owner_from_request('')
    : $user;
if ($docker_form_owner === ''
    || !vx_docker_user_exists($docker_form_owner, $docker_owner_users)
    || !vx_compose_actor_can_access_owner($docker_form_owner, $user)) {
    $_SESSION['error_msg'] = __('Select an existing owner scope.');
    header('Location: /list/docker/');
    exit;
}

$allowed_profiles = $user === 'admin'
    ? array('standard', 'admin-approved')
    : array('standard');
$compose_form = array(
    'project' => '',
    'profile' => 'standard',
    'expires' => $user === 'admin'
        ? gmdate('Y-m-d\TH:i:s\Z', time() + 86400)
        : '',
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
    vx_compose_preview_forget($compose_preview_key);
    header('Location: /add/docker/project/?user='.urlencode($docker_form_owner));
    exit;
}

if (!empty($_POST['validate_preview'])) {
    if (!isset($_POST['token']) || $_SESSION['token'] != $_POST['token']) {
        header('Location: /login/');
        exit;
    }
    if ($user !== 'admin'
        && isset($_POST['profile'])
        && (is_array($_POST['profile'])
            || (string) $_POST['profile'] !== 'standard')) {
        $_SESSION['error_msg'] = __('Invalid Compose profile authority.');
    }
    foreach ($compose_form as $field => $default) {
        if (isset($_POST[$field]) && !is_array($_POST[$field])) {
            $compose_form[$field] = (string) $_POST[$field];
        }
    }
    $compose_form['project'] = trim($compose_form['project']);
    $compose_form['profile'] = trim($compose_form['profile']);
    $compose_form['expires'] = trim($compose_form['expires']);
    if ($user !== 'admin') {
        $compose_form['profile'] = 'standard';
        $compose_form['expires'] = '';
    }

    if (empty($_SESSION['error_msg'])
        && !vx_compose_project_key_is_valid($compose_form['project'])) {
        $_SESSION['error_msg'] = __(
            'Project names use lowercase letters, numbers, and hyphens.'
        );
    } elseif (empty($_SESSION['error_msg'])
        && !in_array($compose_form['profile'], $allowed_profiles, true)) {
        $_SESSION['error_msg'] = __('Invalid Compose profile.');
    } elseif (empty($_SESSION['error_msg'])
        && $compose_form['profile'] === 'admin-approved'
        && !vx_compose_profile_expiry_is_valid($compose_form['expires'])) {
        $_SESSION['error_msg'] = __(
            'Admin-approved profile expiry must be a future UTC timestamp within one year.'
        );
    } elseif (empty($_SESSION['error_msg'])
        && (trim($compose_form['definition']) === ''
        || strlen($compose_form['definition']) > 262144)) {
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
            if ($compose_form['profile'] === 'standard') {
                // v-stage-docker-project-preview owns the immutable candidate.
                $payload = vx_compose_stage_preview(
                    $user,
                    $docker_form_owner,
                    $compose_form['project'],
                    $source,
                    'standard',
                    'add'
                );
                vx_compose_web_source_discard($source);
                $record = vx_compose_preview_record($payload, $user);
            } else {
                $payload = vx_compose_command_json(
                    'v-validate-docker-project-source',
                    array(
                        $docker_form_owner,
                        $compose_form['project'],
                        $source,
                        $compose_form['profile'],
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
                    $payload['OWNER'] = $docker_form_owner;
                    $payload['PROJECT'] = $compose_form['project'];
                    $payload['PROFILE'] = 'admin-approved';
                    $payload['MODE'] = 'add';
                    $payload['PREVIEW_ID'] = $admin_preview_id;
                    $payload['SOURCE_SHA256'] = $source_sha;
                    $payload['CANDIDATE_SHA256'] = isset(
                        $payload['CANDIDATE_SHA256']
                    ) ? $payload['CANDIDATE_SHA256'] : $source_sha;
                    $payload['EXPECTED_CURRENT_REVISION'] = 0;
                    $payload['EXPIRES_AT'] = gmdate(
                        'Y-m-d\TH:i:s\Z',
                        time() + 900
                    );
                }
                $record = vx_compose_preview_record($payload, $user);
            }
            if (empty($record)
                || $record['owner'] !== $docker_form_owner
                || $record['project'] !== $compose_form['project']
                || $record['profile'] !== $compose_form['profile']
                || $record['mode'] !== 'add') {
                $_SESSION['error_msg'] = __('Compose project validation failed.');
            } else {
                $compose_validation_preview = $payload;
                $compose_preview_key = vx_compose_preview_store($record);
                $preview = $record;
                if ($compose_preview_key === '') {
                    $_SESSION['error_msg'] = __(
                        'Unable to retain the validated Compose candidate.'
                    );
                } elseif ($record['profile'] === 'admin-approved'
                    && !vx_compose_admin_expiry_store(
                        $compose_preview_key,
                        array(
                            'actor' => $user,
                            'owner' => $record['owner'],
                            'project' => $record['project'],
                            'profile' => $record['profile'],
                            'mode' => 'add',
                            'admin_expires' => $compose_form['expires'],
                        )
                    )) {
                    vx_compose_preview_forget($compose_preview_key);
                    $compose_preview_key = '';
                    $_SESSION['error_msg'] = __(
                        'Unable to bind the administrator profile expiry.'
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
        || !vx_compose_preview_post_matches($preview, $_POST)
        || $preview['owner'] !== $docker_form_owner
        || $preview['actor'] !== $user
        || !vx_compose_actor_can_access_owner($preview['owner'], $user)) {
        $_SESSION['error_msg'] = __(
            'The validated Compose preview expired. Validate it again.'
        );
    } elseif ($preview['profile'] === 'standard'
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
        $compose_spawn_hash = trim(vx_compose_spawn_command($cmd));
    } elseif ($user === 'admin' && $preview['profile'] === 'admin-approved') {
        $admin_expiry = vx_compose_admin_expiry_get(
            $compose_preview_key,
            $user,
            'add'
        );
        $definition = isset($_POST['definition'])
            && !is_array($_POST['definition'])
            ? (string) $_POST['definition']
            : '';
        $expires = isset($_POST['expires']) && !is_array($_POST['expires'])
            ? (string) $_POST['expires']
            : '';
        if (empty($admin_expiry)
            || $admin_expiry['owner'] !== $preview['owner']
            || $admin_expiry['project'] !== $preview['project']
            || $admin_expiry['profile'] !== $preview['profile']
            || $expires !== $admin_expiry['admin_expires']
            || !hash_equals($preview['source_sha'], hash('sha256', $definition))
            || !vx_compose_profile_expiry_is_valid($expires)) {
            $_SESSION['error_msg'] = __('The Compose preview was altered.');
        } else {
            $source = vx_compose_web_source_create($definition, 'compose.yaml');
            if ($source !== '') {
                $cmd = VESTA_CMD."v-spawn-ajax-process "
                    .escapeshellarg($user)
                    ." /usr/local/vesta/bin/v-web-add-docker-project "
                    .escapeshellarg($preview['owner'])." "
                    .escapeshellarg($preview['project'])." "
                    .escapeshellarg($source)." "
                    .escapeshellarg('admin-approved')." "
                    .escapeshellarg($expires);
                $compose_spawn_hash = trim(vx_compose_spawn_command($cmd));
                if ($compose_spawn_hash === '') {
                    vx_compose_web_source_discard($source);
                }
            }
        }
    } else {
        $_SESSION['error_msg'] = __('Invalid Compose profile authority.');
    }
    if (empty($_SESSION['error_msg']) && $compose_spawn_hash === '') {
        $_SESSION['error_msg'] = __('Unable to start Compose project deployment.');
    }
    if ($compose_spawn_hash !== '') {
        vx_compose_preview_forget($compose_preview_key);
        $compose_form['project'] = $preview['project'];
    }
}
if (!empty($_POST)
    && !empty($_SESSION['error_msg'])
    && empty($compose_validation_preview)
    && $compose_spawn_hash === '') {
    $compose_form['definition'] = '';
}

render_page($user, $TAB, 'add_docker_project');
