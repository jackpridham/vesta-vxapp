<?php

define('VESTA_CMD', '/usr/local/vesta/bin/');
define('VX_COMPOSE_CONTROLLER_TEST', true);
$GLOBALS['ingress_commands'] = array();

function vx_compose_test_command_json($command, $arguments, $default)
{
    $GLOBALS['ingress_commands'][] = array($command, $arguments);
    if ($command !== 'v-list-docker-project-ingress-consumers') {
        return $default;
    }
    if ($arguments[3] === 'admin') {
        return array(array(
            'OWNER' => 'consumer',
            'DOMAIN' => 'app.example.test',
            'HEADER_NAMES' => array('X-Protected-Name'),
        ));
    }
    return array('COUNT' => 1);
}

require_once dirname(__DIR__).'/web/inc/vx_compose.php';

$owner_payload = vx_compose_ingress_consumers_payload(
    'tenant-a',
    'app',
    'tenant-a'
);
$admin_payload = vx_compose_ingress_consumers_payload(
    'tenant-a',
    'app',
    'admin'
);
$invalid_payload = vx_compose_ingress_consumers_payload(
    'tenant-a',
    'app',
    '../admin'
);

if ($owner_payload !== array('COUNT' => 1)
    || count($admin_payload) !== 1
    || $invalid_payload !== array('COUNT' => 0)
    || count($GLOBALS['ingress_commands']) !== 2
    || $GLOBALS['ingress_commands'][0] !== array(
        'v-list-docker-project-ingress-consumers',
        array('tenant-a', 'app', 'json', 'tenant-a'),
    )
    || $GLOBALS['ingress_commands'][1] !== array(
        'v-list-docker-project-ingress-consumers',
        array('tenant-a', 'app', 'json', 'admin'),
    )) {
    fwrite(STDERR, "FAIL: Panel ingress actor binding is unsafe\n");
    exit(1);
}

echo "Compose ingress PHP tests passed.\n";
