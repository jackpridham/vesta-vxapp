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
        'v-list-docker-project-ingress-consumers',
        'v-list-docker-secrets',
        'v-list-docker-project-backups',
        'v-validate-docker-project-source',
        'v-list-docker-project-definition',
        'v-stage-docker-project-preview',
        'v-check-docker-project-capability',
        'v-list-docker-project-drift',
        'v-preview-docker-project-reconcile',
        'v-preview-docker-project-rollback',
        'v-compare-docker-project-revisions',
        'v-list-docker-project-operation',
        'v-list-docker-project-roles',
        'v-list-docker-project-notification-routes',
    );
    if (!in_array($command, $allowed, true) || !is_array($arguments)) {
        return $default;
    }
    if (defined('VX_COMPOSE_CONTROLLER_TEST')
        && VX_COMPOSE_CONTROLLER_TEST === true
        && function_exists('vx_compose_test_command_json')) {
        $result = vx_compose_test_command_json($command, $arguments, $default);
        return is_array($result) ? $result : $default;
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

function vx_compose_spawn_command($command)
{
    if (defined('VX_COMPOSE_CONTROLLER_TEST')
        && VX_COMPOSE_CONTROLLER_TEST === true
        && function_exists('vx_compose_test_spawn_command')) {
        return (string) vx_compose_test_spawn_command($command);
    }
    return (string) shell_exec($command);
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

function vx_compose_preview_forget($key)
{
    if (isset($_SESSION['vx_compose_previews'][$key])) {
        unset($_SESSION['vx_compose_previews'][$key]);
    }
    vx_compose_admin_expiry_forget($key);
}

function vx_compose_preview_store($preview)
{
    $allowed_keys = array(
        'actor',
        'owner',
        'project',
        'profile',
        'mode',
        'preview_id',
        'source_sha',
        'candidate_sha',
        'expected_revision',
        'expires_at',
        'preview',
    );
    if (!is_array($preview)
        || !vx_compose_array_has_exact_keys($preview, $allowed_keys)
        || !vx_compose_preview_payload_is_source_free($preview)
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
    if (!vx_compose_array_has_exact_keys($preview, array(
            'actor',
            'owner',
            'project',
            'profile',
            'mode',
            'preview_id',
            'source_sha',
            'candidate_sha',
            'expected_revision',
            'expires_at',
            'preview',
        ))
        || !vx_compose_preview_payload_is_source_free($preview)
        || empty($preview['actor'])
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
        || empty($preview['expires_at'])
        || !is_string($preview['expires_at'])
        || strtotime($preview['expires_at']) === false
        || strtotime($preview['expires_at']) <= time()
        || (strtotime($preview['expires_at']) - time()) > 900) {
        vx_compose_preview_forget($key);
        return array();
    }
    return $preview;
}

function vx_compose_preview_forget_actor_mode($actor, $mode)
{
    vx_compose_admin_expiry_forget_actor_mode($actor, $mode);
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

function vx_compose_admin_expiry_store($key, $record)
{
    $expected = array(
        'actor',
        'owner',
        'project',
        'profile',
        'mode',
        'admin_expires',
    );
    if (!is_string($key)
        || preg_match('/^[a-f0-9]{32}$/D', $key) !== 1
        || !vx_compose_array_has_exact_keys($record, $expected)
        || $record['actor'] !== 'admin'
        || $record['profile'] !== 'admin-approved'
        || !in_array($record['mode'], array('add', 'change'), true)
        || !vx_compose_owner_key_is_valid($record['owner'])
        || !vx_compose_project_key_is_valid($record['project'])
        || !vx_compose_profile_expiry_is_valid($record['admin_expires'])) {
        return false;
    }
    if (!isset($_SESSION['vx_compose_admin_expiry'])
        || !is_array($_SESSION['vx_compose_admin_expiry'])) {
        $_SESSION['vx_compose_admin_expiry'] = array();
    }
    $_SESSION['vx_compose_admin_expiry'][$key] = $record;
    return true;
}

function vx_compose_admin_expiry_get($key, $actor, $mode)
{
    if (!is_string($key)
        || preg_match('/^[a-f0-9]{32}$/D', $key) !== 1
        || empty($_SESSION['vx_compose_admin_expiry'][$key])
        || !is_array($_SESSION['vx_compose_admin_expiry'][$key])) {
        return array();
    }
    $record = $_SESSION['vx_compose_admin_expiry'][$key];
    if (!vx_compose_array_has_exact_keys($record, array(
            'actor',
            'owner',
            'project',
            'profile',
            'mode',
            'admin_expires',
        ))
        || $record['actor'] !== $actor
        || $record['mode'] !== $mode
        || $record['profile'] !== 'admin-approved'
        || !vx_compose_profile_expiry_is_valid($record['admin_expires'])) {
        vx_compose_admin_expiry_forget($key);
        return array();
    }
    return $record;
}

function vx_compose_admin_expiry_forget($key)
{
    if (isset($_SESSION['vx_compose_admin_expiry'][$key])) {
        unset($_SESSION['vx_compose_admin_expiry'][$key]);
    }
}

function vx_compose_admin_expiry_forget_actor_mode($actor, $mode)
{
    if (empty($_SESSION['vx_compose_admin_expiry'])
        || !is_array($_SESSION['vx_compose_admin_expiry'])) {
        return;
    }
    foreach ($_SESSION['vx_compose_admin_expiry'] as $key => $record) {
        if (is_array($record)
            && isset($record['actor'], $record['mode'])
            && $record['actor'] === $actor
            && $record['mode'] === $mode) {
            vx_compose_admin_expiry_forget($key);
        }
    }
}

function vx_compose_actor_can_access_owner($owner, $actor)
{
    return $actor === 'admin' || $owner === $actor;
}

function vx_compose_actor_has_capability($actor, $owner, $project, $capability)
{
    if (!vx_compose_owner_key_is_valid($actor)
        && $actor !== 'admin') {
        return false;
    }
    $payload = vx_compose_command_json(
        'v-check-docker-project-capability',
        array($actor, $owner, $project, $capability),
        array()
    );
    return isset($payload['AUTHORIZED']) && $payload['AUTHORIZED'] === true;
}

function vx_compose_project_action_capabilities($actor, $owner, $project)
{
    $capabilities = array();
    foreach (array(
        'lifecycle',
        'preview',
        'deploy',
        'rollback',
        'backup',
        'restore',
        'reconcile',
        'secret',
    ) as $capability) {
        $capabilities[$capability] = vx_compose_actor_has_capability(
            $actor,
            $owner,
            $project,
            $capability
        );
    }
    $capabilities['remove'] = $actor === 'admin' || $actor === $owner;
    return $capabilities;
}

function vx_compose_actor_can_manage_profile(
    $actor,
    $owner,
    $profile,
    $project = '',
    $mode = ''
)
{
    if ($profile !== 'standard') {
        return false;
    }
    if ($actor === 'admin' || $actor === $owner) {
        return true;
    }
    return $mode === 'change'
        && $project !== ''
        && vx_compose_actor_has_capability(
            $actor,
            $owner,
            $project,
            'preview'
        );
}

function vx_compose_actor_can_mutate_project($project, $actor, $owner)
{
    if (!is_array($project)
        || empty($project['OWNER'])
        || empty($project['PROFILE'])
        || (string) $project['OWNER'] !== (string) $owner) {
        return false;
    }
    if ($actor === 'admin') {
        return true;
    }
    if ($actor === $owner) {
        return (string) $project['PROFILE'] === 'standard';
    }
    return !empty($project['PROJECT'])
        && (string) $project['PROFILE'] === 'standard'
        && vx_compose_actor_has_capability(
            $actor,
            $owner,
            (string) $project['PROJECT'],
            'lifecycle'
        );
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
    $safe_payload = vx_compose_preview_payload_sanitize($payload);
    if (empty($safe_payload)) {
        return array();
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
        'preview' => $safe_payload,
    );
}

function vx_compose_array_has_exact_keys($value, $expected)
{
    if (!is_array($value)) {
        return false;
    }
    $actual = array_keys($value);
    sort($actual, SORT_STRING);
    sort($expected, SORT_STRING);
    return $actual === $expected;
}

function vx_compose_preview_value_is_source_path($value)
{
    if (!is_string($value)) {
        return false;
    }
    return preg_match(
        '#(?:^|/)(?:tmp/)?vx-compose-web\.[a-f0-9]{32}/(?:compose\.yaml|simple\.spec)$#D',
        $value
    ) === 1
        || stripos($value, 'upload-path-canary') !== false
        || stripos($value, 'source-path-sentinel') !== false;
}

function vx_compose_preview_payload_is_source_free($value, $parent_key = '')
{
    if (!is_array($value)) {
        return !vx_compose_preview_value_is_source_path($value);
    }
    foreach ($value as $key => $item) {
        if (is_string($key)
            && strcasecmp($key, 'source') === 0
            && strcasecmp((string) $parent_key, 'OCI_LABELS') !== 0) {
            return false;
        }
        if (!vx_compose_preview_payload_is_source_free($item, $key)) {
            return false;
        }
    }
    return true;
}

function vx_compose_preview_scalar_list($value)
{
    if (!is_array($value)) {
        return array();
    }
    $result = array();
    foreach ($value as $item) {
        if ((is_string($item) || is_int($item) || is_float($item))
            && !vx_compose_preview_value_is_source_path($item)) {
            $result[] = $item;
        }
    }
    return $result;
}

function vx_compose_preview_string_is_safe($value, $maximum = 1024)
{
    return is_string($value)
        && strlen($value) <= $maximum
        && preg_match('/[\x00-\x1f\x7f]/D', $value) !== 1
        && !vx_compose_preview_value_is_source_path($value);
}

function vx_compose_preview_oci_labels($value)
{
    $keys = array('source', 'revision', 'version', 'vendor', 'created');
    if (!vx_compose_array_has_exact_keys($value, $keys)) {
        return array();
    }
    $safe = array();
    foreach ($keys as $key) {
        if (!vx_compose_preview_string_is_safe($value[$key], 512)
            || preg_match(
                '/(^|[^a-z0-9])(password|passwd|secret|token|credential|'
                .'auth|authorization|authentication|'
                .'auth[._ -]?(header|key|token|secret|credential)|'
                .'bearer|private[._ -]?key|'
                .'access[._ -]?(key|token|secret|credential)|'
                .'client[._ -]?(key|token|secret|credential)|'
                .'api[._ -]?key)([^a-z0-9]|$)/i',
                $value[$key]
            ) === 1
            || preg_match(
                '#[a-z][a-z0-9+.-]*://[^/@\s]+@#i',
                $value[$key]
            ) === 1) {
            return array();
        }
        $safe[$key] = $value[$key];
    }
    return $safe;
}

function vx_compose_preview_trust_adapter($value, $expected_adapter)
{
    if (!is_array($value)
        || !in_array($expected_adapter, array('signature', 'vulnerability'), true)) {
        return array();
    }
    if (vx_compose_array_has_exact_keys($value, array('STATE'))) {
        return $value['STATE'] === 'not-run'
            ? array('STATE' => 'not-run') : array();
    }
    if (!vx_compose_array_has_exact_keys(
        $value,
        array('ADAPTER', 'STATE', 'DETAIL')
    )
        || $value['ADAPTER'] !== $expected_adapter
        || !in_array(
            $value['STATE'],
            array('pass', 'fail', 'offline', 'unavailable', 'timeout', 'error'),
            true
        )
        || !vx_compose_preview_string_is_safe($value['DETAIL'], 256)) {
        return array();
    }
    return array(
        'ADAPTER' => $value['ADAPTER'],
        'STATE' => $value['STATE'],
        'DETAIL' => $value['DETAIL'],
    );
}

function vx_compose_preview_trust($value)
{
    if (!is_array($value)
        || !isset(
            $value['MODE'],
            $value['DECISION'],
            $value['PROFILE'],
            $value['PROFILE_VERSION'],
            $value['POLICY_VERSION'],
            $value['SIGNATURE'],
            $value['VULNERABILITY'],
            $value['EXCEPTION']
        )
        || !in_array($value['MODE'], array('disabled', 'audit', 'enforce'), true)
        || !in_array(
            $value['DECISION'],
            array('disabled', 'pass', 'fail', 'exception'),
            true
        )
        || !vx_compose_preview_string_is_safe($value['PROFILE'], 64)
        || !is_int($value['PROFILE_VERSION'])
        || !is_int($value['POLICY_VERSION'])
        || !is_bool($value['EXCEPTION'])) {
        return array();
    }
    $signature = vx_compose_preview_trust_adapter(
        $value['SIGNATURE'],
        'signature'
    );
    $vulnerability = vx_compose_preview_trust_adapter(
        $value['VULNERABILITY'],
        'vulnerability'
    );
    if (empty($signature) || empty($vulnerability)) {
        return array();
    }
    $safe = array(
        'MODE' => $value['MODE'],
        'DECISION' => $value['DECISION'],
        'PROFILE' => $value['PROFILE'],
        'PROFILE_VERSION' => $value['PROFILE_VERSION'],
        'POLICY_VERSION' => $value['POLICY_VERSION'],
        'SIGNATURE' => $signature,
        'VULNERABILITY' => $vulnerability,
        'EXCEPTION' => $value['EXCEPTION'],
    );
    if ($value['MODE'] === 'disabled') {
        return vx_compose_array_has_exact_keys($value, array_keys($safe))
            ? $safe : array();
    }
    $extended = array(
        'SCHEMA',
        'VULNERABILITY_THRESHOLD',
        'CREATED',
    );
    foreach ($extended as $field) {
        if (!array_key_exists($field, $value)) {
            return array();
        }
    }
    if ($value['SCHEMA'] !== 1
        || !in_array(
            $value['VULNERABILITY_THRESHOLD'],
            array('low', 'medium', 'high', 'critical'),
            true
        )
        || !vx_compose_preview_string_is_safe($value['CREATED'], 64)) {
        return array();
    }
    $safe['SCHEMA'] = 1;
    $safe['VULNERABILITY_THRESHOLD'] = $value['VULNERABILITY_THRESHOLD'];
    $safe['CREATED'] = $value['CREATED'];
    return vx_compose_array_has_exact_keys($value, array_keys($safe))
        ? $safe : array();
}

function vx_compose_preview_image_digest_list($value)
{
    if (!is_array($value)) {
        return null;
    }
    $keys = array_keys($value);
    if ($value !== array() && $keys !== range(0, count($value) - 1)) {
        return null;
    }
    $safe = array();
    foreach ($value as $digest) {
        if (!vx_compose_preview_string_is_safe($digest, 1024)) {
            return null;
        }
        $safe[] = $digest;
    }
    return $safe;
}

function vx_compose_preview_image_identity($identity)
{
    if (!is_array($identity)) {
        return array();
    }
    $legacy_keys = array(
        'REFERENCE',
        'IMAGE_ID',
        'REPO_DIGESTS',
        'OS',
        'ARCHITECTURE',
    );
    $schema2_keys = array(
        'SCHEMA',
        'REFERENCE',
        'IMMUTABLE_REFERENCE',
        'REGISTRY_DIGEST',
        'IMAGE_ID',
        'REPO_DIGESTS',
        'OS',
        'ARCHITECTURE',
        'OCI_LABELS',
        'TRUST',
    );
    $schema2 = array_key_exists('SCHEMA', $identity);
    if ($schema2) {
        if ($identity['SCHEMA'] !== 2
            || !vx_compose_array_has_exact_keys($identity, $schema2_keys)) {
            return array();
        }
    } elseif (!vx_compose_array_has_exact_keys($identity, $legacy_keys)) {
        return array();
    }

    $safe = array();
    if ($schema2) {
        $safe['SCHEMA'] = 2;
    }
    $string_keys = $schema2
        ? array(
            'REFERENCE',
            'IMMUTABLE_REFERENCE',
            'REGISTRY_DIGEST',
            'IMAGE_ID',
            'OS',
            'ARCHITECTURE',
        )
        : array('REFERENCE', 'IMAGE_ID', 'OS', 'ARCHITECTURE');
    foreach ($string_keys as $key) {
        if (!vx_compose_preview_string_is_safe($identity[$key], 1024)) {
            return array();
        }
        $safe[$key] = $identity[$key];
    }
    $repo_digests = vx_compose_preview_image_digest_list(
        $identity['REPO_DIGESTS']
    );
    if ($repo_digests === null) {
        return array();
    }
    $safe['REPO_DIGESTS'] = $repo_digests;
    if (!$schema2) {
        return $safe;
    }
    $labels = vx_compose_preview_oci_labels($identity['OCI_LABELS']);
    $trust = vx_compose_preview_trust($identity['TRUST']);
    if (empty($labels) || empty($trust)) {
        return array();
    }
    $safe['OCI_LABELS'] = $labels;
    $safe['TRUST'] = $trust;
    return $safe;
}

function vx_compose_preview_change_set($value)
{
    $result = array();
    foreach (array('ADDED', 'REMOVED', 'CHANGED', 'UNCHANGED') as $key) {
        $result[$key] = isset($value[$key])
            ? vx_compose_preview_scalar_list($value[$key])
            : array();
    }
    return $result;
}

function vx_compose_preview_payload_sanitize($payload)
{
    if (!is_array($payload)) {
        return array();
    }
    $safe = array();
    $scalar_fields = array(
        'VALID',
        'PREVIEW_ID',
        'OWNER',
        'PROJECT',
        'PROFILE',
        'MODE',
        'SOURCE_SHA256',
        'CANDIDATE_SHA256',
        'CURRENT_REVISION',
        'EXPECTED_CURRENT_REVISION',
        'EXPIRES_AT',
        'DATA_ROLLBACK',
    );
    foreach ($scalar_fields as $field) {
        if (array_key_exists($field, $payload)
            && (is_string($payload[$field])
                || is_int($payload[$field])
                || is_float($payload[$field])
                || is_bool($payload[$field])
                || $payload[$field] === null)
            && !vx_compose_preview_value_is_source_path($payload[$field])) {
            $safe[$field] = $payload[$field];
        }
    }
    foreach (array('SERVICES', 'NETWORKS', 'VOLUMES', 'SECRETS') as $field) {
        if (isset($payload[$field]) && is_array($payload[$field])) {
            $safe[$field] = vx_compose_preview_change_set($payload[$field]);
        }
    }
    if (isset($payload['ROUTES']) && is_array($payload['ROUTES'])) {
        $safe['ROUTES'] = array();
        foreach (
            array('UNCHANGED', 'INVALIDATED', 'RETARGET_REQUIRED')
            as $key
        ) {
            $safe['ROUTES'][$key] = isset($payload['ROUTES'][$key])
                ? vx_compose_preview_scalar_list($payload['ROUTES'][$key])
                : array();
        }
    }
    foreach (array('RECREATE_SERVICES', 'REMOVE_SERVICES', 'WARNINGS') as $field) {
        if (isset($payload[$field])) {
            $safe[$field] = vx_compose_preview_scalar_list($payload[$field]);
        }
    }
    if (isset($payload['RESOURCES']) && is_array($payload['RESOURCES'])) {
        $safe['RESOURCES'] = array();
        foreach (array('CURRENT', 'CANDIDATE', 'DELTA') as $scope) {
            $safe['RESOURCES'][$scope] = array();
            $resource = isset($payload['RESOURCES'][$scope])
                && is_array($payload['RESOURCES'][$scope])
                ? $payload['RESOURCES'][$scope]
                : array();
            foreach (
                array('CPUS_MILLI', 'MEMORY_MB', 'PIDS', 'STORAGE_MB')
                as $key
            ) {
                if (isset($resource[$key]) && is_numeric($resource[$key])) {
                    $safe['RESOURCES'][$scope][$key] = $resource[$key] + 0;
                }
            }
        }
    }
    if (isset($payload['IMAGES']) && is_array($payload['IMAGES'])) {
        $safe['IMAGES'] = array(
            'CURRENT_REFERENCES' => vx_compose_preview_scalar_list(
                isset($payload['IMAGES']['CURRENT_REFERENCES'])
                    ? $payload['IMAGES']['CURRENT_REFERENCES'] : array()
            ),
            'CANDIDATE_REFERENCES' => vx_compose_preview_scalar_list(
                isset($payload['IMAGES']['CANDIDATE_REFERENCES'])
                    ? $payload['IMAGES']['CANDIDATE_REFERENCES'] : array()
            ),
            'CURRENT_IDENTITIES' => array(),
        );
        $identities = isset($payload['IMAGES']['CURRENT_IDENTITIES'])
            && is_array($payload['IMAGES']['CURRENT_IDENTITIES'])
            ? $payload['IMAGES']['CURRENT_IDENTITIES'] : array();
        foreach ($identities as $reference => $identity) {
            if (is_string($reference)
                && is_array($identity)
                && strcasecmp($reference, 'source') !== 0
                && !vx_compose_preview_value_is_source_path($reference)) {
                $safe_identity = vx_compose_preview_image_identity($identity);
                if (empty($safe_identity)) {
                    return array();
                }
                $safe['IMAGES']['CURRENT_IDENTITIES'][$reference] =
                    $safe_identity;
            }
        }
    }
    if (isset($payload['PORTS']) && is_array($payload['PORTS'])) {
        $safe['PORTS'] = array();
        foreach ($payload['PORTS'] as $port) {
            if (!is_array($port)) {
                continue;
            }
            $item = array();
            foreach (array('SERVICE', 'BEFORE', 'AFTER') as $key) {
                if (isset($port[$key])
                    && (is_string($port[$key]) || is_numeric($port[$key]))
                    && !vx_compose_preview_value_is_source_path($port[$key])) {
                    $item[$key] = $port[$key];
                }
            }
            if (!empty($item)) {
                $safe['PORTS'][] = $item;
            }
        }
    }
    return vx_compose_preview_payload_is_source_free($safe) ? $safe : array();
}

function vx_compose_preview_payload_normalize($value)
{
    if (!is_array($value)) {
        return $value;
    }
    $keys = array_keys($value);
    $is_list = $value === array()
        || $keys === range(0, count($value) - 1);
    $normalized = array();
    foreach ($value as $key => $item) {
        $normalized[$key] = vx_compose_preview_payload_normalize($item);
    }
    if (!$is_list) {
        ksort($normalized, SORT_STRING);
    }
    return $normalized;
}

function vx_compose_preview_payload_matches_contract($payload)
{
    if (!is_array($payload)
        || !vx_compose_preview_payload_is_source_free($payload)) {
        return false;
    }
    $sanitized = vx_compose_preview_payload_sanitize($payload);
    return !empty($sanitized)
        && vx_compose_preview_payload_normalize($payload)
            === vx_compose_preview_payload_normalize($sanitized);
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

function vx_compose_normalize_published_endpoints($service_summary)
{
    if (!is_array($service_summary)) {
        return array();
    }

    $endpoints = array();
    ksort($service_summary, SORT_STRING);
    foreach ($service_summary as $service => $summary) {
        if (!is_string($service)
            || preg_match('/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/', $service) !== 1
            || !is_array($summary)
            || !isset($summary['PORTS'])
            || !is_array($summary['PORTS'])) {
            continue;
        }
        foreach ($summary['PORTS'] as $mapping) {
            if (!is_string($mapping)
                || preg_match(
                    '/^(?:'
                    .'(\[(?:[0-9A-Fa-f:]+)\])'
                    .'|'
                    .'((?:[0-9]{1,3}\.){3}[0-9]{1,3})'
                    .'):([0-9]+(?:-[0-9]+)?):'
                    .'([0-9]+(?:-[0-9]+)?)\/(tcp|udp)$/',
                    $mapping,
                    $matches
                ) !== 1) {
                continue;
            }

            $host_ip = $matches[1] !== ''
                ? substr($matches[1], 1, -1)
                : $matches[2];
            if (filter_var($host_ip, FILTER_VALIDATE_IP) === false) {
                continue;
            }
            $host_port = $matches[3];
            $container_port = $matches[4];
            $valid = true;
            foreach (array($host_port, $container_port) as $port_range) {
                $bounds = array_map('intval', explode('-', $port_range));
                if ($bounds[0] < 1 || $bounds[0] > 65535
                    || (count($bounds) === 2
                        && ($bounds[1] < $bounds[0]
                            || $bounds[1] > 65535))) {
                    $valid = false;
                }
            }
            $host_bounds = explode('-', $host_port);
            $container_bounds = explode('-', $container_port);
            if (count($host_bounds) !== count($container_bounds)
                || (count($host_bounds) === 2
                    && ((int) $host_bounds[1] - (int) $host_bounds[0])
                        !== ((int) $container_bounds[1]
                            - (int) $container_bounds[0]))) {
                $valid = false;
            }
            if (!$valid) {
                continue;
            }

            $display_ip = strpos($host_ip, ':') !== false
                ? '['.$host_ip.']'
                : $host_ip;
            $endpoints[] = array(
                'SERVICE' => $service,
                'HOST_IP' => $host_ip,
                'HOST_PORT' => $host_port,
                'CONTAINER_PORT' => $container_port,
                'PROTOCOL' => $matches[5],
                'DISPLAY' => $display_ip.':'.$host_port
                    .' → '.$container_port.'/'.$matches[5],
            );
        }
    }
    return $endpoints;
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
    $health_observation = isset($project['HEALTH_OBSERVATION'])
        && is_array($project['HEALTH_OBSERVATION'])
        ? $project['HEALTH_OBSERVATION']
        : array();
    $published_endpoints = vx_compose_normalize_published_endpoints(
        isset($project['SERVICE_SUMMARY'])
            ? $project['SERVICE_SUMMARY']
            : array()
    );
    $managed_route_targets = array();
    foreach ($routes as $route) {
        if (!is_array($route)
            || empty($route['HOST_PORT'])
            || !preg_match('/^[0-9]+$/', (string) $route['HOST_PORT'])) {
            continue;
        }
        $scheme = isset($route['SCHEME'])
            && in_array($route['SCHEME'], array('http', 'https'), true)
            ? $route['SCHEME']
            : 'http';
        $managed_route_targets[] = $scheme
            .'://127.0.0.1:'.(string) $route['HOST_PORT'];
    }
    $managed_route_targets = array_values(array_unique($managed_route_targets));

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
        'LAST_HEALTH_AT' => isset($health_observation['OBSERVED_AT'])
            ? (string) $health_observation['OBSERVED_AT']
            : '',
        'HEALTH_FRESHNESS' => isset($health_observation['FRESHNESS'])
            ? (string) $health_observation['FRESHNESS']
            : 'unavailable',
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
        'PUBLISHED_ENDPOINTS' => $published_endpoints,
        'PROJECT_ROUTES' => $routes,
        'PROJECT_ROUTE_COUNT' => count($routes),
        'MANAGED_ROUTE_TARGETS' => $managed_route_targets,
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
    $fields = array(
        'DOCKER_PROJECTS' => array('label' => 'Projects', 'unit' => 'count'),
        'DOCKER_SERVICES' => array('label' => 'Services', 'unit' => 'count'),
        'DOCKER_CPUS' => array('label' => 'CPUs', 'unit' => 'cores'),
        'DOCKER_MEMORY_MB' => array('label' => 'Memory', 'unit' => 'MiB'),
        'DOCKER_PIDS' => array('label' => 'PIDs', 'unit' => 'count'),
        'DOCKER_STORAGE_MB' => array('label' => 'Storage', 'unit' => 'MiB'),
        'DOCKER_PORTS' => array('label' => 'Ports', 'unit' => 'count'),
        'DOCKER_SECRETS' => array('label' => 'Secrets', 'unit' => 'count'),
        'DOCKER_VOLUMES' => array('label' => 'Volumes', 'unit' => 'count'),
    );
    $dimensions = array();
    foreach ($fields as $field => $metadata) {
        $limit_value = isset($user_panel[$field])
            ? trim((string) $user_panel[$field])
            : '0';
        $used_field = 'U_'.$field;
        $used_value = isset($user_panel[$used_field])
            ? trim((string) $user_panel[$used_field])
            : ($field === 'DOCKER_CPUS' ? '0.000' : '0');
        $dimensions[$field] = array(
            'label' => $metadata['label'],
            'unit' => $metadata['unit'],
            'limit' => $limit_value,
            'used' => $used_value,
            'reached' => (
                strtolower($limit_value) !== 'unlimited'
                && (float) $used_value >= (float) $limit_value
            ),
        );
    }
    $limit_raw = $dimensions['DOCKER_PROJECTS']['limit'];
    $used = (int) $dimensions['DOCKER_PROJECTS']['used'];
    $limit = null;
    if ($limit_raw !== '' && strtolower($limit_raw) !== 'unlimited') {
        $limit = (int) $limit_raw;
    }
    return array(
        'limit' => $limit,
        'used' => $used,
        'reached' => ($limit !== null && $used >= $limit),
        'dimensions' => $dimensions,
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
    if (!vx_compose_actor_can_access_owner($owner, $actor)
        && !vx_compose_actor_has_capability(
            $actor,
            $owner,
            $project,
            'view'
        )) {
        return array();
    }
    return vx_compose_get_project($owner, $project);
}

function vx_compose_resolve_mutable_project($owner, $project, $actor)
{
    return vx_compose_resolve_capable_project(
        $owner,
        $project,
        $actor,
        'lifecycle'
    );
}

function vx_compose_resolve_capable_project(
    $owner,
    $project,
    $actor,
    $capability
) {
    $resolved = vx_compose_resolve_accessible_project(
        $owner,
        $project,
        $actor
    );
    if (empty($resolved)
        || !vx_compose_actor_has_capability(
            $actor,
            $owner,
            $project,
            $capability
        )) {
        return array();
    }
    return $resolved;
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
            'OBSERVED_AT' => gmdate('Y-m-d\TH:i:s\Z'),
            'SOURCE' => 'command-unavailable',
            'AGE_SECONDS' => 0,
            'FRESHNESS' => 'unavailable',
            'SERVICES' => array(),
        )
    );
    $payload['HEALTH_STATUS'] = isset($payload['STATUS'])
        ? $payload['STATUS']
        : 'unknown';
    $payload['LAST_HEALTH_AT'] = isset($payload['OBSERVED_AT'])
        ? $payload['OBSERVED_AT']
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

function vx_compose_ingress_consumers_payload($owner, $project, $actor)
{
    if (!vx_compose_owner_key_is_valid($owner)
        || !vx_compose_project_key_is_valid($project)
        || ($actor !== 'admin' && !vx_compose_owner_key_is_valid($actor))) {
        return array('COUNT' => 0);
    }
    return vx_compose_command_json(
        'v-list-docker-project-ingress-consumers',
        array($owner, $project, 'json', $actor),
        array('COUNT' => 0)
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

function vx_compose_view_scalar($value, $fallback = '—')
{
    if (is_bool($value)) {
        $value = $value ? 'Yes' : 'No';
    } elseif ($value === null || is_array($value) || is_object($value)) {
        $value = $fallback;
    } elseif (!is_scalar($value) || trim((string) $value) === '') {
        $value = $fallback;
    }
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function vx_compose_view_list($value)
{
    if (!is_array($value)) {
        return array();
    }
    $items = array();
    foreach ($value as $item) {
        if (is_scalar($item) && trim((string) $item) !== '') {
            $items[] = vx_compose_view_scalar($item);
        }
    }
    return $items;
}

function vx_compose_view_records($value)
{
    if (!is_array($value)) {
        return array();
    }
    $records = array();
    foreach ($value as $key => $record) {
        if (is_array($record)) {
            $records[] = array($key, $record);
        }
    }
    return $records;
}

function vx_compose_view_services($project)
{
    $summary = isset($project['SERVICE_SUMMARY'])
        && is_array($project['SERVICE_SUMMARY'])
        ? $project['SERVICE_SUMMARY']
        : array();
    $rows = array();
    foreach ($summary as $service => $record) {
        if (!is_array($record)) {
            continue;
        }
        $rows[] = array(
            'service' => vx_compose_view_scalar($service),
            'image' => vx_compose_view_scalar(
                isset($record['IMAGE']) ? $record['IMAGE'] : null
            ),
            'ports' => vx_compose_view_list(
                isset($record['PORTS']) ? $record['PORTS'] : array()
            ),
            'healthcheck' => vx_compose_view_scalar(
                isset($record['HAS_HEALTHCHECK'])
                    ? $record['HAS_HEALTHCHECK'] : false
            ),
        );
    }
    return $rows;
}

function vx_compose_view_endpoints($project)
{
    $endpoints = isset($project['PUBLISHED_ENDPOINTS'])
        && is_array($project['PUBLISHED_ENDPOINTS'])
        ? $project['PUBLISHED_ENDPOINTS']
        : array();
    $rows = array();
    foreach ($endpoints as $record) {
        if (!is_array($record)) {
            continue;
        }
        $rows[] = array(
            'service' => vx_compose_view_scalar(
                isset($record['SERVICE']) ? $record['SERVICE'] : null
            ),
            'published' => vx_compose_view_scalar(
                isset($record['DISPLAY']) ? $record['DISPLAY'] : null
            ),
            'protocol' => vx_compose_view_scalar(
                isset($record['PROTOCOL']) ? $record['PROTOCOL'] : null
            ),
        );
    }
    return $rows;
}

function vx_compose_view_routes($payload)
{
    if (isset($payload['ROUTES']) && is_array($payload['ROUTES'])) {
        $payload = $payload['ROUTES'];
    }
    $rows = array();
    foreach (vx_compose_view_records($payload) as $item) {
        list($key, $record) = $item;
        $scheme = isset($record['SCHEME']) && is_scalar($record['SCHEME'])
            ? (string) $record['SCHEME'].'://' : '';
        $target = '';
        if (isset($record['HOST']) && is_scalar($record['HOST'])) {
            $target = (string) $record['HOST'];
        } elseif (isset($record['HOST_PORT'])
            && is_scalar($record['HOST_PORT'])) {
            $target = '127.0.0.1:'.(string) $record['HOST_PORT'];
        }
        $rows[] = array(
            'domain' => vx_compose_view_scalar(
                isset($record['DOMAIN']) ? $record['DOMAIN'] : $key
            ),
            'service' => vx_compose_view_scalar(
                isset($record['SERVICE']) ? $record['SERVICE'] : null
            ),
            'target' => vx_compose_view_scalar($scheme.$target),
            'path' => vx_compose_view_scalar(
                isset($record['PATH']) ? $record['PATH'] : '/'
            ),
        );
    }
    return $rows;
}

function vx_compose_view_ingress($payload)
{
    $rows = array();
    $consumers = isset($payload['CONSUMERS'])
        && is_array($payload['CONSUMERS'])
        ? $payload['CONSUMERS']
        : (!isset($payload['COUNT']) && is_array($payload)
            ? $payload : array());
    foreach (vx_compose_view_records($consumers) as $item) {
        list($key, $record) = $item;
        $headers = array();
        if (isset($record['HEADER_NAMES'])
            && is_array($record['HEADER_NAMES'])) {
            foreach ($record['HEADER_NAMES'] as $header) {
                if (is_scalar($header) && trim((string) $header) !== '') {
                    $headers[] = (string) $header;
                }
            }
        }
        $rows[] = array(
            'consumer' => vx_compose_view_scalar(
                isset($record['CONSUMER'])
                    ? $record['CONSUMER']
                    : (isset($record['OWNER']) ? $record['OWNER'] : $key)
            ),
            'domain' => vx_compose_view_scalar(
                isset($record['DOMAIN']) ? $record['DOMAIN'] : null
            ),
            'headers' => vx_compose_view_scalar(
                !empty($headers) ? implode(', ', $headers) : null
            ),
            'target' => vx_compose_view_scalar(
                isset($record['TARGET']) ? $record['TARGET'] : null
            ),
            'health' => vx_compose_view_scalar(
                isset($record['HEALTH']) ? $record['HEALTH'] : null
            ),
        );
    }
    return array(
        'count' => vx_compose_view_scalar(
            isset($payload['COUNT']) ? $payload['COUNT'] : count($rows),
            '0'
        ),
        'rows' => $rows,
    );
}

function vx_compose_view_health($payload)
{
    $services = isset($payload['SERVICES']) && is_array($payload['SERVICES'])
        ? $payload['SERVICES']
        : array();
    $rows = array();
    foreach (vx_compose_view_records($services) as $item) {
        list($key, $record) = $item;
        $rows[] = array(
            'service' => vx_compose_view_scalar(
                isset($record['SERVICE']) ? $record['SERVICE'] : $key
            ),
            'status' => vx_compose_view_scalar(
                isset($record['STATUS']) ? $record['STATUS'] : null
            ),
            'restarts' => vx_compose_view_scalar(
                isset($record['RESTART_COUNT'])
                    ? $record['RESTART_COUNT'] : 0,
                '0'
            ),
        );
    }
    return array(
        'status' => vx_compose_view_scalar(
            isset($payload['STATUS']) ? $payload['STATUS'] : 'unknown'
        ),
        'observed' => vx_compose_view_scalar(
            isset($payload['OBSERVED_AT']) ? $payload['OBSERVED_AT'] : null
        ),
        'freshness' => vx_compose_view_scalar(
            isset($payload['FRESHNESS']) ? $payload['FRESHNESS'] : 'unavailable'
        ),
        'source' => vx_compose_view_scalar(
            isset($payload['SOURCE']) ? $payload['SOURCE'] : null
        ),
        'services' => $rows,
    );
}

function vx_compose_view_resources($project, $stats)
{
    $resources = isset($project['RESOURCES']) && is_array($project['RESOURCES'])
        ? $project['RESOURCES']
        : array();
    $latest = isset($stats['LATEST']) && is_array($stats['LATEST'])
        ? $stats['LATEST']
        : array();
    return array(
        'cpu_limit' => vx_compose_view_scalar(
            isset($resources['CPUS_MILLI'])
                && is_scalar($resources['CPUS_MILLI'])
                ? (string) $resources['CPUS_MILLI'].' millicores' : null
        ),
        'memory_limit' => vx_compose_view_scalar(
            isset($resources['MEMORY_MB'])
                && is_scalar($resources['MEMORY_MB'])
                ? (string) $resources['MEMORY_MB'].' MiB' : null
        ),
        'storage_limit' => vx_compose_view_scalar(
            isset($resources['STORAGE_MB'])
                && is_scalar($resources['STORAGE_MB'])
                ? (string) $resources['STORAGE_MB'].' MiB' : null
        ),
        'pids_limit' => vx_compose_view_scalar(
            isset($resources['PIDS']) ? $resources['PIDS'] : null
        ),
        'cpu_now' => vx_compose_view_scalar(
            isset($latest['CPU_PERCENT']) && is_scalar($latest['CPU_PERCENT'])
                ? (string) $latest['CPU_PERCENT'].'%' : null
        ),
        'memory_now' => vx_compose_view_scalar(
            isset($latest['MEMORY_MB']) && is_scalar($latest['MEMORY_MB'])
                ? (string) $latest['MEMORY_MB'].' MiB' : null
        ),
    );
}

function vx_compose_view_revisions($revisions, $current)
{
    $rows = array();
    foreach ((array) $revisions as $revision) {
        if (!is_numeric($revision)) {
            continue;
        }
        $rows[] = array(
            'revision' => vx_compose_view_scalar((int) $revision),
            'current' => ((int) $revision === (int) $current),
        );
    }
    return $rows;
}

function vx_compose_view_backups($payload)
{
    $rows = array();
    foreach (vx_compose_view_records($payload) as $item) {
        list(, $record) = $item;
        $rows[] = array(
            'archive' => vx_compose_view_scalar(
                isset($record['ARCHIVE']) ? $record['ARCHIVE'] : null
            ),
            'created' => vx_compose_view_scalar(
                isset($record['CREATED']) ? $record['CREATED'] : null
            ),
            'bytes' => vx_compose_view_scalar(
                isset($record['BYTES']) ? $record['BYTES'] : null
            ),
        );
    }
    return $rows;
}

function vx_compose_view_alerts($payload)
{
    $alerts = isset($payload['ALERTS']) && is_array($payload['ALERTS'])
        ? $payload['ALERTS']
        : array();
    $rows = array();
    foreach (vx_compose_view_records($alerts) as $item) {
        list(, $record) = $item;
        $rows[] = array(
            'type' => vx_compose_view_scalar(
                isset($record['TYPE']) ? $record['TYPE'] : null
            ),
            'status' => vx_compose_view_scalar(
                isset($record['STATUS']) ? $record['STATUS'] : null
            ),
            'message' => vx_compose_view_scalar(
                isset($record['VALUE']) ? $record['VALUE'] : null
            ),
            'opened' => vx_compose_view_scalar(
                isset($record['OPENED']) ? $record['OPENED'] : null
            ),
            'acknowledged' => vx_compose_view_scalar(
                isset($record['ACK']) ? $record['ACK'] : false
            ),
        );
    }
    return $rows;
}

function vx_compose_view_operations($events)
{
    $rows = array();
    foreach (vx_compose_view_records($events) as $item) {
        list(, $record) = $item;
        $rows[] = array(
            'action' => vx_compose_view_scalar(
                isset($record['ACTION']) ? $record['ACTION'] : null
            ),
            'result' => vx_compose_view_scalar(
                isset($record['RESULT']) ? $record['RESULT'] : null
            ),
            'timestamp' => vx_compose_view_scalar(
                isset($record['UPDATED'])
                    ? $record['UPDATED']
                    : (isset($record['TIMESTAMP'])
                        ? $record['TIMESTAMP'] : null)
            ),
            'duration' => vx_compose_view_scalar(
                isset($record['PERCENT'])
                    && is_scalar($record['PERCENT'])
                    ? (string) $record['PERCENT'].'%'
                    : (isset($record['DURATION_MS'])
                    && is_scalar($record['DURATION_MS'])
                    ? (string) $record['DURATION_MS'].' ms' : null)
            ),
        );
    }
    return array_slice(array_reverse($rows), 0, 8);
}

function vx_compose_view_events($events)
{
    $rows = array();
    foreach (vx_compose_view_records($events) as $item) {
        list(, $record) = $item;
        $action = isset($record['ACTION']) && is_scalar($record['ACTION'])
            ? (string) $record['ACTION'] : '';
        $result = isset($record['RESULT']) && is_scalar($record['RESULT'])
            ? (string) $record['RESULT'] : '';
        $rows[] = array(
            'timestamp' => vx_compose_view_scalar(
                isset($record['TIMESTAMP']) ? $record['TIMESTAMP'] : null
            ),
            'actor' => vx_compose_view_scalar(
                isset($record['ACTOR']) ? $record['ACTOR'] : null
            ),
            'event' => vx_compose_view_scalar(
                trim($action.' '.$result)
            ),
            'details' => vx_compose_view_scalar(
                isset($record['DETAILS']) ? $record['DETAILS'] : null
            ),
        );
    }
    return array_slice(array_reverse($rows), 0, 20);
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
