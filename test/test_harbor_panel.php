<?php
define('VESTA_CMD', '/usr/local/vesta/bin/');
require_once dirname(__DIR__).'/web/inc/vx_compose_package.php';
$files = array(
    dirname(__DIR__).'/web/inc/vx_compose_package.php',
    dirname(__DIR__).'/web/list/docker/index.php',
    dirname(__DIR__).'/web/templates/docker_list_shared.php',
    dirname(__DIR__).'/web/ajax/docker/router.php',
    dirname(__DIR__).'/web/ajax/docker/actions/harbor_publisher.php',
);
$source = '';
foreach ($files as $file) $source .= file_get_contents($file);
foreach (array('$myvesta_logged_user', 'escapeshellarg', 'harbor_publisher', 'PENDING_OPERATIONS', 'CERTIFICATE_STATE', 'PUBLISHER_ENABLED', 'registry-publisher-rotate') as $needle) {
    if (strpos($source, $needle) === false) { fwrite(STDERR, "FAIL: missing panel boundary $needle\n"); exit(1); }
}
foreach (array('integration.curl', 'backup.agekey', '/run/vesta-harbor', '/api/v2.0', 'registry-publisher-change', 'age1', 'publisher-secret') as $forbidden) {
    if (strpos($source, $forbidden) !== false) { fwrite(STDERR, "FAIL: protected panel detail $forbidden\n"); exit(1); }
}
echo "PASS: Harbor panel boundaries\n";
