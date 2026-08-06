<?php

if (isset($argv[1]) && $argv[1] === 'mutation-readiness') {
    $action = isset($argv[2]) ? $argv[2] : '';
    $allowed_actions = array(
        'acknowledge_alert',
        'backup',
        'deploy',
        'recreate',
        'remove',
        'restore',
        'rollback',
    );
    if (!in_array($action, $allowed_actions, true)) {
        exit(2);
    }
    $document_root = sys_get_temp_dir().'/vx-compose-mutation-'
        .bin2hex(random_bytes(8));
    mkdir($document_root.'/ajax', 0700, true);
    mkdir($document_root.'/inc', 0700, true);
    file_put_contents(
        $document_root.'/ajax/include_authentication_check.php',
        "<?php\n\$myvesta_logged_user = 'alice';\n"
    );
    file_put_contents(
        $document_root.'/inc/vx_docker.php',
        "<?php\n"
        ."function vx_docker_is_orchestration_ready() { return false; }\n"
        ."function __(\$message) { return \$message; }\n"
    );
    file_put_contents($document_root.'/inc/vx_compose.php', "<?php\n");
    $_SERVER['DOCUMENT_ROOT'] = $document_root;
    $_POST = array(
        'token' => 'valid',
        'owner' => 'alice',
        'name' => 'app',
        'aid' => 'alert-1',
        'dataset' => array(
            'owner' => 'alice',
            'container_name' => 'app',
        ),
    );
    ob_start();
    register_shutdown_function(function () use ($document_root) {
        $output = '';
        while (ob_get_level() > 0) {
            $output = ob_get_clean().$output;
        }
        echo json_encode(array('output' => $output))."\n";
        @unlink($document_root.'/ajax/include_authentication_check.php');
        @unlink($document_root.'/inc/vx_docker.php');
        @unlink($document_root.'/inc/vx_compose.php');
        @rmdir($document_root.'/ajax');
        @rmdir($document_root.'/inc');
        @rmdir($document_root);
    });
    require dirname(__DIR__).'/web/ajax/docker/actions/'.$action.'.php';
}

if (isset($argv[1]) && $argv[1] === 'controller') {
    $controller_kind = isset($argv[2]) ? $argv[2] : '';
    $controller_case = isset($argv[3]) ? $argv[3] : '';
    $controller_root = sys_get_temp_dir().'/vx-compose-controller-'
        .bin2hex(random_bytes(8));
    mkdir($controller_root.'/inc', 0700, true);
    file_put_contents($controller_root.'/inc/main.php', "<?php\n");
    file_put_contents($controller_root.'/inc/vx_docker.php', "<?php\n");
    file_put_contents($controller_root.'/inc/vx_compose.php', "<?php\n");

    define('VX_COMPOSE_CONTROLLER_TEST', true);
    define('VESTA_CMD', '/usr/local/vesta/bin/');
    require_once dirname(__DIR__).'/web/inc/vx_compose.php';

    function __($message)
    {
        return $message;
    }
    function render_page($user, $tab, $template)
    {
        extract($GLOBALS, EXTR_SKIP);
        $shared = $template === 'add_docker_project'
            ? 'docker_project_add_shared.php'
            : 'docker_project_edit_shared.php';
        include dirname(__DIR__).'/web/templates/'.$shared;
    }
    function vx_docker_list_users()
    {
        return array('alice' => array('USER' => 'alice'));
    }
    function vx_docker_resolve_owner_from_request($default = '')
    {
        return isset($_REQUEST['user']) && !is_array($_REQUEST['user'])
            ? (string) $_REQUEST['user'] : $default;
    }
    function vx_docker_user_exists($owner, $users = null)
    {
        return $owner === 'alice';
    }
    function vx_docker_get_engine_state()
    {
        return array(
            'DOCKER_ORCHESTRATION_READY' =>
                strpos($GLOBALS['controller_case'], 'not_ready') === 0
                    ? 'no' : 'yes',
        );
    }
    function vx_docker_is_orchestration_ready($docker_state = null)
    {
        return is_array($docker_state)
            && isset($docker_state['DOCKER_ORCHESTRATION_READY'])
            && $docker_state['DOCKER_ORCHESTRATION_READY'] === 'yes';
    }
    function vx_compose_test_project()
    {
        return array(
            'OWNER' => 'alice',
            'PROJECT' => 'app',
            'COMPOSE_PROJECT' => 'vx-alice-app',
            'STATE' => 'running',
            'PROFILE' => 'standard',
            'REVISION' => 2,
            'SERVICES' => array('web'),
            'IMAGES' => array('nginx:stable-alpine'),
        );
    }
    function vx_compose_test_payload($mode)
    {
        return array(
            'VALID' => true,
            'PREVIEW_ID' => str_repeat('c', 32),
            'OWNER' => 'alice',
            'PROJECT' => 'app',
            'PROFILE' => 'standard',
            'MODE' => $mode,
            'SOURCE_SHA256' => str_repeat('a', 64),
            'CANDIDATE_SHA256' => str_repeat('b', 64),
            'EXPECTED_CURRENT_REVISION' => $mode === 'add' ? 0 : 2,
            'EXPIRES_AT' => gmdate('Y-m-d\TH:i:s\Z', time() + 900),
            'SERVICES' => array(
                'ADDED' => array('web'),
                'REMOVED' => array(),
                'CHANGED' => array(),
                'UNCHANGED' => array(),
            ),
            'ROUTES' => array(
                'UNCHANGED' => array(),
                'INVALIDATED' => array(),
                'RETARGET_REQUIRED' => array(),
            ),
        );
    }
    function vx_compose_test_command_json($command, $arguments, $default)
    {
        $GLOBALS['controller_commands'][] = array($command, $arguments);
        if ($command === 'v-list-docker-project') {
            return $GLOBALS['controller_kind'] === 'edit'
                ? vx_compose_test_project() : array();
        }
        if ($command === 'v-list-docker-project-definition') {
            return array(
                'OWNER' => 'alice',
                'PROJECT' => 'app',
                'PROFILE' => 'standard',
                'REVISION' => 2,
                'SOURCE_SHA256' => str_repeat('a', 64),
                'DEFINITION' => "services:\n  web:\n    image: nginx\n",
            );
        }
        if ($command === 'v-stage-docker-project-preview') {
            $payload = vx_compose_test_payload($arguments[5]);
            if ($GLOBALS['controller_case'] === 'unsafe_stage') {
                $payload['SOURCE'] = '/tmp/secret-upload';
                $payload['DIAGNOSTICS'] = array(
                    'secret' => 'secret-canary-value',
                    'upload' => '/tmp/vx-compose-web.'
                        .str_repeat('d', 32).'/compose.yaml',
                    'nested' => array(
                        'candidate' => '/tmp/vx-compose-web.'
                            .str_repeat('e', 32).'/simple.spec',
                    ),
                );
            }
            return $payload;
        }
        return $default;
    }
    function vx_compose_test_spawn_command($command)
    {
        $GLOBALS['controller_spawns'][] = $command;
        return 'spawn-hash';
    }

    $user = $controller_case === 'admin_expiry_altered'
        ? 'admin' : 'alice';
    $_SESSION = array('token' => 'csrf-good');
    $_GET = array();
    $_POST = array();
    $_REQUEST = array();
    $_SERVER['DOCUMENT_ROOT'] = $controller_root;
    $_SERVER['REQUEST_METHOD'] = 'POST';
    $GLOBALS['controller_kind'] = $controller_kind;
    $GLOBALS['controller_case'] = $controller_case;
    $GLOBALS['controller_commands'] = array();
    $GLOBALS['controller_spawns'] = array();

    if ($controller_kind === 'edit') {
        $_GET['project'] = 'app';
    }
    if (in_array($controller_case, array(
        'stage',
        'unsafe_stage',
        'not_ready_stage',
    ), true)) {
        $_POST = array(
            'token' => 'csrf-good',
            'validate_preview' => '1',
            'project' => 'app',
            'profile' => 'standard',
            'definition' => "services:\n  web:\n    image: nginx\n",
        );
    } elseif (in_array($controller_case, array(
        'apply',
        'altered_digest',
        'stale_preview',
        'unknown_preview',
        'forgotten_preview',
        'admin_expiry_altered',
        'not_ready_apply',
    ), true)) {
        $payload = vx_compose_test_payload(
            $controller_kind === 'add' ? 'add' : 'change'
        );
        $definition = "services:\n  web:\n    image: nginx\n";
        if ($controller_case === 'admin_expiry_altered') {
            $payload['PROFILE'] = 'admin-approved';
            $payload['SOURCE_SHA256'] = hash('sha256', $definition);
            $_GET['user'] = 'alice';
        }
        $record = vx_compose_preview_record($payload, 'alice');
        if ($controller_case === 'admin_expiry_altered') {
            $record['actor'] = 'admin';
        }
        $key = $controller_case === 'unknown_preview'
            ? str_repeat('f', 32)
            : vx_compose_preview_store($record);
        $admin_expires = gmdate('Y-m-d\TH:i:s\Z', time() + 86400);
        if ($controller_case === 'admin_expiry_altered') {
            vx_compose_admin_expiry_store($key, array(
                'actor' => 'admin',
                'owner' => 'alice',
                'project' => 'app',
                'profile' => 'admin-approved',
                'mode' => 'add',
                'admin_expires' => $admin_expires,
            ));
        }
        if ($controller_case === 'stale_preview') {
            $_SESSION['vx_compose_previews'][$key]['expires_at'] = gmdate(
                'Y-m-d\TH:i:s\Z',
                time() - 1
            );
        } elseif ($controller_case === 'forgotten_preview') {
            vx_compose_preview_forget($key);
        }
        $_POST = array(
            'token' => 'csrf-good',
            ($controller_kind === 'add'
                ? 'confirm_deploy' : 'confirm_update') => '1',
            'preview_token' => $key,
            'owner' => 'alice',
            'project' => 'app',
            'profile' => $record['profile'],
            'preview_id' => $record['preview_id'],
            'source_sha' => $record['source_sha'],
            'candidate_sha' => $controller_case === 'altered_digest'
                ? str_repeat('d', 64) : $record['candidate_sha'],
            'expected_revision' => (string) $record['expected_revision'],
        );
        if ($controller_case === 'admin_expiry_altered') {
            $_POST['definition'] = $definition;
            $_POST['expires'] = gmdate(
                'Y-m-d\TH:i:s\Z',
                time() + 172800
            );
        }
    } elseif ($controller_case === 'cross_owner') {
        $_GET['user'] = 'bob';
        $_POST = array(
            'token' => 'csrf-good',
            'validate_preview' => '1',
            'project' => 'app',
            'profile' => 'standard',
            'definition' => "services: {}\n",
        );
    } elseif ($controller_case === 'stale_csrf') {
        $_POST = array(
            'token' => 'csrf-stale',
            'validate_preview' => '1',
            'project' => 'app',
            'profile' => 'standard',
            'definition' => "services: {}\n",
        );
    } else {
        $_POST = array(
            'token' => 'csrf-good',
            'validate_preview' => '1',
            'project' => 'app',
            'profile' => $controller_case,
            'definition' => "services: {}\n",
        );
    }
    $_REQUEST = array_merge($_GET, $_POST);

    register_shutdown_function(function () use ($controller_root) {
        $html = '';
        while (ob_get_level() > 0) {
            $html = ob_get_clean().$html;
        }
        echo json_encode(array(
            'commands' => $GLOBALS['controller_commands'],
            'spawns' => $GLOBALS['controller_spawns'],
            'error' => isset($_SESSION['error_msg'])
                ? $_SESSION['error_msg'] : '',
            'html' => $html,
            'session' => $_SESSION,
        ))."\n";
        @unlink($controller_root.'/inc/main.php');
        @unlink($controller_root.'/inc/vx_docker.php');
        @unlink($controller_root.'/inc/vx_compose.php');
        @rmdir($controller_root.'/inc');
        @rmdir($controller_root);
    });
    $controller = dirname(__DIR__).'/web/'.$controller_kind
        .'/docker/project/index.php';
    require $controller;
    exit;
}

define('VESTA_CMD', '/usr/local/vesta/bin/');
require_once dirname(__DIR__).'/web/inc/vx_compose.php';

$project = array(
    'OWNER' => 'alice',
    'PROJECT' => 'app',
    'COMPOSE_PROJECT' => 'vx-alice-app',
    'STATE' => 'running',
    'PROFILE' => 'standard',
    'REVISION' => 2,
    'HEALTH' => 'healthy',
    'SERVICES' => array('web'),
    'IMAGES' => array('example.test/web:v2', 'busybox:1.36.1'),
    'ROUTES' => array(
        'app.example.test' => array(
            'DOMAIN' => 'app.example.test',
            'HOST_PORT' => 18080,
            'CONTAINER_PORT' => 8080,
            'PATH' => '/',
        ),
    ),
    'UPDATED' => '2026-07-25T00:00:00Z',
    'DRIFT' => array(
        'MATCH' => true,
        'DRIFT_DIGEST' => str_repeat('d', 64),
    ),
    'LAST_OPERATION' => array(
        'OPERATION_ID' => str_repeat('e', 32),
        'ACTION' => 'reconcile',
        'RESULT' => 'succeeded',
    ),
    'SIMPLE' => array(
        'GENERATED' => true,
        'COMMAND' => 'nginx -g daemon off;',
        'ENV' => 'APP_ENV=testing',
        'MOUNTS' => 'data:/usr/share/nginx/html',
        'IMAGE' => 'example.test/web:v2',
        'HOST_PORT' => '18080',
        'CONTAINER_PORT' => '8080',
        'DOMAIN' => 'app.example.test',
        'ROUTE_PATH' => '/',
        'AUTO_START' => 'yes',
        'RESTART_POLICY' => 'unless-stopped',
        'HEALTHCHECK_TYPE' => 'http',
        'HEALTHCHECK_TARGET' => '/health',
        'HEALTHCHECK_INTERVAL' => '30',
    ),
);

$normalized = vx_compose_normalize_project($project);
if ($normalized['NAME'] !== 'app'
    || $normalized['CTN_NAME'] !== 'vx-alice-app'
    || $normalized['STATUS'] !== 'running'
    || $normalized['HEALTH_STATUS'] !== 'healthy'
    || $normalized['SERVICE_COUNT'] !== 1
    || $normalized['HOST_PORT'] !== '18080'
    || $normalized['DOMAIN'] !== 'app.example.test'
    || $normalized['REVISION'] !== 2
    || !$normalized['IS_SIMPLE']
    || $normalized['COMMAND'] !== 'nginx -g daemon off;'
    || $normalized['IMAGE'] !== 'example.test/web:v2'
    || $normalized['CONTAINER_PORT'] !== '8080'
    || $normalized['RESTART_POLICY'] !== 'unless-stopped'
    || $normalized['ENV'] !== 'APP_ENV=testing'
    || $normalized['MOUNTS'] !== 'data:/usr/share/nginx/html'
    || $normalized['AUTO_START'] !== 'yes'
    || $normalized['HEALTHCHECK_TARGET'] !== '/health') {
    fwrite(STDERR, "FAIL: Compose project normalization is incomplete\n");
    exit(1);
}
if (empty($normalized['DRIFT']['MATCH'])
    || $normalized['DRIFT']['DRIFT_DIGEST'] !== str_repeat('d', 64)
    || $normalized['LAST_OPERATION']['ACTION'] !== 'reconcile'
    || $normalized['LAST_OPERATION']['RESULT'] !== 'succeeded') {
    fwrite(STDERR, "FAIL: Drift or typed operation view data was dropped\n");
    exit(1);
}

if (vx_compose_normalize_project(array()) !== array()) {
    fwrite(STDERR, "FAIL: Empty command output normalized into a phantom project\n");
    exit(1);
}

$unavailable_health = vx_compose_health_payload('alice', 'app');
if ($unavailable_health['OWNER'] !== 'alice'
    || $unavailable_health['PROJECT'] !== 'app'
    || $unavailable_health['STATUS'] !== 'unknown'
    || $unavailable_health['HEALTH_STATUS'] !== 'unknown'
    || $unavailable_health['SOURCE'] !== 'command-unavailable'
    || $unavailable_health['AGE_SECONDS'] !== 0
    || $unavailable_health['FRESHNESS'] !== 'unavailable'
    || !preg_match(
        '/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/D',
        $unavailable_health['OBSERVED_AT']
    )
    || $unavailable_health['LAST_HEALTH_AT']
        !== $unavailable_health['OBSERVED_AT']
    || $unavailable_health['SERVICES'] !== array()) {
    fwrite(STDERR, "FAIL: Health command failure contract is incomplete\n");
    exit(1);
}

if (!vx_compose_project_key_is_valid('web-api')
    || vx_compose_project_key_is_valid('../web')
    || vx_compose_project_key_is_valid('UPPER')
    || !vx_compose_actor_can_access_owner('alice', 'alice')
    || vx_compose_actor_can_access_owner('alice', 'bob')) {
    fwrite(STDERR, "FAIL: Compose web identifiers or ownership checks are unsafe\n");
    exit(1);
}

if (!vx_compose_actor_can_manage_profile('alice', 'alice', 'standard')
    || !vx_compose_actor_can_manage_profile('admin', 'alice', 'standard')
    || vx_compose_actor_can_manage_profile('alice', 'bob', 'standard')
    || vx_compose_actor_can_manage_profile(
        'alice',
        'alice',
        'admin-approved'
    )) {
    fwrite(STDERR, "FAIL: Compose profile authority is incomplete\n");
    exit(1);
}

$standard_project = array(
    'OWNER' => 'alice',
    'PROFILE' => 'standard',
);
$privileged_project = array(
    'OWNER' => 'alice',
    'PROFILE' => 'admin-approved',
);
if (!vx_compose_actor_can_mutate_project(
    $standard_project,
    'alice',
    'alice'
) || vx_compose_actor_can_mutate_project(
    $privileged_project,
    'alice',
    'alice'
) || !vx_compose_actor_can_mutate_project(
    $privileged_project,
    'admin',
    'alice'
) || vx_compose_actor_can_mutate_project(
    $standard_project,
    'bob',
    'alice'
) || vx_compose_actor_can_mutate_project(
    $standard_project,
    'admin',
    'bob'
)) {
    fwrite(STDERR, "FAIL: Compose project mutation authority is incomplete\n");
    exit(1);
}

$_SESSION = array();
$digest_a = str_repeat('a', 64);
$digest_b = str_repeat('b', 64);
$preview_payload = array(
    'VALID' => true,
    'OWNER' => 'alice',
    'PROJECT' => 'app',
    'PROFILE' => 'standard',
    'MODE' => 'change',
    'PREVIEW_ID' => str_repeat('c', 32),
    'SOURCE_SHA256' => $digest_a,
    'CANDIDATE_SHA256' => $digest_b,
    'EXPECTED_CURRENT_REVISION' => 2,
    'EXPIRES_AT' => gmdate('Y-m-d\TH:i:s\Z', time() + 900),
    'SERVICES' => array(
        'ADDED' => array('worker'),
        'REMOVED' => array(),
        'CHANGED' => array('web'),
        'UNCHANGED' => array(),
    ),
    'ROUTES' => array(
        'UNCHANGED' => array('app.example.test'),
        'INVALIDATED' => array(),
        'RETARGET_REQUIRED' => array(),
    ),
    'RESOURCES' => array(
        'CURRENT' => array('MEMORY_MB' => 256),
        'CANDIDATE' => array('MEMORY_MB' => 512),
        'DELTA' => array('MEMORY_MB' => 256),
    ),
    'IMAGES' => array(
        'CURRENT_REFERENCES' => array('nginx:stable'),
        'CANDIDATE_REFERENCES' => array('nginx:stable'),
        'CURRENT_IDENTITIES' => array(
            'web' => array(
                'SCHEMA' => 2,
                'REFERENCE' => 'nginx:stable',
                'IMMUTABLE_REFERENCE' => 'nginx@sha256:immutable',
                'REGISTRY_DIGEST' => 'sha256:immutable',
                'IMAGE_ID' => 'sha256:immutable',
                'OS' => 'linux',
                'ARCHITECTURE' => 'amd64',
                'REPO_DIGESTS' => array('nginx@sha256:immutable'),
                'OCI_LABELS' => array(
                    'source' => 'https://example.test/source',
                    'revision' => 'revision-1',
                    'version' => '1.0.0',
                    'vendor' => 'Example',
                    'created' => '2026-07-31T00:00:00Z',
                ),
                'TRUST' => array(
                    'MODE' => 'disabled',
                    'DECISION' => 'disabled',
                    'PROFILE' => 'standard',
                    'PROFILE_VERSION' => 1,
                    'POLICY_VERSION' => 1,
                    'SIGNATURE' => array('STATE' => 'not-run'),
                    'VULNERABILITY' => array('STATE' => 'not-run'),
                    'EXCEPTION' => false,
                ),
            ),
        ),
    ),
);
if (!vx_compose_preview_payload_matches_contract($preview_payload)) {
    fwrite(STDERR, "FAIL: Valid Compose impact plan was rejected\n");
    exit(1);
}
$legacy_identity_payload = $preview_payload;
unset(
    $legacy_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['SCHEMA'],
    $legacy_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web'][
        'IMMUTABLE_REFERENCE'
    ],
    $legacy_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web'][
        'REGISTRY_DIGEST'
    ],
    $legacy_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['OCI_LABELS'],
    $legacy_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['TRUST']
);
if (!vx_compose_preview_payload_matches_contract($legacy_identity_payload)) {
    fwrite(STDERR, "FAIL: Production five-field image identity was rejected\n");
    exit(1);
}
$unknown_schema_payload = $preview_payload;
$unknown_schema_payload['IMAGES']['CURRENT_IDENTITIES']['web']['SCHEMA'] = 3;
if (vx_compose_preview_payload_matches_contract($unknown_schema_payload)) {
    fwrite(STDERR, "FAIL: Unknown image identity schema was accepted\n");
    exit(1);
}
$truncated_schema_payload = $preview_payload;
unset(
    $truncated_schema_payload['IMAGES']['CURRENT_IDENTITIES']['web']['TRUST']
);
if (vx_compose_preview_payload_matches_contract($truncated_schema_payload)) {
    fwrite(STDERR, "FAIL: Truncated schema-2 image identity was accepted\n");
    exit(1);
}
$hybrid_identity_payload = $legacy_identity_payload;
$hybrid_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web'][
    'IMMUTABLE_REFERENCE'
] = 'nginx@sha256:immutable';
if (vx_compose_preview_payload_matches_contract($hybrid_identity_payload)) {
    fwrite(STDERR, "FAIL: Schema-less hybrid image identity was accepted\n");
    exit(1);
}
$truncated_legacy_payload = $legacy_identity_payload;
unset(
    $truncated_legacy_payload['IMAGES']['CURRENT_IDENTITIES']['web']['OS']
);
if (vx_compose_preview_payload_matches_contract($truncated_legacy_payload)) {
    fwrite(STDERR, "FAIL: Truncated five-field image identity was accepted\n");
    exit(1);
}
$unsafe_identity_payload = $preview_payload;
$unsafe_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['TRUST'][
    'UNEXPECTED'
] = 'must-not-pass';
if (vx_compose_preview_payload_matches_contract($unsafe_identity_payload)) {
    fwrite(STDERR, "FAIL: Extra image trust metadata was accepted\n");
    exit(1);
}
$unsafe_identity_payload = $preview_payload;
$unsafe_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['OCI_LABELS'][
    'source'
] = 'password=must-not-pass';
if (vx_compose_preview_payload_matches_contract($unsafe_identity_payload)) {
    fwrite(STDERR, "FAIL: Sensitive OCI label metadata was accepted\n");
    exit(1);
}
$unsafe_identity_payload = $preview_payload;
$unsafe_identity_payload['IMAGES']['CURRENT_IDENTITIES']['web']['OCI_LABELS'][
    'source'
] = 'https://example.test/source?auth=must-not-pass';
if (vx_compose_preview_payload_matches_contract($unsafe_identity_payload)) {
    fwrite(STDERR, "FAIL: OCI auth query metadata was accepted\n");
    exit(1);
}
$preview_payload['source'] = '/tmp/upload-path-canary';
$preview_payload['DIAGNOSTICS'] = array(
    'SOURCE' => '/tmp/vx-compose-web.'.str_repeat('d', 32).'/compose.yaml',
    'nested' => array('source-path-sentinel'),
);
if (vx_compose_preview_payload_matches_contract($preview_payload)) {
    fwrite(STDERR, "FAIL: Unsafe Compose impact plan was accepted\n");
    exit(1);
}
$preview_record = vx_compose_preview_record($preview_payload, 'alice');
$preview_key = vx_compose_preview_store($preview_record);
if (!preg_match('/^[a-f0-9]{32}$/D', $preview_key)
    || !vx_compose_array_has_exact_keys(
        $_SESSION['vx_compose_previews'][$preview_key],
        array(
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
        )
    )
    || isset($_SESSION['vx_compose_previews'][$preview_key]['source'])
    || isset($preview_record['preview']['source'])
    || isset($preview_record['preview']['SOURCE'])
    || isset($preview_record['preview']['DIAGNOSTICS'])
    || $preview_record['preview']['SERVICES']['ADDED'] !== array('worker')
    || $preview_record['preview']['ROUTES']['UNCHANGED']
        !== array('app.example.test')
    || $preview_record['preview']['RESOURCES']['DELTA']['MEMORY_MB'] !== 256
    || vx_compose_preview_get($preview_key, 'alice', 'change') === array()
    || vx_compose_preview_get($preview_key, 'bob', 'change') !== array()) {
    fwrite(STDERR, "FAIL: Source-free Compose preview storage is unsafe\n");
    exit(1);
}
if (!vx_compose_preview_payload_is_source_free(array(
    'SOURCE_SHA256' => $digest_a,
    'ROUTE' => array('PATH' => '/health'),
))) {
    fwrite(STDERR, "FAIL: Digest or legitimate route path was rejected\n");
    exit(1);
}

$extra_record = $preview_record;
$extra_record['extra'] = 'must-not-persist';
if (vx_compose_preview_store($extra_record) !== '') {
    fwrite(STDERR, "FAIL: Extra preview session field was stored\n");
    exit(1);
}
foreach (array('source', 'SOURCE') as $source_field) {
    $source_record = $preview_record;
    $source_record[$source_field] = '/tmp/file';
    if (vx_compose_preview_store($source_record) !== '') {
        fwrite(STDERR, "FAIL: Top-level source field was stored\n");
        exit(1);
    }
}
$nested_source_record = $preview_record;
$nested_source_record['preview']['SERVICES']['SOURCE'] = '/tmp/file';
if (vx_compose_preview_store($nested_source_record) !== '') {
    fwrite(STDERR, "FAIL: Nested SOURCE field was stored\n");
    exit(1);
}
$nested_source_record = $preview_record;
$nested_source_record['preview']['SERVICES']['source'] = '/tmp/file';
if (vx_compose_preview_store($nested_source_record) !== '') {
    fwrite(STDERR, "FAIL: Nested source field was stored\n");
    exit(1);
}
$nested_path_record = $preview_record;
$nested_path_record['preview']['WARNINGS'] = array('upload-path-canary');
if (vx_compose_preview_store($nested_path_record) !== '') {
    fwrite(STDERR, "FAIL: Upload path canary was stored\n");
    exit(1);
}
$nested_path_record = $preview_record;
$nested_path_record['preview']['WARNINGS'] = array(
    '/tmp/vx-compose-web.'.str_repeat('8', 32).'/simple.spec',
);
if (vx_compose_preview_store($nested_path_record) !== '') {
    fwrite(STDERR, "FAIL: Protected simple.spec path was stored\n");
    exit(1);
}

$preview_key = vx_compose_preview_store($preview_record);
if (vx_compose_preview_get($preview_key, 'alice', 'add') !== array()) {
    fwrite(STDERR, "FAIL: Compose preview mode mismatch was accepted\n");
    exit(1);
}
$preview_key = vx_compose_preview_store($preview_record);
$_SESSION['vx_compose_previews'][$preview_key]['expires_at'] = gmdate(
    'Y-m-d\TH:i:s\Z',
    time() - 1
);
if (vx_compose_preview_get($preview_key, 'alice', 'change') !== array()) {
    fwrite(STDERR, "FAIL: Expired Compose preview was accepted\n");
    exit(1);
}
foreach (array('preview_id', 'source_sha', 'candidate_sha') as $invalid_field) {
    $invalid = $preview_record;
    $invalid[$invalid_field] = 'not-valid';
    if ($invalid_field === 'preview_id') {
        if (vx_compose_preview_store($invalid) !== '') {
            fwrite(STDERR, "FAIL: Invalid preview ID was stored\n");
            exit(1);
        }
        continue;
    }
    $preview_key = vx_compose_preview_store($invalid);
    if (vx_compose_preview_get($preview_key, 'alice', 'change') !== array()) {
        fwrite(STDERR, "FAIL: Invalid preview digest was accepted\n");
        exit(1);
    }
}
$preview_key = vx_compose_preview_store($preview_record);
$preview_post = array(
    'owner' => 'alice',
    'project' => 'app',
    'profile' => 'standard',
    'preview_id' => str_repeat('c', 32),
    'source_sha' => $digest_a,
    'candidate_sha' => $digest_b,
    'expected_revision' => '2',
);
if (!vx_compose_preview_post_matches($preview_record, $preview_post)) {
    fwrite(STDERR, "FAIL: Exact preview confirmation was rejected\n");
    exit(1);
}
$preview_post['owner'] = 'bob';
if (vx_compose_preview_post_matches($preview_record, $preview_post)) {
    fwrite(STDERR, "FAIL: Cross-owner preview confirmation was accepted\n");
    exit(1);
}
$preview_post['owner'] = 'alice';
$preview_post['profile'] = 'admin-approved';
if (vx_compose_preview_post_matches($preview_record, $preview_post)) {
    fwrite(STDERR, "FAIL: Forced admin-approved confirmation was accepted\n");
    exit(1);
}
$preview_post['profile'] = 'standard';
$preview_post['candidate_sha'] = str_repeat('d', 64);
if (vx_compose_preview_post_matches($preview_record, $preview_post)) {
    fwrite(STDERR, "FAIL: Altered preview digest was accepted\n");
    exit(1);
}
vx_compose_preview_forget($preview_key);
if (isset($_SESSION['vx_compose_previews'][$preview_key])
    || vx_compose_preview_get(str_repeat('e', 32), 'alice', 'change') !== array()) {
    fwrite(STDERR, "FAIL: Forgotten or stale preview token was accepted\n");
    exit(1);
}

$fixed_now = new DateTimeImmutable(
    '2026-07-25T00:00:00Z',
    new DateTimeZone('UTC')
);
if (!vx_compose_profile_expiry_is_valid(
    '2026-07-26T00:00:00Z',
    $fixed_now
) || vx_compose_profile_expiry_is_valid(
    '2028-07-26T00:00:00Z',
    $fixed_now
) || vx_compose_profile_expiry_is_valid(
    '../not-a-date',
    $fixed_now
)) {
    fwrite(STDERR, "FAIL: Compose profile expiry validation is incomplete\n");
    exit(1);
}

$admin_key = str_repeat('9', 32);
$admin_expires = gmdate('Y-m-d\TH:i:s\Z', time() + 86400);
if (!vx_compose_admin_expiry_store($admin_key, array(
        'actor' => 'admin',
        'owner' => 'alice',
        'project' => 'app',
        'profile' => 'admin-approved',
        'mode' => 'add',
        'admin_expires' => $admin_expires,
    ))
    || vx_compose_admin_expiry_get($admin_key, 'admin', 'add')[
        'admin_expires'
    ] !== $admin_expires
    || vx_compose_admin_expiry_get($admin_key, 'alice', 'add') !== array()) {
    fwrite(STDERR, "FAIL: Administrator expiry binding is unsafe\n");
    exit(1);
}

$quota = vx_compose_quota_state('alice', array(
    'DOCKER_PROJECTS' => '2',
    'U_DOCKER_PROJECTS' => '2',
));
if ($quota['limit'] !== 2 || $quota['used'] !== 2 || !$quota['reached']) {
    fwrite(STDERR, "FAIL: Compose project quota mapping is incomplete\n");
    exit(1);
}

$endpoint_project = vx_compose_normalize_project(array(
    'OWNER' => 'alice',
    'PROJECT' => 'advanced',
    'STATE' => 'running',
    'SERVICES' => array('api'),
    'SERVICE_SUMMARY' => array(
        'api' => array('PORTS' => array(
            '127.0.0.1:8420:8420/tcp',
            '127.0.0.1:8530:53/udp',
        )),
    ),
    'ROUTES' => array(
        'app.example.test' => array(
            'SCHEME' => 'https',
            'HOST_PORT' => 8420,
        ),
    ),
));
$expected_endpoints = array(
    array(
        'SERVICE' => 'api',
        'HOST_IP' => '127.0.0.1',
        'HOST_PORT' => '8420',
        'CONTAINER_PORT' => '8420',
        'PROTOCOL' => 'tcp',
        'DISPLAY' => '127.0.0.1:8420 → 8420/tcp',
    ),
    array(
        'SERVICE' => 'api',
        'HOST_IP' => '127.0.0.1',
        'HOST_PORT' => '8530',
        'CONTAINER_PORT' => '53',
        'PROTOCOL' => 'udp',
        'DISPLAY' => '127.0.0.1:8530 → 53/udp',
    ),
);
if ($endpoint_project['PUBLISHED_ENDPOINTS'] !== $expected_endpoints
    || $endpoint_project['PROJECT_ROUTE_COUNT'] !== 1
    || $endpoint_project['PROJECT_ROUTES']
        !== $endpoint_project['ROUTES']
    || $endpoint_project['MANAGED_ROUTE_TARGETS']
        !== array('https://127.0.0.1:8420')) {
    fwrite(STDERR, "FAIL: Published endpoint and route models are conflated\n");
    exit(1);
}

$endpoint_matrix = vx_compose_normalize_published_endpoints(array(
    'api' => array('PORTS' => array(
        '0.0.0.0:80:8080/tcp',
        '203.0.113.10:443:8443/tcp',
        '[::1]:5353:53/udp',
        '[2001:db8::10]:8000-8002:80-82/tcp',
        '',
        '127.0.0.1:0:80/tcp',
        '127.0.0.1:8000-8002:80-81/tcp',
        'localhost:80:80/tcp',
        '127.0.0.1:80/tcp',
        '127.0.0.1:80:80/sctp',
    )),
));
if (count($endpoint_matrix) !== 4
    || $endpoint_matrix[0]['HOST_IP'] !== '0.0.0.0'
    || $endpoint_matrix[1]['HOST_IP'] !== '203.0.113.10'
    || $endpoint_matrix[2]['HOST_IP'] !== '::1'
    || $endpoint_matrix[2]['PROTOCOL'] !== 'udp'
    || $endpoint_matrix[3]['HOST_PORT'] !== '8000-8002') {
    fwrite(STDERR, "FAIL: Published endpoint validation is incomplete\n");
    exit(1);
}

$revisions = vx_compose_revision_options(array(
    'REVISION' => 3,
    'REVISIONS' => array(
        array('REVISION' => 1),
        array('REVISION' => 3),
        array('REVISION' => 2),
    ),
));
if ($revisions !== array(3, 2, 1)) {
    fwrite(STDERR, "FAIL: Compose revision options are not stable\n");
    exit(1);
}

echo "Compose PHP helper tests passed.\n";
