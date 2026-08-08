<?php

require_once dirname(__DIR__).'/web/inc/vx_compose_package.php';

function fail_package_test($message)
{
    fwrite(STDERR, "FAIL: ".$message."\n");
    exit(1);
}

$expected = array(
    'DOCKER_PROJECTS' => '3',
    'DOCKER_SERVICES' => '8',
    'DOCKER_CPUS' => '2.500',
    'DOCKER_MEMORY_MB' => '4096',
    'DOCKER_PIDS' => '512',
    'DOCKER_STORAGE_MB' => '8192',
    'DOCKER_REGISTRY_MB' => '40960',
    'DOCKER_PORTS' => '6',
    'DOCKER_SECRETS' => '12',
    'DOCKER_VOLUMES' => '4',
);

if (vx_compose_package_normalize($expected) !== $expected) {
    fail_package_test('Compose package fields did not round-trip');
}

$fields = array(
    'DOCKER_PROJECTS',
    'DOCKER_SERVICES',
    'DOCKER_CPUS',
    'DOCKER_MEMORY_MB',
    'DOCKER_PIDS',
    'DOCKER_STORAGE_MB',
    'DOCKER_REGISTRY_MB',
    'DOCKER_PORTS',
    'DOCKER_SECRETS',
    'DOCKER_VOLUMES',
);
if (vx_compose_package_fields() !== $fields) {
    fail_package_test('Compose package field order changed');
}

$zero = array_fill_keys($fields, '0');
if (vx_compose_package_normalize($zero) !== $zero) {
    fail_package_test('zero Compose package limits were rejected');
}

$unlimited = array_fill_keys($fields, 'unlimited');
if (vx_compose_package_normalize($unlimited) !== $unlimited) {
    fail_package_test('unlimited Compose package limits were rejected');
}

$missing_defaults = array_fill_keys($fields, '0');
if (vx_compose_package_normalize(array()) !== $missing_defaults) {
    fail_package_test('missing Compose package fields did not use the documented 0 defaults');
}

$trimmed = $expected;
$trimmed['DOCKER_PROJECTS'] = ' 3 ';
if (vx_compose_package_normalize($trimmed) !== $expected) {
    fail_package_test('Compose package values were not trimmed');
}

$leading_zero = $expected;
$leading_zero['DOCKER_PROJECTS'] = '09';
$leading_zero['DOCKER_CPUS'] = '02.500';
$leading_zero_expected = $expected;
$leading_zero_expected['DOCKER_PROJECTS'] = '9';
if (vx_compose_package_normalize($leading_zero) !== $leading_zero_expected) {
    fail_package_test('leading-zero package limits were not normalized as base 10');
}

foreach (array(
    array('DOCKER_PROJECTS', '-1'),
    array('DOCKER_MEMORY_MB', '1.5'),
    array('DOCKER_PORTS', '1; touch /tmp/compose-package-test'),
    array('DOCKER_CPUS', '1.2345'),
    array('DOCKER_PROJECTS', '2147483648'),
    array('DOCKER_MEMORY_MB', '999999999999999999999999999999'),
    array('DOCKER_CPUS', '2147483648.000'),
) as $invalid) {
    $values = $expected;
    $values[$invalid[0]] = $invalid[1];
    if (vx_compose_package_normalize($values) !== false) {
        fail_package_test('malformed '.$invalid[0].' value was accepted');
    }
}

$maximum = $expected;
$maximum['DOCKER_PROJECTS'] = VX_COMPOSE_PACKAGE_MAX_VALUE;
if (vx_compose_package_normalize($maximum) !== $maximum) {
    fail_package_test('maximum bounded package limit was rejected');
}

$non_scalar = $expected;
$non_scalar['DOCKER_SERVICES'] = array('8');
$non_scalar_expected = $expected;
$non_scalar_expected['DOCKER_SERVICES'] = '0';
if (vx_compose_package_normalize($non_scalar) !== $non_scalar_expected) {
    fail_package_test('non-scalar Compose package fields did not use the documented 0 default');
}

if (vx_compose_package_normalize('not-an-array') !== false) {
    fail_package_test('non-array package values were accepted');
}

$lines = vx_compose_package_lines($expected);
if ($lines === false) {
    fail_package_test('valid package values did not serialize');
}
$line_list = explode("\n", rtrim($lines, "\n"));
if (count($line_list) !== count($fields)) {
    fail_package_test('package serialization emitted the wrong number of lines');
}
foreach ($fields as $index => $field) {
    $expected_line = $field."='".$expected[$field]."'";
    if ($line_list[$index] !== $expected_line) {
        fail_package_test('package serialization changed '.$field);
    }
}

if (vx_compose_package_lines(array('DOCKER_PROJECTS' => '-1')) !== false) {
    fail_package_test('invalid package values were serialized');
}

$measured = $expected;
$measured['U_DOCKER_REGISTRY_MB'] = '123';
$measured_lines = vx_compose_package_lines($measured);
if ($measured_lines === false || strpos($measured_lines, 'U_DOCKER_REGISTRY_MB') !== false) {
    fail_package_test('measured registry usage was accepted from a package form');
}

echo "Compose package form tests passed.\n";
