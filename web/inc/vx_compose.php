<?php

function vx_compose_command_json($command, $arguments, $default = array())
{
    $allowed = array(
        'v-list-docker-projects',
        'v-list-docker-project',
        'v-list-docker-project-health',
        'v-list-docker-project-stats',
        'v-list-docker-project-alerts',
        'v-list-docker-project-audit',
        'v-list-docker-project-routes',
        'v-list-docker-secrets',
        'v-list-docker-project-backups',
        'v-validate-docker-project-source',
        'v-list-docker-project-definition',
        'v-stage-docker-project-preview',
    );
    if (!in_array($command, $allowed, true) || !is_array($arguments)) {
        return $default;
    }

    $parts = array(VESTA_CMD.$command);
    foreach ($arguments as $argument) {
        $parts[] = escapeshellarg((string) $argument);
    }

    $output = array();
    $return_var = 0;
    exec(implode(' ', $parts), $output, $return_var);
    if ($return_var !== 0) {
        return $default;
    }

    $decoded = json_decode(implode('', $output), true);
    return is_array($decoded) ? $decoded : $default;
}

function vx_compose_web_source_is_valid_path($source)
{
    return is_string($source)
        && preg_match(
            '#^/tmp/vx-compose-web\.[0-9a-f]{32}/(compose\.yaml|simple\.spec)$#D',
            $source
        ) === 1;
}

function vx_compose_web_source_create($definition, $filename = 'compose.yaml')
{
    if (!is_string($definition)
        || trim($definition) === ''
        || strlen($definition) > 262144) {
        return '';
    }
    try {
        $suffix = bin2hex(random_bytes(16));
    } catch (Exception $exception) {
        return '';
    }
    if (!in_array($filename, array('compose.yaml', 'simple.spec'), true)) {
        return '';
    }
    $directory = '/tmp/vx-compose-web.'.$suffix;
    $source = $directory.'/'.$filename;
    if (!mkdir($directory, 0700) || !chmod($directory, 0700)) {
        return '';
    }
    $handle = @fopen($source, 'x');
    if ($handle === false) {
        @rmdir($directory);
        return '';
    }
    $written = fwrite($handle, $definition);
    $closed = fclose($handle);
    if ($written !== strlen($definition)
        || !$closed
        || !chmod($source, 0600)
        || is_link($source)
        || !is_file($source)) {
        @unlink($source);
        @rmdir($directory);
        return '';
    }
    clearstatcache(true, $source);
    $directory_stat = @stat($directory);
    $source_stat = @stat($source);
    if (!is_array($directory_stat)
        || !is_array($source_stat)
        || $directory_stat['uid'] !== $source_stat['uid']
        || ($directory_stat['mode'] & 0777) !== 0700
        || ($source_stat['mode'] & 0777) !== 0600) {
        @unlink($source);
        @rmdir($directory);
        return '';
    }
    return $source;
}

function vx_compose_web_source_discard($source)
{
    if (!vx_compose_web_source_is_valid_path($source)) {
        return false;
    }
    $directory = dirname($source);
    if (dirname($directory) !== '/tmp'
        || is_link($directory)
        || is_link($source)) {
        return false;
    }
    if (file_exists($source) && !@unlink($source)) {
        return false;
    }
    return !is_dir($directory) || @rmdir($directory);
}

function vx_compose_preview_forget($key, $discard = true)
{
    if (isset($_SESSION['vx_compose_previews'][$key])) {
        unset($_SESSION['vx_compose_previews'][$key]);
    }
}

function vx_compose_preview_store($preview)
{
    if (!is_array($preview)
        || empty($preview['preview_id'])
        || preg_match(
            '/^[a-f0-9]{32}$/D',
            (string) $preview['preview_id']
        ) !== 1) {
        return '';
    }
    try {
        $key = bin2hex(random_bytes(16));
    } catch (Exception $exception) {
        return '';
    }
    if (!isset($_SESSION['vx_compose_previews'])
        || !is_array($_SESSION['vx_compose_previews'])) {
        $_SESSION['vx_compose_previews'] = array();
    }
    $preview['created'] = time();
    $_SESSION['vx_compose_previews'][$key] = $preview;
    return $key;
}

function vx_compose_preview_get($key, $actor, $mode)
{
    if (!is_string($key)
        || preg_match('/^[0-9a-f]{32}$/D', $key) !== 1
        || empty($_SESSION['vx_compose_previews'][$key])
        || !is_array($_SESSION['vx_compose_previews'][$key])) {
        return array();
    }
    $preview = $_SESSION['vx_compose_previews'][$key];
    if (empty($preview['actor'])
        || $preview['actor'] !== $actor
        || empty($preview['mode'])
        || $preview['mode'] !== $mode
        || empty($preview['preview_id'])
        || preg_match(
            '/^[a-f0-9]{32}$/D',
            (string) $preview['preview_id']
        ) !== 1
        || empty($preview['source_sha'])
        || preg_match(
            '/^[a-f0-9]{64}$/D',
            (string) $preview['source_sha']
        ) !== 1
        || empty($preview['candidate_sha'])
        || preg_match(
            '/^[a-f0-9]{64}$/D',
            (string) $preview['candidate_sha']
        ) !== 1
        || !array_key_exists('expected_revision', $preview)
        || !is_int($preview['expected_revision'])
        || $preview['expected_revision'] < 0
        || ($mode === 'add' && $preview['expected_revision'] !== 0)
        || ($mode === 'change' && $preview['expected_revision'] < 1)
        || empty($preview['created'])
        || !is_int($preview['created'])
        || $preview['created'] > time()
        || (time() - $preview['created']) > 900) {
        vx_compose_preview_forget($key);
        return array();
    }
    return $preview;
}

function vx_compose_preview_forget_actor_mode($actor, $mode)
{
    if (empty($_SESSION['vx_compose_previews'])
        || !is_array($_SESSION['vx_compose_previews'])) {
        return;
    }
    foreach ($_SESSION['vx_compose_previews'] as $key => $preview) {
        if (is_array($preview)
            && isset($preview['actor'], $preview['mode'])
            && $preview['actor'] === $actor
            && $preview['mode'] === $mode) {
            vx_compose_preview_forget($key);
        }
    }
}

function vx_compose_actor_can_access_owner($owner, $actor)
{
    return $actor === 'admin' || $owner === $actor;
}

function vx_compose_actor_can_manage_profile($actor, $owner, $profile)
{
    return $profile === 'standard'
        && ($actor === 'admin' || $actor === $owner);
}

function vx_compose_stage_preview(
    $actor,
    $owner,
    $project,
    $source,
    $profile,
    $mode
) {
    return vx_compose_command_json(
        'v-stage-docker-project-preview',
        array($actor, $owner, $project, $source, $profile, $mode),
        array()
    );
}

function vx_compose_preview_record($payload, $actor)
{
    $required = array(
        'OWNER',
        'PROJECT',
        'PROFILE',
        'MODE',
        'PREVIEW_ID',
        'SOURCE_SHA256',
        'CANDIDATE_SHA256',
        'EXPECTED_CURRENT_REVISION',
        'EXPIRES_AT',
    );
    if (!is_array($payload)) {
        return array();
    }
    foreach ($required as $field) {
        if (!array_key_exists($field, $payload)) {
            return array();
        }
    }
    return array(
        'actor' => (string) $actor,
        'owner' => (string) $payload['OWNER'],
        'project' => (string) $payload['PROJECT'],
        'profile' => (string) $payload['PROFILE'],
        'mode' => (string) $payload['MODE'],
        'preview_id' => (string) $payload['PREVIEW_ID'],
        'source_sha' => (string) $payload['SOURCE_SHA256'],
        'candidate_sha' => (string) $payload['CANDIDATE_SHA256'],
        'expected_revision' => $payload['EXPECTED_CURRENT_REVISION'],
        'expires_at' => (string) $payload['EXPIRES_AT'],
        'preview' => $payload,
    );
}

function vx_compose_preview_post_matches($preview, $post)
{
    if (!is_array($preview) || !is_array($post)) {
        return false;
    }
    $fields = array(
        'owner',
        'project',
        'profile',
        'preview_id',
        'source_sha',
        'candidate_sha',
        'expected_revision',
    );
    foreach ($fields as $field) {
        if (!isset($post[$field])
            || is_array($post[$field])
            || !array_key_exists($field, $preview)
            || (string) $post[$field] !== (string) $preview[$field]) {
            return false;
        }
    }
    return true;
}

function vx_compose_project_key_is_valid($project)
{
    return is_string($project)
        && preg_match('/^[a-z0-9][a-z0-9-]{0,47}$/', $project) === 1;
}

function vx_compose_owner_key_is_valid($owner)
{
    return is_string($owner)
        && preg_match('/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,31}$/', $owner) === 1;
}

function vx_compose_profile_expiry_is_valid($expires, $now = null)
{
    if (!is_string($expires)
        || preg_match(
            '/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/',
            $expires
        ) !== 1) {
        return false;
    }
    $expiry = DateTimeImmutable::createFromFormat(
        '!Y-m-d\TH:i:s\Z',
        $expires,
        new DateTimeZone('UTC')
    );
    $errors = DateTimeImmutable::getLastErrors();
    if ($expiry === false
        || (is_array($errors)
            && ($errors['warning_count'] > 0 || $errors['error_count'] > 0))) {
        return false;
    }
    $current = $now instanceof DateTimeImmutable
        ? $now
        : new DateTimeImmutable('now', new DateTimeZone('UTC'));
    $latest = $current->modify('+1 year');
    return $expiry > $current && $expiry <= $latest;
}

function vx_compose_state_for_legacy_view($state)
{
    if ($state === 'running' || $state === 'degraded') {
        return 'running';
    }
    if ($state === 'stopped') {
        return 'exited';
    }
    if ($state === 'validated' || $state === 'draft' || $state === 'adopted') {
        return 'created';
    }
    return $state !== '' ? $state : 'unknown';
}

function vx_compose_normalize_project($project)
{
    if (!is_array($project)
        || empty($project)
        || empty($project['OWNER'])
        || empty($project['PROJECT'])) {
        return array();
    }

    $routes = !empty($project['ROUTES']) && is_array($project['ROUTES'])
        ? $project['ROUTES']
        : array();
    $first_route = !empty($routes) ? reset($routes) : array();
    if (!is_array($first_route)) {
        $first_route = array();
    }
    $services = !empty($project['SERVICES']) && is_array($project['SERVICES'])
        ? array_values($project['SERVICES'])
        : array();
    $images = !empty($project['IMAGES']) && is_array($project['IMAGES'])
        ? array_values($project['IMAGES'])
        : array();
    $state = isset($project['STATE']) ? (string) $project['STATE'] : '';
    $name = isset($project['PROJECT']) ? (string) $project['PROJECT'] : '';
    $simple = isset($project['SIMPLE'])
        && is_array($project['SIMPLE'])
        && !empty($project['SIMPLE']['GENERATED'])
        && count($services) === 1
        ? $project['SIMPLE']
        : array();

    return array_merge($project, $simple, array(
        'NAME' => $name,
        'CTN_NAME' => isset($project['COMPOSE_PROJECT'])
            ? (string) $project['COMPOSE_PROJECT']
            : '',
        'IMAGE' => !empty($simple) && isset($simple['IMAGE'])
            ? (string) $simple['IMAGE']
            : implode(', ', $images),
        'STATUS' => vx_compose_state_for_legacy_view($state),
        'HEALTH_STATUS' => isset($project['HEALTH'])
            ? (string) $project['HEALTH']
            : 'unknown',
        'LAST_HEALTH_AT' => isset($project['UPDATED'])
            ? (string) $project['UPDATED']
            : '',
        'HOST_PORT' => !empty($simple) && isset($simple['HOST_PORT'])
            ? (string) $simple['HOST_PORT']
            : (isset($first_route['HOST_PORT'])
                ? (string) $first_route['HOST_PORT']
                : ''),
        'CONTAINER_PORT' => !empty($simple)
            && isset($simple['CONTAINER_PORT'])
            ? (string) $simple['CONTAINER_PORT']
            : (isset($first_route['CONTAINER_PORT'])
                ? (string) $first_route['CONTAINER_PORT']
                : ''),
        'DOMAIN' => !empty($simple) && isset($simple['DOMAIN'])
            ? (string) $simple['DOMAIN']
            : (isset($first_route['DOMAIN'])
                ? (string) $first_route['DOMAIN']
                : ''),
        'ROUTE_PATH' => !empty($simple) && isset($simple['ROUTE_PATH'])
            ? (string) $simple['ROUTE_PATH']
            : (isset($first_route['PATH'])
                ? (string) $first_route['PATH']
                : ''),
        'PROXY_TARGET' => (
            !empty($simple)
            && !empty($simple['HOST_PORT'])
        )
            ? 'http://127.0.0.1:'.$simple['HOST_PORT']
            : (isset($first_route['HOST_PORT'])
                ? 'http://127.0.0.1:'.$first_route['HOST_PORT']
                : ''),
        'RESTART_POLICY' => !empty($simple)
            && isset($simple['RESTART_POLICY'])
            ? (string) $simple['RESTART_POLICY']
            : '',
        'PROFILE' => isset($project['PROFILE'])
            ? (string) $project['PROFILE']
            : 'standard',
        'SERVICE_COUNT' => count($services),
        'SERVICES' => $services,
        'IMAGES' => $images,
        'REVISION' => isset($project['REVISION']) ? (int) $project['REVISION'] : 0,
        'IS_COMPOSE' => true,
        'IS_SIMPLE' => !empty($simple),
    ));
}

function vx_compose_list_owner_projects($owner)
{
    $projects = vx_compose_command_json(
        'v-list-docker-projects',
        array($owner, 'json'),
        array()
    );
    $normalized = array();
    foreach ($projects as $key => $project) {
        $item = vx_compose_normalize_project($project);
        if (!empty($item)) {
            $normalized[$key] = $item;
        }
    }
    return $normalized;
}

function vx_compose_list_projects_for_actor($actor, $owner = '')
{
    if ($owner !== '') {
        return vx_compose_actor_can_access_owner($owner, $actor)
            ? vx_compose_list_owner_projects($owner)
            : array();
    }
    if ($actor !== 'admin') {
        return vx_compose_list_owner_projects($actor);
    }

    $projects = array();
    foreach (vx_docker_list_users() as $user_key => $user_data) {
        $candidate = is_string($user_key) ? $user_key : '';
        if (is_array($user_data)) {
            $candidate = !empty($user_data['USER'])
                ? (string) $user_data['USER']
                : (!empty($user_data['NAME'])
                    ? (string) $user_data['NAME']
                    : $candidate);
        } elseif (is_string($user_data)) {
            $candidate = $user_data;
        }
        if ($candidate === '') {
            continue;
        }
        $projects = array_merge(
            $projects,
            vx_compose_list_owner_projects($candidate)
        );
    }
    return $projects;
}

function vx_compose_quota_state($owner, $user_panel = null)
{
    if (!is_array($user_panel) || empty($user_panel)) {
        $user_panel = vx_docker_get_user_panel($owner);
    }
    $limit_raw = isset($user_panel['DOCKER_PROJECTS'])
        ? trim((string) $user_panel['DOCKER_PROJECTS'])
        : '0';
    $used = isset($user_panel['U_DOCKER_PROJECTS'])
        ? (int) $user_panel['U_DOCKER_PROJECTS']
        : 0;
    $limit = null;
    if ($limit_raw !== '' && strtolower($limit_raw) !== 'unlimited') {
        $limit = (int) $limit_raw;
    }
    return array(
        'limit' => $limit,
        'used' => $used,
        'reached' => ($limit !== null && $used >= $limit),
    );
}

function vx_compose_get_project($owner, $project)
{
    if (!vx_compose_owner_key_is_valid($owner)
        || !vx_compose_project_key_is_valid($project)) {
        return array();
    }
    $data = vx_compose_command_json(
        'v-list-docker-project',
        array($owner, $project, 'json'),
        array()
    );
    return vx_compose_normalize_project($data);
}

function vx_compose_resolve_accessible_project($owner, $project, $actor)
{
    if (!vx_compose_actor_can_access_owner($owner, $actor)) {
        return array();
    }
    return vx_compose_get_project($owner, $project);
}

function vx_compose_health_payload($owner, $project)
{
    $payload = vx_compose_command_json(
        'v-list-docker-project-health',
        array($owner, $project, 'json'),
        array(
            'OWNER' => $owner,
            'PROJECT' => $project,
            'STATUS' => 'unknown',
            'SERVICES' => array(),
        )
    );
    $payload['HEALTH_STATUS'] = isset($payload['STATUS'])
        ? $payload['STATUS']
        : 'unknown';
    $payload['LAST_HEALTH_AT'] = isset($payload['UPDATED'])
        ? $payload['UPDATED']
        : '';
    $payload['NAME'] = $project;
    return $payload;
}

function vx_compose_stats_payload($owner, $project, $period)
{
    $payload = vx_compose_command_json(
        'v-list-docker-project-stats',
        array($owner, $project, $period, 'json'),
        array(
            'OWNER' => $owner,
            'PROJECT' => $project,
            'PERIOD' => $period,
            'SAMPLES' => array(),
            'LATEST' => null,
        )
    );
    if (isset($payload['LATEST']) && is_array($payload['LATEST'])) {
        $payload['LATEST']['MEM_MB'] = isset($payload['LATEST']['MEMORY_MB'])
            ? $payload['LATEST']['MEMORY_MB']
            : null;
    }
    return $payload;
}

function vx_compose_alerts_payload($owner, $project)
{
    $payload = vx_compose_command_json(
        'v-list-docker-project-alerts',
        array($owner, $project, 'json'),
        array('OWNER' => $owner, 'PROJECT' => $project, 'ALERTS' => array())
    );
    if (!isset($payload['ALERTS']) || !is_array($payload['ALERTS'])) {
        $payload['ALERTS'] = array();
    }
    foreach ($payload['ALERTS'] as &$alert) {
        $alert['OWNER'] = $owner;
        $alert['NAME'] = $project;
        $alert['LEVEL'] = isset($alert['TYPE']) && $alert['TYPE'] === 'health'
            ? 'critical'
            : 'warning';
        $alert['TITLE'] = isset($alert['TYPE'])
            ? ucfirst($alert['TYPE']).' alert'
            : 'Compose alert';
        $alert['MESSAGE'] = isset($alert['VALUE'])
            ? 'Observed value: '.(string) $alert['VALUE']
            : '';
        $alert['ACK'] = !empty($alert['ACK']) ? 'yes' : 'no';
        $alert['LAST_SEEN'] = isset($alert['CLOSED'])
            && $alert['CLOSED'] !== null
            ? $alert['CLOSED']
            : (isset($alert['OPENED']) ? $alert['OPENED'] : '');
    }
    unset($alert);
    return $payload;
}

function vx_compose_audit_payload($owner, $project)
{
    return vx_compose_command_json(
        'v-list-docker-project-audit',
        array($owner, $project, 'json'),
        array()
    );
}

function vx_compose_routes_payload($owner, $project)
{
    return vx_compose_command_json(
        'v-list-docker-project-routes',
        array($owner, $project, 'json'),
        array()
    );
}

function vx_compose_secrets_payload($owner, $project)
{
    return vx_compose_command_json(
        'v-list-docker-secrets',
        array($owner, $project, 'json'),
        array()
    );
}

function vx_compose_backups_payload($owner, $project)
{
    return vx_compose_command_json(
        'v-list-docker-project-backups',
        array($owner, $project, 'json'),
        array()
    );
}

function vx_compose_pretty_json($value)
{
    $flags = defined('JSON_PRETTY_PRINT') ? JSON_PRETTY_PRINT : 0;
    $encoded = json_encode($value, $flags);
    return is_string($encoded) ? $encoded : '{}';
}

function vx_compose_revision_options($project)
{
    if (isset($project['REVISIONS']) && is_array($project['REVISIONS'])) {
        $revisions = array();
        foreach ($project['REVISIONS'] as $revision) {
            if (is_array($revision) && isset($revision['REVISION'])) {
                $revisions[] = (int) $revision['REVISION'];
            } elseif (is_numeric($revision)) {
                $revisions[] = (int) $revision;
            }
        }
        $revisions = array_values(array_unique(array_filter($revisions)));
        rsort($revisions, SORT_NUMERIC);
        if (!empty($revisions)) {
            return $revisions;
        }
    }
    $current = isset($project['REVISION']) ? (int) $project['REVISION'] : 0;
    $revisions = array();
    for ($revision = $current; $revision >= 1; --$revision) {
        $revisions[] = $revision;
    }
    return $revisions;
}

function vx_compose_service_names($project)
{
    if (!is_array($project)) {
        return array();
    }
    $services = array();
    if (!empty($project['SERVICE_SUMMARY'])
        && is_array($project['SERVICE_SUMMARY'])) {
        $services = array_keys($project['SERVICE_SUMMARY']);
    } elseif (!empty($project['SERVICES'])
        && is_array($project['SERVICES'])) {
        $services = array_values($project['SERVICES']);
    }
    $services = array_values(array_filter($services, function ($service) {
        return is_string($service)
            && preg_match('/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/D', $service);
    }));
    sort($services, SORT_STRING);
    return $services;
}
