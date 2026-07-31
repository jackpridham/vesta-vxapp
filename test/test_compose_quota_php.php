<?php

require_once dirname(__DIR__).'/web/inc/vx_compose.php';

$quota = vx_compose_quota_state('alice', array(
    'DOCKER_PROJECTS' => '2',
    'DOCKER_SERVICES' => '4',
    'DOCKER_CPUS' => '1.500',
    'DOCKER_MEMORY_MB' => '1024',
    'DOCKER_PIDS' => '256',
    'DOCKER_STORAGE_MB' => '2048',
    'DOCKER_PORTS' => '3',
    'DOCKER_SECRETS' => '2',
    'DOCKER_VOLUMES' => '5',
    'U_DOCKER_PROJECTS' => '2',
    'U_DOCKER_SERVICES' => '3',
    'U_DOCKER_CPUS' => '1.000',
    'U_DOCKER_MEMORY_MB' => '768',
    'U_DOCKER_PIDS' => '128',
    'U_DOCKER_STORAGE_MB' => '1024',
    'U_DOCKER_PORTS' => '2',
    'U_DOCKER_SECRETS' => '1',
    'U_DOCKER_VOLUMES' => '4',
));

if ($quota['limit'] !== 2 || $quota['used'] !== 2 || !$quota['reached']
    || count($quota['dimensions']) !== 9
    || $quota['dimensions']['DOCKER_PROJECTS']['used'] !== '2'
    || $quota['dimensions']['DOCKER_CPUS']['used'] !== '1.000'
    || $quota['dimensions']['DOCKER_MEMORY_MB']['unit'] !== 'MiB'
    || $quota['dimensions']['DOCKER_VOLUMES']['limit'] !== '5') {
    fwrite(STDERR, "FAIL: Compose quota mapping is incomplete\n");
    exit(1);
}

echo "Compose PHP quota tests passed.\n";
