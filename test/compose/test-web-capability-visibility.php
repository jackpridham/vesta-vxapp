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

// Render the actual Docker fragments without unrelated panel filesystem reads.
function render_docker_quota_fragment($root, $template, $quota, $actor)
{
    $user = $actor === 'admin' ? 'admin' : 'slave';
    $v_username = $key = $user;
    $panel = $data = array($user => $quota);
    $TAB = 'USER';
    $_SESSION = array('user' => $actor === 'admin-look' ? 'admin' : $user);
    if ($actor === 'admin-look') {
        $_SESSION['look'] = $user;
    }
    $source = file_get_contents($root.'/web/templates/'.$template.'.html');
    if (substr($template, -6) === '/panel') {
        $link = strpos($source, 'href="/list/docker/"');
        preg_match_all('/<\?php if\([^\r\n]*\{ \?>/', substr($source, 0, $link), $matches, PREG_OFFSET_CAPTURE);
        $opening = end($matches[0]);
        $start = $opening[1];
        $end = strpos($source, '<?php } ?>', $link) + strlen('<?php } ?>');
    } else {
        $label = strpos($source, "__('Docker')");
        if ($template === 'admin/edit_user') {
            $start = strpos($source, '<input', $label);
            $end = strpos($source, 'disabled>', $start) + strlen('disabled>');
        } else {
            $start = strpos($source, '<div class="l-unit__stat-col l-unit__stat-col--right">', $label);
            $end = strpos($source, '</div>', $start) + strlen('</div>');
        }
    }
    ob_start();
    eval('?>'.substr($source, $start, $end - $start));
    return ob_get_clean();
}

$entitled = array(
    'DOCKER_PROJECTS' => '2', 'U_DOCKER_PROJECTS' => '1',
    'DOCKER_CONTAINERS' => '0', 'U_DOCKER_CONTAINERS' => '0',
    'DOCKER_REGISTRY_MB' => '4096',
);
$disabled = array_merge($entitled, array(
    'DOCKER_PROJECTS' => '0', 'U_DOCKER_PROJECTS' => '0',
    'DOCKER_CONTAINERS' => '7', 'U_DOCKER_CONTAINERS' => '3',
));
foreach (array('admin', 'admin-look', 'slave') as $actor) {
    $template = $actor === 'admin' ? 'admin/panel' : 'user/panel';
    foreach (array($entitled, $disabled) as $quota) {
        $html = render_docker_quota_fragment($argv[1], $template, $quota, $actor);
        $visible = strpos($html, 'href="/list/docker/"') !== false;
        $expected = $quota['DOCKER_PROJECTS'] === '2';
        if ($visible !== $expected || ($visible && strpos($html, '<span>1</span>') === false)) {
            fwrite(STDERR, "FAIL: Compose navigation/count for $actor with project quota ".$quota['DOCKER_PROJECTS']."\n");
            exit(1);
        }
    }
}
foreach (array('admin/list_user', 'admin/edit_user', 'admin/list_packages') as $template) {
    $html = render_docker_quota_fragment($argv[1], $template, $entitled, 'admin-look');
    $text = trim(preg_replace('/\s+/', ' ', strip_tags($html)));
    $passed = $template === 'admin/edit_user'
        ? strpos($html, 'value="1 / 2"') !== false
        : ($text === ($template === 'admin/list_packages' ? '2 / Registry 4096 MB' : '1 / 2'));
    if (!$passed) {
        fwrite(STDERR, "FAIL: Compose quota summary in $template\n");
        exit(1);
    }
}
