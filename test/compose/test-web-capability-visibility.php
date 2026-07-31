<?php

define('VX_COMPOSE_CONTROLLER_TEST', true);
define('VESTA_CMD', '/unused/');

function __($value)
{
    return $value;
}

function vx_docker_is_admin_actor()
{
    return false;
}

function vx_compose_test_command_json($command, $arguments, $default)
{
    return $default;
}

require $argv[1].'/web/inc/vx_compose.php';

$docker_project = array(
    'OWNER' => 'alice',
    'PROJECT' => 'app',
    'PROFILE' => 'standard',
    'REVISION' => 2,
    'STATUS' => 'running',
    'STATE' => 'running',
    'HEALTH_STATUS' => 'healthy',
    'COMPOSE_PROJECT' => 'vx-alice-app',
    'SERVICES' => array(),
    'IS_SIMPLE' => false,
    'LAST_OPERATION' => array(),
);
$docker_project_owner = 'alice';
$docker_project_name = 'app';
$docker_project_health = array();
$docker_project_stats = array();
$docker_project_alerts = array();
$docker_project_audit = array();
$docker_project_routes = array();
$docker_project_secrets = array();
$docker_project_backups = array();
$docker_project_revisions = array();
$docker_project_capabilities = array();
$_SESSION = array('token' => 'test-token');

$cases = array(
    'viewer' => array(),
    'operator' => array('lifecycle'),
    'deployer' => array('preview', 'deploy', 'rollback'),
    'backup-operator' => array('backup', 'restore'),
    'secret-manager' => array('secret'),
    'revoked' => array(),
    'suspended' => array(),
);
foreach ($cases as $role => $allowed) {
    $user = $role;
    $docker_project_capabilities = array();
    foreach (array(
        'lifecycle', 'preview', 'deploy', 'rollback', 'backup',
        'restore', 'reconcile', 'secret', 'remove',
    ) as $capability) {
        $docker_project_capabilities[$capability] = in_array(
            $capability,
            $allowed,
            true
        );
    }
    ob_start();
    include $argv[1].'/web/templates/docker_project_shared.php';
    $rendered = ob_get_clean();
    $has_restart = strpos($rendered, 'Restart project') !== false;
    $has_update = strpos($rendered, 'Advanced update') !== false;
    $want_restart = in_array('lifecycle', $allowed, true);
    $want_update = in_array('preview', $allowed, true)
        && in_array('deploy', $allowed, true);
    if ($has_restart !== $want_restart || $has_update !== $want_update) {
        fwrite(
            STDERR,
            "FAIL: rendered detail action visibility mismatch for $role\n"
        );
        exit(1);
    }
}
